import Foundation
import Metal
import simd

extension SheetProfile {
    /// A TR84/273 trapezoidal sheet, 84 mm deep at 273 mm, of `thickness`: its flats, a 100 mm crest
    /// and a 50 mm trough, are those that give Pruszyński's T-84 (84 mm at 275 mm, the same family)
    /// its published second moment at 1.5 mm, 200 cm⁴/m, within 2%; its yield `yield`.
    public static func tr84(thickness: Float, yield: Float) -> Self {
        Self(
            name: "TR84/273 (\(thickness * 1000) mm)", shape: .trapezoidal, thickness: thickness,
            pitch: 0.273,
            depth: 0.084, crestWidth: 0.1, troughWidth: 0.05, yieldStress: yield,
            source: "ADBLAST (EUR 27487, 2015); Pruszyński T-84 data sheet")
    }
}

/// ADBLAST's single-span cladding tests (Fixtures/ADBLAST2015; docs/profiled-sheeting.md): three
/// TR84 sheets over a 2.46 m span between square tubes, screwed to them, under C4 3.5 m above.
///
/// The sheets are a `ProfiledSheet` lying flat, crests up, troughs on the tubes. Each support is a
/// `SpringSupport` per metre of edge, at the troughs' screws, 1/0.273 a metre:
/// - along the span, the screws in bearing: EN 1993-1-3 Table 8.2's F_b = 3.2 √(t/d) f_u d t (at most
///   2.1 f_u d t) a screw, at ADBLAST's stiffness of 0.66 MN/m a screw;
/// - across, the sheet bearing down on the tube, rigidly; pulled up, the screws until the sheet
///   pulls over them, F_p = d_w t f_u a screw (d_w 16 mm, the screws' washer), and then the sheet
///   comes away from that tube;
/// - turning, free.
/// The load is each test's measured reflected pressure, a triangle of its peak and impulse,
/// applied over the whole sheet, with no air.
public enum AdblastCladdingTest {
    public struct Test: Sendable, Codable {
        public var test: Int
        public var chargeKgC4: Float
        public var thicknessMM: Float
        public var reflectedPeakKPa: Float?
        public var reflectedImpulseKPaMS: Float?
        public var firstDynamicDeflectionMM: Float?
        public var plasticDeformationMM: Float?
        public var note: String
    }

    struct Fixture: Decodable {
        var singleSpanTests: [Test]
    }

