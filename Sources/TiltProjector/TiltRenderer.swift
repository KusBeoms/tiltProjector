import AppKit
import Metal
import MetalKit
import CoreVideo
import simd

private let tiltShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 c0;
    float4 c1;
    float4 c2;
    float4 bg;
    float scale;
    float srcAspect;
    float outAspect;
    float dist;
};

struct VOut {
    float4 position [[position]];
    float2 ndc;
};

vertex VOut tilt_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    VOut o;
    o.position = float4(p, 0.0, 1.0);
    o.ndc = float2(p.x * u.outAspect, p.y);
    return o;
}

fragment float4 tilt_fragment(VOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c0 = u.c0.xyz, c1 = u.c1.xyz, c2 = u.c2.xyz;
    float3 ray = float3(in.ndc.x, in.ndc.y, u.dist);
    float denom = dot(c2, ray);
    if (fabs(denom) < 1e-6) return u.bg;
    float t = c2.z * u.dist / denom;
    if (t <= 0.0) return u.bg;
    float3 p = ray * t - float3(0.0, 0.0, u.dist);
    float lx = dot(c0, p);
    float ly = dot(c1, p);
    float2 uv = float2(lx / (2.0 * u.scale * u.srcAspect) + 0.5, 0.5 - ly / (2.0 * u.scale));
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return u.bg;
    return float4(tex.sample(s, uv).rgb, 1.0);
}
"""

private struct TiltUniforms {
    var c0: SIMD4<Float>
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var bg: SIMD4<Float>
    var scale: Float
    var srcAspect: Float
    var outAspect: Float
    var dist: Float
}

final class TiltRenderer: NSObject, MTKViewDelegate {
    private let model: TiltModel
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    let device: MTLDevice

    init?(model: TiltModel) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        guard let library = try? device.makeLibrary(source: tiltShaderSource, options: nil),
              let vf = library.makeFunction(name: "tilt_vertex"),
              let ff = library.makeFunction(name: "tilt_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              cache != nil else { return nil }
        self.model = model
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.textureCache = cache
        super.init()
    }

    func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestBuffer = pixelBuffer
        lock.unlock()
    }

    func attach(to view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = self
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        lock.lock()
        let buffer = latestBuffer
        lock.unlock()

        var cvTexture: CVMetalTexture?
        var texture: MTLTexture?
        var srcAspect: Float = 1
        if let buffer, let cache = textureCache {
            let w = CVPixelBufferGetWidth(buffer)
            let h = CVPixelBufferGetHeight(buffer)
            if w > 0, h > 0,
               CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                                                         .bgra8Unorm, w, h, 0, &cvTexture) == kCVReturnSuccess,
               let cvTexture {
                texture = CVMetalTextureGetTexture(cvTexture)
                srcAspect = Float(w) / Float(h)
            }
        }

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        DiagLog.draw(hasTexture: texture != nil, params: model.params, size: size)
        if let texture {
            let geo = TiltGeometry(params: model.params, srcAspect: srcAspect,
                                   outAspect: Float(size.width / size.height))
            var u = TiltUniforms(c0: SIMD4(geo.c0, 0), c1: SIMD4(geo.c1, 0), c2: SIMD4(geo.c2, 0),
                                 bg: SIMD4(0, 0, 0, 1),
                                 scale: geo.scale, srcAspect: geo.srcAspect,
                                 outAspect: geo.outAspect, dist: TiltGeometry.distance)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<TiltUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<TiltUniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cb.present(drawable)
        // Keep the CVMetalTexture (and its buffer) alive until the GPU is done.
        cb.addCompletedHandler { _ in withExtendedLifetime(cvTexture) {} }
        cb.commit()
    }
}

/// MTKView that forwards input. All callbacks invoked on main thread.
final class InteractiveMTKView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX, -event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}
