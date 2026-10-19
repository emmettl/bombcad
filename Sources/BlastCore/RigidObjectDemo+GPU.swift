import BlastModel
import Foundation
import Metal
import simd

extension RigidObjectDemo {
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
