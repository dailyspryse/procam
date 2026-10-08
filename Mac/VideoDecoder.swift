import CoreMedia
import VideoToolbox

/// Hardware decoder producing BGRA IOSurface buffers that Metal, the virtual
/// camera and the scopes can all read without another conversion.
final class VideoDecoder {

    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onNeedKeyframe: (() -> Void)?

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var format: VideoFormat?
    private var waitingForKeyframe = true

    func setFormat(_ f: VideoFormat) {
        guard f != format else { return }
        invalidate()
        format = f
        guard let desc = Self.makeDescription(f) else { return }
        formatDesc = desc

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let spec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: desc, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &s)
        guard st == noErr, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        waitingForKeyframe = true
    }

    func decode(sample: Data, ptsUs: UInt64, keyframe: Bool) {
        guard let session, let formatDesc else {
            onNeedKeyframe?()
            return
        }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return }
        sample.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: sample.count)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = sample.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return }

        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status != noErr || image == nil {
                self.waitingForKeyframe = true
                self.onNeedKeyframe?()
                return
            }
            self.onFrame?(image!, ptsUs)
        }
        if status != noErr {
            waitingForKeyframe = true
            onNeedKeyframe?()
            // A broken session (e.g. after sleep) has to be rebuilt.
            if status == kVTInvalidSessionErr, let f = format {
                format = nil
                setFormat(f)
            }
        }
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDesc = nil
        format = nil
    }

    private static func makeDescription(_ f: VideoFormat) -> CMVideoFormatDescription? {
        // Copy each parameter set into stable memory for the C call.
        let buffers = f.parameterSets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = f.parameterSets.map(\.count)

        var desc: CMVideoFormatDescription?
        let st: OSStatus
        switch f.codec {
        case .hevc:
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(f.nalLengthSize),
                extensions: nil, formatDescriptionOut: &desc)
        case .h264:
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(f.nalLengthSize),
                formatDescriptionOut: &desc)
        }
        return st == noErr ? desc : nil
    }
}