    /// The single-span tests with a load measured.
    public static func tests(from url: URL) throws -> [Test] {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).singleSpanTests.filter {
            $0.reflectedPeakKPa != nil && $0.reflectedImpulseKPaMS != nil
        }
    }

    public struct Settings: Sendable {
        public var elementSize: Float = 0.123
        /// Simulated time (s).
        public var duration: Float = 0.2
        /// Whether the sheets' flanges soften once they buckle.
        public var buckles = true
        public var postBuckling = ProfiledSheet.PostBuckling.automatic
        /// Whether the screws can pull through (false: the sheet held to the tubes).
        public var releases = true
        public init() {}
    }

    public struct Result: Sendable {
        public var test: Test
        /// The first peak deflection downward (m, negative), and the mean over the last 50 ms (m).
        public var firstPeak: Float
        public var final: Float
        public var history: [SIMD2<Float>]
        /// Whether a support's screws pulled through.
        public var released: Bool
    }

    /// The yield the coupons gave at 2.3 /s, the nearest of ADBLAST's rates to a blast's (Table 8).
    public static func yield(thicknessMM: Float) -> Float {
        thicknessMM < 1 ? 439.15e6 : 420.36e6
    }

    /// Ultimate strength at 2.3 /s (Table 8).
    public static func ultimate(thicknessMM: Float) -> Float {
        thicknessMM < 1 ? 437.83e6 : 464.61e6
    }

    public static func model(thicknessMM: Float, settings: Settings, offset: SIMD3<Float> = .zero)
        -> StructureModel
    {
        let t = thicknessMM / 1000
        let profile = SheetProfile.tr84(thickness: t, yield: yield(thicknessMM: thicknessMM))
        let steel = StructureMaterial(
            name: "S320GD", density: 7850, youngsModulus: 210e9, poissonRatio: 0.3,
            yieldStress: profile.yieldStress,
            hardeningModulus: 0.5e9, failureStrain: 0.26)
        var model = StructureModel(
            solids: [], material: steel, elementSize: settings.elementSize, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let (span, width): (Float, Float) = (2.46, 3.263)
        let sheet = ProfiledSheet(
            profile: profile,
            region: Box(min: offset + SIMD3(0, 0, 0.99), max: offset + SIMD3(span, width, 1.01)), span: 0,
            steel: steel, crestSide: 1, buckles: settings.buckles,
            postBuckling: settings.postBuckling)
        sheet.add(to: &model)
        // The screws, one in each trough: 1 / 0.273 a metre.
        let perMetre: Float = 1 / profile.pitch
        let fu = ultimate(thicknessMM: thicknessMM)
        let d: Float = 0.0063
        let alpha = min(3.2 * (t / d).squareRoot(), 2.1)
        let bearing = alpha * fu * d * t
        let pullThrough = 0.016 * t * fu
        let stiffness: Float = 6.6e5
        let held = SpringLaw(stiffness: 1e10)
        for x in [Float(0), span] {
            model.springSupports.append(
                SpringSupport(
                    region: Box(
                        min: offset + SIMD3(x - 0.005, -0.01, 0.95),
                        max: offset + SIMD3(x + 0.005, width + 0.01, 1.05)),
                    edge: 1,
                    along: 0, pull: SpringLaw(stiffness: stiffness * perMetre, yield: bearing * perMetre),
                    across: settings.releases
                        ? SpringLaw(
                            stiffness: stiffness * perMetre, yield: pullThrough * perMetre,
                            hardening: -10 * stiffness * perMetre) : held,
                    acrossNegative: held, turnPositive: SpringLaw(stiffness: 0),
                    turnNegative: SpringLaw(stiffness: 0),
                    releases: settings.releases))
        }
        return model
    }

    public static func run(_ test: Test, settings: Settings = Settings(), device: MTLDevice) throws -> Result
    {
        let model = model(thicknessMM: test.thicknessMM, settings: settings)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 0
        let peak = test.reflectedPeakKPa! * 1000
        let duration = 2 * test.reflectedImpulseKPaMS! / test.reflectedPeakKPa! / 1000
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true,
            history: [SIMD2(0, peak), SIMD2(duration, 0), SIMD2(duration + 10, 0)])
        let gauge = solver.nearestNode(to: SIMD3(1.23, 1.63, 1))
        let step = solver.criticalTimeStep
        let stepsPerSample = max(1, Int((0.0002 / step).rounded()))
        var history: [SIMD2<Float>] = []
        var time: Float = 0
        while time < settings.duration {
            solver.advance(steps: stepsPerSample)
            time += Float(stepsPerSample) * step
            history.append(SIMD2(time, solver.node(gauge).displacement.z))
        }
        // The first peak: the lowest point before the sheet first comes back up past half of it.
        var first: Float = 0
        for sample in history {
            if sample.y < first { first = sample.y } else if first < 0 && sample.y > 0.5 * first { break }
        }
        let tail = history.filter { $0.x > settings.duration - 0.05 }.map(\.y)
        let edge = solver.nearestNode(to: SIMD3(0, 1.63, 1))
        return Result(
            test: test, firstPeak: first, final: tail.reduce(0, +) / Float(max(tail.count, 1)),
            history: history,
            released: solver.node(edge).displacement.z > 0.05 || abs(solver.node(edge).displacement.x) > 0.05)
    }

    public struct AirResult: Sendable {
        public var structure: Result
        /// The reflected pressure's peak above ambient (Pa) and its impulse (Pa s) at the sheets'
        /// middle, as the gauge there read them.
        public var reflectedPeak: Float
        public var reflectedImpulse: Float
    }

    /// The test as shot: the charge, `tntEquivalence` times its C4 by weight (1.13, the heats of
    /// detonation's ratio, UFC 3-340-02 Table 2-1), 3.5 m above the sheets' middle, the sheets 1 m
    /// above rigid ground on two rigid supports under the tubes (the rig's height is not given), in
    /// air of `cellSize`.
    public static func runInAir(
        _ test: Test, settings: Settings = Settings(), cellSize: Float = 0.05, tntEquivalence: Float = 1.13,
        device: MTLDevice
    ) throws -> AirResult {
        let offset = SIMD3<Float>(3, 3, 0)
        let model = model(thicknessMM: test.thicknessMM, settings: settings, offset: offset)
        let middle = offset + SIMD3<Float>(1.23, 1.6315, 1)
        let supports = [Float(0), 2.46].map { x in
            Box(min: offset + SIMD3(x - 0.1, -0.2, 0), max: offset + SIMD3(x + 0.1, 3.463, 0.95))
        }
        let scenario = Scenario(
            name: "ADBLAST test \(test.test)", domainSize: SIMD3(8.5, 9.3, 5.5), boxes: supports,
            charge: Charge(mass: test.chargeKgC4 * tntEquivalence, position: middle + SIMD3(0, 0, 3.5)),
            gauges: [Gauge("Middle", at: middle + SIMD3(0, 0, 0.065))], structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        guard let shells = solver.shells else { throw BlastError.allocationFailed("the sheets in the air") }
        let gauge = shells.nearestNode(to: middle)
        var history: [SIMD2<Float>] = []
        var time: Double = 0
        while time < Double(settings.duration) {
            time += 0.0005
            _ = solver.advance(until: time)
            history.append(SIMD2(Float(time), shells.node(gauge).displacement.z))
        }
        var first: Float = 0
        for sample in history {
            if sample.y < first { first = sample.y } else if first < 0 && sample.y > 0.5 * first { break }
        }
        let tail = history.filter { $0.x > settings.duration - 0.05 }.map(\.y)
        let samples = solver.gaugeHistories.first ?? []
        let ambient = samples.first?.pressure ?? 101_325
        var impulse: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += 0.5 * max(0, a.pressure - ambient + b.pressure - ambient) * Float(b.time - a.time)
        }
        let edge = shells.nearestNode(to: offset + SIMD3(0, 1.63, 1))
        return AirResult(
            structure: Result(
                test: test, firstPeak: first, final: tail.reduce(0, +) / Float(max(tail.count, 1)),
                history: history,
                released: shells.node(edge).displacement.z > 0.05
                    || abs(shells.node(edge).displacement.x) > 0.05),
            reflectedPeak: (samples.map(\.pressure).max() ?? ambient) - ambient, reflectedImpulse: impulse)
    }

    public struct EnvelopeResult: Sendable {
        /// The one-way model's peak deflection (m, down positive), the deflection it leaves (m),
        /// its damage, and whether its screws were pulled through.
        public var peak: Double
        public var residual: Double
        public var level: EnvelopeDamageLevel
        public var screwsPulled: Bool
    }

    /// The sheets as an envelope's construction, `EnvelopePanel.profiledSheetOneWay` on a single
    /// span of 2.46 m, at S320's nominal yield times UFC's 1.21 × 1.1 (426 MPa, the coupons 420–439
    /// at 2.3 /s), with one screw a trough pulling through by EN 1993-1-3 (as the shells' are);
    /// under `pressures` (Pa, inward positive) binned at `step`.
    public static func envelope(_ test: Test, pressures: [Double], step: Double) -> EnvelopeResult {
        let t = test.thicknessMM / 1000
        let profile = SheetProfile.tr84(thickness: t, yield: 320e6)
        let system = EnvelopePanel.profiledSheetOneWay(profile: profile, span: 2.46, continuous: false)
        let response = system.response(pressures: pressures, step: step)
        let rotation = atan(max(response.peakDeflection, -response.reboundDeflection) / 1.23) * 180 / .pi
        var level = EnvelopeDamageLevel.profiledSheet(ductility: response.ductility, rotationDeg: rotation)
        let screw = Double(0.016 * t * ultimate(thicknessMM: test.thicknessMM))
        let holding = screw / Double(profile.pitch)
        let pulled =
            EnvelopePanel.sheetPullOff(
                system, response: response, suction: -(pressures.min() ?? 0), span: 2.46)
            > holding
        if pulled { level = .failed }
        return EnvelopeResult(
            peak: response.peakDeflection, residual: response.residualDeflection, level: level,
            screwsPulled: pulled)
    }

    /// The one-way model under the test's measured reflected pulse at the middle, as a triangle.
    public static func envelopeOnMeasured(_ test: Test) -> EnvelopeResult {
        let step = 1e-4
        let peak = Double(test.reflectedPeakKPa!) * 1000
        let duration = 2 * Double(test.reflectedImpulseKPaMS!) / Double(test.reflectedPeakKPa!) / 1000
        let pressures = stride(from: 0.0, through: 0.1, by: step).map { time in
            time < duration ? peak * (1 - time / duration) : 0
        }
        return envelope(test, pressures: pressures, step: step)
    }

    /// The one-way model under the load the air puts on the same panel as a rigid envelope, 1 m
    /// above ground on two rigid supports, the charge as `runInAir`'s. The panel is cut into
    /// `along` × `across` envelope objects, each recorded as the envelope recorder sums a component
    /// (its mean net pressure): `whole` is under their mean, the whole panel's as one component;
    /// `middle` under the middle band across (the ribs where the deflection was measured), along
    /// the span weighted by the deflected shape sin(πx/L) (Biggs's equivalent uniform load). The
    /// load depends only on the charge, so `loads` (along the span fastest) serves every test of it.
    public static func envelopeInAir(
        _ test: Test, along: Int = 5, across: Int = 3, cellSize: Float = 0.05, tntEquivalence: Float = 1.13,
        device: MTLDevice
    ) throws -> (whole: EnvelopeResult, middle: EnvelopeResult, loads: [EnvelopeComponentLoad]) {
        let loads = try envelopeLoadsInAir(
            test, along: along, across: across, cellSize: cellSize, tntEquivalence: tntEquivalence,
            device: device)
        let (whole, middle) = envelope(test, loads: loads, along: along, across: across)
        return (whole, middle, loads)
    }

    /// `envelopeInAir`'s two results from its strips' loads.
    public static func envelope(_ test: Test, loads: [EnvelopeComponentLoad], along: Int, across: Int)
        -> (whole: EnvelopeResult, middle: EnvelopeResult)
    {
        let count = loads.map(\.netPa.count).min() ?? 0
        let step = loads[0].binS
        let tail = Array(repeating: 0.0, count: Int(0.07 / step))
        let shape = (0..<along).map { sin(Double.pi * (Double($0) + 0.5) / Double(along)) }
        let band = across / 2
        let nets = loads.map(\.netPa)
        let whole = (0..<count).map { n in nets.reduce(0) { $0 + $1[n] } / Double(nets.count) }
        let middle = (0..<count).map { n in
            (0..<along).reduce(0) { $0 + shape[$1] * nets[band * along + $1][n] } / shape.reduce(0, +)
        }
        return (
            envelope(test, pressures: whole + tail, step: step),
            envelope(test, pressures: middle + tail, step: step)
        )
    }

    /// The air's load on the same panel cut into `along` × `across` envelope objects (along the
    /// span fastest).
    public static func envelopeLoadsInAir(
        _ test: Test, along: Int, across: Int, cellSize: Float = 0.05, tntEquivalence: Float = 1.13,
        device: MTLDevice
    ) throws -> [EnvelopeComponentLoad] {
        let offset = SIMD3<Float>(3, 3, 0)
        let middle = offset + SIMD3<Float>(1.23, 1.6315, 1)
        let supports = [Float(0), 2.46].map { x in
            Box(min: offset + SIMD3(x - 0.1, -0.2, 0), max: offset + SIMD3(x + 0.1, 3.463, 0.95))
        }
        var scenario = Scenario(
            name: "ADBLAST test \(test.test) as an envelope", domainSize: SIMD3(8.5, 9.3, 5.5),
            boxes: supports,
            charge: Charge(mass: test.chargeKgC4 * tntEquivalence, position: middle + SIMD3(0, 0, 3.5)))
        var owners: [UUID] = []
        let (dx, dy) = (Float(2.46) / Float(along), Float(3.263) / Float(across))
        for j in 0..<across {
            for i in 0..<along {
                let strip = Box(
                    min: offset + SIMD3(Float(i) * dx, Float(j) * dy, 0.958),
                    max: offset + SIMD3(Float(i + 1) * dx, Float(j + 1) * dy, 1.042))
                owners.append(
                    try scenario.addEnvelopeObject(
                        try BuildingEnvelope(solids: [strip]), name: "Strip \(i) \(j)"))
            }
        }
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        try solver.configureEnvelopeComponents(
            objects: scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.03))
        _ = solver.advance(until: 0.03)
        let histories = solver.envelopeComponentHistories() ?? []
        return try owners.map { owner in
            guard
                let history = histories.first(where: {
                    $0.component.owner == owner && $0.component.kind == .roof
                })
            else { throw BlastError.allocationFailed("a strip's roof component") }
            return EnvelopeComponentLoad(history)
        }
    }
}
