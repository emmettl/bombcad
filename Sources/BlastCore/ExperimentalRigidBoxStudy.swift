import Foundation
import Metal
import simd

/// Reproducible resolution/timestep study for the standalone coupling prototype.
/// Uniform fine-grid references plus held/free adaptive comparisons.
public enum ExperimentalRigidBoxStudy {
    public struct Result: Codable, Sendable {
        public let cellSize: Float
        public let cfl: Float
        public let refinement: Int
        public let held: Bool
        public let time: Double
        public let steps: Int
        public let displacement: SIMD3<Double>
        public let velocity: SIMD3<Double>
        public let linearImpulse: SIMD3<Double>
        public let angularImpulse: SIMD3<Double>
        public let relativeMassChange: Double
        public let computeSeconds: Double
    }

    /// Identical saved inputs on three uniform grids, a halved timestep on the finest,
    /// and factor-two adaptive held/free comparisons.
    /// The closed domain isolates mass conservation from boundary outflow; its reflections
    /// are part of this study, so it must not be compared directly with the open-domain demo.
    public static func run(device: MTLDevice) throws -> [Result] {
        let object = try RigidObjectDefinition(
            name: "Study box", shape: .box(size: SIMD3(repeating: 0.8)),
            position: SIMD3(2, 2, 0.4), mass: 2)
        var scene = Scenario(
            name: "Rigid box convergence", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.1, position: SIMD3(0.5, 2, 0)), rigidObjects: [object])
        scene.reflectiveFaces = .all
        var results: [Result] = []
        for (cell, cfl, ratio) in [
            (Float(0.2), Float(0.45), 1), (0.1, 0.45, 1),
            (0.05, 0.45, 1), (0.05, 0.225, 1), (0.2, 0.45, 2),
        ] {
            let modes = [true, false]
            for held in modes {
                var config = SolverConfiguration()
                config.cfl = cfl
                config.refinement = ratio
                if ratio > 1 { config.refinementMemory = 32 << 20 }
                let simulation = try ExperimentalRigidBoxSimulation(
                    device: device, scenario: scene,
                    cellSize: cell, configuration: config, motion: held ? .held : .free)
                let initialMass = simulation.air.totals().mass
                let initialPosition = simulation.position
                var linear = SIMD3<Double>.zero
                var angular = SIMD3<Double>.zero
                let started = Date.timeIntervalSinceReferenceDate
                while simulation.air.time < 0.03 - 1e-8 {
                    try simulation.advance(steps: 1, timeLimit: 0.03)
                    linear += simulation.lastImpulse
                    angular += simulation.lastAngularImpulse
                }
                results.append(
                    Result(
                        cellSize: cell, cfl: cfl, refinement: ratio, held: held,
                        time: simulation.air.time, steps: simulation.air.stepCount,
                        displacement: simulation.position - initialPosition, velocity: simulation.velocity,
                        linearImpulse: linear, angularImpulse: angular,
                        relativeMassChange: simulation.air.totals().mass / initialMass - 1,
                        computeSeconds: Date.timeIntervalSinceReferenceDate - started))
            }
        }
        return results
    }
}
