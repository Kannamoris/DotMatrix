import Metal
import MetalKit
import simd

/// Draws the core's framebuffer into an `MTKView`.
///
/// The texture is uploaded whole each frame. At 160x144 that is 92 KB, far
/// cheaper than tracking dirty regions, and it keeps the emulation thread free
/// of any graphics work.
final class Renderer: NSObject, MTKViewDelegate {
    private struct DisplayUniforms {
        var sourceSize: SIMD2<Float>
        var gridStrength: Float
        var smoothing: Float
        var sourceRect: SIMD4<Float>
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let texture: MTLTexture

    private let width: Int
    private let height: Int

    /// Set from the UI; read on the render thread.
    var gridStrength: Float = 0.0
    var smoothing: Float = 0.0
    /// Sub-region of the framebuffer to display, in source pixels. Defaults to
    /// the whole screen.
    var sourceRect: CGRect?

    /// Supplies the pixels to draw. Called once per view frame.
    var frameProvider: ((UnsafeMutableRawPointer, Int) -> Void)?

    /// Staging buffer, so the provider can copy straight into shared memory.
    private let staging: UnsafeMutableRawPointer
    private let stagingBytes: Int

    init?(device: MTLDevice, width: Int, height: Int) {
        guard let queue = device.makeCommandQueue() else { return nil }

        // The shader library is compiled into the app bundle from Shaders.metal.
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "display_vertex"),
              let fragmentFunction = library.makeFunction(name: "display_fragment")
        else {
            NSLog("DotMatrix: could not load Metal shader functions")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            NSLog("DotMatrix: could not build render pipeline")
            return nil
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        // Shared storage lets the CPU write the texture with no staging blit.
        textureDescriptor.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: textureDescriptor) else { return nil }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline
        self.texture = tex
        self.width = width
        self.height = height
        self.stagingBytes = width * height * 4
        self.staging = UnsafeMutableRawPointer.allocate(
            byteCount: stagingBytes,
            alignment: MemoryLayout<UInt32>.alignment
        )
        staging.initializeMemory(as: UInt8.self, repeating: 0, count: stagingBytes)

        super.init()
    }

    deinit {
        staging.deallocate()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // Pull the newest frame. The provider copies under its own lock so a
        // half-written frame is never uploaded.
        frameProvider?(staging, stagingBytes)

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: staging,
            bytesPerRow: width * 4
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        let region = sourceRect ?? CGRect(x: 0, y: 0, width: width, height: height)
        var uniforms = DisplayUniforms(
            sourceSize: SIMD2<Float>(Float(width), Float(height)),
            gridStrength: gridStrength,
            smoothing: smoothing,
            sourceRect: SIMD4<Float>(
                Float(region.origin.x) / Float(width),
                Float(region.origin.y) / Float(height),
                Float(region.width) / Float(width),
                Float(region.height) / Float(height)
            )
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
