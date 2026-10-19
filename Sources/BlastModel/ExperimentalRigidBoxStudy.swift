import Foundation
import simd

/// Reproducible resolution/timestep study for the standalone coupling prototype.
/// Uniform fine-grid references plus held/free adaptive comparisons.
public enum ExperimentalRigidBoxStudy {
    public struct Result: Codable, Sendable {
        public let remapMode: ExperimentalBoxRemap
        public let cellSize: Float
        public let cfl: Float
        public let refinement: Int
        public let held: Bool
        public let time: Double
        public let steps: Int
        public let displacement: SIMD3<Double>
        public let velocity: SIMD3<Double>
        public let linearImpulse: SIMD3<Double>
        public let angularImpulse: SIMD3<Double>
        public let groundImpulse: SIMD3<Double>
        public let groundAngularImpulse: SIMD3<Double>
        public let orientation: SIMD4<Double>
        public let angularMomentum: SIMD3<Double>
        public let initialGasMass: Double
        public let initialGasEnergy: Double
        public let relativeMassChange: Double
        public let computeSeconds: Double
        public let remapTimings: [String: Double]

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            remapMode: ExperimentalBoxRemap,
            cellSize: Float,
            cfl: Float,
            refinement: Int,
            held: Bool,
            time: Double,
            steps: Int,
            displacement: SIMD3<Double>,
            velocity: SIMD3<Double>,
            linearImpulse: SIMD3<Double>,
            angularImpulse: SIMD3<Double>,
            groundImpulse: SIMD3<Double>,
            groundAngularImpulse: SIMD3<Double>,
            orientation: SIMD4<Double>,
            angularMomentum: SIMD3<Double>,
            initialGasMass: Double,
            initialGasEnergy: Double,
            relativeMassChange: Double,
            computeSeconds: Double,
            remapTimings: [String: Double]
        ) {
            self.remapMode = remapMode
            self.cellSize = cellSize
            self.cfl = cfl
            self.refinement = refinement
            self.held = held
            self.time = time
            self.steps = steps
            self.displacement = displacement
            self.velocity = velocity
            self.linearImpulse = linearImpulse
            self.angularImpulse = angularImpulse
            self.groundImpulse = groundImpulse
            self.groundAngularImpulse = groundAngularImpulse
            self.orientation = orientation
            self.angularMomentum = angularMomentum
            self.initialGasMass = initialGasMass
            self.initialGasEnergy = initialGasEnergy
            self.relativeMassChange = relativeMassChange
            self.computeSeconds = computeSeconds
            self.remapTimings = remapTimings
        }
    }
}
