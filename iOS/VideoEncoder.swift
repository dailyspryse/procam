import CoreMedia
import QuartzCore
import VideoToolbox

/// Hardware HEVC/H.264 encoder tuned for latency, not for archiving.
///
/// Settings carried over from Beamer, where each was measured on hardware:
/// no frame reordering (B-frames cost a full frame on both ends), RealTime,
/// at most one frame held inside the encoder, and a burst cap so keyframes do
/// not flood the Wi-Fi queue.
final class VideoEncoder {

    struct Frame {
        let sample: Data       // AVCC, length-prefixed NAL units
        let keyframe: Bool
        let ptsUs: UInt64
    }

    var onFrame: ((Frame) -> Void)?
    var onFormat: ((VideoFormat) -> Void)?
    var onEncodeError: (() -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var config: (codec: VideoCodec, width: Int, height: Int, fps: Double, bitrate: Int)?
    private var forceKeyframe = false
    private var lastFormat: VideoFormat?

    private(set) var encodedFrames = 0

    /// Rebuilds the session if codec or size changed; bitrate and frame rate
    /// are updated live.
    func ensure(codec: VideoCodec, width: Int, height: Int, fps: Double, bitrateMbps: Double) {
        let bitrate = Int(bitrateMbps * 1_000_000)
        lock.lock()
        let current = config
        lock.unlock()

        if let c = current, c.codec == codec, c.width == width, c.height == height, session != nil {
            if c.bitrate != bitrate || c.fps != fps, let s = session {
                applyRate(s, bitrate: bitrate, fps: fps)
                lock.withLock { config = (codec, width, height, fps, bitrate) }
            }
            return
        }
        start(codec: codec, width: width, height: height, fps: fps, bitrate: bitrate)
    }

    private func start(codec: VideoCodec, width: Int, height: Int, fps: Double, bitrate: Int) {
        stop()
        var out: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &out)
        guard status == noErr, let s = out else { return }

        set(s, kVTCompressionPropertyKey_RealTime, true)
        set(s, kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(s, kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // No MaxFrameDelayCount: forcing it to 1 made the 4K HEVC encoder
        // block forever in EncodeFrame after some format switches. RealTime
        // without reordering already keeps the delay at about one frame.
        set(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(s, kVTCompressionPropertyKey_MaximizePowerEfficiency, false)
        set(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0)
        applyRate(s, bitrate: bitrate, fps: fps)
        VTCompressionSessionPrepareToEncodeFrames(s)

        lock.withLock {
            session = s
            config = (codec, width, height, fps, bitrate)
            lastFormat = nil
            forceKeyframe = true
        }
    }

    private func applyRate(_ s: VTCompressionSession, bitrate: Int, fps: Double) {
        set(s, kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(s, kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(fps * 2))
        let burstBytes = Double(bitrate) / 8.0 * 1.5
        set(s, kVTCompressionPropertyKey_DataRateLimits, [burstBytes, 1.0] as CFArray)
    }

    private func set(_ s: VTCompressionSession, _ key: CFString, _ value: Any) {
        // Unsupported keys are rejected per encoder; the encode works anyway.
        _ = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
    }

    func requestKeyframe() {
        lock.withLock { forceKeyframe = true }
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard let s = session else { lock.unlock(); return }
        let force = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let props: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { onEncodeError?() }
    }

    fileprivate func handle(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb),
              let fmt = CMSampleBufferGetFormatDescription(sb),
              let block = CMSampleBufferGetDataBuffer(sb) else { return }

        let keyframe = Self.isKeyframe(sb)
        if keyframe, let format = makeFormat(fmt), format != lastFormat {
            lastFormat = format
            onFormat?(format)
        }

        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr else { return }
        let data = Data(bytes: ptr, count: length)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        encodedFrames += 1
        onFrame?(Frame(sample: data, keyframe: keyframe,
                       ptsUs: UInt64(max(0, pts.seconds * 1_000_000))))
    }

    private func makeFormat(_ fmt: CMFormatDescription) -> VideoFormat? {
        guard let c = config else { return nil }
        var sets: [Data] = []
        var count = 0
        var nalLen: Int32 = 4
        let isHEVC = c.codec == .hevc

        func get(_ i: Int) -> Data? {
            var p: UnsafePointer<UInt8>?
            var size = 0
            let st = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
            guard st == noErr, let p else { return nil }
            return Data(bytes: p, count: size)
        }

        guard let first = get(0) else { return nil }
        sets.append(first)
        if count > 1 {
            for i in 1..<count {
                guard let d = get(i) else { return nil }
                sets.append(d)
            }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        return VideoFormat(codec: c.codec, width: Int(dims.width), height: Int(dims.height),
                           parameterSets: sets, nalLengthSize: Int(nalLen))
    }

    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[CFString: Any]], let first = arr.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    func stop() {
        lock.lock()
        let s = session
        session = nil
        config = nil
        lock.unlock()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    deinit { stop() }
}

private func encoderCallback(refcon: UnsafeMutableRawPointer?, frameRefcon: UnsafeMutableRawPointer?,
                             status: OSStatus, flags: VTEncodeInfoFlags, sb: CMSampleBuffer?) {
    guard status == noErr, let refcon, let sb, !flags.contains(.frameDropped) else { return }
    Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().handle(sb)
}

/// Runs the encoder off the camera thread and replaces it if it hangs.
///
/// VideoToolbox can block inside EncodeFrame indefinitely (seen on 4K format
/// switches). On the camera thread that froze the whole camera. Here a hung
/// encoder is abandoned after a second and a fresh one takes over; frames
/// arriving while an encode is still running are dropped, never queued.
final class EncoderHost {
    var onFrame: ((VideoEncoder.Frame) -> Void)?
    var onFormat: ((VideoFormat) -> Void)?
    var onEncodeError: (() -> Void)?

    private let lock = NSLock()
    private var current: VideoEncoder!
    private var busySince: CFTimeInterval?
    /// Hung encoders are kept alive but never touched again: invalidating
    /// one would block just like the call that hung.
    private var abandoned: [VideoEncoder] = []
    private(set) var resets = 0
    private(set) var busyDrops = 0
    private let queue = DispatchQueue(label: "procam.encode", qos: .userInteractive,
                                      attributes: .concurrent)

    init() { current = make() }

    private func make() -> VideoEncoder {
        let enc = VideoEncoder()
        enc.onFrame = { [weak self, weak enc] f in
            guard let self, let enc, self.isCurrent(enc) else { return }
            self.onFrame?(f)
        }
        enc.onFormat = { [weak self, weak enc] f in
            guard let self, let enc, self.isCurrent(enc) else { return }
            self.onFormat?(f)
        }
        enc.onEncodeError = { [weak self] in self?.onEncodeError?() }
        return enc
    }

    private func isCurrent(_ enc: VideoEncoder) -> Bool {
        lock.withLock { current === enc }
    }

    func submit(_ pb: CVPixelBuffer, pts: CMTime, settings s: CameraSettings) {
        lock.lock()
        if let since = busySince {
            if CACurrentMediaTime() - since > 1.0 {
                abandoned.append(current)
                if abandoned.count > 4 { abandoned.removeFirst() }
                current = make()
                busySince = nil
                resets += 1
            } else {
                busyDrops += 1
                lock.unlock()
                return
            }
        }
        let enc: VideoEncoder = current
        busySince = CACurrentMediaTime()
        lock.unlock()

        queue.async { [weak self] in
            enc.ensure(codec: s.codec, width: CVPixelBufferGetWidth(pb),
                       height: CVPixelBufferGetHeight(pb), fps: s.fps, bitrateMbps: s.bitrateMbps)
            enc.encode(pb, pts: pts)
            guard let self else { return }
            self.lock.withLock { if self.current === enc { self.busySince = nil } }
        }
    }

    func requestKeyframe() {
        lock.withLock { current }.requestKeyframe()
    }

    var debugState: String {
        lock.withLock { "encResets=\(resets) encBusyDrop=\(busyDrops)" }
    }
}
