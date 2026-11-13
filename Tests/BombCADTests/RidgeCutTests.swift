import AppKit
import Metal
import SwiftUI
import Testing
import simd

@testable import BlastModel
@testable import BlastRender
@testable import BombCAD

/// File ▸ New Ridge Cut (emmettl/bombcad-work#131): the Quarry Face window's other scene, a cut
/// through a ridge. The window opens it, breaks and fires it and settles; the scene can be switched
/// in the window, the cut's width and depth changed, its line dragged across the ridge in the 3-D
/// view, and a project's terrain cut across its ridge. Offscreen: the window is never shown.
/// Illustrative scene.
@MainActor
@Suite("Ridge cut scene", .serialized, .hangLimit)
struct RidgeCutSceneTests {
    /// Waits until `done`, however long that takes (the suite's `hangLimit` is the only bound; a
    /// 240 s deadline of its own until 13 November 2026, as `QuarryFaceHandlingTests` had).
    static func waitUntil(_ model: QuarryFaceModel, _ done: () -> Bool) async throws {
        while !done() {
            try await Task.sleep(for: .milliseconds(20))
            model.session?.update(elapsed: 0.02)
        }
    }

    @Test("The window opens a ridge cut, breaks and fires it, and it settles")
    func opensFiresAndSettles() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 12000, scene: .ridgeCut)
        #expect(model.scene == .ridgeCut && model.terrainName == "Built-in ridge")
        model.prepare()
        try await Self.waitUntil(model) { model.session?.isReady == true }
        let session = try #require(model.session)
        #expect(session.isReady && model.problem == nil)
        let ridge = try #require(session.face.ridge)
        #expect(session.face.blocks.count > 8000)
        // The firings are the ridge cut's, inside the cut.
        #expect(
            session.firings.allSatisfy { $0.position.x >= ridge.cutStart && $0.position.x <= ridge.cutEnd })
        // The crest is broken: at the end, most of the rock has left the old ground above the floor.
        session.seek(to: session.eventFrames - 1)
        session.update(elapsed: 0)
        let end = session.shownPoses
        var moved = 0
        for (n, block) in session.face.blocks.enumerated() {
            let p = end[2 * n]
            if simd_distance(SIMD3(p.x, p.y, p.z), block.centre) > 1 { moved += 1 }
        }
        #expect(moved > session.face.blocks.count / 2)
        // Down both flanks: some rock well out past each end of the cut along the line.
        let out = (0..<session.face.blocks.count).map { end[2 * $0].x }
        #expect(out.contains { $0 < ridge.cutStart - 5 } && out.contains { $0 > ridge.cutEnd + 5 })
        // The last second: still.
        session.seek(to: session.eventFrames - 31)
        session.update(elapsed: 0)
        let before = session.shownPoses
        var still: [Float] = []
        for n in stride(from: 0, to: before.count, by: 2) {
            let (a, b) = (before[n], end[n])
            still.append(simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)))
        }
        still.sort()
        #expect(still[still.count * 99 / 100] < 0.02)
        #expect(still.filter { $0 > 0.1 }.count < max(10, still.count / 500))
        #expect(end.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        _ = session.draw()
    }

    @Test("Switching scene lays out the other on the built-in ground; the cut's width and depth apply")
    func switchesSceneAndCut() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 8000)
        #expect(model.scene == .face)
        model.useScene(.ridgeCut)
        #expect(model.scene == .ridgeCut && model.terrainName == "Built-in ridge")
        #expect(model.preparing != nil)
        try await Self.waitUntil(model) { model.session?.canPlay == true && model.preparing == nil }
        #expect(model.session?.face.ridge != nil)
        model.cutWidth = 20
        model.cutDepth = 18
        model.applyCut()
        #expect(model.site.width == 20 && model.site.depth == 18)
        #expect(model.preparing != nil)
        try await Self.waitUntil(model) {
            model.session?.face.ridge?.halfWidth == 10 && model.preparing == nil
        }
        let ridge = try #require(model.session?.face.ridge)
        #expect(ridge.halfWidth == 10 && abs(ridge.floor - (ridge.crest - 18)) < 1e-3)
        // And back: the face on its own built-in hillside.
        model.useScene(.face)
        #expect(model.scene == .face && model.terrainName == "Built-in hillside")
        try await Self.waitUntil(model) { model.session?.face.ridge == nil && model.preparing == nil }
        #expect(model.session?.face.ridge == nil)
        #expect(model.problem == nil)
    }

    @Test(
        "A cut's line dragged across the ridge in the 3-D view lands where it is dragged, with its outline drawn"
    )
    func dragsTheCutInTheView() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 8000, scene: .ridgeCut)
        let (window, host, view) = try QuarryFaceHandlingTests.host(model)
        defer { window.close() }
        #expect(!window.isVisible)
        model.prepare()
        try await Self.waitUntil(model) { model.session?.canPlay == true && model.preparing == nil }
        // SwiftUI hands the session to the 3-D view on a later turn of the main run loop; asked
        // before that, the view drew no overlay and placed no point (the strip test's race, fixed
        // in d365dc82; this one failed the same way in emmettl/bombcad-work#140's ship).
        try await QuarryFaceHandlingTests.waitForView(view, host, model)
        model.stripMode = true
        view.refreshOverlay()
        #expect(view.overlay.isShowing)
        let ground = model.site.terrain
        let session = try #require(model.session)
        // From high above, so both flanks are in view (from the default view, beside the ridge,
        // the far flank is behind the crest).
        session.focus = SIMD3(80, 30, 10)
        session.pitch = 1.2
        session.distance = 330
        // Across the ridge 30 m along it from the built-in cut, from flank to flank, in the
        // ground's metres and on the view.
        func onView(_ p: SIMD2<Float>) throws -> CGPoint {
            let q = try #require(view.onView(SIMD3(p, ground.height(at: p))))
            #expect(view.bounds.contains(q), "\(q) in \(view.bounds)")
            return q
        }
        let (start, end) = (SIMD2<Float>(-70, 30), SIMD2<Float>(70, 30))
        let a = try onView(start)
        let b = try onView(end)
        view.mouseDown(with: QuarryFaceHandlingTests.mouse(.leftMouseDown, at: a, in: view))
        for k in 1...20 {
            let t = CGFloat(k) / 20
            view.mouseDragged(
                with: QuarryFaceHandlingTests.mouse(
                    .leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                    in: view))
        }
        view.mouseUp(with: QuarryFaceHandlingTests.mouse(.leftMouseUp, at: b, in: view))
        // Not snapped to a face: where it was dragged, picked through the view (a few metres).
        #expect(simd_distance(model.site.start, start) < 4, "\(model.site.start)")
        #expect(simd_distance(model.site.end, end) < 4, "\(model.site.end)")
        #expect(model.site.scene == .ridgeCut && model.preparing != nil)
        _ = session
        try await Self.waitUntil(model) { model.preparing == nil }
        #expect(model.problem == nil, "\(model.problem ?? "")")
        #expect(model.session?.face.ridge != nil)
    }

    @Test("A project's terrain is cut across its ridge; ground with no ridge asks for a line")
    func projectTerrain() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 8000, scene: .ridgeCut)
        // A project's terrain: part of the built-in ridge, far from the origin, at 2 m.
        let built = QuarrySite.builtInRidge().terrain
        let origin = SIMD2<Float>(5000, 3000)
        let size = 400
        var heights = [Float](repeating: 0, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                heights[i + size * j] = built.height(at: SIMD2(Float(i), Float(j)) * 2 - 400)
            }
        }
        let terrain = Terrain(origin: origin, spacing: 2, columns: size, rows: size, heights: heights)
        model.useTerrain(terrain, name: "Ridge project")
        #expect(model.problem == nil && model.preparing != nil)
        let middle = (model.site.start + model.site.end) / 2 - origin - 400
        #expect(abs(middle.x - BuiltInRidge.axis(middle.y)) < 10, "\(middle)")
        try await Self.waitUntil(model) { model.session?.canPlay == true && model.preparing == nil }
        #expect(model.session?.face.ridge != nil)
        let flat = Terrain(
            origin: .zero, spacing: 2, columns: 300, rows: 300, heights: Array(repeating: 3, count: 90_000))
        model.useTerrain(flat, name: "Flat")
        #expect(model.problem?.contains("No ridge") == true)
    }
}
