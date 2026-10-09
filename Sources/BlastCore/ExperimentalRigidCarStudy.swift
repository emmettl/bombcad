import Foundation
import Metal
import simd

/// Resolution study for the saloon side-on to a ground-level charge (the `--car-blast` scene):
/// the same inputs on uniform air and with adaptive patches over the car, which refine the
/// 0.15 m gap under the shell. Reports the air's impulse, the peak tilt, the outcome and the
/// cost, split into the air solver, the coupling and the contact mechanics.
public enum ExperimentalRigidCarStudy {
    public struct Case: Codable, Sendable, Hashable {
        public let cellSize: Float
        public let refinement: Int
        /// The domain grown by half each way around the same car and charge (12.6 × 14.4 × 7.2 m).
        public var large = false
        public var remapMode: ExperimentalBoxRemap = .redistribution
        public init(
            cellSize: Float, refinement: Int, large: Bool = false,
            remapMode: ExperimentalBoxRemap = .redistribution
        ) {
            self.cellSize = cellSize
            self.refinement = refinement
            self.large = large
            self.remapMode = remapMode
        }
        /// The air cell size next to the car.
        public var nearCellSize: Float { cellSize / Float(max(refinement, 1)) }
        public var label: String {
            (refinement > 1
                ? String(format: "%.2f m, ×%d (%.3f m at the car)", cellSize, refinement, nearCellSize)
                : String(format: "%.2f m uniform", cellSize)) + (large ? ", large domain" : "")
                + (remapMode == .redistribution ? "" : ", connected transport")
        }
    }

    public enum Outcome: String, Codable, Sendable { case upright, tilted, overturned }

    public struct Result: Codable, Sendable {
        public let study: Case
        public let chargeMass: Double
        public let standoff: Double
        public let time: Double
        public let steps: Int
        /// Gas impulse on the shell (N s) until the run stopped: y is away from the charge, z up.
        public let airImpulse: SIMD3<Double>
        /// The same up to 50 ms, when the blast has passed and the gas is near ambient again.
        public let earlyAirImpulse: SIMD3<Double>
        public let groundImpulse: SIMD3<Double>
        /// Largest angle between the car's up axis and the vertical (degrees).
        public let peakTilt: Double
        public let peakTiltTime: Double
        public let finalTilt: Double
        public let outcome: Outcome
        public let displacement: SIMD3<Double>
        public let peakSpeed: Double
        public let relativeMassChange: Double
        public let wallSeconds: Double
        public let timings: ExperimentalRigidCarSimulation.Timings
        /// Fine patches in use at the end.
        public let patches: Int
        /// Every 10 ms: time, accumulated air impulse, centre-of-mass height and tilt.
        public let history: [Sample]
        /// Why the run stopped early, if it failed; the rest describes it up to then.
        public let failure: String?
        public let finalCorners: [SIMD3<Double>]
    }

    public struct Sample: Codable, Sendable {
        public let time: Double
        public let airImpulse: SIMD3<Double>
        public let height: Double
        public let tilt: Double
    }

    /// Near the car 0.075, 0.05, 0.0375 and 0.025 m: two, three, four and six cells across the
    /// gap, with 0.2 m × 4 checking 0.1 m × 2 for the outer air.
    public static let defaultCases = [
        Case(cellSize: 0.15, refinement: 2), Case(cellSize: 0.1, refinement: 2),
        Case(cellSize: 0.2, refinement: 4), Case(cellSize: 0.15, refinement: 4),
        Case(cellSize: 0.1, refinement: 4),
    ]

    /// The `--car-blast` scene: an 8.4 × 9.6 × 4.8 m open domain, the saloon side-on with its
    /// near side `standoff` from a charge 0.3 m above the ground. The domain divides into 0.2,
    /// 0.15 and 0.1 m cells, and the shell's faces lie on the faces of 0.05 m cells (and so of
    /// 0.025 m ones). The gap under the shell, 0.15 m, is a whole number of 0.075, 0.05, 0.0375
    /// and 0.025 m cells, so those resolve it exactly; whole-cell masks make it 0.2 m on 0.2 m
    /// cells and 0.1 m on 0.1 m cells, whose centres lie on the shell's underside.
    public static func scenario(chargeMass: Double, standoff: Double, large: Bool = false) throws -> Scenario
    {
        let shift = large ? SIMD3<Float>(2.1, 3, 0) : .zero
        var scene = Scenario(
            name: "Car blast", domainSize: large ? SIMD3(12.6, 14.4, 7.2) : SIMD3(8.4, 9.6, 4.8), boxes: [],
            charge: Charge(
                mass: Float(chargeMass), position: SIMD3(4.2, Float(3.025 - 0.775 - standoff), 0.3) + shift))
        scene.rigidCars = [try .saloon(position: SIMD3(4.2, 3.025, 0) + SIMD3<Double>(shift))]
        return scene
    }

    /// Adaptive cases refine the car and its surroundings and, as usual, the blast front.
    public static func configuration(for study: Case) -> SolverConfiguration {
        var config = SolverConfiguration()
        config.refinement = study.refinement
        if study.refinement > 1 { config.refinementMemory = 2 << 30 }
        return config
    }

