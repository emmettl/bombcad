import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// A quarry firing simulated on its own thread into a pose cache that is read while it fills
/// (emmettl/bombcad-work#126). Illustrative scene; these guard the hand-over, not the physics.
@Suite("Quarry run", .serialized, .gpuThreads)
struct QuarryRunTests {
    func face(blocks: Int) throws -> QuarryFace {
        var options = QuarryFace.Options()
        options.blocks = blocks
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(), options: options)
        face.generate()
        return face
    }

    @Test("A run can be shown after its first frames and read while it fills, to the last frame")
    func fillsWhileRead() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let face = try face(blocks: 8000)
        let firings = QuarryFiringPattern.row(face: face, count: 8, first: 0.3, stagger: 0.05)
        let run = QuarryRun(
            device: device, face: face, firings: firings, frames: 61, frameRate: 30, substeps: 8, buffers: 4,
            lead: 5)
        await withCheckedContinuation { done in run.whenStartable { done.resume() } }
        let cache = try #require(run.cache)
        #expect(run.isStartable)
        #expect(cache.available >= 5)
        var out = [SIMD4<Float>](repeating: .zero, count: 2 * cache.bodies)
        var shown = 0
        while !cache.isComplete || shown < 60 {
            let head = cache.available - 1
            #expect(head >= shown)
            shown = head
            out.withUnsafeMutableBufferPointer { cache.decode(frame: shown, into: $0.baseAddress!) }
            #expect(out.allSatisfy { $0.x.isFinite })
            try await Task.sleep(for: .milliseconds(5))
        }
        await withCheckedContinuation { done in run.whenFinished { done.resume() } }
        #expect(!run.isSimulating)
        #expect(run.failure == nil)
        #expect(run.frameGPUSeconds.count == 60)
        // It fired: some rock has left its place by the last frame.
        let moved = zip(face.blocks, stride(from: 0, to: out.count, by: 2).map { out[$0] }).filter {
            simd_distance($0.0.centre, SIMD3($0.1.x, $0.1.y, $0.1.z)) > 0.5
        }
        #expect(!moved.isEmpty)
    }

    @Test("A cancelled run stops and keeps what it stored")
    func cancels() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let face = try face(blocks: 8000)
        let run = QuarryRun(
            device: device, face: face, firings: QuarryFiringPattern.row(face: face), frames: 601,
            frameRate: 30,
            substeps: 8, lead: 3)
        await withCheckedContinuation { done in run.whenStartable { done.resume() } }
        run.cancel()
        await withCheckedContinuation { done in run.whenFinished { done.resume() } }
        let cache = try #require(run.cache)
        #expect(!run.isSimulating)
        #expect(!cache.isComplete)
        #expect(cache.available >= 3)
    }
}
