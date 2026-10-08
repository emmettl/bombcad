import BlastRender
import MetalKit
import SceneRender
import SwiftUI

/// The 3D viewport: an `MTKView` that redraws every frame from the model's renderer.
struct MetalView: NSViewRepresentable {
    let model: SimulationModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> OrbitControlView {
        let view = OrbitControlView(frame: .zero, device: model.device)
        view.controller = model
        view.delegate = context.coordinator
        view.colorPixelFormat = SceneRenderer.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ view: OrbitControlView, context: Context) {}

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

/// The model steers the shared viewport's camera, and clicks select what lies under them.
extension SimulationModel: OrbitControlling {}
