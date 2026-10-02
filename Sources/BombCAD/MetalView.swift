import BlastRender
import MetalKit
import SwiftUI

/// The 3D viewport: an `MTKView` that redraws every frame from the model's renderer.
struct MetalView: NSViewRepresentable {
    let model: SimulationModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: model.device)
        view.model = model
        view.delegate = context.coordinator
        view.colorPixelFormat = SceneRenderer.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: SimulationModel

        init(model: SimulationModel) {
            self.model = model
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer = model.renderer, let commandQueue = model.commandQueue,
                let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }
            var settings = model.renderSettings
            settings.showCharge = model.time == 0
            settings.highlight = model.highlightedBox
            renderer.settings = settings
            renderer.encode(into: commandBuffer, descriptor: descriptor, camera: model.camera)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// Adds camera controls: drag or two-finger scroll to orbit, shift-drag or right-drag to pan,
/// pinch or mouse wheel to zoom.
final class InteractiveMTKView: MTKView {
    weak var model: SimulationModel?

    override var acceptsFirstResponder: Bool { true }

    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragged = false
    }

    override func mouseUp(with event: NSEvent) {
        // A press and release without movement is a click on the scene.
        guard !dragged, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ndc = SIMD2(Float(2 * point.x / bounds.width - 1), Float(2 * point.y / bounds.height - 1))
        model?.click(ndc: ndc, aspectRatio: Float(bounds.width / bounds.height))
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        if event.modifierFlags.contains(.shift) {
            pan(event)
        } else {
            model?.camera.orbit(
                deltaAzimuth: -Float(event.deltaX) * 0.008, deltaElevation: Float(event.deltaY) * 0.008)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        pan(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            model?.camera.orbit(
                deltaAzimuth: -Float(event.scrollingDeltaX) * 0.006,
                deltaElevation: Float(event.scrollingDeltaY) * 0.006)
        } else {
            model?.camera.zoom(by: exp(-Float(event.scrollingDeltaY) * 0.05))
        }
    }

    override func magnify(with event: NSEvent) {
        model?.camera.zoom(by: 1 / (1 + Float(event.magnification)))
    }

    private func pan(_ event: NSEvent) {
        let scale = 1 / Float(max(bounds.height, 1))
        model?.camera.pan(right: Float(event.deltaX) * scale, forward: Float(event.deltaY) * scale)
    }
}
