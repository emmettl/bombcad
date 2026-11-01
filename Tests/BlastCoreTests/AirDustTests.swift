import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// A collapse's dust carried by the air (`AirDust`; docs/whole-event.md, "Dust, stage 1").
@Suite("Dust in the air", .gpuThreads)
struct AirDustTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dust-tests-\(name)-\(UUID().uuidString)")
    }

    /// Still air 8 m on a side on 0.5 m cells, a block 2 m high in one corner, and a charge too small
    /// to stir it.
    func stillAir() -> Scenario {
        Scenario(
            name: "Still air", domainSize: SIMD3(8, 8, 8), boxes: [Box(x: 5...7, y: 5...7, height: 2)],
            charge: Charge(mass: 1e-6, position: SIMD3(0.5, 0.5, 4)), gauges: [])
    }

    @Test("Fines settle at their terminal speeds onto the ground and a block, and the ledger closes")
    func settling() throws {
        let solver = try BlastSolver(
            device: device, scenario: stillAir(), cellSize: 0.5, configuration: SolverConfiguration())
        let settings = DustSettings.standard
        try solver.enableDust(settings)
        solver.advance(steps: 1)
        // A kilogram in the bottom cell in the open, and one in the cell above the block.
        solver.addDust(4, 4, 0, mass: 1)
        solver.addDust(12, 12, 4, mass: 1)
        let plan = (min: SIMD2<Float>(0, 0), max: SIMD2<Float>(0, 0))
        var steps = 0
        while solver.time < 3 {
            solver.advance(steps: 64)
            steps += 64
            #expect(steps < 100_000)
        }
        let (ledger, _) = try #require(solver.dustReading(plan: plan))
        // The classes split in 4,096ths.
        let fine = (settings.fineShare * 4096).rounded() / 4096
        #expect(abs(ledger.made.x - 2 * fine) < 1e-9)
        #expect(abs(ledger.made.y - 2 * (1 - fine)) < 1e-9)
        // Nothing is lost: made = airborne + settled + gone, to the field's rounding.
        #expect(abs(ledger.unplaced) < 1e-6 * ledger.total)
        // Each kilogram sits in the cell on a floor, which it leaves at w / dx a second: the explicit
        // scheme's (1 - w dt / dx)^n, 1 - exp(-w t / dx) to within its steps' rounding. In three
        // seconds a 100 µm grain falls 1.6 m, so 96% of the coarse class is down, half on the ground
        // and half on the block; the 10 µm class 2 cm, 4.4% of it down.
        for (made, settled, speed) in [
            (ledger.made.y, ledger.deposited.y, settings.coarseSettling),
            (ledger.made.x, ledger.deposited.x, settings.fineSettling),
        ] {
            let expected = (1 - exp(-speed * solver.time / 0.5)) * made
            #expect(abs(settled / expected - 1) < 0.01)
        }
        #expect(abs(ledger.onSolids.y - ledger.onGroundOutside.y) < 0.01 * ledger.made.y)
        // The charge's breath carries next to nothing out.
        #expect(ledger.leftDomain.x + ledger.leftDomain.y < 1e-6)
    }

    /// A concrete wall struck close in, its failed concrete as rubble, its work traced, with dust.
    func struckWall() -> (Scenario, SolverConfiguration) {
        var scene = ScenarioPreset.blastWall.scenario
        scene.structure?.rubbleParticles = true
        return (scene, SolverConfiguration.recommended)
    }

    func dustySolver(_ scene: Scenario, _ configuration: SolverConfiguration) throws -> BlastSolver {
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration)
        solver.settleStructures()
        try #require(solver.bodies.first?.solids).tracesWork = true
        try solver.enableDust(.standard)
        return solver
    }

    @Test("A struck wall's fines are all accounted for, and carry on from a checkpoint to the bit")
    func struckWallCarriesOn() throws {
        let (scene, configuration) = struckWall()
        let straight = try dustySolver(scene, configuration)
        straight.advance(steps: 256)
        let first = try dustySolver(scene, configuration)
        first.advance(steps: 128)
        let place = folder("wall")
        defer { try? FileManager.default.removeItem(at: place) }
        let saved = try first.saveCheckpoint(to: place, scene: scene)
        #expect(saved.covers.contains("dust"))
        let resumed = try dustySolver(scene, configuration)
        try resumed.restoreCheckpoint(from: place, scene: scene)
        resumed.advance(steps: 128)
        #expect(resumed.stateDigest() == straight.stateDigest())

        let bounds = try #require(scene.structure?.bounds)
        let plan = (min: SIMD2(bounds.min.x, bounds.min.y), max: SIMD2(bounds.max.x, bounds.max.y))
        let (ledger, _) = try #require(straight.dustReading(plan: plan))
        let (again, _) = try #require(resumed.dustReading(plan: plan))
        #expect(ledger == again)
        #expect(ledger.fromElements > 0)
        #expect(abs(ledger.fromElements + ledger.fromImpacts + ledger.madeOutside - ledger.total) < 1e-9)
        #expect(abs(ledger.unplaced) < 1e-5 * ledger.total)
    }

    @Test("Without the dust nothing changes: the same run to the bit, and no part in its checkpoint")
    func offChangesNothing() throws {
        let (scene, configuration) = struckWall()
        func run(_ dust: Bool) throws -> (UInt64, [String]) {
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: 0.5, configuration: configuration)
            solver.settleStructures()
            try #require(solver.bodies.first?.solids).tracesWork = true
            if dust { try solver.enableDust(.standard) }
            solver.advance(steps: 128)
            let place = folder("off")
            defer { try? FileManager.default.removeItem(at: place) }
            let header = try solver.saveCheckpoint(to: place, scene: scene)
            // The digest of the air and the structure alone.
            solver.dust = nil
            return (solver.stateDigest(), header.covers)
        }
        let (plain, plainCovers) = try run(false)
        let (dusty, dustyCovers) = try run(true)
        #expect(!plainCovers.contains("dust") && dustyCovers.contains("dust"))
        // The dust is passive: the air and the structure come out as without it.
        #expect(plain == dusty)
    }
}
