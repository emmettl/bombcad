import Foundation
import simd

/// A reinforced concrete beam with no stirrups, which fails suddenly in diagonal tension: beam
/// OA1 of F. J. Vecchio and W. Shim, "Experimental and analytical reexamination of classic
/// concrete beam tests", Journal of Structural Engineering 130(3), 2004, their repeat of
/// Bresler and Scordelis's beam of the same name (1963).
///
/// The geometry, concrete strength and measured load against deflection are taken from P.
/// Bernardi, R. Cerioni, E. Michelini and A. Sirico, "A non-linear procedure for the numerical
/// analysis of crack development in beams failing in shear", Frattura ed Integrità Strutturale
/// 35, 2016, 98-107 (open access), which models the beam and reproduces the measured curve.
public enum ShearBeamBenchmark {
    /// 305 mm wide and 552 mm deep, 4,100 mm long on supports 3,660 mm apart, loaded at
    /// mid-span. Two M30 bars 64 mm above the bottom and two M25 bars 64 mm above them; no
    /// stirrups and no top bars.
    public static let width: Float = 0.305
    public static let depth: Float = 0.552
    public static let length: Float = 4.1
    public static let span: Float = 3.66
    /// Canadian M30 and M25 bars: 700 and 500 mm².
    public static let bars: [(height: Float, area: Float)] = [(0.064, 2 * 700e-6), (0.128, 2 * 500e-6)]
    /// Width of the loading and bearing plates, which the sources do not give: an assumption.
    public static let plate: Float = 0.1

    /// Mid-span load (N) against mid-span deflection (m), read by hand off the source's plot
    /// of Vecchio and Shim's test: the beam cracks in bending, then fails in diagonal tension
    /// at about 332 kN and 9.2 mm, the load falling to 250 kN by 9.4 mm.
    public static let measured: [SIMD2<Float>] = {
        let points: [(Float, Float)] = [
            (0, 0), (0.5, 49), (1, 93), (2, 118), (3, 152), (4, 195), (5, 226), (6, 259), (7, 275), (8, 307),
            (9, 330), (9.2, 332),
        ]
        return points.map { SIMD2($0.0 * 1e-3, $0.1 * 1e3) }
    }()

    public static let measuredPeak: Float = 332e3
    public static let measuredPeakDeflection: Float = 0.0092

    public static func measuredLoad(at deflection: Float) -> Float {
        SlabBenchmark.interpolate(measured, at: deflection)
    }

    /// Concrete of 22.6 MPa, its other properties from the standard correlations; bars of
    /// 440 MPa, which a secondary summary gives and which matters little: they stay elastic up
    /// to the measured failure load.
    public static var material: StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 440e6, ultimateStress: 640e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        return .concrete(name: "Vecchio-Shim OA1", compressiveStrength: 22.6e6, steel: steel)
    }

    /// `slice`, if given, is the width of a slice of the beam to model instead of the whole: it
    /// bends and cracks the same way, and makes fine meshes affordable.
    public static func model(elementsThroughDepth: Int, slice: Float? = nil) -> StructureModel {
        let h = depth / Float(elementsThroughDepth)
        let base = (1 / h).rounded() * h
        let width = slice ?? Self.width
        let beam = Box(min: SIMD3(0, 0, base), max: SIMD3(length, width, base + depth))
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        // Each row of bars smeared through a band one element deep centred on it.
        model.reinforcement = bars.map { row in
            var band = beam
            band.min.z = base + row.height - h / 2
            band.max.z = band.min.z + h
            return ReinforcementLayer(region: band, ratio: SIMD3(row.area / (Self.width * h), 0, 0))
        }
        return model
    }

    public struct Result: Sendable {
        /// Mid-span load (N) against mid-span deflection (m).
        public var curve: [SIMD2<Float>]
        public var peak: Float
        public var peakDeflection: Float
        public var summary: StructureSummary
        public var elementCount: Int
        public var wallSeconds: Double
        /// The cracks through the middle of the width when the beam had deflected by `mapAt`
        /// (see `StructureSolver.crackMap`), and the load then; empty if not asked for.
        public var crackMap: [String] = []
        public var mapLoad: Float = 0

        public func load(at deflection: Float) -> Float {
            SlabBenchmark.interpolate(curve, at: deflection)
        }

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            curve: [SIMD2<Float>],
            peak: Float,
            peakDeflection: Float,
            summary: StructureSummary,
            elementCount: Int,
            wallSeconds: Double,
            crackMap: [String] = [],
            mapLoad: Float = 0
        ) {
            self.curve = curve
            self.peak = peak
            self.peakDeflection = peakDeflection
            self.summary = summary
            self.elementCount = elementCount
            self.wallSeconds = wallSeconds
            self.crackMap = crackMap
            self.mapLoad = mapLoad
        }
    }
}
