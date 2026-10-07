import Foundation
import Metal
import simd

/// Recorded reference trajectories for visual review without running the app or blast solver.
public enum RigidObjectDemo {
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let corners: [SIMD3<Double>]
        public let centreOfMass: SIMD3<Double>
        public let speed: Double
        public let energy: Double
    }

    public struct Recording: Codable, Sendable {
        public let name: String
        public let description: String
        public let frames: [Frame]
    }

    /// Two seconds at 1 ms mechanics steps, sampled every 20 ms. Each case is independent.
    public static func recordings() throws -> [Recording] {
        let cases: [(String, String, Double)] = [
            ("Resting", "A 2 kg box supported by its weight.", 0),
            ("Friction holding", "Horizontal force 11.58 N, below the 11.77 N static-friction limit.", 0),
            ("Sliding", "Initial speed 5 m/s; sliding friction 0.5 slows the box to rest.", 0),
            ("Lift-off", "Upward force 40 N for 0.15 s, then gravity alone.", 0),
            ("Rocking", "Tall box tilted 0.2 rad, below the 0.464 rad balance angle.", 0.2),
            ("Tipping", "Tall box tilted 0.6 rad, beyond the 0.464 rad balance angle.", 0.6),
        ]
        return try cases.enumerated().map { index, specification in
            let (name, description, angle) = specification
            let tall = index >= 4
            let size = tall ? SIMD3<Double>(1, 1, 2) : SIMD3<Double>(2, 2, 0.5)
            let height = tall ? cos(angle) + 0.5 * sin(angle) : 0.25
            let definition = try RigidObjectDefinition(
                name: name, shape: .box(size: size), position: SIMD3(0, 0, height), mass: 2,
                orientation: simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)).vector)
            var body = try definition.makeBody()
            if index == 2 { body.applyImpulse(SIMD3(10, 0, 0)) }
            var frames: [Frame] = []
            for step in 0...2000 {
                if step % 20 == 0 {
                    frames.append(
                        Frame(
                            time: Double(step) * 0.001, corners: body.corners,
                            centreOfMass: body.position, speed: simd_length(body.linearVelocity),
                            energy: body.kineticEnergy + body.mass * 9.81 * body.position.z))
                }
                guard step < 2000 else { break }
                let force: SIMD3<Double> =
                    index == 1
                    ? SIMD3(0.59 * 2 * 9.81, 0, 0)
                    : index == 3 && step < 150 ? SIMD3(0, 0, 40) : .zero
                body.advanceWithGround(by: 0.001, ground: definition.ground, force: force)
            }
            return Recording(name: name, description: description, frames: frames)
        }
    }
    /// Small uniform-grid blast comparison. Timings describe this synchronous reference,
    /// including CPU remapping, rather than a production performance forecast.
    public static func coupledRecordings(device: MTLDevice, refinement: Int = 1) throws -> [Recording] {
        let object = try RigidObjectDefinition(
            name: "Box", shape: .box(size: SIMD3(repeating: 0.8)),
            position: SIMD3(2, 2, 0.4), mass: 2)
        let scenario = Scenario(
            name: "Box blast", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.1, position: SIMD3(0.5, 2, 0)), rigidObjects: [object])
        return try [ExperimentalRigidBoxSimulation.Motion.held, .free].map { motion in
            var config = SolverConfiguration()
            config.refinement = refinement
            if refinement > 1 { config.refinementMemory = 32 << 20 }
            let simulation = try ExperimentalRigidBoxSimulation(
                device: device, scenario: scenario, cellSize: 0.2, configuration: config, motion: motion)
            var frames: [Frame] = []
            func record() {
                frames.append(
                    Frame(
                        time: simulation.air.time, corners: simulation.corners,
                        centreOfMass: simulation.position, speed: simd_length(simulation.velocity),
                        energy: simulation.mechanicalEnergy))
            }
            record()
            let before = Date.timeIntervalSinceReferenceDate
            while simulation.air.time < 0.03 - 1e-8 {
                try simulation.advance(steps: 1, timeLimit: 0.03)
                record()
            }
            let elapsed = Date.timeIntervalSinceReferenceDate - before
            let name = motion == .held ? "Held box under blast" : "Free box under blast"
            let description = String(
                format:
                    "2 kg box, 0.1 kg TNT-equivalent, 0.2 m air cells, refinement %d. %d steps in %.3f s (synchronous reference).",
                refinement, simulation.air.stepCount, elapsed)
            return Recording(name: name, description: description, frames: frames)
        }
    }
}
