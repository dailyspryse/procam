import MetalKit
import SwiftUI

struct OverlayOptions: Equatable, Codable {
    var zebra = false
    var zebraLevel: Float = 0.95
    var peaking = false
    var peakThreshold: Float = 0.12
    var falseColor = false
    var grid = false
    var safeArea = false
}

private struct PreviewUniforms {
    var scale: SIMD2<Float>
    var texel: SIMD2<Float>
    var zebra: Float
    var zebraLevel: Float
    var peaking: Float
    var peakThreshold: Float
    var falseColor: Float
    var time: Float
}

/// Holds the newest decoded frame. The decoder writes, the display link reads.
final class FrameStore {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private(set) var generation = 0

    func put(_ pb: CVPixelBuffer) {
        lock.lock(); frame = pb; generation &+= 1; lock.unlock()
    }

    func clear() {
        lock.lock(); frame = nil; generation &+= 1; lock.unlock()
    }

    func take() -> (CVPixelBuffer?, Int) {
        lock.lock(); defer { lock.unlock() }
        return (frame, generation)
    }
}

/// Metal preview with monitoring overlays, redrawn on the display's refresh.
struct PreviewView: NSViewRepresentable {
    let store: FrameStore
    var overlays: OverlayOptions

    func makeCoordinator() -> Renderer { Renderer(store: store) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = context.coordinator.device
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.framebufferOnly = true
        v.delegate = context.coordinator
        // The decoded frames are sRGB-encoded already; tag the layer so macOS
        // does not colour-manage them a second time.
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.overlays = overlays
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private var cache: CVMetalTextureCache?
        private let store: FrameStore
        private let start = CACurrentMediaTime()
        var overlays = OverlayOptions()

        init(store: FrameStore) {
            self.store = store
            device = MTLCreateSystemDefaultDevice()!
            queue = device.makeCommandQueue()!
            let lib = device.makeDefaultLibrary()!
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "previewVertex")
            desc.fragmentFunction = lib.makeFunction(name: "previewFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try! device.makeRenderPipelineState(descriptor: desc)
            super.init()
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

            let (frame, _) = store.take()
            if let frame, let cache {
                let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
                var cvTex: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame, nil, .bgra8Unorm, w, h, 0, &cvTex)
                if let cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
                    let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
                    let imgAspect = Float(w) / Float(h)
                    let scale: SIMD2<Float> = imgAspect > viewAspect
                        ? [1, viewAspect / imgAspect]
                        : [imgAspect / viewAspect, 1]
                    let o = overlays
                    var u = PreviewUniforms(
                        scale: scale, texel: [1 / Float(w), 1 / Float(h)],
                        zebra: o.zebra ? 1 : 0, zebraLevel: o.zebraLevel,
                        peaking: o.peaking ? 1 : 0, peakThreshold: o.peakThreshold,
                        falseColor: o.falseColor ? 1 : 0,
                        time: Float(CACurrentMediaTime() - start))
                    enc.setRenderPipelineState(pipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
                    enc.setFragmentTexture(tex, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    cmd.addCompletedHandler { _ in _ = cvTex }
                }
            }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}

/// Where the image sits inside a view of the given size (aspect-fit).
func fittedRect(image: CGSize, in container: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: container) }
    let s = min(container.width / image.width, container.height / image.height)
    let size = CGSize(width: image.width * s, height: image.height * s)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                  width: size.width, height: size.height)
}
