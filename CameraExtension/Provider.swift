import CoreGraphics
import CoreMediaIO
import CoreText
import Foundation
import IOKit.audio
import os.log

private let log = Logger(subsystem: "de.procam.studio.camera", category: "extension")

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Gerät konnte nicht angelegt werden: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "ProCam" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

/// One device, two streams:
/// - the **source** stream is what Zoom, OBS, FaceTime … see as the camera;
/// - the **sink** stream is fed by ProCam Studio with the iPhone's frames.
///
/// A timer ticks at the output rate. Each tick it pulls whatever the sink has
/// and forwards it; if the Studio has gone quiet for a second, it sends a
/// placeholder card instead so the conferencing app never shows a frozen face.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStream!
    private var sink: SinkStream!

    private let timerQueue = DispatchQueue(label: "procam.ext.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame: UInt64 = 0
    private var placeholder: CVPixelBuffer?
    private var formatDescription: CMFormatDescription!

    override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: VirtualCameraIDs.deviceName,
            deviceID: UUID(uuidString: VirtualCameraIDs.deviceUID)!,
            legacyDeviceID: VirtualCameraIDs.deviceUID,
            source: self)

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: VirtualCameraIDs.width, height: VirtualCameraIDs.height,
            extensions: nil, formatDescriptionOut: &formatDescription)

        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 30),
            minFrameDuration: CMTime(value: 1, timescale: VirtualCameraIDs.maxFps),
            validFrameDurations: nil)

        source = SourceStream(
            name: "ProCam Video", id: UUID(uuidString: VirtualCameraIDs.sourceStreamUID)!,
            format: format, owner: self)
        sink = SinkStream(
            name: "ProCam Sink", id: UUID(uuidString: VirtualCameraIDs.sinkStreamUID)!,
            format: format, owner: self)

        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Streams konnten nicht angelegt werden: \(error)")
        }
        placeholder = Self.makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "ProCam" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Streaming

    func sourceStarted() {
        timerQueue.async { [self] in
            sourceClients += 1
            ensureTimer()
        }
    }

    func sourceStopped() {
        timerQueue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            stopTimerIfIdle()
        }
    }

    func sinkStarted(client: CMIOExtensionClient) {
        timerQueue.async { [self] in
            sinkClient = client
            ensureTimer()
        }
    }

    func sinkStopped() {
        timerQueue.async { [self] in
            sinkClient = nil
            stopTimerIfIdle()
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        // Pull at twice the top frame rate so a 60 fps feed never waits a
        // whole tick; ticks with nothing new cost nothing.
        let interval = 1.0 / Double(VirtualCameraIDs.maxFps * 2)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimerIfIdle() {
        if sourceClients == 0 && sinkClient == nil {
            timer?.cancel()
            timer = nil
        }
    }

    private var placeholderTick = 0
    private var consumePending = false

    private func tick() {
        let now = Self.hostTimeNs()
        // One pull outstanding at a time: whether CoreMediaIO answers an
        // empty queue at once or only when a frame arrives, requests can
        // never pile up behind each other.
        if let client = sinkClient, !consumePending {
            consumePending = true
            sink.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, _, _ in
                guard let self else { return }
                self.timerQueue.async {
                    self.consumePending = false
                    guard let sbuf else { return }
                    self.lastSinkFrame = Self.hostTimeNs()
                    if self.sourceClients > 0 {
                        self.source.stream.send(sbuf, discontinuity: [],
                                                hostTimeInNanoseconds: self.lastSinkFrame)
                    }
                    let output = CMIOExtensionScheduledOutput(
                        sequenceNumber: seq, hostTimeInNanoseconds: self.lastSinkFrame)
                    self.sink.stream.notifyScheduledOutputChanged(output)
                }
            }
        }

        // No fresh frame for a second: show the placeholder at 15 fps.
        guard sourceClients > 0, now - lastSinkFrame > 1_000_000_000 else { return }
        placeholderTick += 1
        guard placeholderTick % 8 == 0, let pb = placeholder else { return }
        if let sb = Self.sampleBuffer(pb, format: formatDescription, hostTimeNs: now) {
            source.stream.send(sb, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    static func hostTimeNs() -> UInt64 {
        UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
    }

    static func sampleBuffer(_ pb: CVPixelBuffer, format: CMFormatDescription,
                             hostTimeNs: UInt64) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(hostTimeNs), timescale: CMTimeScale(NSEC_PER_SEC)),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    /// "Waiting for iPhone" card, drawn once.
    private static func makePlaceholder() -> CVPixelBuffer? {
        let w = Int(VirtualCameraIDs.width), h = Int(VirtualCameraIDs.height)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Camera-lens ring.
        let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2 + 70)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: CGRect(x: center.x - 70, y: center.y - 70, width: 140, height: 140))
        ctx.setFillColor(CGColor(red: 1, green: 0.27, blue: 0.23, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))

        func draw(_ text: String, size: CGFloat, alpha: CGFloat, y: CGFloat, weight: CGFloat) {
            let font = CTFontCreateWithName("SF Pro Display" as CFString, size, nil)
            let traits = [kCTFontWeightTrait: weight] as CFDictionary
            let desc = CTFontDescriptorCreateWithAttributes(
                [kCTFontTraitsAttribute: traits] as CFDictionary)
            let weighted = CTFontCreateCopyWithAttributes(font, size, nil, desc)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): weighted,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (CGFloat(w) - CGFloat(width)) / 2, y: y)
            CTLineDraw(line, ctx)
        }
        draw("ProCam", size: 64, alpha: 0.92, y: CGFloat(h) / 2 - 90, weight: 0.4)
        draw("Warte auf das iPhone – ProCam Studio öffnen", size: 30, alpha: 0.5,
             y: CGFloat(h) / 2 - 150, weight: 0)
        return pb
    }
}

// MARK: - Streams

final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: DeviceSource

    init(name: String, id: UUID, format: CMIOExtensionStreamFormat, owner: DeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: 30) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { owner.sourceStarted() }
    func stopStream() throws { owner.sourceStopped() }
}

final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: DeviceSource
    private var client: CMIOExtensionClient?

    init(name: String, id: UUID, format: CMIOExtensionStreamFormat, owner: DeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: 30) }
        // A short queue: a late frame is worth less than a dropped one.
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { return }
        owner.sinkStarted(client: client)
    }

    func stopStream() throws {
        owner.sinkStopped()
    }
}
