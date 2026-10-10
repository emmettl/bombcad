import Foundation
import Metal
import simd

/// A row of parked saloons side by side, the nearest side-on to a charge 0.3 m above the ground:
/// the first populated case. Every car is coupled to the air as in the single-car study, or only
/// the nearest, the rest then moving only when struck (see `ExperimentalRigidWorldSimulation`).
/// Each case also runs
/// with every car held, so the air solver's own cost is measured on identical geometry apart
/// from motion, coupling and contact.
public enum ExperimentalRigidRowStudy {
    public struct Car: Codable, Sendable {
        public let name: String
        public let displacement: SIMD3<Double>
        public let peakSpeed: Double
        public let peakTilt: Double
        public let finalTilt: Double
        public let outcome: ExperimentalRigidCarStudy.Outcome
        /// The air's impulse on the car (N s); zero if it is not in the air.
        public let airImpulse: SIMD3<Double>
    }

    public struct Result: Codable, Sendable {
        public let study: ExperimentalRigidCarStudy.Case
        public let chargeMass: Double
        public let held: Bool
        /// Only the nearest car was in the air.
        public let nearestOnly: Bool
        public let time: Double
        public let steps: Int
        public let cars: [Car]
        public let wallSeconds: Double
        public let timings: ExperimentalRigidCarSimulation.Timings
        public let failure: String?
    }

    /// `count` saloons in 2.4 m bays along y, the first's near side `standoff` from the charge.
    /// The domain divides into 0.2, 0.15 and 0.1 m cells, and the shells' faces lie on 0.05 m
    /// cell faces, as in `ExperimentalRigidCarStudy.scenario`.
    public static func scenario(chargeMass: Double, standoff: Double = 1.5, count: Int = 4) throws -> Scenario
    {
        var scene = try ExperimentalRigidCarStudy.scenario(chargeMass: chargeMass, standoff: standoff)
        scene.name = "Row of cars"
        scene.domainSize = SIMD3(8.4, 3.6 + 2.4 * Float(count), 4.8)
        scene.rigidCars = try (0..<count).map {
            try .saloon(name: "Car \($0 + 1)", position: SIMD3(4.2, 3.025 + 2.4 * Double($0), 0))
        }
        return scene
    }

    public static func run(
        device: MTLDevice, study: ExperimentalRigidCarStudy.Case, chargeMass: Double, held: Bool = false,
        count: Int = 4, nearestOnly: Bool = false, duration: Double = 2, recordEvery: Double? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> (result: Result, frames: [RigidObjectDemo.Frame]) {
        let simulation = try ExperimentalRigidWorldSimulation(
            device: device, scenario: scenario(chargeMass: chargeMass, count: count),
            cellSize: study.cellSize, configuration: ExperimentalRigidCarStudy.configuration(for: study),
            motion: held ? .held : .free, coupled: nearestOnly ? [0] : nil)
        let start = simulation.members
        var peakSpeed = [Double](repeating: 0, count: count)
        var peakTilt = [Double](repeating: 0, count: count)
        var impulse = [SIMD3<Double>](repeating: .zero, count: count)
        var frames: [RigidObjectDemo.Frame] = []
        var next = 0.0
        var reported = 0.0
        func record() {
            let members = simulation.members
            frames.append(
                RigidObjectDemo.Frame(
                    time: simulation.air.time, corners: members[0].corners,
                    centreOfMass: members[0].centreOfMass,
                    speed: simd_length(members[0].velocity), energy: simulation.kineticEnergy,
                    tyres: members[0].tyres, others: members.dropFirst().map(\.corners)))
        }
        if recordEvery != nil { record() }
        let started = Date.timeIntervalSinceReferenceDate
        var failure: String?
        while simulation.air.time < duration - 1e-8 {
            do { try simulation.advance(steps: 1, timeLimit: duration) } catch {
                failure = "\(error)"
                break
            }
            for n in 0..<count { impulse[n] += simulation.lastAirImpulses[n] }
            for (n, member) in simulation.members.enumerated() {
                peakSpeed[n] = max(peakSpeed[n], simd_length(member.velocity))
                peakTilt[n] = max(peakTilt[n], member.tilt)
            }
            if let every = recordEvery, simulation.air.time >= next - 1e-9 {
                record()
                next += simulation.air.time < 0.05 ? min(every, 0.001) : every
            }
            if simulation.air.time >= reported + 0.1 {
                reported = simulation.air.time
                progress?(reported)
            }
        }
        let balance = atan(try RigidCarDefinition.saloon().staticStabilityFactor) * 180 / .pi
        let cars = zip(start, simulation.members).enumerated().map { n, pair in
            let tilt = pair.1.tilt
            return Car(
                name: pair.1.name, displacement: pair.1.centreOfMass - pair.0.centreOfMass,
                peakSpeed: peakSpeed[n], peakTilt: peakTilt[n], finalTilt: tilt,
                outcome: tilt > balance ? .overturned : tilt < 2 ? .upright : .tilted, airImpulse: impulse[n])
        }
        return (
            Result(
                study: study, chargeMass: chargeMass, held: held, nearestOnly: nearestOnly,
                time: simulation.air.time, steps: simulation.air.stepCount, cars: cars,
                wallSeconds: Date.timeIntervalSinceReferenceDate - started, timings: simulation.timings,
                failure: failure),
            frames
        )
    }
}

/// Contact cost for a crowded scene, mechanics only: `count` boxes dropped into a walled pen in
/// layers, side by side almost touching, so they fall, strike and settle on each other. Reports time per step, contacts
/// and the pairs the sweep tests, against the n(n−1)/2 an unfiltered search would.
public enum RigidBodyWorldBenchmark {
    public struct Result: Codable, Sendable {
        public let bodies: Int
        public let steps: Int
        public let secondsPerStep: Double
        public let meanContacts: Double
        public let meanCandidatePairs: Double
        public let allPairs: Int
        public let kineticEnergyStart: Double
        public let kineticEnergyEnd: Double
    }

