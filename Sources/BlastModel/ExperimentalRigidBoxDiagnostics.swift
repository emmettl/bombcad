import Foundation
import simd

/// Controlled standalone diagnostics, with no change to app scenario loading.
public enum ExperimentalRigidBoxDiagnostics {
    public struct Result: Codable, Sendable {
        public let kind: String
        public let remapMode: ExperimentalBoxRemap
        public let cellSize: Float?
        public let cfl: Float?
        public let mechanicalStep: Double?
        public let time: Double
        public let displacement: SIMD3<Double>
        public let velocity: SIMD3<Double>
        public let orientation: SIMD4<Double>
        public let angularMomentum: SIMD3<Double>
        public let appliedImpulse: SIMD3<Double>
        public let groundImpulse: SIMD3<Double>
        public let relativeGasMassChange: Double?
        public let relativeGasEnergyChange: Double?
        public let gasMomentumChange: SIMD3<Double>?
        public let maximumRelativePressureError: Double?
        public let occupiedVolumeChange: Double?

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            kind: String,
            remapMode: ExperimentalBoxRemap,
            cellSize: Float?,
            cfl: Float?,
            mechanicalStep: Double?,
            time: Double,
            displacement: SIMD3<Double>,
            velocity: SIMD3<Double>,
            orientation: SIMD4<Double>,
            angularMomentum: SIMD3<Double>,
            appliedImpulse: SIMD3<Double>,
            groundImpulse: SIMD3<Double>,
            relativeGasMassChange: Double?,
            relativeGasEnergyChange: Double?,
            gasMomentumChange: SIMD3<Double>?,
            maximumRelativePressureError: Double?,
            occupiedVolumeChange: Double?
        ) {
            self.kind = kind
            self.remapMode = remapMode
            self.cellSize = cellSize
            self.cfl = cfl
            self.mechanicalStep = mechanicalStep
            self.time = time
            self.displacement = displacement
            self.velocity = velocity
            self.orientation = orientation
            self.angularMomentum = angularMomentum
            self.appliedImpulse = appliedImpulse
            self.groundImpulse = groundImpulse
            self.relativeGasMassChange = relativeGasMassChange
            self.relativeGasEnergyChange = relativeGasEnergyChange
            self.gasMomentumChange = gasMomentumChange
            self.maximumRelativePressureError = maximumRelativePressureError
            self.occupiedVolumeChange = occupiedVolumeChange
        }
    }
}
