import BlastModel
import Foundation
import Metal
import simd

extension RigidCarDemo {
    /// The saloon side-on to a ground-level charge, coupled to ideal-gas air: uniform, or with
    /// patches `refinement` times finer over the car (see `ExperimentalRigidCarStudy`). Timings
    /// describe this synchronous reference, not a production forecast.
    public static func coupledRecordings(
        device: MTLDevice, charges: [(mass: Double, standoff: Double)] = [(1, 1.5), (5, 1.5), (10, 1.5)],
        duration: Double = 2, cellSize: Float = 0.2, refinement: Int = 1
    ) throws -> [RigidObjectDemo.Recording] {
        try charges.map { charge in
            let study = ExperimentalRigidCarStudy.Case(cellSize: cellSize, refinement: refinement)
            let simulation = try ExperimentalRigidCarSimulation(
                device: device,
                scenario: ExperimentalRigidCarStudy.scenario(
                    chargeMass: charge.mass, standoff: charge.standoff),
                cellSize: cellSize, configuration: ExperimentalRigidCarStudy.configuration(for: study))
            var frames: [RigidObjectDemo.Frame] = []
            var impulse = SIMD3<Double>.zero
            var next = 0.0
            func record(loads: [Double]?) {
                frames.append(
                    RigidObjectDemo.Frame(
                        time: simulation.air.time, corners: simulation.corners,
                        centreOfMass: simulation.position, speed: simd_length(simulation.velocity),
                        energy: simulation.mechanicalEnergy, tyres: simulation.tyres, tyreLoads: loads))
            }
            record(loads: nil)
            let before = Date.timeIntervalSinceReferenceDate
            var peakRoll = 0.0
            while simulation.air.time < duration - 1e-8 {
                try simulation.advance(steps: 1, timeLimit: duration)
                impulse += simulation.lastImpulse
                let up = simd_quatd(vector: simulation.orientation).act(SIMD3<Double>(0, 0, 1))
                peakRoll = max(peakRoll, abs(atan2(up.y, up.z)))
                if simulation.air.time >= next - 1e-9 {
                    record(loads: simulation.lastTyreLoads)
                    next += simulation.air.time < 0.05 ? 0.001 : 0.005
                }
            }
            let elapsed = Date.timeIntervalSinceReferenceDate - before
            let description = String(
                format:
                    "%g kg TNT-equivalent %.1f m from the near side at 0.3 m height; air impulse %.0f N s sideways, %.0f N s up; peak roll %.1f°. %@ air, %d steps in %.0f s (synchronous reference).",
                charge.mass, charge.standoff, impulse.y, impulse.z, peakRoll * 180 / .pi, study.label,
                simulation.air.stepCount, elapsed)
            return RigidObjectDemo.Recording(
                name: String(format: "Car beside %g kg", charge.mass), description: description,
                frames: frames, view: "front")
        }
    }
}
