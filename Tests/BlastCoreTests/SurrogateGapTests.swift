import Foundation
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Paths through the façade load surrogate (`FacadeLoadSurrogate`) that `FacadeLoadSurrogateTests`
/// does not reach: the sign and monotonicity of each fitted feature taken alone, the rise share's
/// clamp and rounding, the pulses' rounding to a shared step, and Kingery–Bulmash recovered when
/// the fitted terms are taken away. `FacadeLoadSurrogateTests.sight` compares three faces of one
/// scene once; none of its checks holds every feature but one fixed.
@Suite("Façade load surrogate paths not otherwise reached")
struct SurrogateGapTests {
    /// A face `distanceM` from the charge, facing it by `facing`, with nothing in the way, on flat
    /// ground, at ground level.
    private static func open(_ distanceM: Double, facing: Double = 1) -> FacadeLoadSurrogate.Features {
        FacadeLoadSurrogate.Features(
            distanceM: distanceM, cosIncidence: facing, buildingsCrossed: 0, blockedM: 0, ridgeM: 0,
            groundRiseM: 0, heightM: 0, shadowM: 0, frontM: Double(FacadeLoadSurrogate.Raster.frontReachM))
    }

    /// The fit's own regime: 20 t and 500 t on 4 m cells, cells over W^(1/3) of 0.15 and 0.05
    /// (docs/surrogate-first-look.md, "How it was fitted").
    static let masses: [Double] = [20_000, 500_000]
    static let cellSize = 4.0

    /// Coefficients that correct nothing: every term's weight zero.
    private static let uncorrected = FacadeLoadSurrogate.Coefficients(
        peak: [Double](repeating: 0, count: FacadeLoadSurrogate.termNames.count),
        impulse: [Double](repeating: 0, count: FacadeLoadSurrogate.termNames.count),
        rise: [Double](repeating: 0, count: FacadeLoadSurrogate.termNames.count),
        scaledRange: 0.2...40, scatter: .zero, fittedTo: "nothing")

    /// The predictions for `base` with one feature set by `set` to each of `values` in turn.
    private static func sweep(
        _ base: FacadeLoadSurrogate.Features, mass: Double, values: [Double],
        set: (inout FacadeLoadSurrogate.Features, Double) -> Void
    ) -> [FacadeLoadSurrogate.Prediction] {
        values.map { value in
            var f = base
            set(&f, value)
            return FacadeLoadSurrogate.predict(f, mass: mass, cellSize: cellSize)
        }
    }

    /// Where in `values` (as indices of the later one) a value rises above the one before it.
    private static func rises(_ values: [Double]) -> [Int] {
        values.indices.dropFirst().filter { values[$0] > values[$0 - 1] }
    }

    // MARK: Terms and coefficients

    /// `predict` sums the coefficients against the terms with `zip`, which stops at the shorter
    /// of the two without a word. A refit (`Scripts/fit-surrogate.py`) that dropped or added a term,
    /// or a coefficients file decoded with too few, would quietly leave the last terms out. The
    /// names, the terms and the three fitted lists must all be the same length.
    @Test("The fitted coefficients, the terms and their names are the same length")
    func termsAndCoefficientsAgree() {
        let n = FacadeLoadSurrogate.termNames.count
        let terms = FacadeLoadSurrogate.terms(Self.open(200), mass: 1_000, cellSize: 4)
        let fitted = FacadeLoadSurrogate.Coefficients.fitted
        #expect(terms.count == n)
        #expect(fitted.peak.count == n && fitted.impulse.count == n && fitted.rise.count == n)
        #expect(terms.allSatisfy { $0.isFinite })
    }

    // MARK: Kingery–Bulmash recovered

