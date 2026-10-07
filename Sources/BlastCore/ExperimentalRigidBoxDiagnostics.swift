import Foundation
import Metal
import simd

/// Controlled standalone diagnostics, with no change to app scenario loading.
public enum ExperimentalRigidBoxDiagnostics {
    public struct Result: Codable, Sendable {
        public let kind: String
        public let remapMode: ExperimentalBoxRemap
        public let cellSize: Float?
        public let cfl: Float?
        public let mechanicalStep: Double?
        public let time: Double
        public let displacement: SIMD3<Double>
        public let velocity: SIMD3<Double>
        public let orientation: SIMD4<Double>
        public let angularMomentum: SIMD3<Double>
        public let appliedImpulse: SIMD3<Double>
        public let groundImpulse: SIMD3<Double>
        public let relativeGasMassChange: Double?
        public let relativeGasEnergyChange: Double?
        public let gasMomentumChange: SIMD3<Double>?
        public let maximumRelativePressureError: Double?
        public let occupiedVolumeChange: Double?
    }

    /// Remap-only tests have no air evolution or ground; uniform-flow tests have no
    /// charge, gravity or contact; contact-only tests have no gas or spatial grid.
    public static func run(
        device: MTLDevice, cellSizes: [Float] = [0.2, 0.1, 0.05],
        remapMode: ExperimentalBoxRemap = .redistribution
    ) throws -> [Result] {
        let object = try RigidObjectDefinition(
            name: "Diagnostic box", shape: .box(size: SIMD3(repeating: 0.8)),
            position: SIMD3(2.095, 2, 2), mass: 2)
        let scene = Scenario(
            name: "Rigid box diagnostics", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 2, 2)), rigidObjects: [object])
        var results: [Result] = []
        for cell in cellSizes {
            for rotate in [false, true] {
                let simulation = try ExperimentalRigidBoxSimulation(
                    device: device, scenario: scene, cellSize: cell, motion: .held)
                simulation.remapMode = remapMode
                let initial = simulation.air.totals()
                let momentum = simulation.air.momentum()
                let fluidCount = simulation.air.fluidCellCount
                var body = try object.makeBody()
                let start = body.position
                body.applyImpulse(SIMD3(2 * 4, 0, 0))
                if rotate { body.applyAngularImpulse(SIMD3(0, body.inertia.y * (5 * .pi / 180) / 0.03, 0)) }
                var pressureError = 0.0
                for _ in 0..<12 {
                    body.advance(by: 0.0025, gravity: .zero)
                    try simulation.air.updateExperimentalBox(body)
                    pressureError = max(pressureError, relativePressureError(simulation.air))
                }
                let final = simulation.air.totals()
                results.append(Result(
                    kind: rotate ? "remap-translation-rotation" : "remap-translation",
                    remapMode: remapMode,
                    cellSize: cell, cfl: nil, mechanicalStep: 0.0025, time: 0.03,
                    displacement: body.position - start, velocity: body.linearVelocity,
                    orientation: body.orientation.vector, angularMomentum: body.angularMomentum,
                    appliedImpulse: SIMD3(8, 0, 0), groundImpulse: .zero,
                    relativeGasMassChange: final.mass / initial.mass - 1,
                    relativeGasEnergyChange: final.energy / initial.energy - 1,
                    gasMomentumChange: simulation.air.momentum() - momentum,
                    maximumRelativePressureError: pressureError,
                    occupiedVolumeChange: Double(fluidCount - simulation.air.fluidCellCount)
                        * pow(Double(cell), 3)))
            }
        }
        var flowCases = cellSizes.map { ($0, Float(0.45)) }
        if let finest = cellSizes.min() { flowCases.append((finest, 0.225)) }
        for (cell, cfl) in flowCases {
            var config = SolverConfiguration()
            config.cfl = cfl
            config.startupSteps = 1
            var open = scene
            open.reflectiveFaces = []
            let simulation = try ExperimentalRigidBoxSimulation(
                device: device, scenario: open, cellSize: cell, configuration: config)
            simulation.remapMode = remapMode
            simulation.gravity = .zero
            simulation.air.fill(uniform: Primitive(density: 1.225, velocity: SIMD3(20, 0, 0), pressure: 101325))
            simulation.air.restart()
            let initial = simulation.air.totals()
            let momentum = simulation.air.momentum()
            let start = simulation.position
            var impulse = SIMD3<Double>.zero
            while simulation.air.time < 0.01 - 1e-8 {
                try simulation.advance(steps: 1, timeLimit: 0.01)
                impulse += simulation.lastImpulse
            }
            let final = simulation.air.totals()
            results.append(Result(
                kind: "uniform-flow-no-contact", remapMode: remapMode, cellSize: cell, cfl: cfl, mechanicalStep: nil,
                time: simulation.air.time, displacement: simulation.position - start,
                velocity: simulation.velocity, orientation: simulation.orientation,
                angularMomentum: simulation.angularMomentum, appliedImpulse: impulse, groundImpulse: .zero,
                relativeGasMassChange: final.mass / initial.mass - 1,
                relativeGasEnergyChange: final.energy / initial.energy - 1,
                gasMomentumChange: simulation.air.momentum() - momentum,
                maximumRelativePressureError: nil, occupiedVolumeChange: nil))
        }
        for step in [0.0002, 0.0001, 0.00005, 0.000025] {
            var body = try RigidBoxBody(mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(2, 2, 0.4))
            let start = body.position
            var time = 0.0
            var impulse = SIMD3<Double>.zero
            var contactImpulse = SIMD3<Double>.zero
            while time < 0.03 - 1e-12 {
                let dt = min(step, 0.03 - time)
                let midpoint = time + 0.5 * dt
                // Smooth 10 ms centred force pulse, integral 5 N s, followed by free contact motion.
                let force = SIMD3<Double>(midpoint < 0.01 ? 1000 * pow(sin(.pi * midpoint / 0.01), 2) : 0, 0, 0)
                let contacts = body.advanceWithGround(by: dt, force: force)
                impulse += dt * force
                for contact in contacts { contactImpulse += SIMD3(contact.tangent.x, contact.tangent.y, contact.normal) }
                time += dt
            }
            results.append(Result(
                kind: "contact-only", remapMode: remapMode, cellSize: nil, cfl: nil, mechanicalStep: step, time: time,
                displacement: body.position - start, velocity: body.linearVelocity,
                orientation: body.orientation.vector, angularMomentum: body.angularMomentum,
                appliedImpulse: impulse, groundImpulse: contactImpulse,
                relativeGasMassChange: nil, relativeGasEnergyChange: nil, gasMomentumChange: nil,
                maximumRelativePressureError: nil, occupiedVolumeChange: nil))
        }
        return results
    }

    private static func relativePressureError(_ air: BlastSolver) -> Double {
        let grid = air.grid
        return air.withState { cells in
            var maximum = 0.0
            for n in cells.indices where !air.isSolid(n % grid.nx, (n / grid.nx) % grid.ny, n / (grid.nx * grid.ny)) {
                let pressure = cells[n].primitive(gamma: 1.4).pressure
                maximum = max(maximum, abs(Double(pressure) / 101325 - 1))
            }
            return maximum
        }
    }
}