    public static func run(count: Int, steps: Int = 1000, dt: Double = 0.001) throws -> Result {
        let side = max(2, Int((Double(count) / 4).squareRoot().rounded(.up)))  // four layers
        let layer = side * side
        var members: [RigidBodyWorld.Member] = []
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for n in 0..<count {
            let i = n % side
            let j = (n / side) % side
            let k = n / layer
            // Nearly touching sideways, layers 0.1 m apart: they land on each other at once.
            let position = SIMD3(
                0.85 * Double(i) + 0.05 * random(), 0.85 * Double(j) + 0.05 * random(), 0.3 + 0.6 * Double(k))
            members.append(
                RigidBodyWorld.Member(
                    body: try RigidBoxBody(
                        mass: 20 + 20 * random(), size: SIMD3(0.6, 0.5, 0.4) + 0.1 * random(),
                        position: position,
                        orientation: simd_quatd(angle: 0.3 * random(), axis: SIMD3(0, 0, 1))),
                    supports: [], friction: RigidBoxBody.Ground()))
        }
        let span = Float(0.85 * Double(side))
        let blocks = [
            Box(min: SIMD3(-0.9, -0.9, 0), max: SIMD3(-0.5, span + 0.5, 1)),
            Box(min: SIMD3(span, -0.9, 0), max: SIMD3(span + 0.4, span + 0.5, 1)),
            Box(min: SIMD3(-0.5, -0.9, 0), max: SIMD3(span, -0.5, 1)),
            Box(min: SIMD3(-0.5, span, 0), max: SIMD3(span, span + 0.5, 1)),
        ]
        var world = RigidBodyWorld(members: members, blocks: blocks)
        let energyStart = world.kineticEnergy
        var contacts = 0
        var pairs = 0
        let started = Date.timeIntervalSinceReferenceDate
        for _ in 0..<steps {
            contacts += world.advance(by: dt).count
            pairs += world.lastCandidatePairs
        }
        let seconds = Date.timeIntervalSinceReferenceDate - started
        return Result(
            bodies: count, steps: steps, secondsPerStep: seconds / Double(steps),
            meanContacts: Double(contacts) / Double(steps), meanCandidatePairs: Double(pairs) / Double(steps),
            allPairs: count * (count - 1) / 2 + count * blocks.count, kineticEnergyStart: energyStart,
            kineticEnergyEnd: world.kineticEnergy)
    }
}
