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
        view.preferredFramesPerSecond = Coordinator.frameRates.upperBound
        context.coordinator.updateDrawing(view)
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: OrbitControlView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: SimulationModel
        /// The GPU time a frame has been taking to draw, smoothed; 0 before the first.
        private var frameSeconds = 0.0
        /// The paint last handed to the renderer, which keeps it between frames.
        private var paint: SurfacePaint?

        /// The share of the GPU the view may take while a run goes as fast as it can. A frame of
        /// the blast wave is ray-marched through the whole domain at every pixel, so at 60 frames
        /// a second a large window took most of the GPU from the run; and the frames a second it
        /// never drops below, nor goes above.
        static let runShare = 0.1
        static let frameRates = 10...60

        init(model: SimulationModel) {
            self.model = model
        }

        /// As many frames a second as the GPU can spare during a run as fast as possible.
        private var framesPerSecond: Int {
            guard model.isRunning, model.speed == .unlimited, frameSeconds > 0 else {
                return Self.frameRates.upperBound
            }
            let rate = Int((Self.runShare / frameSeconds).rounded())
            return min(max(rate, Self.frameRates.lowerBound), Self.frameRates.upperBound)
        }

        private func frameDrawn(gpuSeconds: Double) {
            guard gpuSeconds > 0 else { return }
            frameSeconds = frameSeconds == 0 ? gpuSeconds : frameSeconds + 0.2 * (gpuSeconds - frameSeconds)
        }

        /// What a frame draws from the model.
        private struct Frame {
            var settings: RenderSettings
            var dots: [SIMD4<Float>]
            var paint: SurfacePaint?
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
        /// those that land after a run finishes, and the paint from the thermal radiation's, so
        /// `thermalReckoned` stands in for its last frames.
        private func frame() -> Frame {
            _ = model.isRunning
            _ = model.sceneVersion
            _ = model.fragmentLive
            _ = model.thermalReckoned
            var settings = model.renderSettings
            settings.showCharge = model.time == 0
            settings.highlight = model.highlightedBox
            // The ground points read the project's points and the run's estimate, both observed.
            let dots =
                model.fragmentDots(showFragments: settings.showFragments, showTracers: settings.showTracers)
                + (settings.showGroundPoints ? model.groundShockDots() : [])
            let paint = settings.thermal.flatMap { model.thermalPaint($0) }
            return Frame(settings: settings, dots: dots, paint: paint, camera: model.camera)
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
            if frame.paint != paint {
                paint = frame.paint
                renderer.setSurfacePaint(paint)
            }
            if view.bounds.width > 0 {
                renderer.pixelsPerPoint = Float(view.drawableSize.width / view.bounds.width)
            }
            renderer.encode(into: commandBuffer, descriptor: descriptor, camera: frame.camera)
            commandBuffer.addCompletedHandler { [weak self] buffer in
                let seconds = buffer.gpuEndTime - buffer.gpuStartTime
                Task { @MainActor in self?.frameDrawn(gpuSeconds: seconds) }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            let rate = framesPerSecond
            if view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }
        }
    }
}

/// The model steers the shared viewport's camera, and clicks select what lies under them.
extension SimulationModel: OrbitControlling {}
