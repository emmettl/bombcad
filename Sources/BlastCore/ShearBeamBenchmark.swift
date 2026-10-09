import Foundation
import Metal
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
    }

    /// Pushes the loading plate down at `rate` (m/s), slow against the beam's period, with light
    /// damping, until the centre has gone down by `deflection`. With a `slice` of the width, the
    /// load is scaled up to the whole beam's.
    public static func run(
        device: MTLDevice, elementsThroughDepth: Int = 12, slice: Float? = nil, deflection: Float = 0.016,
        rate: Float = 0.05, crackAxes: CrackAxes = .turningUntilOpen, bondSlip: BondSlip? = nil,
        crackShearStiffness: Bool = false,
        mapAt: Float? = nil,
        slipWidensCracks: Bool = true,
        adjust: (inout StructureMaterial) -> Void = { _ in }
    ) throws -> Result {
        var model = model(elementsThroughDepth: elementsThroughDepth, slice: slice)
        let scale = width / (slice ?? width)
        model.crackAxes = crackAxes
        model.bondSlip = bondSlip
        model.crackShearStiffness = crackShearStiffness
        adjust(&model.material)
        model.slipWidensCracks = slipWidensCracks
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100

        let h = model.elementSize
        let overhang = (length - span) / 2
        let reach = max(Int((plate / 2 / h).rounded()), 0)
        let supports = [overhang, length - overhang].map { Int(($0 / h).rounded()) }
        let middle = Int((length / 2 / h).rounded())
        // Bearings and the loading plate are lines of nodes across the beam, a plate's width
        // along it. The bearings hold the beam up, one of them lengthwise too; the loading plate
        // moves down and is free lengthwise, so no arch or tie forms through it.
        // The beam's width need not be a whole number of elements, so the lattice's last row of
        // nodes across it may be unused; only nodes that exist are held.
        solver.mutateNodes { nodes in
            func node(_ i: Int, _ j: Int, _ k: Int, _ body: (inout StructureNode) -> Void) {
                if let index = solver.storedNode(i, j, k) { body(&nodes[index]) }
            }
            for j in 0...solver.ey {
                for offset in -reach...reach {
                    node(supports[0] + offset, j, 0) { $0.restrain(z: true) }
                    node(supports[1] + offset, j, 0) { $0.restrain(z: true) }
                    node(middle + offset, j, solver.ez) {
                        $0.isPushedVertically = true
                        $0.velocity = SIMD3(0, 0, -rate)
                    }
                }
                node(supports[0], j, 0) { $0.restrain(x: true, y: j == 0) }
            }
        }

        let start = ContinuousClock.now
        var curve: [SIMD2<Float>] = [.zero]
        var map: [String] = []
        var mapLoad: Float = 0
        let stepsPerSample = max(1, Int(0.0001 / rate / solver.criticalTimeStep))
        while curve.last!.x < deflection, solver.time < Double(1.5 * deflection / rate) {
            solver.advance(steps: stepsPerSample)
            var reaction: Float = 0
            for j in 0...solver.ey {
                for support in supports {
                    for offset in -reach...reach where solver.storedNode(support + offset, j, 0) != nil {
                        reaction -= solver.nodalForce(support + offset, j, 0).z
                    }
                }
            }
            let centre = -solver.displacement(middle, solver.ey / 2, 0).z
            curve.append(SIMD2(centre, reaction * scale))
            if let mapAt, map.isEmpty, centre >= mapAt {
                map = solver.crackMap(row: solver.ey / 2)
                mapLoad = reaction * scale
            }
            if !centre.isFinite { break }
        }
        let elapsed = ContinuousClock.now - start
        let top = curve.max { $0.y < $1.y } ?? .zero
        return Result(
            curve: curve, peak: top.y, peakDeflection: top.x, summary: solver.summary(),
            elementCount: solver.elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
            crackMap: map, mapLoad: mapLoad)
    }
}
