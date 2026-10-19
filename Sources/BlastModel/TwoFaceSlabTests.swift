import Foundation
import simd

/// Slabs with steel in one face or both, under TNT in contact, close in and in the open air:
/// two open data sets (both CC BY 4.0; the derived data are in `Fixtures/TwoFaceSlabs`).
///
/// Y. Wu et al., "A research investigation into the impact of reinforcement distribution and
/// blast distance on the blast resilience of reinforced concrete slabs", *Materials* 16, 4068
/// (2023): sixteen slabs 2 × 2 m and 100 mm thick, eight with one layer of 8 mm bars at 100 mm
/// both ways (S) and eight with a layer at 200 mm in each face (D), the same steel in all;
/// spanning one way on a steel frame, bolted down by two clamps a side; one shot each of TNT in
/// contact (S1-S4, D1-D4) or 0.25-0.50 m above at 0.43 m/kg^(1/3) (S5-S8, D5-D8). Concrete
/// measured at 47.0 MPa (the mean of six 150 mm cubes), bars at 455 MPa yield and 587.5 MPa
/// ultimate. Measured: the displacement 300 mm from the centre of the underside (its peak,
/// rebound and residual are tabulated), damaged areas on each face and any hole's diameter.
///
/// W. Wang et al., "Blast resistance of reinforced concrete slabs based on residual
/// load-bearing capacity", *Materials* 15, 6449 (2022): two slabs 1,200 × 500 × 100 mm with
/// bars both ways in both faces, 8 mm at 100 mm (A) and 12 mm at 100 mm (B), standing upright
/// with their centres 0.7 m above the ground, clamped all round; one shot of a 10 kg sphere of
/// TNT, RDX and aluminium, which the paper gives as 10 kg of TNT, 1.2 m from each. Reflected
/// pressures were measured on a steel plate placed as the slabs were, and displacements at five
/// points down each slab's back.
///
/// Assumed, for Wu: the cube strength's 0.8 for the cylinder strength; the layers centred 20 mm
/// from the faces, as the drawing dimensions them (its text prints the two layers 600 mm apart);
/// the slab bearing on 100 mm of each supported edge, held down there along the clamps' line and
/// lengthwise at one edge only; the frame's beams under the supported edges, from the ground,
/// 0.6 m below the slab; the blast distance to the charge's centre, a contact charge as a sphere
/// of TNT touching the slab. For Wang: 30 MPa, the grade's value its own model used, and HRB400
/// bars at 400 MPa yield and 540 MPa ultimate; the layers 20 mm from the faces (its drawing
/// marks 13 mm of cover, and its steel ratios put the bars 80 mm from the far face); the edges
/// fixed over 50 mm all round; a steel frame 0.1 m wide about the slab and a shield 0.3 m behind
/// it; the displacement gauges 0.2 and 0.4 m above and below the centre, which its sketches
/// place only roughly; and the TNT equivalence of its aluminised charge, 10 kg, as stated.
public enum TwoFaceSlabTests {
    /// Steel in one face (Wu's S) or both (Wu's D, Wang's).
    public enum Layers: String, Sendable {
        case one, two
    }

    // MARK: - Wu et al. (2023)

    public struct WuTest: Sendable {
        public var name: String
        public var layers: Layers
        /// TNT (kg), and the height of its centre above the top face (m); nil in contact.
        public var charge: Float
        public var standoff: Float?
        /// Measured 300 mm from the centre of the underside (m, down positive): the peak, the
        /// rebound (positive up, beyond where it started) and the residual, from the paper's
        /// Table 10; nil where not measured.
        public var peak: Float?
        public var rebound: Float?
        public var residual: Float?
        /// Damaged area of the top and bottom faces (m²) and the hole's diameter (m), from its
        /// Tables 6 and 9; nil where none was reported.
        public var damagedTop: Float?
        public var damagedBottom: Float?
        public var hole: Float?
        public var remark: String
    }

