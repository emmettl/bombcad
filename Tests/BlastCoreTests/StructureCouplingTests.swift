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

    @Test("An intact wall lets through only the sound it makes by flexing")
    func intactWallSeals() throws {
        let (solver, structure, ambient) = try makeSealedTube()
        solver.advance(until: 0.03)
        let downstream = try #require(solver.gaugeHistories.first)
        let loudest = downstream.map { abs($0.pressure - ambient.pressure) }.max() ?? 0
        // The wall's top swings a few metres per second, which radiates a few hundred pascals;
        // a breach lets through more than ten kilopascals.
        #expect(loudest > 50 && loudest < 2000, "downstream overpressure \(loudest) Pa")
        #expect(solver.isSolid(32, 8, 8) && solver.isSolid(33, 8, 8))
        #expect(!structure.hasFailed)
    }

    @Test("A wall treated as stationary keeps the air behind it undisturbed")
    func stationaryWallSeals() throws {
        let (solver, _, ambient) = try makeSealedTube()
        solver.configuration.movingWalls = false
        solver.advance(until: 0.03)
        let downstream = try #require(solver.gaugeHistories.first)
        #expect(downstream.allSatisfy { abs($0.pressure - ambient.pressure) < 1 })
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
        // Still airtight: the air beyond the wall has only been squeezed by the wall's advance.
        let squeezed = ambient.pressure * pow(7.5 / (7.5 - travel), 1.4)
        let far = solver.primitive(62, 8, 8).pressure
        #expect(
            abs(far - squeezed) < 0.05 * squeezed, "far end at \(far) Pa, adiabatic estimate \(squeezed) Pa")
    }

    @Test("A wall driven into still air raises the piston shock ahead and the rarefaction behind")
    func pistonShock() throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 1, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 0.5, 0.5)),
            structure: StructureModel(
                solids: [Box(x: 6...6.5, y: 0...1, height: 1)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let speed: Float = 100
        structure.mutateNodes { nodes in
            for index in nodes.indices {
                nodes[index].velocity = SIMD3(speed, 0, 0)
                nodes[index].isPrescribed = true
            }
        }
        let result = solver.advance(until: 0.01)
        #expect(result.isStable)

        // Exact solutions for a piston started impulsively in a perfect gas.
        let ambient = scenario.atmosphere
        let gamma: Float = 1.4
        let mach = speed / (gamma * ambient.pressure / ambient.density).squareRoot()
        let quarter = (gamma + 1) / 4
        let ahead =
            1 + gamma * quarter * mach * mach + gamma * mach
            * (1 + quarter * quarter * mach * mach).squareRoot()
        let behind = pow(1 - (gamma - 1) / 2 * mach, 2 * gamma / (gamma - 1))

        let face = structure.position(0, 4, 4).x
        #expect(abs(face - 7) < 0.01, "the wall should have travelled 1 m, its rear face is at \(face)")
        let front = solver.grid.cell(containing: SIMD3(face + 0.5 + 0.375, 0.5, 0.5))
        let rear = solver.grid.cell(containing: SIMD3(face - 0.375, 0.5, 0.5))
        for offset in 0..<6 {
            let pressure = solver.primitive(front.i + offset, 2, 2).pressure / ambient.pressure
            #expect(abs(pressure - ahead) < 0.02 * ahead, "ahead of the wall \(pressure), expected \(ahead)")
            let wind = solver.primitive(front.i + offset, 2, 2).velocity.x
            #expect(abs(wind - speed) < 0.02 * speed, "the air ahead moves at \(wind) m/s")
        }
        for offset in 0..<6 {
            let pressure = solver.primitive(rear.i - offset, 2, 2).pressure / ambient.pressure
            #expect(abs(pressure - behind) < 0.02 * behind, "behind the wall \(pressure), expected \(behind)")
        }
    }

    @Test(
        "A wall driven through the grid conserves the gas, once its staircase volume is allowed for",
        arguments: [10, 50, 150] as [Float])
    func movingWallConservesMass(speed: Float) throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 1, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 0.5, 0.5)),
            structure: StructureModel(
                solids: [Box(x: 6...6.5, y: 0...1, height: 1)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        func drive(_ velocity: Float) {
            structure.mutateNodes { nodes in
                for index in nodes.indices {
                    nodes[index].velocity = SIMD3(velocity, 0, 0)
                    nodes[index].isPrescribed = true
                }
            }
        }
        let before = solver.totals()
        // Drive the wall 1.1 m, four and a bit cells, then let the air settle.
        drive(speed)
        solver.advance(until: Double(1.1 / speed))
        drive(0)
        let result = solver.advance(until: Double(1.1 / speed) + 0.05)
        #expect(result.isStable)
        let after = solver.totals()

        // The 0.5 m wall now covers three cells instead of two, so the grid holds one cell's
        // worth less gas than the true volume does. Scaled to the true volume, nothing is lost.
        let cell = Double(pow(solver.grid.cellSize, 3))
        let gridVolume = Double(solver.fluidCellCount) * cell
        let trueVolume = 16.0 - 0.5
        #expect(abs(gridVolume - trueVolume) <= 16 * cell + 1e-9)
        let trueMass = after.mass / gridVolume * trueVolume
        #expect(
            abs(trueMass - before.mass) / before.mass < 0.005,
            "mass change \((trueMass - before.mass) / before.mass)")
    }

    @Test("With moving walls switched off, a driven wall leaves the air undisturbed until it is covered")
    func stationaryWallOption() throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 1, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 0.5, 0.5)),
            structure: StructureModel(
                solids: [Box(x: 6...6.5, y: 0...1, height: 1)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        solver.configuration.movingWalls = false
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        structure.mutateNodes { nodes in
            for index in nodes.indices {
                nodes[index].velocity = SIMD3(100, 0, 0)
                nodes[index].isPrescribed = true
            }
        }
        solver.advance(until: 0.01)
        let ambient = scenario.atmosphere.pressure
        for i in 34..<44 where !solver.isSolid(i, 2, 2) {
            #expect(abs(solver.primitive(i, 2, 2).pressure - ambient) < 0.01 * ambient)
        }
    }

    /// Air in a 4 m cube with open sides, holding the loose nodes of a broken block. The block is
    /// broken and the air's mask opened where it stood, so that the air flows through it.
    private func looseDebris(
        _ block: Box, elementSize: Float, cellSize: Float, domain: Float = 4, debrisDrag: Bool = true,
        air: (_ i: Int, _ j: Int, _ k: Int) -> Primitive
    ) throws -> (BlastSolver, StructureSolver) {
        var scenario = Scenario(
            name: "Debris", domainSize: SIMD3(repeating: domain), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [block], material: Self.elastic, elementSize: elementSize, fixedBase: false))
        scenario.reflectiveFaces = []
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // Steady wind is quiet air to the solver; keep it awake.
        solver.configuration.airSleepThreshold = 0
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        structure.debrisDrag = debrisDrag
        solver.fill(air)
        structure.erode { _, _, _ in true }
        solver.mutateMask { mask in
            for index in mask.indices { mask[index] = 0 }
        }
        return (solver, structure)
    }

    /// One 62.5 mm element in the middle of a 0.5 m air cell: debris too sparse to slow the air.
    private static let sparseBlock = Box(min: SIMD3(2.1875, 2.1875, 2.1875), max: SIMD3(2.25, 2.25, 2.25))

    @Test(
        "Sparse loose debris in a steady wind gains the momentum drag theory predicts",
        arguments: [true, false])
    func debrisDrag(enabled: Bool) throws {
        let ambient = Atmosphere()
        let wind: Float = 100
        let (solver, structure) = try looseDebris(
            Self.sparseBlock, elementSize: 0.0625, cellSize: 0.5, debrisDrag: enabled
        ) { _, _, _ in
            Primitive(density: ambient.density, velocity: SIMD3(wind, 0, 0), pressure: ambient.pressure)
        }
        solver.advance(until: 0.01)
        let elapsed = solver.time

        // Each node stands for a cube of the block's solid of its own mass, with a drag
        // coefficient of one, in the relative wind; it has gained speed steadily, so its mean
        // speed is half its final one. The air is uniform, so there is no pressure gradient.
        var expected = 0.0
        structure.mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                let area = pow(Double(node.mass) / 2400, 2.0 / 3.0)
                let relative = Double(wind - node.vx / 2)
                expected += 0.5 * Double(ambient.density) * area * relative * relative * elapsed
            }
        }
        let momentum = structure.momentum()
        if enabled {
            #expect(abs(momentum.x - expected) / expected < 0.03, "momentum \(momentum.x) vs \(expected) N s")
            #expect(abs(momentum.y) + abs(momentum.z) < 0.01 * expected)
        } else {
            #expect(simd_length(momentum) < 1e-6 * expected)
        }
    }

    @Test("Sparse loose debris in a pressure gradient is pushed down it, as the solid it stands for")
    func debrisPressureGradient() throws {
        let ambient = Atmosphere()
        // Pressure falling by 1 kPa per metre along x. Until waves from the boundaries arrive,
        // the air accelerates uniformly and the gradient stays the same. The gradient is gentle
        // so that the drag of the air it accelerates is a small part of the push.
        let gradient: Float = 1_000
        // In the middle of an 8 m cube of air, so that the open sides do not disturb the gradient
        // around the debris in the time run.
        let block = Box(min: SIMD3(4.1875, 4.1875, 4.1875), max: SIMD3(4.25, 4.25, 4.25))
        let (solver, structure) = try looseDebris(block, elementSize: 0.0625, cellSize: 0.5, domain: 8) {
            i, _, _ in
            Primitive(
                density: ambient.density, pressure: ambient.pressure + gradient * (4 - (Float(i) + 0.5) * 0.5)
            )
        }
        solver.advance(until: 0.001)
        let elapsed = solver.time

        // The gradient's push, G V t per node with V its mass over the solid's density, plus the
        // drag of the air that the same gradient accelerates past it, at G t / rho relative speed.
        let rho = Double(ambient.density)
        let g = Double(gradient)
        var expected = 0.0
        structure.mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                let volume = Double(node.mass) / 2400
                let area = pow(volume, 2.0 / 3.0)
                expected +=
                    g * volume * elapsed + 0.5 * rho * area * g * g / (rho * rho) * pow(elapsed, 3) / 3
            }
        }
        let momentum = structure.momentum()
        #expect(abs(momentum.x - expected) / expected < 0.02, "momentum \(momentum.x) vs \(expected) N s")
        #expect(abs(momentum.y) + abs(momentum.z) < 0.01 * expected)
    }

    @Test("Debris packed into the air conserves momentum, and slows the air through it without reversing it")
    func debrisMomentumExchange() throws {
        let ambient = Atmosphere()
        // Fine debris filling one 0.5 m air cell: unchecked, its drag over one air step would
        // take nearly twice the air's momentum.
        let wind: Float = 300
        // The cell is the middle one of 17, far enough from the open sides that what leaves through
        // them in the time run is negligible.
        let (solver, structure) = try looseDebris(
            Box(min: SIMD3(4, 4, 4), max: SIMD3(4.5, 4.5, 4.5)), elementSize: 0.03125, cellSize: 0.5,
            domain: 8.5
        ) { _, _, _ in
            Primitive(density: ambient.density, velocity: SIMD3(wind, 0, 0), pressure: ambient.pressure)
        }
        // Full-length air steps from the start, as when a blast arrives at debris already flying.
        solver.configuration.startupSteps = 1
        let before = solver.momentum()
        var slowest = Float.infinity
        // Stop before the disturbance reaches the open boundaries, through which momentum
        // would leave.
        while solver.time < 0.002 {
            let result = solver.advance(steps: 1)
            #expect(result.isStable)
            slowest = min(slowest, solver.primitive(8, 8, 8).velocity.x)
        }
        let debris = structure.momentum()
        let total = solver.momentum() + debris
        #expect(debris.x > 5, "debris momentum \(debris.x) N s")
        #expect(
            simd_length(total - before) < 0.01 * debris.x,
            "total momentum changed by \(total - before) N s; debris took \(debris.x) N s")
        #expect(slowest > 0 && slowest < 0.8 * wind, "slowest air in the debris \(slowest) m/s")
    }

    @Test("A wall broken by the blast, run twice, gives the same answer to the last bit")
    func repeatableBreach() throws {
        // Elements failing beside faces the air is loading, and debris colliding, are where
        // thread timing could leak in.
        func run() throws -> (nodes: [StructureNode], failed: Int) {
            var scenario = ScenarioPreset.blastWall.scenario
            scenario.charge.mass = 500
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
            let structure = try #require(solver.structure)
            // Uneven batches, as the app runs them.
            for steps in [7, 64, 3, 128, 1, 256, 256, 256] {
                solver.advance(steps: steps)
            }
            var copy: [StructureNode] = []
            structure.mutateNodes { copy = Array($0) }
            return (copy, structure.summary().erodedElements)
        }
        let first = try run()
        let second = try run()
        #expect(first.failed > 100, "only \(first.failed) elements failed")
        #expect(first.failed == second.failed)
        let differing = zip(first.nodes, second.nodes).filter {
            $0.0.displacement != $0.1.displacement || $0.0.velocity != $0.1.velocity
        }.count
        #expect(differing == 0, "\(differing) of \(first.nodes.count) nodes differ")
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
