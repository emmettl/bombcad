import BlastModel
import Foundation
import Metal
import simd

extension ExperimentalRigidBoxStudy {
    /// Identical saved inputs on three uniform grids, a halved timestep on the finest,
    /// and factor-two adaptive held/free comparisons.
    /// Extended mode adds 0.025 m uniform grids at both timesteps and adaptive runs
    /// with 0.05 m fine cells. Adaptive cases have a 128 MiB patch budget.
    /// The closed domain isolates mass conservation from boundary outflow; its reflections
    /// are part of this study, so it must not be compared directly with the open-domain demo.
    public static func run(
        device: MTLDevice, extended: Bool = false,
        remapMode: ExperimentalBoxRemap = .redistribution,
        completed: ((Result) throws -> Void)? = nil
    ) throws -> [Result] {
        let object = try RigidObjectDefinition(
            name: "Study box", shape: .box(size: SIMD3(repeating: 0.8)),
            position: SIMD3(2, 2, 0.4), mass: 2)
        var scene = Scenario(
            name: "Rigid box convergence", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.1, position: SIMD3(0.5, 2, 0)), rigidObjects: [object])
        scene.reflectiveFaces = .all
        var results: [Result] = []
        var cases: [(Float, Float, Int)] = [
            (Float(0.2), Float(0.45), 1), (0.1, 0.45, 1),
            (0.05, 0.45, 1), (0.05, 0.225, 1), (0.2, 0.45, 2),
        ]
        if extended {
            cases += [(0.025, 0.45, 1), (0.025, 0.225, 1), (0.1, 0.45, 2), (0.2, 0.45, 4)]
        }
        for (cell, cfl, ratio) in cases {
            let modes = [true, false]
            for held in modes {
                var config = SolverConfiguration()
                config.cfl = cfl
                config.refinement = ratio
                if ratio > 1 { config.refinementMemory = 128 << 20 }
                let simulation = try ExperimentalRigidBoxSimulation(
                    device: device, scenario: scene,
                    cellSize: cell, configuration: config, motion: held ? .held : .free)
                simulation.remapMode = remapMode
                simulation.recordsRemapTimings = true
                let initialTotals = simulation.air.totals()
                let initialPosition = simulation.position
                var linear = SIMD3<Double>.zero
                var angular = SIMD3<Double>.zero
                var ground = SIMD3<Double>.zero
                var groundAngular = SIMD3<Double>.zero
                let started = Date.timeIntervalSinceReferenceDate
                while simulation.air.time < 0.03 - 1e-8 {
                    try simulation.advance(steps: 1, timeLimit: 0.03)
                    linear += simulation.lastImpulse
                    angular += simulation.lastAngularImpulse
                    ground += simulation.lastGroundImpulse
                    groundAngular += simulation.lastGroundAngularImpulse
                }
                results.append(
                    Result(
                        remapMode: remapMode,
                        cellSize: cell, cfl: cfl, refinement: ratio, held: held,
                        time: simulation.air.time, steps: simulation.air.stepCount,
                        displacement: simulation.position - initialPosition, velocity: simulation.velocity,
                        linearImpulse: linear, angularImpulse: angular,
                        groundImpulse: ground, groundAngularImpulse: groundAngular,
                        orientation: simulation.orientation, angularMomentum: simulation.angularMomentum,
                        initialGasMass: initialTotals.mass, initialGasEnergy: initialTotals.energy,
                        relativeMassChange: simulation.air.totals().mass / initialTotals.mass - 1,
                        computeSeconds: Date.timeIntervalSinceReferenceDate - started,
                        remapTimings: simulation.remapTimings))
                try completed?(results.last!)
            }
        }
        return results
    }
}
