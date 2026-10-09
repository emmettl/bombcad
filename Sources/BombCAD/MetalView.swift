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
        view.preferredFramesPerSecond = Coordinator.frameRates.upperBound
        return view
    }

    func updateNSView(_ view: OrbitControlView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: SimulationModel
        /// The GPU time a frame has been taking to draw, smoothed; 0 before the first.
        private var frameSeconds = 0.0

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
            renderer.setDots(
                model.fragmentDots(showFragments: settings.showFragments, showTracers: settings.showTracers))
            if view.bounds.width > 0 {
                renderer.pixelsPerPoint = Float(view.drawableSize.width / view.bounds.width)
            }
            renderer.encode(into: commandBuffer, descriptor: descriptor, camera: model.camera)
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
