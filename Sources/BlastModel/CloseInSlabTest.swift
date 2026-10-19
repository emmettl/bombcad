import Foundation
import simd

/// Full-scale reinforced concrete slabs under charges hung 0.5 m and 1 m above them: M. Chiquito,
/// L. M. López, R. Castedo, A. P. Santos and A. Pérez-Caldentey, "Full-scale field tests on
/// concrete slabs subjected to close-in blast loads", *Buildings* 13, 2068 (2023), and, for the
/// second campaign's damage on each face, S. Martínez-Almajano et al., "Field test and numerical
/// modelling of RC slabs at different scaled distances with two types of external
/// reinforcement", *International Journal of Computational Methods and Experimental
/// Measurements* 9(3), 2021. Both open access.
///
/// Slabs 4.40 × 1.46 × 0.15 m of C25/30 concrete (25 MPa, 20 mm aggregate) with B500 bars, laid
/// across two concrete blocks 0.9 m high and clamped to them by steel bars bolted through the
/// slab 0.2 m from each end (4.00 m apart). The first campaign (S) had 12 mm bars at 150 mm in
/// both faces; the second (P), 10 mm bars at 300 mm in the face towards the charge and 12 mm at
/// 150 mm in the other, both ways, with about 30 mm of cover. Only the slabs without added
/// protection are used. Pressure gauges sat flush in the tops of blocks beside the slab, level
/// with its top face, 1 m and 2 m from its centre across its width.
///
/// Assumed: the charge's height is to its centre; the clamps are hinges that hold the slab down
/// and lengthwise at mid-depth on the bolt line, the slab's ends resting on the blocks behind
/// them; the blocks beside the slab carrying the gauges are 0.55 m long and reach from 0.83 m to
/// 2.4 m from the slab's centre, read off the paper's Figure 4.
public enum CloseInSlabTest {
    public struct Test: Sendable {
        public var name: String
        /// TNT-equivalent mass (kg) and height of its centre above the slab's top face (m).
        public var charge: Float
        public var standoff: Float
        /// The second campaign's bars (10 mm at 300 mm towards the charge) rather than the first's.
        public var lightTopMat: Bool
        /// Measured permanent deflection at mid-span (m), where it was measured.
        public var deflection: Float?
        /// Spalled area as a fraction of the slab's face, on the side towards the charge and the
        /// side away from it, where reported.
        public var damagedTop: Float?
        public var damagedBottom: Float?
        public var perforated: Bool
        /// Peak pressure measured at the gauges 1 m and 2 m from the centre (Pa), where recorded.
        public var nearGauge: ClosedRange<Float>?
        public var farGauge: ClosedRange<Float>?
        public var remark: String
    }

    public static let tests: [Test] = [
        Test(
            name: "S1-S3", charge: 2.0, standoff: 1.0, lightTopMat: false, deflection: nil, damagedTop: 0,
            damagedBottom: 0, perforated: false, nearGauge: 2.5e6...3.6e6, farGauge: 0.47e6...0.58e6,
            remark:
                "calibration shots: minor cracks only; the text gives 2.5 and 0.5 MPa at G1 and G3, its Figure 9 peaks of 3.3-3.6 and 0.47-0.58"
        ),
        Test(
            name: "P1", charge: 1.74, standoff: 1.0, lightTopMat: true, deflection: 0, damagedTop: 0,
            damagedBottom: 0, perforated: false, nearGauge: 2.01e6...2.01e6, farGauge: nil,
            remark: "calibration shot: minor cracks; one gauge, 1 m from the centre"),
        Test(
            name: "S4", charge: 15, standoff: 1.0, lightTopMat: false, deflection: nil, damagedTop: 0.03,
            damagedBottom: nil, perforated: false, nearGauge: nil, farGauge: nil,
            remark: "bent at mid-span, hanging as a membrane"),
        Test(
            name: "P7", charge: 13.05, standoff: 1.0, lightTopMat: true, deflection: 0.34, damagedTop: 0.0338,
            damagedBottom: 0.1034, perforated: false, nearGauge: nil, farGauge: nil,
            remark: "bent at mid-span, hanging as a membrane"),
        Test(
            name: "S5", charge: 15, standoff: 0.5, lightTopMat: false, deflection: nil, damagedTop: 0.07,
            damagedBottom: nil, perforated: true, nearGauge: nil, farGauge: nil,
            remark: "punched through under the charge"),
        Test(
            name: "P2", charge: 13.05, standoff: 0.5, lightTopMat: true, deflection: 0.51, damagedTop: 0.0819,
            damagedBottom: 0.1862, perforated: true, nearGauge: nil, farGauge: nil,
            remark: "punched through under the charge, the bars left across the hole"),
    ]

    // Coordinates: x along the span, y across it, z up from the ground.
    public static let slab = Box(min: SIMD3(1.2, 2.5, 0.9), max: SIMD3(5.6, 3.96, 1.05))
    public static let boltLines: [Float] = [1.4, 5.4]
    public static var centre: SIMD3<Float> {
        SIMD3((slab.min.x + slab.max.x) / 2, (slab.min.y + slab.max.y) / 2, slab.max.z)
    }
    package static let domainSize = SIMD3<Float>(6.8, 6.45, 3.0)

