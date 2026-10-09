import Foundation
import Metal
import simd

/// Recorded car trajectories for the rigid-object replay: mechanical checks only, no blast.
public enum RigidCarDemo {
    /// Three seconds at 1 ms mechanics steps, sampled every 20 ms. Each case is independent.
    public static func recordings() throws -> [RigidObjectDemo.Recording] {
        let saloon = try RigidCarDefinition.saloon()
        let weight = saloon.mass * 9.81
        let mu = saloon.slidingFriction
        let h = saloon.centreOfMass.z
        let balance = atan(saloon.staticStabilityFactor)
        let degrees = 180 / Double.pi
        let cases:
            [(name: String, description: String, view: String, tilt: Double, velocity: SIMD3<Double>)] = [
                (
                    "Car at rest",
                    String(
                        format:
                            "1500 kg saloon on locked tyres. Each front tyre carries %.2f kN and each rear %.2f kN, as statics requires.",
                        weight * 1.5 / 5.4 / 1000, weight * 1.2 / 5.4 / 1000),
                    "side", 0, .zero
                ),
                (
                    "Car braking",
                    String(
                        format:
                            "From 10 m/s with all wheels locked, sliding friction %.1f: stops in %.1f m. While sliding the front axle gains μWh/L = %.2f kN.",
                        mu, 100 / (2 * mu * 9.81), mu * weight * h / saloon.wheelbase / 1000),
                    "side", 0, SIMD3(10, 0, 0)
                ),
                (
                    "Car sliding sideways",
                    String(
                        format:
                            "A sideways impulse gives 4 m/s. While sliding the leading tyres gain μWh/t = %.2f kN; μ = %.1f is below the stability factor %.2f, so it stays on four tyres.",
                        mu * weight * h / saloon.track / 1000, mu, saloon.staticStabilityFactor),
                    "front", 0, SIMD3(0, 4, 0)
                ),
                (
                    "Car rocking",
                    String(
                        format: "Released on two tyres at %.1f°, below the %.1f° balance angle atan(t/2h).",
                        (balance - 0.05) * degrees, balance * degrees),
                    "front", balance - 0.05, .zero
                ),
                (
                    "Car tipping",
                    String(
                        format:
                            "Released on two tyres at %.1f°, beyond the %.1f° balance angle; it comes to rest on its side.",
                        (balance + 0.05) * degrees, balance * degrees),
                    "front", balance + 0.05, .zero
                ),
            ]
        return try cases.map { specification in
            let definition = try RigidCarDefinition.saloon(
                name: specification.name,
                position: SIMD3(0, 0, saloon.track / 2 * sin(specification.tilt)),
                orientation: simd_quatd(angle: specification.tilt, axis: SIMD3(1, 0, 0)).vector)
            var car = try definition.makeBody()
            car.applyImpulse(definition.mass * specification.velocity)
            var contacts: [RigidCarBody.Contact] = []
            var frames: [RigidObjectDemo.Frame] = []
            for step in 0...3000 {
                if step % 20 == 0 {
                    var loads = [Double](repeating: 0, count: 4)
                    for contact in contacts {
                        if case .tyre(let n) = contact.location { loads[n] += contact.normal / 0.001 }
                    }
                    frames.append(
                        RigidObjectDemo.Frame(
                            time: Double(step) * 0.001, corners: car.body.corners,
                            centreOfMass: car.position, speed: simd_length(car.linearVelocity),
                            energy: car.mechanicalEnergy(), tyres: car.tyrePoints,
                            tyreLoads: step == 0 ? nil : loads))
                }
                guard step < 3000 else { break }
                contacts = car.advanceWithGround(by: 0.001, ground: definition.ground)
            }
            return RigidObjectDemo.Recording(
                name: specification.name, description: specification.description, frames: frames,
                view: specification.view)
        }
    }
}

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
