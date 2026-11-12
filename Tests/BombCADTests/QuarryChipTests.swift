import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel
@testable import BlastRender

/// The quarry's decorative rubble (emmettl/bombcad-work#137): chips lying on the rock ride it, so
/// rubble goes where the rock goes rather than being left where the rock was and dropping straight
/// down. Illustrative scene; this guards how the rubble moves, not how it looks.
@Suite("Quarry rubble", .serialized)
struct QuarryChipTests {
    @Test("Rubble on the moving rock goes with it; little of it is left to drop straight down")
    func ridesTheRock() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 6000
        options.meshDetail = 1
        // The ridge cut, where the rock heaves and runs off down the flanks.
        var face = try QuarryFace(site: .builtIn(.ridgeCut), options: options)
        face.generate()
        let firings = QuarrySession.firings(face: face, settings: QuarryFiringSettings())
        let frames = 121
        let run = QuarryRun(
            device: device, face: face.withoutMesh(), firings: firings, frames: frames, frameRate: 30,
            substeps: QuarrySession.substeps)
        await withCheckedContinuation { done in run.whenFinished { done.resume() } }
        let cache = try #require(run.cache)
        #expect(run.failure == nil)
        let path = QuarryCameraPath(
            eyes: (.zero, SIMD3(0, 1, 0)), targets: (SIMD3(0, 1, 0), .zero), fovY: (36, 36), duration: 4)
        // The window's quality: the height the chips land on is drawn every few frames.
        let renderer = try QuarryRenderer(
            device: device, face: face, width: 64, height: 36, supersample: 1, path: path, frameRate: 30,
            quality: .live)
        let bodies = cache.bodies
        let pose = try #require(device.makeBuffer(length: 32 * bodies, options: .storageModeShared))
        let previous = try #require(device.makeBuffer(length: 32 * bodies, options: .storageModeShared))
        func decode(_ f: Int, _ buffer: MTLBuffer) {
            cache.decode(
                frame: f, into: buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies))
        }
        let count = renderer.chipCount
        let chips = renderer.chips.contents().bindMemory(to: QuarryDecor.Chip.self, capacity: count)
        var inAir = 0
        var straight = 0
        var last = [UInt32](repeating: 0, count: count)
        // Whether each chip's last fall began from rest: left lying where it was when what held
        // it went.
        var fromRest = [Bool](repeating: false, count: count)
        for f in 1..<frames {
            decode(f - 1, previous)
            decode(f, pose)
            renderer.stepDecor(pose: pose, previous: previous, time: Float(f) / 30)
            for i in 0..<count {
                let c = chips[i]
                let across = simd_length(SIMD2(c.velAge.x, c.velAge.y))
                if last[i] == 2, c.state == 1 { fromRest[i] = across < 0.5 && c.velAge.z > -1 }
                last[i] = c.state
                guard c.state == 1 else { continue }
                inAir += 1
                // Dropping straight down from rest, faster than 3 m/s: rubble left hanging where
                // the rock was.
                if fromRest[i], c.velAge.z < -3, across < 0.5 { straight += 1 }
            }
        }
        #expect(inAir > 0)
        let share = Double(straight) / Double(max(1, inAir))
        #expect(
            share < 0.05, "falling straight down from rest: \(straight) of \(inAir) chip-frames in the air")
    }
}
