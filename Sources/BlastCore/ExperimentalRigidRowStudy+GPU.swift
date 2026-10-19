import BlastModel
import Foundation
import Metal
import simd

extension ExperimentalRigidRowStudy {
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
