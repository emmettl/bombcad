import BlastRender
import Foundation
import MetalKit
import Testing

@testable import BombCAD

/// Counts the frames asked for: AppKit keeps no display flag for a view outside a window.
private final class ProbeView: MTKView {
    var requests = 0

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { requests += 1 }
            super.needsDisplay = newValue
        }
    }
}

/// The viewport draws every frame during a run and otherwise only when what it draws changes.
@MainActor
@Suite("Viewport drawing", .serialized)
struct ViewportDrawingTests {
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("An idle view draws on a change to what it draws, and on its timer through a run")
    func drawsOnChange() async throws {
        var document = ProjectDocument()
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.002
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        try #require(model.device != nil, "These tests need a Metal device")
        try await waitUntil { model.experimentIsReady }

        let coordinator = MetalView.Coordinator(model: model)
        let view = ProbeView(frame: .zero, device: model.device)
        view.delegate = coordinator
        coordinator.updateDrawing(view)
        #expect(view.isPaused && view.enableSetNeedsDisplay)

        /// Draws a frame as the view would, then whether `change` asks for another.
        func redraws(after change: () -> Void) async throws -> Bool {
            coordinator.draw(in: view)
            let requests = view.requests
            change()
            let deadline = ContinuousClock.now + .seconds(30)
            while view.requests == requests, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            return view.requests > requests
        }

        #expect(try await redraws { model.renderSettings.waveOpacity = 0.5 })
        #expect(try await redraws { model.camera.zoom(by: 0.5) })
        let version = model.sceneVersion
        #expect(try await redraws { model.reset() })
        try await waitUntil { model.sceneVersion > version }
        // Nothing it draws changed: no frame.
        coordinator.draw(in: view)
        let requests = view.requests
        model.fragmentsHost = model.fragmentsHost == nil ? "another Mac" : nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.requests == requests)

        coordinator.draw(in: view)
        model.run()
        try await waitUntil { !view.isPaused }
        #expect(!view.enableSetNeedsDisplay)
        try await waitUntil { !model.isRunning && !model.hasPendingGPUWork }
        // The first frame after the run returns to drawing on change.
        coordinator.draw(in: view)
        #expect(view.isPaused && view.enableSetNeedsDisplay)
    }
}
