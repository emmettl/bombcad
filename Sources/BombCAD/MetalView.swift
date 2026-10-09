import BlastRender
import MetalKit
import SceneRender
import SwiftUI

/// The 3D viewport: an `MTKView` that draws from the model's renderer every frame during a run,
/// and otherwise only when something it draws changes. A frame ray-marches the blast wave through
/// the whole domain at every pixel, so an idle window drawing 60 frames a second took a large share
/// of the GPU from runs and sweeps elsewhere on the Mac.
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
        context.coordinator.updateDrawing(view)
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: OrbitControlView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: SimulationModel

        init(model: SimulationModel) {
            self.model = model
        }

        /// What a frame draws from the model.
        private struct Frame {
            var settings: RenderSettings
            var dots: [SIMD4<Float>]
            var camera: OrbitCamera
        }

        /// Draws on the view's timer during a run, and otherwise when marked as needing display:
        /// by a change to what the last frame read from the model, a camera control or a resize.
        func updateDrawing(_ view: MTKView) {
            let continuous = model.isRunning
            guard view.isPaused == continuous else { return }
            view.isPaused = !continuous
            view.enableSetNeedsDisplay = !continuous
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if view.isPaused { view.needsDisplay = true }
        }

        /// Everything a frame depends on in the model. The scene and the solver's textures are
        /// read by the renderer outside Observation, so `sceneVersion` stands in for the scene,
        /// and `time` for the air and the structure, which change only as a run steps. The dots
        /// come from the fragments' consumer while it has them, so `fragmentLive` stands in for
        /// those that land after a run finishes.
        private func frame() -> Frame {
            _ = model.isRunning
            _ = model.sceneVersion
            _ = model.fragmentLive
            var settings = model.renderSettings
            settings.showCharge = model.time == 0
            settings.highlight = model.highlightedBox
            let dots = model.fragmentDots(
                showFragments: settings.showFragments, showTracers: settings.showTracers)
            return Frame(settings: settings, dots: dots, camera: model.camera)
        }

        func draw(in view: MTKView) {
            let frame: Frame
            if model.isRunning {
                frame = self.frame()
            } else {
                // Read before anything that may fail, so a change still draws a frame.
                frame = withObservationTracking(self.frame) { [weak self, weak view] in
                    Task { @MainActor in
                        guard let self, let view else { return }
                        self.updateDrawing(view)
                        if view.isPaused { view.needsDisplay = true }
                    }
                }
            }
            updateDrawing(view)
            guard let renderer = model.renderer, let commandQueue = model.commandQueue,
                let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }
            renderer.settings = frame.settings
            renderer.setDots(frame.dots)
            if view.bounds.width > 0 {
                renderer.pixelsPerPoint = Float(view.drawableSize.width / view.bounds.width)
            }
            renderer.encode(into: commandBuffer, descriptor: descriptor, camera: frame.camera)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// The model steers the shared viewport's camera, and clicks select what lies under them.
extension SimulationModel: OrbitControlling {}
