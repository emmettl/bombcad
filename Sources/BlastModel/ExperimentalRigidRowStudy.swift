import Foundation
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            name: String,
            displacement: SIMD3<Double>,
            peakSpeed: Double,
            peakTilt: Double,
            finalTilt: Double,
            outcome: ExperimentalRigidCarStudy.Outcome,
            airImpulse: SIMD3<Double>
        ) {
            self.name = name
            self.displacement = displacement
            self.peakSpeed = peakSpeed
            self.peakTilt = peakTilt
            self.finalTilt = finalTilt
            self.outcome = outcome
            self.airImpulse = airImpulse
        }
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            bodies: Int,
            steps: Int,
            secondsPerStep: Double,
            meanContacts: Double,
            meanCandidatePairs: Double,
            allPairs: Int,
            kineticEnergyStart: Double,
            kineticEnergyEnd: Double
        ) {
            self.bodies = bodies
            self.steps = steps
            self.secondsPerStep = secondsPerStep
            self.meanContacts = meanContacts
            self.meanCandidatePairs = meanCandidatePairs
            self.allPairs = allPairs
            self.kineticEnergyStart = kineticEnergyStart
            self.kineticEnergyEnd = kineticEnergyEnd
        }
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