    /// C25/30 at the 25 MPa the papers give, 2,300 kg/m³ and 20 mm aggregate, strengthening with
    /// strain rate; B500 bars, 500 MPa at yield and 575 at ultimate.
    public static func material() -> StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 500e6, ultimateStress: 575e6, ultimateStrain: 0.075, ruptureStrain: 0.15)
        var material = StructureMaterial.concrete(
            name: "C25/30", compressiveStrength: 25e6, density: 2300, steel: steel)
        material.aggregateSize = 0.02
        material.rateDependent = true
        return material
    }

    /// The scene, moved by `pad.low` with the domain grown by `pad.low + pad.high`
    /// (`Scenario.openFaceRoom`).
    public static func scenario(
        _ test: Test, elementSize: Float = 0.025,
        pad: (low: SIMD3<Float>, high: SIMD3<Float>) = (.zero, .zero)
    ) -> Scenario {
        let o = pad.low
        let slab = Self.slab.moved(by: o)
        let boltLines = Self.boltLines.map { $0 + o.x }
        var model = StructureModel(
            solids: [slab], material: material(), elementSize: elementSize, fixedBase: false)
        // Bars 30 mm in, to the centre of the outer layer and the inner one about a bar further.
        let bottom: Float = 113.1e-6 / 0.15
        let top: Float = test.lightTopMat ? 78.5e-6 / 0.3 : bottom
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: bottom, depth: 0.042, faces: (low: true, high: false))
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: top, depth: 0.042, faces: (low: false, high: true))
        let c = centre + o
        let boxes = [
            // The supporting blocks, under the slab's ends to the bolt lines.
            Box(min: SIMD3(0.2 + o.x, c.y - 1, 0), max: SIMD3(boltLines[0], c.y + 1, slab.min.z)),
            Box(min: SIMD3(boltLines[1], c.y - 1, 0), max: SIMD3(6.6 + o.x, c.y + 1, slab.min.z)),
            // The gauges' blocks, either side, their tops level with the slab's.
            Box(min: SIMD3(c.x - 0.275, c.y + 0.83, 0), max: SIMD3(c.x + 0.275, c.y + 2.4, slab.max.z)),
            Box(min: SIMD3(c.x - 0.275, c.y - 2.4, 0), max: SIMD3(c.x + 0.275, c.y - 0.83, slab.max.z)),
        ]
        // Gauges sit in the air cell against the surface (cells up to 50 mm), where the gas is
        // brought to rest: a cell further out misses the momentum it still carries towards it.
        let lift: Float = 0.01
        let gauges = [
            Gauge("G1, 1 m", at: SIMD3(c.x, c.y + 1, slab.max.z + lift)),
            Gauge("G2, 1 m", at: SIMD3(c.x, c.y - 1, slab.max.z + lift)),
            Gauge("G3, 2 m", at: SIMD3(c.x, c.y + 2, slab.max.z + lift)),
            Gauge("G4, 2 m", at: SIMD3(c.x, c.y - 2, slab.max.z + lift)),
            // In the open, level with the charge and as far from it as G1, for the incident wave.
            Gauge("Free air, as G1", at: c + SIMD3(1.414, 0, test.standoff)),
            // On the slab's top face under the charge, where the wave strikes square on.
            Gauge("Slab centre", at: c + SIMD3(0, 0, lift)),
        ]
        return Scenario(
            name: "Close-in slab \(test.name)", domainSize: domainSize + pad.low + pad.high, boxes: boxes,
            charge: Charge(mass: test.charge, position: c + SIMD3(0, 0, test.standoff)), gauges: gauges,
            structure: model)
    }

    public struct Result: Sendable {
        /// Mid-span deflection (m, down) against time (s): the median across the slab's width of
        /// its mid-depth nodes at mid-span, which a spall or crater under the charge leaves out.
        public var history: [SIMD2<Float>]
        public var peak: Float
        /// Mean of the last fifth of the record.
        public var permanent: Float
        /// Fraction of each face whose surface element has been removed or cracked loose.
        public var damagedTop: Float
        public var damagedBottom: Float
        /// Whether a column of failed elements runs through the slab's thickness.
        public var perforated: Bool
        public var gaugePeaks: [(name: String, pressure: Float)]
        /// Impulse of each gauge's overpressure, positive phase only (Pa s).
        public var gaugeImpulses: [Float]
        /// Each gauge's record of absolute pressure.
        public var gaugeHistories: [[GaugeSample]]
        /// The slab's largest downward momentum in the first 5 ms (N s): about the impulse the
        /// blast gave it, before the supports have taken much.
        public var impulse: Float
        public var summary: StructureSummary
        public var wallSeconds: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            history: [SIMD2<Float>],
            peak: Float,
            permanent: Float,
            damagedTop: Float,
            damagedBottom: Float,
            perforated: Bool,
            gaugePeaks: [(name: String, pressure: Float)],
            gaugeImpulses: [Float],
            gaugeHistories: [[GaugeSample]],
            impulse: Float,
            summary: StructureSummary,
            wallSeconds: Double
        ) {
            self.history = history
            self.peak = peak
            self.permanent = permanent
            self.damagedTop = damagedTop
            self.damagedBottom = damagedBottom
            self.perforated = perforated
            self.gaugePeaks = gaugePeaks
            self.gaugeImpulses = gaugeImpulses
            self.gaugeHistories = gaugeHistories
            self.impulse = impulse
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
    }
}
