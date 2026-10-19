import Foundation
import RadialBlast
import simd

/// A horizontal plane of fixed Eulerian probes, sampled after each complete air step.
/// Pressure is trilinearly interpolated from coarse cell centres at fixed physical points.
/// Values include restricted fine state, rather than fine-cell maxima.
/// Arrival is the first endpoint at or above an absolute overpressure threshold.
public struct ExposurePlaneSnapshot: Codable, Sendable {
    public var nx: Int
    public var ny: Int
    public var cellSizeM: Float
    public var airCellSizeM: Float
    public var heightM: Float
    public var thresholdPa: Float
    public var elapsedS: Double
    public var peakPa: [Float?]
    public var positiveImpulsePaS: [Float?]
    public var arrivalS: [Float?]
    /// A stencil that ever included a solid cell is excluded from all three maps.
    public var everSolid: [Bool]

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        nx: Int,
        ny: Int,
        cellSizeM: Float,
        airCellSizeM: Float,
        heightM: Float,
        thresholdPa: Float,
        elapsedS: Double,
        peakPa: [Float?],
        positiveImpulsePaS: [Float?],
        arrivalS: [Float?],
        everSolid: [Bool]
    ) {
        self.nx = nx
        self.ny = ny
        self.cellSizeM = cellSizeM
        self.airCellSizeM = airCellSizeM
        self.heightM = heightM
        self.thresholdPa = thresholdPa
        self.elapsedS = elapsedS
        self.peakPa = peakPa
        self.positiveImpulsePaS = positiveImpulsePaS
        self.arrivalS = arrivalS
        self.everSolid = everSolid
    }
}
