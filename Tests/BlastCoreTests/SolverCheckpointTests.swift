import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

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

    @Test("A checkpoint is refused while a batch is in flight")
    func batchInFlightRefuses() throws {
        let scene = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 1)
        let commands = try #require(solver.encodeBatch(steps: 64))
        #expect(solver.checkpointUnsupported != nil)
        #expect(throws: SolverCheckpoint.Refusal.self) {
            try solver.saveCheckpoint(to: folder("flight"), scene: scene)
        }
        commands.commit()
        commands.waitUntilCompleted()
        _ = solver.completeBatch()
        #expect(solver.checkpointUnsupported == nil)
    }

    /// Straight through to `steps`, against saved at `at` and carried on by a new solver, each
    /// configured by `configure`: the two digests.
    func straightAndResumed(
        _ scene: Scenario, cellSize: Float, configuration: SolverConfiguration, steps: Int, at: Int,
        configure: (BlastSolver) throws -> Void = { _ in }
    ) throws -> (UInt64, UInt64) {
        func solver() throws -> BlastSolver {
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: cellSize, configuration: configuration)
            try configure(solver)
            return solver
        }
        let straight = try solver()
        straight.advance(steps: steps)
        let first = try solver()
        first.advance(steps: at)
        let place = folder("resumed")
        defer { try? FileManager.default.removeItem(at: place) }
        try first.saveCheckpoint(to: place, scene: scene)
        let resumed = try solver()
        try resumed.restoreCheckpoint(from: place, scene: scene)
        resumed.advance(steps: steps - at)
        return (straight.stateDigest(), resumed.stateDigest())
    }

    @Test("A wall in shells, struck and refined, carries on from a checkpoint to the bit")
    func structureCarriesOn() throws {
        var scene = ScenarioPreset.blastWall.scenario
        scene.structure?.elementKind = .shell
        var configuration = SolverConfiguration.recommended
        configuration.refinement = 2
        let (straight, resumed) = try straightAndResumed(
            scene, cellSize: 0.5, configuration: configuration, steps: 192, at: 128)
        #expect(straight == resumed)
    }

    @Test("A glazed building's recorded loads and vented panes carry on from a checkpoint to the bit")
    func envelopesCarryOn() throws {
        let (scene, _) = try FragmentVentingTests().scene()
        var configuration = SolverConfiguration.recommended
        configuration.airSleepThreshold = 0
        let (straight, resumed) = try straightAndResumed(
            scene, cellSize: 0.25, configuration: configuration, steps: 256, at: 128
        ) { solver in
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.03))
            let construction = EnvelopeConstruction.assumed(objectID: scene.envelopeObjects[0].id)
            try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) { _ in construction }
        }
        #expect(straight == resumed)
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
