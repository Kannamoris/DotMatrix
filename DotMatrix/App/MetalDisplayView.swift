import SwiftUI
import MetalKit

/// Hosts an `MTKView` driving the emulator's `Renderer`.
struct MetalDisplayView: UIViewRepresentable {
    let session: EmulatorSession
    var gridStrength: Float
    var smoothing: Float

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.isOpaque = true
        view.layer.isOpaque = true
        view.backgroundColor = .black
        view.framebufferOnly = true
        // The emulation thread produces frames independently, so the view just
        // samples whatever is newest at the display's own rate.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("DotMatrix: Metal is unavailable on this device")
            return view
        }
        view.device = device

        guard let renderer = Renderer(
            device: device,
            width: session.screenWidth,
            height: session.screenHeight
        ) else {
            return view
        }

        renderer.frameProvider = { [weak session] pointer, byteCount in
            session?.copyLatestFrame(into: pointer, byteCount: byteCount)
        }
        renderer.gridStrength = gridStrength
        renderer.smoothing = smoothing

        context.coordinator.renderer = renderer
        view.delegate = renderer

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.gridStrength = gridStrength
        context.coordinator.renderer?.smoothing = smoothing
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        // Stop the display link before the renderer goes away.
        uiView.isPaused = true
        uiView.delegate = nil
        coordinator.renderer = nil
    }

    final class Coordinator {
        var renderer: Renderer?
    }
}
