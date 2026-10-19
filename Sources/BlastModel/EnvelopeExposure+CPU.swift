import Foundation
import simd

/// Compact diagnostics for one stationary building. The positive scalar sum includes every
/// valid interior/exterior face; it is not a resultant vector impulse or structural reaction.
public struct EnvelopeExposureSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var elapsedS: Double
    public var airCellSizeM: Float
    public var faceCount: Int
    public var invalidFaceCount = 0
    public var areaM2: Double = 0
    public var validAreaM2: Double = 0
    public var peakPositivePa: Float = 0
    public var surfacePositiveImpulseNS: Double = 0
    public var forceN = SIMD3<Double>.zero
    public var signedImpulseNS = SIMD3<Double>.zero

    public var meanPositiveImpulsePaS: Double? {
        validAreaM2 > 0 ? surfacePositiveImpulseNS / validAreaM2 : nil
    }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        id: UUID,
        name: String,
        elapsedS: Double,
        airCellSizeM: Float,
        faceCount: Int,
        invalidFaceCount: Int = 0,
        areaM2: Double = 0,
        validAreaM2: Double = 0,
        peakPositivePa: Float = 0,
        surfacePositiveImpulseNS: Double = 0,
        forceN: SIMD3<Double> = SIMD3<Double>.zero,
        signedImpulseNS: SIMD3<Double> = SIMD3<Double>.zero
    ) {
        self.id = id
        self.name = name
        self.elapsedS = elapsedS
        self.airCellSizeM = airCellSizeM
        self.faceCount = faceCount
        self.invalidFaceCount = invalidFaceCount
        self.areaM2 = areaM2
        self.validAreaM2 = validAreaM2
        self.peakPositivePa = peakPositivePa
        self.surfacePositiveImpulseNS = surfacePositiveImpulseNS
        self.forceN = forceN
        self.signedImpulseNS = signedImpulseNS
    }
}

public struct EnvelopeSurfaceExposure: Codable, Sendable {
    public var positionM: SIMD3<Float>
    /// Outward from solid into air. Pressure force on the solid is -p A n.
    public var normal: SIMD3<Float>
    public var areaM2: Float
    public var overpressurePa: Float
    public var peakPositivePa: Float
    public var positiveImpulsePaS: Float
    public var signedImpulsePaS: Float
    public var invalid: Bool

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        positionM: SIMD3<Float>,
        normal: SIMD3<Float>,
        areaM2: Float,
        overpressurePa: Float,
        peakPositivePa: Float,
        positiveImpulsePaS: Float,
        signedImpulsePaS: Float,
        invalid: Bool
    ) {
        self.positionM = positionM
        self.normal = normal
        self.areaM2 = areaM2
        self.overpressurePa = overpressurePa
        self.peakPositivePa = peakPositivePa
        self.positiveImpulsePaS = positiveImpulsePaS
        self.signedImpulsePaS = signedImpulsePaS
        self.invalid = invalid
    }
}

public struct EnvelopeExposureSnapshot: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var elapsedS: Double
    public var airCellSizeM: Float
    public var surfaces: [EnvelopeSurfaceExposure]
    /// Includes both interior and exterior resolved faces, excluding domain boundaries.
    public var forceN: SIMD3<Double> {
        surfaces.filter { !$0.invalid }.reduce(.zero) {
            $0 - SIMD3<Double>($1.normal) * Double($1.overpressurePa * $1.areaM2)
        }
    }
    public var signedImpulseNS: SIMD3<Double> {
        surfaces.filter { !$0.invalid }.reduce(.zero) {
            $0 - SIMD3<Double>($1.normal) * Double($1.signedImpulsePaS * $1.areaM2)
        }
    }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        id: UUID,
        name: String,
        elapsedS: Double,
        airCellSizeM: Float,
        surfaces: [EnvelopeSurfaceExposure]
    ) {
        self.id = id
        self.name = name
        self.elapsedS = elapsedS
        self.airCellSizeM = airCellSizeM
        self.surfaces = surfaces
    }
}
