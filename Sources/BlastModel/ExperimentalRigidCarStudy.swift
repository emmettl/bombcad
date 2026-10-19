import Foundation
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
        /// After this time the air no longer acts on the car, which carries on alone.
        public var airUntil: Double?
        /// Scales the air's load on the car (see `ExperimentalRigidCarSimulation.airLoadScale`).
        public var airLoadScale = 1.0
        public var remapMode: ExperimentalBoxRemap = .redistribution
        /// The domain's open faces: ambient air beyond them (since 16 October 2026), or copies of the
        /// cells inside, which drained the domain and turned the late flow.
        public var openFaces: OpenFaces = .farField
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
                + (airUntil.map { String(format: ", air for %.2f s", $0) } ?? "")
                + (airLoadScale == 1 ? "" : String(format: ", air load × %.2f", airLoadScale))
                + (openFaces == .farField ? "" : ", copying faces")
        }
    }

    public enum Outcome: String, Codable, Sendable { case upright, tilted, overturned }

    public struct Sample: Codable, Sendable {
        public let time: Double
        public let airImpulse: SIMD3<Double>
        public let height: Double
        public let tilt: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            time: Double,
            airImpulse: SIMD3<Double>,
            height: Double,
            tilt: Double
        ) {
            self.time = time
            self.airImpulse = airImpulse
            self.height = height
            self.tilt = tilt
        }
    }

    /// Near the car 0.075, 0.05, 0.0375 and 0.025 m: two, three, four and six cells across the
    /// gap, with 0.2 m × 4 checking 0.1 m × 2 for the outer air.
    public static let defaultCases = [
        Case(cellSize: 0.15, refinement: 2), Case(cellSize: 0.1, refinement: 2),
        Case(cellSize: 0.2, refinement: 4), Case(cellSize: 0.15, refinement: 4),
        Case(cellSize: 0.1, refinement: 4),
    ]

    /// Adaptive cases refine the car and its surroundings and, as usual, the blast front.
    public static func configuration(for study: Case) -> SolverConfiguration {
        var config = SolverConfiguration()
        config.refinement = study.refinement
        config.openFaces = study.openFaces
        if study.refinement > 1 { config.refinementMemory = 2 << 30 }
        return config
    }

    package static func tiltDegrees(_ orientation: SIMD4<Double>) -> Double {
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            study: Case,
            remapMode: ExperimentalBoxRemap,
            velocity: SIMD3<Double>,
            spin: SIMD3<Double>,
            time: Double,
            airImpulse: SIMD3<Double>,
            airAngularImpulse: SIMD3<Double>,
            pistonScale: Double,
            wallSeconds: Double
        ) {
            self.study = study
            self.remapMode = remapMode
            self.velocity = velocity
            self.spin = spin
            self.time = time
            self.airImpulse = airImpulse
            self.airAngularImpulse = airAngularImpulse
            self.pistonScale = pistonScale
            self.wallSeconds = wallSeconds
        }
    }
}