    public static func run(
        device: MTLDevice, study: Case, chargeMass: Double, standoff: Double = 1.5, duration: Double = 2,
        stopWhenDecided: Bool = true, progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        let simulation = try ExperimentalRigidCarSimulation(
            device: device,
            scenario: scenario(chargeMass: chargeMass, standoff: standoff, large: study.large),
            cellSize: study.cellSize, configuration: configuration(for: study))
        simulation.remapMode = study.remapMode
        let before = simulation.air.totals()
        let start = simulation.position
        var impulse = SIMD3<Double>.zero
        var early = SIMD3<Double>.zero
        var ground = SIMD3<Double>.zero
        var peakTilt = 0.0
        var peakTiltTime = 0.0
        var peakSpeed = 0.0
        var reported = 0.0
        var history: [Sample] = []
        var settledSince: Double?
        let started = Date.timeIntervalSinceReferenceDate
        var failure: String?
        while simulation.air.time < duration - 1e-8 {
            do { try simulation.advance(steps: 1, timeLimit: duration) } catch {
                failure = "\(error)"
                break
            }
            impulse += simulation.lastImpulse
            if simulation.air.time <= 0.05 + 1e-9 { early = impulse }
            ground += simulation.lastGroundImpulse
            let tilt = tiltDegrees(simulation.orientation)
            if tilt > peakTilt {
                peakTilt = tilt
                peakTiltTime = simulation.air.time
            }
            peakSpeed = max(peakSpeed, simd_length(simulation.velocity))
            if simulation.air.time >= 0.01 * Double(history.count + 1) - 1e-9 {
                history.append(
                    Sample(
                        time: simulation.air.time, airImpulse: impulse, height: simulation.position.z,
                        tilt: tilt))
            }
            // Decided: on its side, or back on its tyres and still for 0.1 s after the blast.
            if stopWhenDecided {
                if tilt > 80 { break }
                let still =
                    tilt < 0.5 && simd_length(simulation.angularVelocity) < 0.02
                    && simd_length(simulation.velocity) < 0.02
                settledSince = still ? settledSince ?? simulation.air.time : nil
                if simulation.air.time > 0.2, let since = settledSince, simulation.air.time - since > 0.1 {
                    break
                }
            }
            if simulation.air.time >= reported + 0.1 {
                reported = simulation.air.time
                progress?(reported)
            }
        }
        let finalTilt = tiltDegrees(simulation.orientation)
        let balance = atan(simulation.definition.staticStabilityFactor) * 180 / .pi
        return Result(
            study: study, chargeMass: chargeMass, standoff: standoff, time: simulation.air.time,
            steps: simulation.air.stepCount, airImpulse: impulse, earlyAirImpulse: early,
            groundImpulse: ground, peakTilt: peakTilt, peakTiltTime: peakTiltTime, finalTilt: finalTilt,
            outcome: finalTilt > balance ? .overturned : finalTilt < 2 ? .upright : .tilted,
            displacement: simulation.position - start, peakSpeed: peakSpeed,
            relativeMassChange: simulation.air.totals().mass / before.mass - 1,
            wallSeconds: Date.timeIntervalSinceReferenceDate - started, timings: simulation.timings,
            patches: simulation.air.refinement?.patchCount ?? 0, history: history,
            failure: failure, finalCorners: simulation.corners)
    }

    static func tiltDegrees(_ orientation: SIMD4<Double>) -> Double {
        let up = simd_quatd(vector: orientation).act(SIMD3<Double>(0, 0, 1))
        return acos(min(1, max(-1, up.z))) * 180 / .pi
    }

    public struct Flight: Codable, Sendable {
        public let study: Case
        public let remapMode: ExperimentalBoxRemap
        public let velocity: SIMD3<Double>
        public let spin: SIMD3<Double>
        public let time: Double
        /// Gas impulse and its moment about the centre of mass on the moving shell (N s, N m s).
        public let airImpulse: SIMD3<Double>
        public let airAngularImpulse: SIMD3<Double>
        /// ρ c v A over the run for the largest face, the scale of a wholly acoustic (piston) load;
        /// the true load of steady motion this slow is a small fraction of it.
        public let pistonScale: Double
        public let wallSeconds: Double
    }

    /// The saloon's shell flying through still air at a set velocity and spin, with no charge,
    /// no gravity and nothing touching it, lifted 0.6 m so its tyres clear the ground. At a few
    /// metres per second the air's true load is drag and added mass, tens of newtons; what the
    /// coupling records beyond that comes from moving the shell across whole cells.
    public static func flight(
        device: MTLDevice, study: Case, velocity: SIMD3<Double> = SIMD3(0, 2, 0),
        spin: SIMD3<Double> = SIMD3(1.5, 0, 0), duration: Double = 0.2,
        remapMode: ExperimentalBoxRemap = .redistribution
    ) throws -> Flight {
        var scene = try scenario(chargeMass: 0, standoff: 1.5)
        scene.rigidCars = [try .saloon(position: SIMD3(4.2, 3.025, 0.6))]
        let simulation = try ExperimentalRigidCarSimulation(
            device: device, scenario: scene, cellSize: study.cellSize,
            configuration: configuration(for: study))
        simulation.remapMode = remapMode
        simulation.gravity = .zero
        let car = simulation.definition
        try simulation.applyImpulse(car.mass * velocity)
        // Spin about the centre of mass along the body's principal axes (initially the world's).
        try simulation.applyAngularImpulse(car.inertia * spin)
        var impulse = SIMD3<Double>.zero
        var angular = SIMD3<Double>.zero
        let started = Date.timeIntervalSinceReferenceDate
        while simulation.air.time < duration - 1e-8 {
            try simulation.advance(steps: 1, timeLimit: duration)
            impulse += simulation.lastImpulse
            angular += simulation.lastAngularImpulse
        }
        let size = car.shellSize
        let face = max(size.x * size.y, max(size.x * size.z, size.y * size.z))
        let speed = simd_length(velocity) + simd_length(spin) * simd_length(size) / 2
        return Flight(
            study: study, remapMode: remapMode, velocity: velocity, spin: spin, time: simulation.air.time,
            airImpulse: impulse, airAngularImpulse: angular,
            pistonScale: 1.225 * 340 * speed * face * duration,
            wallSeconds: Date.timeIntervalSinceReferenceDate - started)
    }
}
