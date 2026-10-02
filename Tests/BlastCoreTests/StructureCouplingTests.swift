import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Checks that the air loads the structure correctly and that the coupled run behaves sensibly.
@Suite("Structure coupling")
struct StructureCouplingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private static let elastic = StructureMaterial.elastic(
        density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)

    @Test("A block immersed in pressurised air settles into hydrostatic compression")
    func hydrostaticPressure() throws {
        var scenario = Scenario(
            name: "Pressure vessel", domainSize: SIMD3(4, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [Box(min: SIMD3(1.5, 1.5, 1.5), max: SIMD3(2.5, 2.5, 2.5))], material: Self.elastic,
                elementSize: 0.125, fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.damping = 20_000

        let overpressure: Float = 200_000
        solver.fill(
            uniform: Primitive(
                density: scenario.atmosphere.density, pressure: scenario.atmosphere.pressure + overpressure))
        #expect(solver.grid.cellCount - solver.fluidCellCount == 64)
        let result = solver.advance(steps: 80)
        #expect(result.isStable)

        let stress = structure.stress(4, 4, 4)
        for component in 0..<3 {
            #expect(abs(stress[component] + overpressure) / overpressure < 0.03, "stress \(stress)")
        }
        for component in 3..<6 {
            #expect(abs(stress[component]) / overpressure < 0.01, "stress \(stress)")
        }
        // Balanced pressure must not push the block anywhere.
        let drift = structure.momentum()
        #expect(simd_length(drift) < 1e-3 * Double(overpressure) * solver.time, "momentum \(drift)")
        #expect(structure.summary().maxDisplacement < 1e-4)
    }

    @Test("A free wall gains exactly the impulse the air delivers to its face")
    func impulseTransfer() throws {
        // A shock tube closed by a free wall: only the wall's near face is ever loaded, and the
        // driver gas keeps that face above ambient pressure throughout.
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            gauges: [Gauge("Face", at: SIMD3(7.9, 2, 2))],
            structure: StructureModel(
                solids: [Box(x: 8...8.5, y: 0...4, height: 4)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let ambient = scenario.atmosphere
        solver.fill { i, _, _ in
            Primitive(
                density: ambient.density * (i < 8 ? 4 : 1), pressure: ambient.pressure * (i < 8 ? 5 : 1))
        }
        solver.advance(until: 0.025)

        let history = try #require(solver.gaugeHistories.first)
        let peak = history.map(\.pressure).max() ?? 0
        #expect(peak > 2 * ambient.pressure, "the shock should have reflected off the wall")
        // The comparison below is only exact if the face has never seen suction.
        #expect(history.allSatisfy { $0.pressure >= ambient.pressure - 1 })

        // Impulse recorded by the air cells touching the wall's near face (i = 31).
        var delivered = 0.0
        for k in 0..<solver.grid.nz {
            for j in 0..<solver.grid.ny {
                #expect(solver.isSolid(32, j, k) && !solver.isSolid(31, j, k))
                delivered += Double(solver.impulse(31, j, k)) * 0.25 * 0.25
            }
        }
        let momentum = structure.momentum()
        #expect(delivered > 10_000, "delivered \(delivered) N s")
        #expect(abs(momentum.x - delivered) / delivered < 0.01, "momentum \(momentum.x) vs \(delivered) N s")
        #expect(abs(momentum.y) + abs(momentum.z) < 0.001 * delivered)
    }

    @Test("A cantilever wall bends away from a moderate charge and survives")
    func wallSurvivesModerateCharge() throws {
        let scenario = ScenarioPreset.blastWall.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        let result = solver.advance(until: 0.06)
        #expect(result.isStable)

        let summary = structure.summary()
        #expect(summary.erodedElements == 0)
        #expect(summary.maxPlasticStrain > 0, "the base should have yielded")
        // Top of the wall at mid-length, on the face away from the charge.
        let top = structure.displacement(structure.ex, structure.ey / 2, structure.ez)
        #expect(top.x > 0.01 && top.x < 0.5, "top deflection \(top.x) m")
        #expect(abs(top.y) < 0.01)
        // The clamped base has not moved.
        #expect(simd_length(structure.displacement(0, structure.ey / 2, 0)) == 0)
    }

    @Test("The same wall is breached by a much larger charge")
    func wallFailsUnderLargeCharge() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.charge.mass = 500
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        let result = solver.advance(until: 0.06)
        #expect(result.isStable)

        let summary = structure.summary()
        #expect(summary.erodedElements > 100, "eroded \(summary.erodedElements)")
        #expect(structure.hasFailed)
        #expect(!structure.summary().hasBlownUp)
        #expect(summary.maxDisplacement > 0.2, "displacement \(summary.maxDisplacement) m")
        // Restarting restores the undamaged wall.
        solver.restart()
        #expect(structure.summary().erodedElements == 0)
        #expect(structure.summary().maxDisplacement == 0)
    }

    // MARK: Two-way coupling

    /// A shock tube whose far half is sealed off by a wall clamped to the ground.
    private func makeSealedTube() throws -> (
        solver: BlastSolver, structure: StructureSolver, ambient: Atmosphere
    ) {
        var scenario = Scenario(
            name: "Sealed tube", domainSize: SIMD3(16, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            gauges: [Gauge("Downstream", at: SIMD3(12, 2, 2))],
            structure: StructureModel(
                solids: [Box(x: 8...8.5, y: 0...4, height: 4)], material: Self.elastic, elementSize: 0.125))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        let ambient = scenario.atmosphere
        solver.fill { i, _, _ in
            Primitive(
                density: ambient.density * (i < 8 ? 4 : 1), pressure: ambient.pressure * (i < 8 ? 5 : 1))
        }
        return (solver, structure, ambient)
    }

    @Test("An intact wall keeps the air behind it undisturbed")
    func intactWallSeals() throws {
        let (solver, structure, ambient) = try makeSealedTube()
        solver.advance(until: 0.03)
        let downstream = try #require(solver.gaugeHistories.first)
        #expect(downstream.allSatisfy { abs($0.pressure - ambient.pressure) < 1 })
        #expect(solver.isSolid(32, 8, 8) && solver.isSolid(33, 8, 8))
        #expect(!structure.hasFailed)
    }

    @Test("A hole in the wall opens the air's mask and lets the blast through")
    func breachVents() throws {
        let (solver, structure, ambient) = try makeSealedTube()
        // Knock out a 1 m square through the full thickness of the wall.
        structure.erode { _, j, k in (12..<20).contains(j) && (12..<20).contains(k) }
        #expect(structure.hasFailed)
        #expect(!structure.summary().hasBlownUp)
        solver.advance(steps: 1)
        #expect(!solver.isSolid(32, 8, 8) && !solver.isSolid(33, 8, 8), "the hole should be open to the air")
        #expect(solver.isSolid(32, 2, 2) && solver.isSolid(33, 14, 14), "the rest of the wall should remain")
        let refilled = solver.primitive(32, 8, 8)
        #expect(refilled.density > 0 && refilled.pressure >= ambient.pressure * 0.99)

        let result = solver.advance(until: 0.03)
        #expect(result.isStable)
        let downstream = try #require(solver.gaugeHistories.first)
        let peak = (downstream.map(\.pressure).max() ?? 0) - ambient.pressure
        #expect(peak > 10_000, "downstream overpressure \(peak) Pa")
    }

    @Test("The air's mask travels with a wall that is pushed along")
    func maskFollowsMovingWall() throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [Box(x: 8...8.5, y: 0...4, height: 4)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let ambient = scenario.atmosphere
        solver.fill { i, _, _ in
            Primitive(
                density: ambient.density * (i < 8 ? 4 : 1), pressure: ambient.pressure * (i < 8 ? 5 : 1))
        }
        let result = solver.advance(until: 0.12)
        #expect(result.isStable)

        let travel = structure.displacement(0, 16, 16).x
        #expect(travel > 0.5, "the wall should have moved at least two cells, moved \(travel) m")
        let centre = solver.grid.cell(containing: SIMD3(8.25 + travel, 2, 2))
        #expect(solver.isSolid(centre.i, centre.j, centre.k))
        #expect(!solver.isSolid(centre.i - 2, centre.j, centre.k), "the cells the wall left should be air")
        #expect(!solver.isSolid(centre.i + 2, centre.j, centre.k))
        // Still airtight: nothing has reached the far end.
        #expect(abs(solver.primitive(62, 8, 8).pressure - ambient.pressure) < 0.05 * ambient.pressure)
    }

    // MARK: Long runs

    @Test("Once the blast has passed, the air is frozen and the structure carries on alone")
    func airGoesToSleep() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.charge.mass = 20
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let structure = try #require(solver.structure)
        // Treat anything under 30 kPa as quiet, so that sleep comes soon after the wave has gone.
        solver.configuration.airSleepThreshold = 0.3
        solver.advance(until: 0.01)
        #expect(!solver.airIsAsleep, "the blast is still in the domain")

        solver.advance(until: 0.12)
        #expect(solver.airIsAsleep)
        let air = solver.primitive(20, 32, 4)
        let top = structure.displacement(structure.ex, structure.ey / 2, structure.ez).x
        let steps = solver.stepCount

        let result = solver.advance(until: 0.2)
        #expect(result.isStable)
        #expect(abs(solver.time - 0.2) < 1e-6)
        #expect(solver.stepCount > steps)
        #expect(solver.primitive(20, 32, 4) == air, "the air should no longer change")
        let later = structure.displacement(structure.ex, structure.ey / 2, structure.ez).x
        #expect(later != top, "the wall should still be swinging")

        solver.restart()
        #expect(!solver.airIsAsleep)
    }
}

/// A larger structure: the two-storey frame, on its own under gravity.
@Suite("Frame")
struct FrameTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("The frame carries its own weight")
    func standsUnderGravity() throws {
        let model = try #require(ScenarioPreset.frame.scenario.structure)
        let solver = try StructureSolver(device: device, model: model)
        solver.advance(steps: Int(0.3 / solver.criticalTimeStep))
        let summary = solver.summary()
        #expect(summary.erodedElements == 0)
        #expect(
            summary.maxDisplacement > 1e-4 && summary.maxDisplacement < 0.005,
            "sag \(summary.maxDisplacement) m")
    }

    @Test("With a ground-floor column taken away, the slabs bridge the gap")
    func bridgesLostColumn() throws {
        let model = try #require(ScenarioPreset.frame.scenario.structure)
        let solver = try StructureSolver(device: device, model: model)
        // The middle front column, from the ground to the underside of the first slab.
        solver.erode { i, j, k in (48...50).contains(i) && j <= 2 && k < 26 }
        let removed = solver.summary().erodedElements
        #expect(removed == 3 * 3 * 26)

        solver.advance(steps: Int(0.8 / solver.criticalTimeStep))
        let summary = solver.summary()
        #expect(summary.erodedElements == removed, "nothing else should fail")
        // The slab edge above the missing column sags, but only by millimetres.
        let sag = -solver.displacement(49, 1, 28).z
        #expect(sag > 0.004 && sag < 0.1, "sag \(sag) m")
        // Both floors move together: the column above hangs from the upper slab.
        #expect(abs(solver.displacement(49, 1, 56).z + sag) < 0.005)
    }
}