    public static let wuTests: [WuTest] = [
        WuTest(
            name: "S1", layers: .one, charge: 0.2, standoff: nil, damagedTop: 0.075, damagedBottom: 0.14,
            hole: 0.15, remark: "holed, 15 cm"),
        WuTest(
            name: "S2", layers: .one, charge: 0.4, standoff: nil, damagedTop: 0.1, damagedBottom: 0.195,
            hole: 0.21, remark: "holed, 21 cm"),
        WuTest(
            name: "S3", layers: .one, charge: 0.8, standoff: nil, damagedTop: 0.11, damagedBottom: 0.2225,
            hole: 0.23, remark: "holed, 23 cm"),
        WuTest(
            name: "S4", layers: .one, charge: 1.6, standoff: nil, damagedTop: 0.1275, damagedBottom: 0.285,
            hole: 0.275, remark: "holed, 27.5 cm"),
        WuTest(
            name: "D1", layers: .two, charge: 0.2, standoff: nil, damagedTop: 0.065, damagedBottom: 0.1375,
            hole: 0.14, remark: "holed, 14 cm"),
        WuTest(
            name: "D2", layers: .two, charge: 0.4, standoff: nil, damagedTop: 0.0825, damagedBottom: 0.15,
            hole: 0.18, remark: "holed, 18 cm"),
        WuTest(
            name: "D3", layers: .two, charge: 0.8, standoff: nil, damagedTop: 0.0975, damagedBottom: 0.1925,
            hole: 0.22, remark: "holed, 22 cm"),
        WuTest(
            name: "D4", layers: .two, charge: 1.6, standoff: nil, damagedTop: 0.1125, damagedBottom: 0.2125,
            hole: 0.235, remark: "holed, 23.5 cm"),
        WuTest(
            name: "S5", layers: .one, charge: 0.2, standoff: 0.25, peak: 0.00399, rebound: 0.00185,
            residual: 0.0007, remark: "a small crack under the centre"),
        WuTest(
            name: "S6", layers: .one, charge: 0.4, standoff: 0.32, peak: 0.00824, rebound: 0.00587,
            residual: 0.00199, damagedBottom: 0.1075, remark: "underside spalled 4.5 cm deep"),
        WuTest(
            name: "S7", layers: .one, charge: 0.8, standoff: 0.40, peak: 0.01319, rebound: 0.01164,
            residual: 0.00425, damagedBottom: 0.0975, remark: "underside spalled 4 cm deep"),
        WuTest(
            name: "S8", layers: .one, charge: 1.6, standoff: 0.50, peak: 0.01799, rebound: 0.0184,
            residual: 0.00561, remark: "ring and radial cracks on the underside"),
        WuTest(
            name: "D5", layers: .two, charge: 0.2, standoff: 0.25, peak: 0.0041, rebound: -0.0011,
            residual: 0.00197, remark: "no damage"),
        WuTest(
            name: "D6", layers: .two, charge: 0.4, standoff: 0.32, peak: 0.0101, rebound: 0.00428,
            residual: 0.00406, damagedBottom: 0.14, remark: "underside spalled 3.5 cm deep"),
        WuTest(
            name: "D7", layers: .two, charge: 0.8, standoff: 0.40, peak: 0.01198, rebound: 0.00959,
            residual: 0.00436, remark: "ring and radial cracks on the underside"),
        WuTest(
            name: "D8", layers: .two, charge: 1.6, standoff: 0.50, peak: 0.01391, rebound: 0.01312,
            residual: 0.00695, remark: "ring and radial cracks on the underside"),
    ]

    // Coordinates: x along the span, y across it, z up from the ground.
    public static let wuSlab = Box(min: SIMD3(0.5, 0.5, 0.6), max: SIMD3(2.5, 2.5, 0.7))
    /// Bearing width on each supported edge.
    public static let wuBearing: Float = 0.1
    static let wuDomain = SIMD3<Float>(3.0, 3.0, 1.5)

    public static var wuCentre: SIMD3<Float> {
        SIMD3((wuSlab.min.x + wuSlab.max.x) / 2, (wuSlab.min.y + wuSlab.max.y) / 2, wuSlab.max.z)
    }

