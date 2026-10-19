import Foundation
import simd

/// A reinforced concrete beam bent slowly to failure: one of the conventionally reinforced
/// beams of J. R. Janney, E. Hognestad and D. McHenry, "Ultimate flexural strength of
/// prestressed and conventionally reinforced concrete beams", Journal of the American Concrete
/// Institute 52(1), 1956.
///
/// Its dimensions, materials and measured curve are taken from J. Xu and Y. Lu, "Numerical
/// modelling for reinforced concrete response to blast load: understanding the demands on
/// material models", ACI SP-306, 2016, which models the beam and reproduces the measured
/// moment against deflection (its Figures 10, 11 and 21).
public enum BeamBenchmark {
    /// The beam is 6 in wide, 12 in deep and 120 in long, on supports 108 in apart, loaded at
    /// the third points of the span. Three No. 5 bars lie 8.3 in below the top (1.87% of the
    /// section above them); there are no stirrups.
    public static let width: Float = 0.1524
    public static let depth: Float = 0.3048
    public static let length: Float = 3.048
    public static let span: Float = 2.7432
    public static let shearSpan: Float = 0.9144
    public static let barDepth: Float = 0.2108
    public static let barArea: Float = 3 * 200e-6

    /// Mid-span moment (N m) against central deflection (m), read by hand off the source's
    /// plot of the experiment: the bars yield at about 37 kN m and 11 mm, and the record ends
    /// with the beam's failure in flexure at about 42 mm.
    public static let measured: [SIMD2<Float>] = {
        let points: [(Float, Float)] = [
            (0, 0), (1, 6), (2.5, 11), (5, 19), (7.5, 27), (10, 34), (11.5, 37), (15, 37.8), (20, 38.8),
            (30, 40.3), (42, 41.5),
        ]
        return points.map { SIMD2($0.0 * 1e-3, $0.1 * 1e3) }
    }()

    public static let measuredPeakMoment: Float = 41.5e3
    public static let measuredFailureDeflection: Float = 0.042

    /// Measured moment at central deflection `deflection`, interpolated.
    public static func measuredMoment(at deflection: Float) -> Float {
        SlabBenchmark.interpolate(measured, at: deflection)
    }

    /// The moment at which section analysis has the bars yield, with a rectangular stress block.
    public static var sectionMoment: Float {
        let tension = barArea * material.steel!.yieldStress
        return tension * (barDepth - tension / (0.85 * material.compressiveStrength * width) / 2)
    }

    /// Concrete of 36.2 MPa (5,250 psi), its other properties from the standard correlations;
    /// bars that yield at 333 MPa and, as the experiment reports, do not harden.
    public static var material: StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 333e6, ultimateStress: 333e6, ultimateStrain: 0.1, ruptureStrain: 0.2)
        return .concrete(name: "Janney beam", compressiveStrength: 36.2e6, steel: steel)
    }

    public static func model(elementsThroughDepth: Int) -> StructureModel {
        let h = depth / Float(elementsThroughDepth)
        // Lifted clear of the ground plane.
        let base = (1 / h).rounded() * h
        let beam = Box(min: SIMD3(0, 0, base), max: SIMD3(length, width, base + depth))
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        // The bars, smeared through a band one element deep centred on them.
        var band = beam
        band.min.z = base + depth - barDepth - h / 2
        band.max.z = band.min.z + h
        model.reinforcement = [ReinforcementLayer(region: band, ratio: SIMD3(barArea / (width * h), 0, 0))]
        return model
    }

    public struct Result: Sendable {
        /// Mid-span moment (N m) against central deflection (m).
        public var curve: [SIMD2<Float>]
        public var peakMoment: Float
        /// Central deflection at which the moment first falls below 85% of its peak, having
        /// reached it; nil if it never does.
        public var failureDeflection: Float?
        public var summary: StructureSummary
        public var elementCount: Int
        public var wallSeconds: Double
        /// With `unload`: the central deflection left once the plates have been drawn back until
        /// they no longer push, and the beam has settled.
        public var residual: Float?

        /// Predicted moment at central deflection `deflection`, interpolated.
        public func moment(at deflection: Float) -> Float {
            SlabBenchmark.interpolate(curve, at: deflection)
        }

        /// Root-mean-square difference from the measured curve, sampled every millimetre of
        /// deflection up to `limit`, in N m.
        public func curveError(upTo limit: Float = BeamBenchmark.measuredFailureDeflection) -> Float {
            let samples = stride(from: Float(0.001), through: limit, by: 0.001)
            let squares = samples.map { pow(moment(at: $0) - BeamBenchmark.measuredMoment(at: $0), 2) }
            return (squares.reduce(0, +) / Float(max(squares.count, 1))).squareRoot()
        }

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            curve: [SIMD2<Float>],
            peakMoment: Float,
            failureDeflection: Float? = nil,
            summary: StructureSummary,
            elementCount: Int,
            wallSeconds: Double,
            residual: Float? = nil
        ) {
            self.curve = curve
            self.peakMoment = peakMoment
            self.failureDeflection = failureDeflection
            self.summary = summary
            self.elementCount = elementCount
            self.wallSeconds = wallSeconds
            self.residual = residual
        }
    }
}