    /// With the fitted terms taken away, a face squarely facing the charge in the open must take
    /// Kingery–Bulmash's reflected peak and impulse and its arrival exactly, and a face side-on
    /// its incident values; beyond the curves' end at Z = 40 both fall as 1/r from their values
    /// there, and the shock goes on at the speed of sound (since b1d28c8b, as `ChargeInference`).
    /// `FacadeLoadSurrogate.base` is reached by every other surrogate test only through the
    /// fitted terms, so none of them separates a fault in the base from one in the fit.
    @Test(
        "Without the fitted terms, a face facing the charge in the open takes Kingery–Bulmash's values",
        arguments: [1_000.0, 20_000, 500_000])
    func kingeryBulmashRecoveredUncorrected(mass: Double) throws {
        let root = cbrt(mass)
        for z in [0.5, 1.5, 3, 7.5, 15, 30, 39.5] {
            let kb = try #require(KingeryBulmash.point(at: z))
            let facing = FacadeLoadSurrogate.predict(
                Self.open(z * root), mass: mass, cellSize: Self.cellSize, coefficients: Self.uncorrected)
            #expect(abs(facing.peakPa / kb.reflectedPressure - 1) < 1e-9, "Z \(z): \(facing.peakPa)")
            #expect(
                abs(facing.impulsePaS / kb.reflectedImpulse(mass: mass) - 1) < 1e-9,
                "Z \(z): \(facing.impulsePaS)")
            #expect(abs(facing.arrivalS / kb.arrival(mass: mass) - 1) < 1e-9, "Z \(z): \(facing.arrivalS)")
            #expect(facing.riseShare == 0)
            let side = FacadeLoadSurrogate.predict(
                Self.open(z * root, facing: 0), mass: mass, cellSize: Self.cellSize,
                coefficients: Self.uncorrected)
            #expect(abs(side.peakPa / kb.incidentPressure - 1) < 1e-9, "Z \(z): \(side.peakPa)")
            #expect(abs(side.impulsePaS / kb.incidentImpulse(mass: mass) - 1) < 1e-9)
            // Facing away, the base is the side-on value too: only the fitted term lowers it.
            let away = FacadeLoadSurrogate.predict(
                Self.open(z * root, facing: -1), mass: mass, cellSize: Self.cellSize,
                coefficients: Self.uncorrected)
            #expect(away.peakPa == side.peakPa && away.impulsePaS == side.impulsePaS)
        }
        // Beyond the curves: at Z 80 half of Z 40's, arriving 40 W^(1/3) / 340.3 m/s later.
        let end = FacadeLoadSurrogate.predict(
            Self.open(40 * root), mass: mass, cellSize: Self.cellSize, coefficients: Self.uncorrected)
        let beyond = FacadeLoadSurrogate.predict(
            Self.open(80 * root), mass: mass, cellSize: Self.cellSize, coefficients: Self.uncorrected)
        #expect(abs(beyond.peakPa / end.peakPa - 0.5) < 1e-9)
        #expect(abs(beyond.impulsePaS / end.impulsePaS - 0.5) < 1e-9)
        #expect(abs(beyond.arrivalS - end.arrivalS - 40 * root / 340.3) < 1e-9 * beyond.arrivalS)
    }

    /// With the fitted terms, the same face in the open stands for a run on 4 m cells, whose shock
    /// is smeared over several cells; the fit makes no promise to recover Kingery–Bulmash, and
    /// docs/surrogate-first-look.md says so ("It copies the runs, artefacts and all": façade peaks
    /// 0.45–0.57 of the reflected ones even in sight of the charge). So the open face's load is
    /// pinned where the fit puts it, and a refit that moves it shows here. Measured on the Studio
    /// on 19 October 2026, over Z 5–35: the peak 0.35–0.50 of the reflected peak at 20 t and
    /// 0.48–0.68 at 500 t, the impulse 0.47–0.60 and 0.36–0.46 of the reflected impulse.
    @Test(
        "With the fitted terms, the open face takes the fit's share of Kingery–Bulmash's reflected load",
        arguments: masses)
    func kingeryBulmashRecoveredFitted(mass: Double) throws {
        let root = cbrt(mass)
        for z in [5.0, 10, 20, 35] {
            let kb = try #require(KingeryBulmash.point(at: z))
            let p = FacadeLoadSurrogate.predict(Self.open(z * root), mass: mass, cellSize: Self.cellSize)
            let peak = p.peakPa / kb.reflectedPressure
            let impulse = p.impulsePaS / kb.reflectedImpulse(mass: mass)
            // Arrival carries no fitted term, so it is recovered whatever the fit.
            #expect(abs(p.arrivalS / kb.arrival(mass: mass) - 1) < 1e-9)
            // The measured shares with a margin of about 10% of each.
            #expect(peak > 0.31 && peak < 0.75, "Z \(z): peak ×\(peak)")
            #expect(impulse > 0.32 && impulse < 0.66, "Z \(z): impulse ×\(impulse)")
        }
    }

    // MARK: Each feature alone

    /// Across the fit's scaled range and past the curves' end, holding the facing and everything
    /// else fixed, neither the peak nor the impulse may rise with distance. The fitted (log Z)²
    /// term bends the correction upward close in, so this is not given by Kingery–Bulmash alone;
    /// from the coefficients it holds from Z ≈ 1.1 out (Python port), and the range tested starts
    /// at 1.5.
    @Test("Further from the charge, neither the peak nor the impulse rises", arguments: masses)
    func monotoneInDistance(mass: Double) {
        let root = cbrt(mass)
        let zs = (0...200).map { 1.5 * pow(80 / 1.5, Double($0) / 200) }
        for facing in [1.0, 0.5, 0, -1] {
            let p = Self.sweep(Self.open(root, facing: facing), mass: mass, values: zs.map { $0 * root }) {
                $0.distanceM = $1
            }
            let peakRises = Self.rises(p.map(\.peakPa))
            let impulseRises = Self.rises(p.map(\.impulsePaS))
            #expect(peakRises.isEmpty, "facing \(facing): the peak rises at Z \(peakRises.map { zs[$0] })")
            #expect(
                impulseRises.isEmpty,
                "facing \(facing): the impulse rises at Z \(impulseRises.map { zs[$0] })")
            #expect(
                Self.rises(p.map(\.arrivalS).map { -$0 }).isEmpty, "facing \(facing): an arrival came sooner")
        }
    }

    /// More buildings crossed on the line from the charge must never raise the peak: the fitted
    /// weight on log(1 + buildings crossed) is −0.022 and on the length inside them −0.001 per
    /// W^(1/3). Each building here adds 20 m inside.
    @Test("More buildings in the way never raise the peak", arguments: masses)
    func buildingsCrossedNeverRaisePeak(mass: Double) {
        let root = cbrt(mass)
        for z in [6.0, 12, 25] {
            let p = Self.sweep(Self.open(z * root), mass: mass, values: (0...12).map(Double.init)) {
                $0.buildingsCrossed = Int($1)
                $0.blockedM = 20 * $1
            }
            #expect(Self.rises(p.map(\.peakPa)).isEmpty, "Z \(z): \(p.map(\.peakPa))")
            // The length inside them alone, the count held.
            let inside = Self.sweep(
                Self.open(z * root), mass: mass, values: stride(from: 0.0, to: 300, by: 10).map { $0 }
            ) {
                $0.buildingsCrossed = 2
                $0.blockedM = $1
            }
            #expect(Self.rises(inside.map(\.peakPa)).isEmpty)
            #expect(Self.rises(inside.map(\.impulsePaS)).isEmpty)
        }
    }

    /// The impulse behind buildings: the fitted weight on log(1 + buildings crossed) for the impulse
    /// is +0.123, larger than the length inside them takes off at 20 m a building, so one building
    /// in the way raises a face's impulse while its peak falls. That is what the fitted runs show
    /// (behind buildings the load builds up as the streets fill, docs/surrogate-first-look.md), not
    /// a fault in the code, so it is pinned where the fit puts it: measured on the Studio on
    /// 19 October 2026 at Z 12, one building raises the impulse to 1.07 (20 t) and 1.08 (500 t)
    /// of the open face's, five to 1.15 and 1.21, while the peak falls to 0.98 and then 0.96. A refit
    /// that turns the impulse round, or raises it further, shows here.
    @Test("More buildings in the way raise the impulse only as far as the fit does", arguments: masses)
    func buildingsCrossedAndImpulse(mass: Double) {
        let root = cbrt(mass)
        let p = Self.sweep(Self.open(12 * root), mass: mass, values: (0...5).map(Double.init)) {
            $0.buildingsCrossed = Int($1)
            $0.blockedM = 20 * $1
        }
        let impulses = p.map { $0.impulsePaS / p[0].impulsePaS }
        let peaks = p.map { $0.peakPa / p[0].peakPa }
        // Rising with each building, but gently: the measured 1.07-1.08 for one and 1.15-1.21 for
        // five, with a margin.
        #expect(Self.rises(impulses).count == 5, "\(impulses)")
        #expect(impulses[1] > 1.04 && impulses[1] < 1.11, "\(impulses)")
        #expect(impulses[5] > 1.12 && impulses[5] < 1.26, "\(impulses)")
        // The peak falls with each, as the shielding should.
        #expect(Self.rises(peaks).isEmpty && peaks[5] < 0.97, "\(peaks)")
    }

    /// A ridge in the way lowers both the peak and the impulse (−0.073 and −0.202 per W^(1/3)); a
    /// face higher above its ground takes less peak and impulse (−0.260 and −0.103); facing
    /// further away lowers both (−0.165 and −0.161, on a base already side-on); and coarser cells
    /// smear the run's peak lower (−0.286 on log(cell / W^(1/3))). Each is checked alone over a
    /// range wide enough to see a sign error.
    @Test("A ridge, height, facing away and coarser cells each lower the peak", arguments: masses)
    func eachFeatureSign(mass: Double) {
        let root = cbrt(mass)
        let face = Self.open(10 * root)
        let ridge = Self.sweep(face, mass: mass, values: stride(from: 0.0, through: 60, by: 2).map { $0 }) {
            $0.ridgeM = $1
        }
        #expect(Self.rises(ridge.map(\.peakPa)).isEmpty && Self.rises(ridge.map(\.impulsePaS)).isEmpty)
        let height = Self.sweep(face, mass: mass, values: stride(from: 0.0, through: 80, by: 2).map { $0 }) {
            $0.heightM = $1
        }
        #expect(Self.rises(height.map(\.peakPa)).isEmpty && Self.rises(height.map(\.impulsePaS)).isEmpty)
        let away = Self.sweep(face, mass: mass, values: stride(from: 0.0, through: 1, by: 0.05).map { -$0 }) {
            $0.cosIncidence = $1
        }
        #expect(Self.rises(away.map(\.peakPa)).isEmpty && Self.rises(away.map(\.impulsePaS)).isEmpty)
        let cells = [1.0, 2, 4, 8, 16].map {
            FacadeLoadSurrogate.predict(face, mass: mass, cellSize: $0).peakPa
        }
        #expect(Self.rises(cells).isEmpty, "\(cells)")
        // The features that are recorded but carry no term change nothing.
        var other = face
        other.shadowM = 120
        other.frontM = 3
        #expect(
            FacadeLoadSurrogate.predict(other, mass: mass, cellSize: Self.cellSize)
                == FacadeLoadSurrogate.predict(face, mass: mass, cellSize: Self.cellSize))
    }

    /// Turning a face from side-on toward the charge should not lower its load much. The base rises
    /// with the square of the facing, but the fitted term on the facing itself is −0.319 for the
    /// peak and −0.468 for the impulse, linear, so just off side-on the term wins and the load
    /// dips before it rises. Measured on the Studio on 19 October 2026, the same at 20 t and 500 t:
    /// the peak falls to 0.975–0.981 of side-on at a facing of 0.12–0.16, the impulse to
    /// 0.928–0.951 at 0.22–0.34, and from a facing of 0.4 on both rise. Not a fault in the code,
    /// which computes the fitted form as written, but an artefact of that form: small against the
    /// fit's scatter (0.24 and 0.17 in the log), though a face turned slightly toward a charge is
    /// loaded less than one side-on. The test pins the dip at its measured depth, so that a refit
    /// that deepens it, or moves the turn past 0.4, shows here.
    @Test("Turning a face toward the charge lowers its load only by the fit's small dip", arguments: masses)
    func monotoneInFacing(mass: Double) {
        let root = cbrt(mass)
        for z in [5.0, 20, 38] {
            let p = Self.sweep(Self.open(z * root), mass: mass, values: (0...100).map { Double($0) / 100 }) {
                $0.cosIncidence = $1
            }
            // From a facing of 0.4 on, the base's square has won.
            let late = Array(p.dropFirst(40))
            #expect(Self.rises(late.map(\.peakPa).map { -$0 }).isEmpty, "Z \(z)")
            #expect(Self.rises(late.map(\.impulsePaS).map { -$0 }).isEmpty, "Z \(z)")
            // The dip: measured 0.975 at its deepest for the peak and 0.928 for the impulse.
            let peaks = p.map { $0.peakPa / p[0].peakPa }
            let impulses = p.map { $0.impulsePaS / p[0].impulsePaS }
            #expect(peaks.min()! > 0.965, "Z \(z): the peak dips to \(peaks.min()!) of side-on")
            #expect(impulses.min()! > 0.915, "Z \(z): the impulse dips to \(impulses.min()!) of side-on")
        }
    }

    /// The same, end to end through the scene: a face behind 0 to 3 cubes in a row, at the same
    /// distance from the charge each time, must see each cube as one more building crossed and
    /// take no more peak for it. `FacadeLoadSurrogateTests.sight` puts one cube in the way, once.
    @Test("A face behind more of a row of buildings sees each and takes no more peak")
    func rowOfBuildings() throws {
        var peaks: [Double] = []
        for count in 0...3 {
            var scene = Scenario(
                name: "Row", domainSize: SIMD3(300, 120, 60), boxes: [],
                charge: Charge(mass: 1_000, position: SIMD3(20, 60, 1)))
            for n in 0..<count {
                let x = Float(60 + 40 * n)
                try scene.addEnvelopeObject(
                    BuildingEnvelope(solids: [Box(min: SIMD3(x, 50, 0), max: SIMD3(x + 20, 70, 20))]))
            }
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(200, 50, 0), max: SIMD3(220, 70, 20))]))
            let objects = scene.envelopeObjects
            let raster = FacadeLoadSurrogate.Raster(objects: objects, terrain: nil, cell: 2)
            let target = count
            let strip = try #require(
                objects[target].envelope?.components(owner: objects[target].id, cellSize: 2).first {
                    $0.kind == .facade && $0.axis == 0 && $0.outward < 0
                })
            let f = FacadeLoadSurrogate.features(
                strip, owner: target, charge: scene.charge.position, raster: raster)
            #expect(f.buildingsCrossed == count, "\(count) in the way: crossed \(f.buildingsCrossed)")
            // Measured 19.96 m inside each 20 m cube (the line runs a little aslant); 0.1 m a cube allowed.
            #expect(abs(f.blockedM - 20 * Double(count)) < 0.1 * Double(count) + 1e-9, "\(f.blockedM)")
            peaks.append(FacadeLoadSurrogate.predict(f, mass: 1_000, cellSize: 2).peakPa)
        }
        #expect(Self.rises(peaks).isEmpty, "\(peaks)")
    }

    // MARK: The rise share

    /// The rise share is a linear sum of the terms, so nothing but the clamp keeps it in 0–0.9: the
    /// ground-rise weight is +0.628 per W^(1/3) and the ridge's −0.444, so a face on a hill above
    /// the charge rises over the clamp's top and one behind a high ridge under its bottom. Behind
    /// buildings the load builds up as the streets fill (docs/surrogate-first-look.md), so the share
    /// must not fall with buildings crossed. No other test sets a feature that reaches the clamp.
    @Test("The rise share stays in 0–0.9 and grows behind buildings", arguments: masses)
    func riseShareClampAndShielding(mass: Double) {
        let root = cbrt(mass)
        var hill = Self.open(10 * root)
        hill.groundRiseM = 3 * root
        #expect(FacadeLoadSurrogate.predict(hill, mass: mass, cellSize: Self.cellSize).riseShare == 0.9)
        var ridge = Self.open(10 * root)
        ridge.ridgeM = 3 * root
        #expect(FacadeLoadSurrogate.predict(ridge, mass: mass, cellSize: Self.cellSize).riseShare == 0)
        for z in [5.0, 12, 30] {
            let p = Self.sweep(Self.open(z * root), mass: mass, values: (0...8).map(Double.init)) {
                $0.buildingsCrossed = Int($1)
                $0.blockedM = 20 * $1
            }
            #expect(p.allSatisfy { $0.riseShare >= 0 && $0.riseShare <= 0.9 })
            #expect(Self.rises(p.map(\.riseShare).map { -$0 }).isEmpty, "Z \(z): \(p.map(\.riseShare))")
        }
    }

    /// `load` rounds the rise share to a twentieth before building the pulse, and a share of 0 is
    /// a shock that starts at its peak. The pulse's impulse must be kept whatever the share, its
    /// highest bin must fall at the rounded share, and at 0 it must be the first bin.
    /// `FacadeLoadSurrogateTests.pulse` runs one share, 0.3, already a twentieth.
    @Test(
        "The pulse keeps its impulse and peaks at the rise share rounded to a twentieth",
        arguments: [(0.0, 0.0), (0.33, 0.35), (0.62, 0.6), (0.9, 0.9)])
    func riseShareRounding(share: Double, rounded: Double) throws {
        let component = try #require(
            FacadeLoadSurrogateTests.row().envelopeObjects[0].envelope?.components(owner: UUID(), cellSize: 1)
                .first { $0.kind == .facade })
        // Peak and impulse already on the 3% steps, so only the rise is rounded.
        let peak = FacadeLoadSurrogate.quantized(20_000)
        let impulse = FacadeLoadSurrogate.quantized(200)
        let prediction = FacadeLoadSurrogate.Prediction(
            peakPa: peak, impulsePaS: impulse, riseShare: share, arrivalS: 0.1)
        let binS = 0.1e-3
        let load = FacadeLoadSurrogate.load(component, prediction, binS: binS)
        let total = load.outerPa.reduce(0, +) * binS
        // Measured to 4e-15.
        #expect(abs(total / impulse - 1) < 1e-12, "\(total) against \(impulse)")
        let duration = 2 * impulse / peak
        let top = try #require(load.outerPa.indices.max { load.outerPa[$0] < load.outerPa[$1] })
        // Within a bin of the rounded share's time (measured 0.3-0.9 of a bin: the bin holding it).
        #expect(abs(Double(top) * binS - rounded * duration) <= binS, "top at bin \(top)")
        if rounded == 0 { #expect(top == 0) }
        #expect(load.innerPa.allSatisfy { $0 == 0 })
    }

    /// Pulses are rounded to steps of 3% so that a district's components share them and the SDOF
    /// memo can answer for most of them. Two predictions within a step of each other must make
    /// the same pulse, bin for bin, and two a few steps apart must not. Not reached elsewhere:
    /// `FacadeLoadSurrogateTests.firstLook` sees only that the memo has hits.
    @Test("Loads within the rounding step share one pulse; loads a few steps apart do not")
    func pulsesShareTheRoundingStep() throws {
        let component = try #require(
            FacadeLoadSurrogateTests.row().envelopeObjects[0].envelope?.components(owner: UUID(), cellSize: 1)
                .first { $0.kind == .facade })
        // Peak and impulse at the middle of a step, so ±0.5% stays inside it.
        let step = log(1 + FacadeLoadSurrogate.quantum)
        let peak = exp(300 * step)
        let impulse = exp(150 * step)
        func pulse(_ scale: Double) -> [Double] {
            FacadeLoadSurrogate.load(
                component,
                FacadeLoadSurrogate.Prediction(
                    peakPa: peak * scale, impulsePaS: impulse * scale, riseShare: 0.25, arrivalS: 0),
                binS: 0.5e-3
            ).outerPa
        }
        #expect(pulse(1.005) == pulse(0.995))
        #expect(pulse(1.1) != pulse(1))
        #expect(FacadeLoadSurrogate.quantized(0) == 0 && FacadeLoadSurrogate.quantized(-5) == 0)
    }
}