    /// C40 at 0.8 of the 47.0 MPa cube mean, strengthening with strain rate; HRB400E bars at
    /// 455 MPa and 587.5 MPa, the 21% elongation taken as the rupture strain.
    public static func wuMaterial() -> StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 455e6, ultimateStress: 587.5e6, ultimateStrain: 0.1, ruptureStrain: 0.21)
        var material = StructureMaterial.concrete(name: "C40", compressiveStrength: 0.8 * 47e6, steel: steel)
        material.rateDependent = true
        return material
    }

    /// Radius (m) of a sphere of TNT (1,600 kg/m³) of `mass` kg.
    static func sphereRadius(_ mass: Float) -> Float { pow(3 * mass / (4 * .pi * 1600), 1 / 3) }

    /// The scene, moved by `pad.low` with the domain grown by `pad.low + pad.high`
    /// (`Scenario.openFaceRoom`).
    public static func scenario(
        _ test: WuTest, elementSize: Float = 0.0125,
        pad: (low: SIMD3<Float>, high: SIMD3<Float>) = (.zero, .zero)
    ) -> Scenario {
        let wuSlab = Self.wuSlab.moved(by: pad.low)
        var model = StructureModel(
            solids: [wuSlab], material: wuMaterial(), elementSize: elementSize, fixedBase: false)
        let bar: Float = .pi * 0.004 * 0.004
        switch test.layers {
        case .one:
            model.addMat(
                to: wuSlab, thicknessAxis: 2, areaPerMetre: bar / 0.1, depth: 0.02,
                faces: (low: true, high: false))
        case .two:
            model.addMat(to: wuSlab, thicknessAxis: 2, areaPerMetre: bar / 0.2, depth: 0.02)
        }
        let c = wuCentre + pad.low
        // The frame's beams under the supported edges.
        let boxes = [
            Box(
                min: SIMD3(wuSlab.min.x, wuSlab.min.y, 0),
                max: SIMD3(wuSlab.min.x + wuBearing, wuSlab.max.y, wuSlab.min.z)),
            Box(
                min: SIMD3(wuSlab.max.x - wuBearing, wuSlab.min.y, 0),
                max: SIMD3(wuSlab.max.x, wuSlab.max.y, wuSlab.min.z)),
        ]
        let height = test.standoff ?? sphereRadius(test.charge)
        return Scenario(
            name: "Wu \(test.name)", domainSize: wuDomain + pad.low + pad.high, boxes: boxes,
            charge: Charge(mass: test.charge, position: c + SIMD3(0, 0, height)),
            gauges: [Gauge("Slab centre", at: c + SIMD3(0, 0, 0.01))], structure: model)
    }

    // MARK: - Wang et al. (2022)

    public struct WangTest: Sendable {
        public var name: String
        /// Bar diameter (m), at 100 mm both ways in both faces.
        public var bar: Float
        /// Peak and residual displacement (m, away from the charge positive) at the five gauges,
        /// top to bottom (the paper's D1-D5 or D6-D10, Tables 3 and 4).
        public var peaks: [Float]
        public var residuals: [Float]
        public var remark: String
    }

    public static let wangTests: [WangTest] = [
        WangTest(
            name: "A", bar: 0.008, peaks: [0.0051, 0.0118, 0.0197, 0.0198, 0.0089],
            residuals: [-0.0037, 0.0118, 0.0197, 0.0173, 0.0038],
            remark: "cracks both ways at the back, shear cracks at the ends, bars exposed"),
        WangTest(
            name: "B", bar: 0.012, peaks: [0.0067, 0.0092, 0.0141, 0.0109, 0.0079],
            residuals: [0.0003, 0.0031, 0.0058, 0.008, 0.0008], remark: "fine cracks at the back"),
    ]

    /// The measured reflected pressure (Table 2): name, offset from the face's centre across and
    /// up (m), peak (Pa), arrival (s) and impulse (Pa s).
    public static let wangGauges:
        [(name: String, offset: SIMD2<Float>, peak: Float, arrival: Float, impulse: Float)] = [
            ("P1", SIMD2(0, 0), 32.32e6, 0.00036, 3350),
            ("P2", SIMD2(0.16, 0), 26.47e6, 0.000363, 3020),
            ("P3", SIMD2(0, 0.3), 23.58e6, 0.00038, 2930),
        ]
    /// The displacement gauges' heights relative to the slab's centre, top to bottom.
    public static let wangGaugeHeights: [Float] = [0.4, 0.2, 0, -0.2, -0.4]

    // Coordinates: x across the slab's width, y away from the charge, z up from the ground.
    public static let wangSlab = Box(min: SIMD3(1.0, 1.6, 0.1), max: SIMD3(1.5, 1.7, 1.3))
    public static let wangEdge: Float = 0.05
    static let wangDomain = SIMD3<Float>(2.5, 2.3, 2.0)
    public static var wangCentre: SIMD3<Float> {
        SIMD3((wangSlab.min.x + wangSlab.max.x) / 2, wangSlab.min.y, (wangSlab.min.z + wangSlab.max.z) / 2)
    }

    public static func wangMaterial() -> StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 400e6, ultimateStress: 540e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        var material = StructureMaterial.concrete(
            name: "C30", compressiveStrength: 30e6, density: 2300, steel: steel)
        material.rateDependent = true
        return material
    }

    /// The scene, moved by `pad.low` with the domain grown by `pad.low + pad.high`
    /// (`Scenario.openFaceRoom`).
    public static func scenario(
        _ test: WangTest, elementSize: Float = 0.0125,
        pad: (low: SIMD3<Float>, high: SIMD3<Float>) = (.zero, .zero)
    ) -> Scenario {
        let wangSlab = Self.wangSlab.moved(by: pad.low)
        var model = StructureModel(
            solids: [wangSlab], material: wangMaterial(), elementSize: elementSize, fixedBase: false)
        model.addMat(
            to: wangSlab, thicknessAxis: 1, areaPerMetre: .pi * test.bar * test.bar / 4 / 0.1, depth: 0.02)
        let s = wangSlab
        let frame: Float = 0.1
        let boxes = [
            // The frame about the slab, in its plane, and the shield behind it.
            Box(min: SIMD3(s.min.x - frame, s.min.y, 0), max: SIMD3(s.min.x, s.max.y, s.max.z + frame)),
            Box(min: SIMD3(s.max.x, s.min.y, 0), max: SIMD3(s.max.x + frame, s.max.y, s.max.z + frame)),
            Box(min: SIMD3(s.min.x, s.min.y, s.max.z), max: SIMD3(s.max.x, s.max.y, s.max.z + frame)),
            Box(min: SIMD3(s.min.x, s.min.y, 0), max: SIMD3(s.max.x, s.max.y, s.min.z)),
            Box(
                min: SIMD3(s.min.x - 0.5, s.max.y + 0.3, 0),
                max: SIMD3(s.max.x + 0.5, s.max.y + 0.35, s.max.z + 0.3)),
        ]
        let c = wangCentre + pad.low
        let gauges = wangGauges.map { Gauge($0.name, at: c + SIMD3($0.offset.x, -0.01, $0.offset.y)) }
        return Scenario(
            name: "Wang \(test.name)", domainSize: wangDomain + pad.low + pad.high, boxes: boxes,
            charge: Charge(mass: 10, position: c - SIMD3(0, 1.2, 0)), gauges: gauges, structure: model)
    }

    // MARK: - Running them

    public struct Result: Sendable {
        /// Displacement (m) against time (s) at each probe, positive away from the charge.
        public var probes: [String]
        public var histories: [[SIMD2<Float>]]
        public var peaks: [Float]
        /// The largest movement back towards the charge after the peak (m, positive towards it).
        public var rebounds: [Float]
        /// The mean of the last 10 ms.
        public var residuals: [Float]
        /// Areas (m²) of the face towards the charge and the face away from it whose surface
        /// element has been removed or cracked loose, and of columns removed through the
        /// thickness, as the diameter of a circle of that area (m).
        public var damagedFront: Float
        public var damagedBack: Float
        public var hole: Float
        public var gaugePeaks: [Float]
        public var gaugeArrivals: [Float]
        public var gaugeImpulses: [Float]
        /// With the work trace on (`StructureSolver.tracesWork`), the work by mechanism when the
        /// first probe peaked and at the end (see `StructureSolver.WorkChannel`).
        public var workAtPeak: [Double]?
        public var work: [Double]?
        public var summary: StructureSummary
        public var wallSeconds: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            probes: [String],
            histories: [[SIMD2<Float>]],
            peaks: [Float],
            rebounds: [Float],
            residuals: [Float],
            damagedFront: Float,
            damagedBack: Float,
            hole: Float,
            gaugePeaks: [Float],
            gaugeArrivals: [Float],
            gaugeImpulses: [Float],
            workAtPeak: [Double]? = nil,
            work: [Double]? = nil,
            summary: StructureSummary,
            wallSeconds: Double
        ) {
            self.probes = probes
            self.histories = histories
            self.peaks = peaks
            self.rebounds = rebounds
            self.residuals = residuals
            self.damagedFront = damagedFront
            self.damagedBack = damagedBack
            self.hole = hole
            self.gaugePeaks = gaugePeaks
            self.gaugeArrivals = gaugeArrivals
            self.gaugeImpulses = gaugeImpulses
            self.workAtPeak = workAtPeak
            self.work = work
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
    }

    /// A probe: its name and the lattice node it reads, with the axis along which the slab bends.
    package struct Probe {
        package var name: String
        package var node: (Int, Int, Int)
    }

    /// How Wang's slabs are held at their edges.
    public enum WangEdges: String, Sendable {
        /// Every node within `wangEdge` of an edge fixed: clamped, and held in its plane.
        case fixed
        /// A line of nodes at mid-depth `wangEdge` / 2 in held, free to turn: hinged, but still
        /// held in its plane.
        case hinged
        /// Every node within `wangEdge` of an edge held across the slab only, free to slide in
        /// its plane: clamped against turning, but with no thrust to arch against.
        case sliding
    }
}
