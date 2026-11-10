import Metal
import Testing
import simd

@testable import BlastModel
@testable import BlastRender
@testable import BombCAD

/// File ▸ New Quarry Face: the window's model opens on the built-in hillside, breaks its rock,
/// fires in the background, and replays a settled event within its memory budget. Illustrative.
@MainActor
@Suite("Quarry face scene", .serialized)
struct QuarryFaceSceneTests {
    @Test("The scene opens, fires and settles, and scrubs within its memory budget")
    func opensFiresAndSettles() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 12000)
        model.prepare()
        var waited = 0.0
        while model.session?.isReady != true, waited < 240 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        let session = try #require(model.session)
        #expect(session.isReady)
        #expect(model.problem == nil)
        // The last second of the event: still.
        session.seek(to: session.eventFrames - 31)
        session.update(elapsed: 0)
        let before = session.shownPoses
        session.seek(to: session.eventFrames - 1)
        session.update(elapsed: 0)
        let after = session.shownPoses
        var moved: [Float] = []
        for n in stride(from: 0, to: before.count, by: 2) {
            let a = before[n]
            let b = after[n]
            moved.append(simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)))
        }
        moved.sort()
        #expect(moved[moved.count * 99 / 100] < 0.02)
        #expect(moved.filter { $0 > 0.1 }.count < max(10, moved.count / 500))
        #expect(after.allSatisfy { $0.x.isFinite })
        // Scrubbing back replays the dust from the field kept on disk.
        session.seek(to: 45)
        session.update(elapsed: 0)
        #expect(session.frame == 45)
        // The budget: the packed poses are a fraction of the floats they replace.
        let memory = session.memory
        #expect(memory.poses < session.face.blocks.count * session.eventFrames * 32 / 4)
        _ = session.draw()
    }
}
