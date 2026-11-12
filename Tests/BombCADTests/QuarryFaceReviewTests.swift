import AppKit
import Metal
import SwiftUI
import Testing

@testable import BlastRender
@testable import BombCAD

/// The Quarry Face window captured offscreen while its event is watched as it is simulated
/// (emmettl/bombcad-work#126): `BOMBCAD_INTERFACE_REVIEW=dir swift test --filter QuarryFaceReview`.
/// The 3-D view is a Metal layer, which a capture of the window leaves blank, so each step also
/// writes the session's own frame. For a person to look at; it checks only that each state is reached.
@MainActor
@Suite(
    "Quarry Face window review", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
struct QuarryFaceReviewTests {
    @Test("Preparing, following the solver, firing again, and done")
    func streamingStates() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        )
        .appendingPathComponent("quarry-stream")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = QuarryFaceModel(blocks: 12000)
        let host = NSHostingView(rootView: QuarryFaceView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 860)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        #expect(!window.isVisible)
        if model.session == nil, model.preparing == nil { model.prepare() }

        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            if let session = model.session {
                session.draw()
                session.renderer.savePNG(output.appendingPathComponent(name + "-view.png"))
            }
        }
        func wait(_ seconds: Double, until done: () -> Bool) async throws {
            var waited = 0.0
            while !done(), waited < seconds {
                try await Task.sleep(for: .milliseconds(20))
                model.session?.update(elapsed: 0.02)
                waited += 0.02
            }
        }

        try await wait(60) { model.preparing != nil }
        try capture("1-preparing")
        try await wait(240) { model.session?.isSimulating == true }
        try await Task.sleep(for: .milliseconds(400))
        try capture("2-following")
        try await wait(240) { model.session?.isReady == true }
        model.fire()
        try capture("3-fired-again")
        let session = try #require(model.session)
        #expect(session.isStarting || session.isSimulating)
        try await wait(240) { session.isReady && !session.isStarting }
        session.seek(to: session.eventFrames - 1)
        session.update(elapsed: 0)
        try capture("4-done")
        #expect(session.isReady)
    }
}
