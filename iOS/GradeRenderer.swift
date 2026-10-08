import CoreVideo
import Metal
import MetalPerformanceShaders
import Vision

/// Must match `GradeUniforms` in Grade.metal.
private struct GradeUniforms {
    var fullRange: Float = 0
    var bt2020: Float = 0
    var logDecode: Float = 0
    var logRaw: Float = 0
    var exposure: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var vibrance: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var blackPoint: Float = 0
    var liftR: Float = 0, liftG: Float = 0, liftB: Float = 0
    var gammaR: Float = 1, gammaG: Float = 1, gammaB: Float = 1
    var gainR: Float = 1, gainG: Float = 1, gainB: Float = 1
    var vignette: Float = 0
    var sharpen: Float = 0
    var lutIntensity: Float = 0
    var lutSize: Float = 2
}

/// Turns a camera YUV frame into a graded BGRA frame on the GPU.
///
/// Everything runs on the caller's queue and waits for the GPU, so the
/// returned buffer is complete. At webcam resolutions the whole pass costs a
/// few milliseconds; waiting keeps the pipeline free of in-flight bookkeeping.
final class GradeRenderer {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gradePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var intermediate: MTLTexture?
    private var blurred: MTLTexture?
    private var blurKernel: MPSImageGaussianBlur?
    private var blurSigma: Float = 0

