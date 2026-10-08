import CoreMediaIO
import Foundation
import SystemExtensions
import VideoToolbox

/// Feeds frames into the camera extension's sink stream.
///
/// The extension runs in its own sandboxed process. The documented way in is
/// CoreMediaIO's C API: find our device by UID, take its sink stream, get the
/// stream's buffer queue and enqueue sample buffers there.
final class VirtualCameraSink {

    private(set) var isReady = false
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDesc: CMFormatDescription?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()

    init() {
        // Without this, CoreMediaIO hides devices from DAL plug-ins and
        // extensions that are not "screen capture" devices from this process.
        var allow: UInt32 = 1
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)

        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCVPixelFormatType_32BGRA,
            width: VirtualCameraIDs.width, height: VirtualCameraIDs.height,
            extensions: nil, formatDescriptionOut: &formatDesc)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        if let transfer {
            // Letterbox rather than stretch when the phone sends portrait.
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_Letterbox)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(VirtualCameraIDs.width),
            kCVPixelBufferHeightKey as String: Int(VirtualCameraIDs.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// Looks for the extension's device; cheap enough to call every second
    /// until it shows up (it appears only after the extension is approved).
    @discardableResult
    func connectIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isReady { return true }
        guard let device = Self.findDevice(uid: VirtualCameraIDs.deviceUID),
              let sink = Self.sinkStream(of: device) else { return false }

        var q: Unmanaged<CMSimpleQueue>?
        let st = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q)
        guard st == noErr, let q else { return false }
        queue = q.takeRetainedValue()
        guard CMIODeviceStartStream(device, sink) == noErr else {
            queue = nil
            return false
        }
        deviceID = device
        streamID = sink
        isReady = true
        return true
    }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if isReady { CMIODeviceStopStream(deviceID, streamID) }
        isReady = false
        queue = nil
    }

    func send(_ pb: CVPixelBuffer) {
        lock.lock()
        guard isReady, let queue, let formatDesc else { lock.unlock(); return }
        lock.unlock()

        // Drop rather than queue when the extension is behind.
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

        let frame: CVPixelBuffer
        if CVPixelBufferGetWidth(pb) == Int(VirtualCameraIDs.width),
           CVPixelBufferGetHeight(pb) == Int(VirtualCameraIDs.height) {
            frame = pb
        } else {
            guard let pool, let transfer else { return }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let out, VTPixelTransferSessionTransferImage(transfer, from: pb, to: out) == noErr
            else { return }
            frame = out
        }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: frame, formatDescription: formatDesc,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sb).toOpaque())
    }

    // MARK: CoreMediaIO lookup

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func findDevice(uid: String) -> CMIOObjectID? {
        for dev in objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) {
            var addr = address(kCMIODevicePropertyDeviceUID)
            var cf: Unmanaged<CFString>?
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard CMIOObjectGetPropertyData(dev, &addr, 0, nil, size, &used, &cf) == noErr,
                  let value = cf?.takeRetainedValue() else { continue }
            if (value as String) == uid { return dev }
        }
        return nil
    }

    private static func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        // Direction 1 = input to the device, i.e. the sink; source is 0.
        for stream in objectIDs(of: device, selector: kCMIODevicePropertyStreams) {
            var addr = address(kCMIOStreamPropertyDirection)
            var direction: UInt32 = 0
            var used: UInt32 = 0
            if CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                         &used, &direction) == noErr, direction == 1 {
                return stream
            }
        }
        // Fall back to the order the extension adds them in.
        let streams = objectIDs(of: device, selector: kCMIODevicePropertyStreams)
        return streams.count > 1 ? streams[1] : nil
    }
}

/// Installs / updates the camera extension through the SystemExtensions API.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {

    enum Outcome { case installed, needsApproval, failed(String) }
    var onOutcome: ((Outcome) -> Void)?

    func activate() {
        let r = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: VirtualCameraIDs.extensionBundleID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func deactivate() {
        let r = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: VirtualCameraIDs.extensionBundleID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onOutcome?(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        onOutcome?(.installed)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        var msg = ns.localizedDescription
        if ns.domain == OSSystemExtensionErrorDomain,
           ns.code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
            msg = "ProCam Studio muss im Ordner „Programme“ liegen."
        }
        onOutcome?(.failed(msg))
    }
}
