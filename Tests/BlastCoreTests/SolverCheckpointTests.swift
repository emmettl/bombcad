import Foundation
import Metal
import Testing

@testable import BlastCore

/// The solver's state saved part way and taken back (`SolverCheckpoint`).
@Suite("Solver checkpoints", .gpuThreads)
struct SolverCheckpointTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// The open ground over a slope on 1 m cells, refined twice on the recommended air.
    func scene() -> (Scenario, SolverConfiguration) {
        var scene = ScenarioPreset.openGround.scenario
        let domain = scene.domainSize
        scene.replaceTerrain(with: .slope(domain: domain, spacing: 1, foot: 0.3 * domain.x, angle: 20))
        var configuration = SolverConfiguration.recommended
        configuration.refinement = 2
        configuration.refinementLevels = 2
        return (scene, configuration)
    }

    func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "checkpoint-tests-\(name)-\(UUID().uuidString)")
    }

    @Test(
        "A run saved at step 64 and carried on by another solver ends as the run straight through, to the bit"
    )
    func carriesOnExactly() throws {
        let (scene, configuration) = scene()
        let straight = try BlastSolver(
            device: device, scenario: scene, cellSize: 1, configuration: configuration)
        straight.advance(steps: 128)

        let first = try BlastSolver(
            device: device, scenario: scene, cellSize: 1, configuration: configuration)
        first.advance(steps: 64)
        let place = folder("exact")
        defer { try? FileManager.default.removeItem(at: place) }
        let saved = try first.saveCheckpoint(to: place, scene: scene)
        #expect(saved.stepCount == 64 && saved.complete && saved.covers.contains("refinement"))
        #expect(saved.storedBytes < saved.rawBytes)

        let resumed = try BlastSolver(
            device: device, scenario: scene, cellSize: 1, configuration: configuration)
        try resumed.restoreCheckpoint(from: place, scene: scene)
        #expect(resumed.stepCount == 64 && resumed.time == first.time)
        resumed.advance(steps: 64)
        #expect(resumed.stepCount == straight.stepCount && resumed.time == straight.time)
        #expect(resumed.stateDigest() == straight.stateDigest())
    }

    @Test("A checkpoint is refused off a 64-step boundary, and into another scene or configuration")
    func refusals() throws {
        let (scene, configuration) = scene()
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: 1, configuration: configuration)
        solver.advance(steps: 10)
        #expect(throws: SolverCheckpoint.Refusal.self) {
            try solver.saveCheckpoint(to: folder("off"), scene: scene)
        }
        solver.advance(steps: 54)
        let place = folder("refusals")
        defer { try? FileManager.default.removeItem(at: place) }
        try solver.saveCheckpoint(to: place, scene: scene)

        var other = scene
        other.charge.mass *= 2
        let wrongScene = try BlastSolver(
            device: device, scenario: other, cellSize: 1, configuration: configuration)
        #expect(throws: SolverCheckpoint.Refusal.self) {
            try wrongScene.restoreCheckpoint(from: place, scene: other)
        }
        var changed = configuration
        changed.cfl *= 0.9
        let wrongConfiguration = try BlastSolver(
            device: device, scenario: scene, cellSize: 1, configuration: changed)
        #expect(throws: SolverCheckpoint.Refusal.self) {
            try wrongConfiguration.restoreCheckpoint(from: place, scene: scene)
        }
    }

    @Test("A part of the solver not yet covered refuses rather than be left out")
    func uncoveredPartsRefuse() throws {
        let scene = ScenarioPreset.blastWall.scenario
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        #expect(solver.checkpointUnsupported != nil)
        #expect(throws: SolverCheckpoint.Refusal.self) {
            try solver.saveCheckpoint(to: folder("wall"), scene: scene)
        }
    }

    @Test(
        "Compressed parts come back byte for byte, in chunks and stored as they are where they do not compress"
    )
    func compression() throws {
        var random = SystemRandomNumberGenerator()
        let noise = Data(
            (0..<(SolverCheckpoint.chunk + 12_345)).map { _ in UInt8.random(in: 0...255, using: &random) })
        let zeros = Data(count: 3 * SolverCheckpoint.chunk + 7)
        for data in [noise, zeros, Data()] {
            #expect(try SolverCheckpoint.decompress(SolverCheckpoint.compress(data)) == data)
        }
        #expect(SolverCheckpoint.compress(zeros).count < 100_000)
    }
}