    private var lutTexture: MTLTexture
    private var lutSize = 2
    private var hasLut = false
    private let lutLock = NSLock()

    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let sequenceHandler = VNSequenceRequestHandler()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let gradeFn = lib.makeFunction(name: "grade"),
              let compFn = lib.makeFunction(name: "compositeBlur"),
              let grade = try? device.makeComputePipelineState(function: gradeFn),
              let comp = try? device.makeComputePipelineState(function: compFn)
        else { return nil }
        self.device = device
        self.queue = queue
        self.gradePipeline = grade
        self.compositePipeline = comp
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        lutTexture = Self.makeIdentityLut(device: device)
    }

    // MARK: LUT

    func setLUT(_ lut: CubeLUT?) {
        lutLock.lock(); defer { lutLock.unlock() }
        guard let lut else {
            hasLut = false
            return
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = lut.size
        desc.height = lut.size
        desc.depth = lut.size
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        lut.rgba.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, lut.size, lut.size, lut.size),
                        mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: lut.size * 16, bytesPerImage: lut.size * lut.size * 16)
        }
        lutTexture = tex
        lutSize = lut.size
        hasLut = true
    }

    private static func makeIdentityLut(device: MTLDevice) -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = 2; desc.height = 2; desc.depth = 2
        desc.usage = .shaderRead
        let tex = device.makeTexture(descriptor: desc)!
        var data: [Float] = []
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            data += [Float(r), Float(g), Float(b), 1]
        } } }
        data.withUnsafeBytes {
            tex.replace(region: MTLRegionMake3D(0, 0, 0, 2, 2, 2), mipmapLevel: 0, slice: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 32, bytesPerImage: 64)
        }
        return tex
    }

    // MARK: Render

    func process(_ input: CVPixelBuffer, settings s: CameraSettings) -> CVPixelBuffer? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let format = CVPixelBufferGetPixelFormatType(input)
        // Chroma is sampled with normalised coordinates, so 4:2:0 and 4:2:2
        // (Apple Log) need no separate path — only the bit depth matters.
        let tenBit = CameraEngine.isTenBit(format)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange

        guard let luma = makeTexture(cache, input, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
              let chroma = makeTexture(cache, input, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let out = makeOutputBuffer(width: width, height: height),
              let outTex = makeTexture(cache, out, plane: 0, format: .bgra8Unorm)
        else { return nil }

        var u = uniforms(s, fullRange: fullRange)
        lutLock.lock()
        let lut = lutTexture
        lutLock.unlock()

        // Blur only when a mask actually came back; otherwise grade straight
        // into the output so a Vision hiccup never produces an empty frame.
        let maskTex = s.backgroundBlur
            ? personMask(input).flatMap { makeTexture(cache, $0, plane: 0, format: .r8Unorm) }
            : nil
        if maskTex != nil { ensureBlurTargets(width: width, height: height, amount: s.backgroundBlurAmount) }
        let useBlur = maskTex != nil && intermediate != nil && blurred != nil && blurKernel != nil

        guard let cmd = queue.makeCommandBuffer() else { return nil }

        let gradeTarget = useBlur ? intermediate! : CVMetalTextureGetTexture(outTex)!
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(gradePipeline)
            enc.setTexture(CVMetalTextureGetTexture(luma), index: 0)
            enc.setTexture(CVMetalTextureGetTexture(chroma), index: 1)
            enc.setTexture(lut, index: 2)
            enc.setTexture(gradeTarget, index: 3)
            enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            dispatch(enc, gradePipeline, width, height)
            enc.endEncoding()
        }

        if useBlur, let maskTex, let blurKernel, let intermediate, let blurred {
            blurKernel.encode(commandBuffer: cmd, sourceTexture: intermediate, destinationTexture: blurred)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(compositePipeline)
                enc.setTexture(intermediate, index: 0)
                enc.setTexture(blurred, index: 1)
                enc.setTexture(CVMetalTextureGetTexture(maskTex), index: 2)
                enc.setTexture(CVMetalTextureGetTexture(outTex), index: 3)
                dispatch(enc, compositePipeline, width, height)
                enc.endEncoding()
            }
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        // The CVMetalTexture wrappers must outlive the GPU work.
        _ = (luma, chroma, outTex, maskTex)
        return out
    }

    private func uniforms(_ s: CameraSettings, fullRange: Bool) -> GradeUniforms {
        let g = s.grade
        var u = GradeUniforms()
        u.fullRange = fullRange ? 1 : 0
        u.bt2020 = s.appleLog ? 1 : 0
        u.logDecode = (s.appleLog && g.logToRec709) ? 1 : 0
        u.logRaw = (s.appleLog && !g.logToRec709) ? 1 : 0
        u.exposure = g.exposure
        u.contrast = g.contrast
        u.saturation = g.saturation
        u.vibrance = g.vibrance
        u.temperature = g.temperature
        u.tint = g.tint
        u.highlights = g.highlights
        u.shadows = g.shadows
        u.blackPoint = g.blackPoint
        u.liftR = g.lift.r; u.liftG = g.lift.g; u.liftB = g.lift.b
        u.gammaR = g.gamma.r; u.gammaG = g.gamma.g; u.gammaB = g.gamma.b
        u.gainR = g.gain.r; u.gainG = g.gain.g; u.gainB = g.gain.b
        u.vignette = g.vignette
        u.sharpen = g.sharpen
        lutLock.lock()
        u.lutIntensity = (hasLut && g.lutEnabled) ? g.lutIntensity : 0
        u.lutSize = Float(lutSize)
        lutLock.unlock()
        return u
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = p.threadExecutionWidth
        let th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private func personMask(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        do {
            try sequenceHandler.perform([segmentation], on: input, orientation: .up)
            return segmentation.results?.first?.pixelBuffer
        } catch {
            return nil
        }
    }

    private func ensureBlurTargets(width: Int, height: Int, amount: Float) {
        if intermediate?.width != width || intermediate?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            intermediate = device.makeTexture(descriptor: desc)
            blurred = device.makeTexture(descriptor: desc)
        }
        // Scale with resolution so the look is the same at 720p and 4K.
        let sigma = max(1, amount * 30 * Float(height) / 1080)
        if blurKernel == nil || abs(sigma - blurSigma) > 0.5 {
            let k = MPSImageGaussianBlur(device: device, sigma: sigma)
            k.edgeMode = .clamp
            blurKernel = k
            blurSigma = sigma
        }
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    private func makeTexture(_ cache: CVMetalTextureCache, _ pb: CVPixelBuffer, plane: Int,
                             format: MTLPixelFormat) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, format, w, h, planar ? plane : 0, &tex)
        return status == kCVReturnSuccess ? tex : nil
    }
}
