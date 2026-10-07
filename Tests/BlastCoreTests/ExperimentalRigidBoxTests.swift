import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Experimental rigid-box coupling", .serialized)
struct ExperimentalRigidBoxTests {
    let device: MTLDevice
    init() throws { device = try #require(MTLCreateSystemDefaultDevice()) }

    @Test("Connected remapping preserves a uniform field and transports gradients around solid cells")
    func connectedRemap() throws {
        let old = (0..<9).map { $0 == 4 || $0 == 8 }
        let new = (0..<9).map { $0 == 0 || $0 == 4 }
        func neighbours(_ n: Int) -> [Int] {
            let x = n % 3
            let y = n / 3
            return [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                .filter { $0.0 >= 0 && $0.0 < 3 && $0.1 >= 0 && $0.1 < 3 }
                .map { $0.0 + 3 * $0.1 }
        }
        for gradient in [false, true] {
            let cells = (0..<9).map { n in
                CellState(
                    Primitive(
                        density: gradient ? 1 + Float(n) : 1.225,
                        velocity: SIMD3(1, 2, 3), pressure: gradient ? 101325 + 100 * Float(n) : 101325),
                    gamma: 1.4)
            }
            let remapped = try ConservativeCellRemap.apply(
                cells, oldSolid: old, newSolid: new, mode: .connectedTransport, neighbours: neighbours)
            func sum(_ field: [CellState], mask: [Bool]) -> SIMD8<Double> {
                field.indices.filter { !mask[$0] }.reduce(.zero) { total, n in
                    let c = field[n]
                    return total
                        + SIMD8(
                            Double(c.density), Double(c.momentumX), Double(c.momentumY),
                            Double(c.momentumZ), Double(c.energy), 0, 0, 0)
                }
            }
            #expect(sum(cells, mask: old) == sum(remapped, mask: new))
            #expect(remapped[4].energy == cells[4].energy)
            if !gradient {
                for n in cells.indices where !new[n] {
                    #expect(remapped[n].density == cells[0].density)
                    #expect(remapped[n].energy == cells[0].energy)
                }
            }
        }
        let cells = Array(
            repeating: CellState(Primitive(density: 1.225, pressure: 101325), gamma: 1.4), count: 3)
        #expect(throws: ConservativeCellRemap.Failure.self) {
            try ConservativeCellRemap.apply(
                cells, oldSolid: [false, true, true],
                newSolid: [true, true, false], mode: .connectedTransport
            ) { n in
                [n - 1, n + 1].filter { (0..<3).contains($0) }
            }
        }
    }

    @Test(
        "Controlled diagnostics separate conservative remapping, gas loading and ground impulses",
        arguments: [ExperimentalBoxRemap.redistribution, .connectedTransport])
    func controlledDiagnostics(mode: ExperimentalBoxRemap) throws {
        // Physical budgets need one grid here; the release CLI performs the full spatial study.
        let results = try ExperimentalRigidBoxDiagnostics.run(
            device: device, cellSizes: [0.2], remapMode: mode)
        for r in results {
            if r.kind.hasPrefix("remap-") {
                #expect(abs(try #require(r.relativeGasMassChange)) < 1e-7)
                #expect(abs(try #require(r.relativeGasEnergyChange)) < 1e-7)
                #expect(simd_length(try #require(r.gasMomentumChange)) < 1e-8)
                #expect(abs(r.displacement.x - 0.12) < 1e-10)
                if mode == .connectedTransport {
                    #expect(try #require(r.maximumRelativePressureError) < 1e-7)
                }
            } else if r.kind == "uniform-flow-no-contact" {
                // With no gravity/contact, the body must receive precisely the recorded gas impulse.
                #expect(simd_length(2 * r.velocity - r.appliedImpulse) < 1e-8)
                #expect(r.groundImpulse == .zero)
            } else {
                // Includes gravity, whose integral is known independently of the contact algorithm.
                let expected = r.appliedImpulse + r.groundImpulse + SIMD3<Double>(0, 0, -2 * 9.81 * r.time)
                #expect(simd_length(2 * r.velocity - expected) < 1e-8)
                #expect(abs(r.appliedImpulse.x - 5) < 1e-10)
            }
        }
        let contact = results.filter { $0.kind == "contact-only" }
        let finest = try #require(contact.last)
        let preceding = contact[contact.count - 2]
        #expect(simd_length(finest.velocity - preceding.velocity) < 1e-4)
        #expect(simd_length(finest.displacement - preceding.displacement) < 1e-4)
    }

    private func scenario(position: SIMD3<Double> = SIMD3(2, 2, 2)) throws -> Scenario {
        Scenario(
            name: "One box", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 2, 2)),
            rigidObjects: [
                try RigidObjectDefinition(
                    name: "Box", shape: .box(size: SIMD3(repeating: 0.8)),
                    position: position, mass: 10)
            ])
    }

    @Test("Ambient air exerts no net box load and preserves gas")
    func ambientBalance() throws {
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scenario(), cellSize: 0.2)
        simulation.gravity = .zero
        let before = simulation.air.totals()
        try simulation.advance(steps: 10)
        #expect(simd_length(simulation.velocity) < 1e-8)
        #expect(simd_length(simulation.lastAngularImpulse) < 1e-8)
        #expect(abs(simulation.air.totals().mass / before.mass - 1) < 1e-7)
    }

    @Test("Coupled stepping clips to a common end time and does not advance beyond it")
    func commonEndTime() throws {
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scenario(),
            cellSize: 0.2, motion: .held)
        let end = 0.00013
        try simulation.advance(steps: 100, timeLimit: end)
        #expect(abs(simulation.air.time - end) < 1e-8)
        let time = simulation.air.time
        let steps = simulation.air.stepCount
        try simulation.advance(steps: 10, timeLimit: end)
        #expect(simulation.air.time == time && simulation.air.stepCount == steps)
    }

    @Test("Numerical wall impulse balances the gas momentum change before remasking")
    func momentumExchange() throws {
        var scene = try scenario()
        scene.reflectiveFaces = []
        var config = SolverConfiguration()
        config.startupSteps = 1
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scene, cellSize: 0.2, configuration: config)
        simulation.gravity = .zero
        simulation.air.fill { _, _, _ in
            Primitive(density: 1.225, velocity: SIMD3(20, 0, 0), pressure: 101325)
        }
        let gasBefore = simulation.air.momentum()
        try simulation.advance(steps: 1)
        #expect(simulation.lastImpulse.x > 0)
        #expect(simd_length(simulation.air.momentum() - gasBefore + simulation.lastImpulse) < 5e-4)
        #expect(simd_length(10 * simulation.velocity - simulation.lastImpulse) < 1e-8)
        #expect(simd_length(simulation.angularMomentum - simulation.lastAngularImpulse) < 1e-8)
    }

    @Test("Cell crossings fill exposed gas conservatively instead of creating or losing mass")
    func movingMask() throws {
        var scene = try scenario(position: SIMD3(2.095, 2, 2))
        scene.reflectiveFaces = .all
        let simulation = try ExperimentalRigidBoxSimulation(device: device, scenario: scene, cellSize: 0.2)
        simulation.gravity = .zero
        let before = simulation.air.totals()
        let count = simulation.air.fluidCellCount
        try simulation.applyImpulse(SIMD3(10, 0, 0))
        try simulation.advance(steps: 100)
        #expect(simulation.position.x > 2.1)
        #expect(simulation.air.fluidCellCount == count)
        #expect(abs(simulation.air.totals().mass / before.mass - 1) < 1e-6)
        #expect(
            simulation.air.withState {
                $0.allSatisfy { $0.density.isFinite && $0.density > 0 && $0.energy.isFinite }
            })
    }

    @Test("Remapping alone conserves all five gas quantities across a prescribed cell crossing")
    func conservativeRemap() throws {
        let scene = try scenario()
        let simulation = try ExperimentalRigidBoxSimulation(device: device, scenario: scene, cellSize: 0.2)
        simulation.air.fill { _, _, _ in Primitive(density: 1.225, velocity: SIMD3(1, 2, 3), pressure: 101325)
        }
        let before = simulation.air.totals()
        let momentum = simulation.air.momentum()
        var moved = try #require(scene.rigidObjects?.first).makeBody()
        moved.applyImpulse(SIMD3(10, 0, 0))
        moved.advance(by: 0.2, gravity: .zero)
        try simulation.air.updateExperimentalBox(moved)
        let after = simulation.air.totals()
        #expect(abs(after.mass / before.mass - 1) < 1e-7)
        #expect(abs(after.energy / before.energy - 1) < 1e-7)
        #expect(simd_length(simulation.air.momentum() - momentum) < 1e-5)
    }

    @Test("Pressure-gradient loading converges with grid resolution and gives torque about an offset centre")
    func forceAndTorqueConvergence() throws {
        func force(cell: Float, cfl: Float) throws -> SIMD3<Double> {
            var scene = try scenario()
            scene.rigidObjects = [
                try RigidObjectDefinition(
                    name: "Offset box", shape: .box(size: SIMD3(repeating: 0.8)),
                    position: SIMD3(2, 2, 2), mass: 10, centreOfMass: SIMD3(0, 0.1, 0),
                    inertia: SIMD3(repeating: 1))
            ]
            var config = SolverConfiguration()
            config.cfl = cfl
            config.startupSteps = 1
            let simulation = try ExperimentalRigidBoxSimulation(
                device: device, scenario: scene, cellSize: cell,
                configuration: config, motion: .held)
            simulation.air.fill { i, _, _ in
                Primitive(density: 1.225, pressure: 101325 + 1000 * (Float(i) + 0.5) * cell)
            }
            try simulation.advance(steps: 1)
            #expect(abs(simulation.lastAngularImpulse.z - 0.1 * simulation.lastImpulse.x) < 1e-6)
            return simulation.lastImpulse / simulation.air.time
        }
        let expected = -1000 * 0.8 * 0.8 * 0.8
        let coarse = try force(cell: 0.2, cfl: 0.1)
        let fine = try force(cell: 0.1, cfl: 0.1)
        let smallerStep = try force(cell: 0.1, cfl: 0.05)
        #expect(abs(fine.x - expected) < 0.8 * abs(coarse.x - expected))
        #expect(abs(fine.x / expected - 1) < 0.2)
        #expect(simd_length(smallerStep - fine) / abs(expected) < 0.01)
    }

    @Test("A held box responds to a blast while existing scenario loading leaves experimental inputs inert")
    func blastAndOptIn() throws {
        var scene = try scenario()
        scene.charge.mass = 0.01
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scene, cellSize: 0.2, motion: .held)
        var largest = 0.0
        for _ in 0..<100 {
            try simulation.advance(steps: 1)
            largest = max(largest, simd_length(simulation.lastImpulse))
        }
        #expect(largest > 0.01)
        #expect(simulation.position == SIMD3(2, 2, 2))
        let ordinary = try BlastSolver(device: device, scenario: scene, cellSize: 0.2)
        #expect(ordinary.fluidCellCount == ordinary.grid.cellCount)
    }

    @Test("A held grid-aligned box can be loaded by refined air without duplicate coarse impulses")
    func refinedHeldBox() throws {
        var scene = try scenario()
        scene.reflectiveFaces = []
        var config = SolverConfiguration()
        config.refinement = 2
        config.startupSteps = 1
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scene, cellSize: 0.2,
            configuration: config, motion: .held)
        simulation.air.fill { _, _, _ in
            Primitive(density: 1.225, velocity: SIMD3(20, 0, 0), pressure: 101325)
        }
        let momentum = simulation.air.momentum()
        try simulation.advance(steps: 1)
        #expect(simulation.lastImpulse.x > 0)
        #expect(simd_length(simulation.air.momentum() - momentum + simulation.lastImpulse) < 1e-3)
        #expect(simulation.position == SIMD3(2, 2, 2))
    }

    @Test("Refined held-box force agrees with a uniform grid at the same fine resolution", arguments: [2, 4])
    func refinedForceReference(ratio: Int) throws {
        func force(cell: Float, ratio: Int) throws -> SIMD3<Double> {
            var config = SolverConfiguration()
            config.refinement = ratio
            config.cfl = 0.1
            config.startupSteps = 1
            let simulation = try ExperimentalRigidBoxSimulation(
                device: device, scenario: scenario(), cellSize: cell,
                configuration: config, motion: .held)
            simulation.air.fill { i, _, _ in
                Primitive(density: 1.225, pressure: 101325 + 1000 * (Float(i) + 0.5) * cell)
            }
            if let refinement = simulation.air.refinement {
                // Give both grids the same analytic initial field. Prolongation next to a wall
                // otherwise flattens a coarse slope and obscures the load-integration check.
                var fine: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)] = [:]
                let h = cell / Float(ratio)
                for k in 0..<(simulation.air.grid.nz * ratio) {
                    for j in 0..<(simulation.air.grid.ny * ratio) {
                        for i in 0..<(simulation.air.grid.nx * ratio) {
                            fine[SIMD3(i, j, k)] = (
                                simulation.air.cellState(
                                    Primitive(density: 1.225, pressure: 101325 + 1000 * (Float(i) + 0.5) * h)),
                                .zero
                            )
                        }
                    }
                }
                refinement.setFine(fine)
            }
            try simulation.advance(steps: 1)
            return simulation.lastImpulse / simulation.air.time
        }
        let refined = try force(cell: 0.2, ratio: ratio)
        let uniform = try force(cell: 0.2 / Float(ratio), ratio: 1)
        #expect(simd_length(refined - uniform) / simd_length(uniform) < 0.02)
    }

    @Test("Refinement accepts unaligned geometry but rejects inadequate patch coverage")
    func refinedCoverageLimits() throws {
        var config = SolverConfiguration()
        config.refinement = 2
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device,
            scenario: scenario(position: SIMD3(2.05, 2, 2)), cellSize: 0.2, configuration: config)
        #expect(simulation.air.refinement != nil)
        config.refinementMemory = 1
        #expect(throws: ExperimentalRigidBoxSimulation.Failure.self) {
            try ExperimentalRigidBoxSimulation(
                device: device, scenario: scenario(), cellSize: 0.2,
                configuration: config)
        }
    }

    @Test("Moving refined walls exchange equal and opposite momentum with the free box", arguments: [2, 4])
    func refinedMovingMomentum(ratio: Int) throws {
        var scene = try scenario()
        scene.reflectiveFaces = []
        var config = SolverConfiguration()
        config.refinement = ratio
        config.refinementMemory = 128 << 20
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scene, cellSize: 0.2,
            configuration: config)
        simulation.gravity = .zero
        try simulation.applyImpulse(SIMD3(10, 0, 0))
        let momentum = simulation.air.momentum() + 10 * simulation.velocity
        try simulation.advance(steps: 10)
        #expect(simulation.velocity.x < 1 && simulation.velocity.x > 0)
        #expect(simd_length(simulation.air.momentum() + 10 * simulation.velocity - momentum) < 1e-3)
    }

    @Test(
        "Fine-cell translation across patch boundaries and rotation conserve gas quantities",
        arguments: [ExperimentalBoxRemap.redistribution, .connectedTransport])
    func refinedConservativeRemap(mode: ExperimentalBoxRemap) throws {
        var scene = try scenario(position: SIMD3(2.095, 2, 2))
        scene.domainSize.x = 8
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementMemory = 32 << 20
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scene, cellSize: 0.2,
            configuration: config)
        simulation.remapMode = mode
        simulation.air.fill { _, _, _ in Primitive(density: 1.225, velocity: SIMD3(1, 2, 3), pressure: 101325)
        }
        let before = simulation.air.totals()
        let momentum = simulation.air.momentum()
        var moved = try #require(scene.rigidObjects?.first).makeBody()
        moved.applyImpulse(SIMD3(10, 0, 0))
        moved.applyAngularImpulse(SIMD3(0, 1, 0))
        moved.advance(by: 0.12, gravity: .zero)
        try simulation.air.updateExperimentalBox(moved)
        let after = simulation.air.totals()
        #expect(abs(after.mass / before.mass - 1) < 1e-7)
        #expect(abs(after.energy / before.energy - 1) < 1e-7)
        #expect(simd_length(simulation.air.momentum() - momentum) < 1e-5)
    }

    @Test(
        "A refined ground gap can open and close without losing gas or energy",
        arguments: [ExperimentalBoxRemap.redistribution, .connectedTransport])
    func refinedGroundGap(mode: ExperimentalBoxRemap) throws {
        let scene = try scenario(position: SIMD3(2, 2, 0.4))
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementMemory = 32 << 20
        let simulation = try ExperimentalRigidBoxSimulation(
            device: device, scenario: scene, cellSize: 0.2, configuration: config)
        simulation.remapMode = mode
        let before = simulation.air.totals()
        var moved = try #require(scene.rigidObjects?.first).makeBody()
        moved.applyImpulse(SIMD3(0, 0, 1))
        moved.advance(by: 0.6, gravity: .zero)
        try simulation.air.updateExperimentalBox(moved)
        let opened = simulation.air.totals()
        #expect(abs(opened.mass / before.mass - 1) < 1e-7)
        #expect(abs(opened.energy / before.energy - 1) < 1e-7)
        moved.applyImpulse(SIMD3(0, 0, -2))
        moved.advance(by: 0.6, gravity: .zero)
        try simulation.air.updateExperimentalBox(moved)
        let closed = simulation.air.totals()
        #expect(abs(closed.mass / before.mass - 1) < 1e-7)
        #expect(abs(closed.energy / before.energy - 1) < 1e-7)
    }

    @Test(
        "Fine remapping is independent of GPU patch-slot allocation",
        arguments: [ExperimentalBoxRemap.redistribution, .connectedTransport])
    func patchOrderIndependence(mode: ExperimentalBoxRemap) throws {
        let scene = try scenario(position: SIMD3(2.095, 2, 2))
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementMemory = 32 << 20
        func make() throws -> ExperimentalRigidBoxSimulation {
            let s = try ExperimentalRigidBoxSimulation(
                device: device, scenario: scene, cellSize: 0.2, configuration: config)
            s.remapMode = mode
            s.air.fill { i, j, k in
                Primitive(
                    density: 1.225, velocity: SIMD3(Float(i) * 0.01, Float(j) * 0.01, Float(k) * 0.01),
                    pressure: 101325 + Float(i + j + k) * 100)
            }
            return s
        }
        let first = try make()
        let second = try make()
        let reference = try make()
        try #require(reference.air.refinement).useLocalBoxRemap = false
        let r = try #require(second.air.refinement)
        let cells = r.side * r.side * r.side
        let owners = r.tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: r.maxPatches)
        let active = (0..<r.maxPatches).filter { owners[$0] != .max }
        let a = try #require(active.first)
        let b = try #require(active.last)
        let state = r.fine[0].contents().bindMemory(to: CellState.self, capacity: r.maxPatches * cells)
        let mask = r.fineMask.contents().bindMemory(to: UInt8.self, capacity: r.maxPatches * cells)
        let map = r.patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: r.tileDims.x * r.tileDims.y * r.tileDims.z)
        let ownerA = owners[a]
        let ownerB = owners[b]
        owners[a] = ownerB
        owners[b] = ownerA
        map[Int(ownerA)] = Int32(b)
        map[Int(ownerB)] = Int32(a)
        for n in 0..<cells {
            let oldState = state[a * cells + n]
            let oldMask = mask[a * cells + n]
            state[a * cells + n] = state[b * cells + n]
            mask[a * cells + n] = mask[b * cells + n]
            state[b * cells + n] = oldState
            mask[b * cells + n] = oldMask
        }
        var moved = try #require(scene.rigidObjects?.first).makeBody()
        moved.applyImpulse(SIMD3(10, 0, 0))
        moved.applyAngularImpulse(SIMD3(0, 1, 0))
        moved.advance(by: 0.12, gravity: .zero)
        try first.air.updateExperimentalBox(moved)
        try second.air.updateExperimentalBox(moved)
        try reference.air.updateExperimentalBox(moved)
        func snapshot(_ air: BlastSolver) throws -> [SIMD3<Int>: CellState] {
            let r = try #require(air.refinement)
            let count = r.side * r.side * r.side
            let owners = r.tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: r.maxPatches)
            let state = r.fine[0].contents().bindMemory(to: CellState.self, capacity: r.maxPatches * count)
            let mask = r.fineMask.contents().bindMemory(to: UInt8.self, capacity: r.maxPatches * count)
            var result: [SIMD3<Int>: CellState] = [:]
            for patch in 0..<r.maxPatches where owners[patch] != .max {
                let tile = Int(owners[patch])
                let origin =
                    SIMD3(
                        tile % r.tileDims.x, (tile / r.tileDims.x) % r.tileDims.y,
                        tile / (r.tileDims.x * r.tileDims.y)) &* r.side
                for n in 0..<count where mask[patch * count + n] & 1 == 0 {
                    result[origin &+ SIMD3(n % r.side, (n / r.side) % r.side, n / (r.side * r.side))] =
                        state[patch * count + n]
                }
            }
            return result
        }
        #expect(try snapshot(first.air) == snapshot(second.air))
        #expect(try snapshot(first.air) == snapshot(reference.air))
    }
}
