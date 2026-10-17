import Foundation
import simd

// Numeric error bands for the standing (see docs/standing.md#error-bands): how far a result has
// been from measurement, as model/measured, where the scene lies inside a comparison's range, and
// which options suit the scene's regime. The numbers mirror docs/validation.md;
// `ErrorBandTests` parses its tables and checks every quote against it.

/// What a band is a ratio of, so that a displayed value can find its band.
public enum BandMeasure: String, Codable, CaseIterable, Sendable {
    case peakOverpressure
    case impulse
    case peakDeflection
    case permanentDeflection
    case shearCapacity
    case gasPressure
    case wallPressure
    case footingMoment
    case footingSettlement
    case footingRotation
    case debrisSpeed
    case radiatedEnergy
    case cloudTop
    case ventedPressure
    case breakageTime
    case insidePressure
}

/// How far a model result has been from measurement, as model/measured, and where that holds.
public struct ErrorBand: Codable, Hashable, Sendable {
    public var measure: BandMeasure
    public var quantity: String
    /// Model over measured (or over the reference), lowest and highest.
    public var low: Double
    public var high: Double
    /// Whether the model reading low reads on the unsafe side (a load or a deflection under-read).
    public var lowIsUnsafe: Bool
    /// What the model reading low or high means, in a few words: "too stiff", "under-resolved".
    public var meaningLow: String
    public var meaningHigh: String
    /// Where the band holds: distances, cells, mesh, material and options.
    public var validity: String
    public var check: String
    /// A heading under docs/, with its anchor.
    public var document: String
    /// Whether it was scaled to this scene's resolution between compared grids.
    public var scaled: Bool
    /// The model's own spread from uncertain inputs in the case behind the band, as a coefficient
    /// of variation (validation.md, "The model's spread from uncertain inputs"); nil where not run.
    public var inputSpread: Double? = nil
    /// The reference's own scatter about its mean, one standard deviation as a fraction (the tests
    /// behind Kingery–Bulmash, repeats against it, UFC 3-340-02's rooms); nil where none is known.
    public var referenceScatter: Double? = nil
    /// For a structure, the mesh (and step) the band was derived on: no structural result
    /// converges on today's defaults, so a band holds only there; nil for the air's bands.
    public var derivedMesh: String? = nil
    /// For a result after failure, its half-range across roundings of the same arithmetic (the
    /// default build, without fused multiply-adds, and with relaxed math) as a fraction: such a
    /// result is one draw among roundings; nil where it does not move.
    public var roundingSpread: Double? = nil

    /// Which way the model errs.
    public var reads: String {
        high < 1 ? "reads low: \(meaningLow)" : low > 1 ? "reads high: \(meaningHigh)" : "reads either way"
    }

    /// Whether the error lies on the unsafe side, the safe side, or either.
    public var side: String {
        if high < 1 { return lowIsUnsafe ? "unsafe side" : "safe side" }
        if low > 1 { return lowIsUnsafe ? "safe side" : "unsafe side" }
        return "either side"
    }

    /// The band as text: "model 105–115% of measured".
    public var ratio: String {
        func number(_ value: Double) -> String { String(format: "%.0f", value * 100) }
        return abs(high - low) < 0.005 ? "\(number(low))%" : "\(number(low))–\(number(high))%"
    }

    public var summary: String { "\(quantity): model \(ratio) of measured (\(reads); \(side))" }

    /// Where the measured value would lie, for a model value, if the band holds.
    public func expected(_ value: Double) -> ClosedRange<Double> {
        let a = value / high
        let b = value / low
        return min(a, b)...max(a, b)
    }

    /// Half the band's width over its middle.
    public var relativeHalfWidth: Double { (high - low) / (high + low) }

    /// The band's half-width and the inputs' 5–95% half-range (1.645 coefficients of variation)
    /// added in quadrature, with the roundings' half-range: the model's error, its spread from
    /// uncertain inputs and its spread from rounding are separate.
    public var combinedHalfWidth: Double {
        let inputs = 1.645 * (inputSpread ?? 0)
        let reference = 1.645 * (referenceScatter ?? 0)
        let rounding = roundingSpread ?? 0
        return
            (relativeHalfWidth * relativeHalfWidth + inputs * inputs + reference * reference
            + rounding * rounding).squareRoot()
    }

    /// Whether the model's error lies within the reference's own scatter (one standard deviation),
    /// so that it cannot be told apart from the tests'; nil where the scatter is not known.
    public var withinReference: Bool? {
        referenceScatter.map { max(abs(low - 1), abs(high - 1)) <= $0 + 1e-9 }
    }

    /// The model's error against the reference's scatter, in words; nil where it is not known.
    public var againstReference: String? {
        guard let scatter = referenceScatter, let within = withinReference else { return nil }
        let tests = String(format: "the tests' own scatter, %.1f%%", scatter * 100)
        return within
            ? "Inside \(tests): the model cannot be told apart from the tests here."
            : "Outside \(tests): the difference is the model's."
    }

    /// Where a measured value would lie for a model value: the band, with the inputs' spread and
    /// the reference's own scatter (each at 5–95%) and the roundings' spread added in quadrature.
    public func expectedWithInputs(_ value: Double) -> ClosedRange<Double> {
        guard inputSpread != nil || referenceScatter != nil || roundingSpread != nil else {
            return expected(value)
        }
        let centre = value / ((low + high) / 2)
        return centre * (1 - combinedHalfWidth)...centre * (1 + combinedHalfWidth)
    }
}

/// The bands of one gauge, by its scaled distance and whether it sits on a surface.
public struct GaugeBands: Codable, Hashable, Sendable {
    public var name: String
    /// Scaled distance from the nearest charge, m/kg^(1/3).
    public var scaledDistance: Double
    /// On a surface (reflected) or in the open (incident).
    public var onSurface: Bool
    public var peak: ErrorBand?
    public var impulse: ErrorBand?
    /// Why a band is missing, when one is.
    public var note: String?
}

/// Whether a chosen option suits the regime the scene is in, by the validation record.
public struct RegimeAdvice: Codable, Hashable, Sendable {
    /// The regime the scene is in: "close in", "in contact", "confined", "far field".
    public var regime: String
    public var option: String
    /// Whether the option, as set, suits the regime; nil when the record does not say.
    public var suits: Bool?
    public var note: String
    public var suggestion: String?
    public var document: String
}

extension ResultStanding {
    /// Which way the result errs, first, by its bands: the unsafe side named when any band lies on
    /// it (a load or deflection under-read, a strength over-read); nil without bands.
    public var direction: String? {
        guard let bands, !bands.isEmpty else { return nil }
        let unsafe = bands.filter { $0.side == "unsafe side" }
        if let worst = unsafe.first {
            return
                "Errs on the unsafe side: \(worst.quantity.lowercased()) \(worst.reads) (\(worst.ratio) of measured)"
                + (unsafe.count > 1 ? ", and \(unsafe.count - 1) more" : "") + "."
        }
        if bands.allSatisfy({ $0.side == "safe side" }) {
            return "Errs on the safe side: \(bands[0].quantity.lowercased()) \(bands[0].reads)."
        }
        return "Errs either way: \(bands[0].quantity.lowercased()) \(bands[0].ratio) of measured."
    }

    /// Whether any band lies on the unsafe side.
    public var errsUnsafe: Bool { bands?.contains { $0.side == "unsafe side" } ?? false }
}

extension SceneStanding {
    /// The band for `measure`, among the results that carry one.
    public func band(_ measure: BandMeasure) -> ErrorBand? {
        results.lazy.compactMap { $0.bands?.first { $0.measure == measure } }.first
    }

    /// The bands of the gauge named `name`, when recorded.
    public func gauge(_ name: String) -> GaugeBands? { gauges?.first { $0.name == name } }
}

// MARK: - The mirrored tables

/// The validation record's numbers, as model/measured percentages. Tables are mirrored row for
/// row and checked against the document by parsing; single figures carry the quote they come from.
public enum ValidationTables {
    /// Kingery–Bulmash's scaled distances, m/kg^(1/3), for 100 kg on rigid ground.
    public static let distances: [Double] = [0.75, 1, 1.5, 2, 3, 4, 5, 6]
    /// The compared grids, 0.5, 0.25 and 0.125 m for 100 kg, as cells per kg^(1/3).
    public static let grids: [Double] = [0.5, 0.25, 0.125].map { $0 / cbrt(100) }

    /// One quantity's ratios: a row per grid (nil where not compared), a column per distance.
    public struct Table: Sendable {
        public var byGrid: [[Double]?]
    }

    public static let incidentPeak = Table(byGrid: [
        [59, 57, 66, 62, 67, 66, 68, 69], [77, 77, 82, 76, 80, 79, 81, 80], [97, 94, 94, 86, 87, 89, 90, 90],
    ])
    public static let incidentImpulse = Table(byGrid: [
        [116, 82, 81, 81, 86, 84, 85, 85], [103, 80, 78, 80, 86, 86, 86, 85],
        [106, 84, 78, 80, 86, 87, 86, 86],
    ])
    public static let reflectedPeak = Table(byGrid: [
        [20, 25, 35, 45, 57, 63, 68, 69], [37, 44, 58, 65, 76, 80, 80, 82], [67, 68, 83, 83, 88, 91, 92, 91],
    ])
    public static let reflectedImpulse = Table(byGrid: [
        [73, 77, 88, 95, 99, 94, 94, 93], [84, 91, 97, 101, 102, 97, 94, 94],
        [96, 102, 102, 105, 104, 98, 95, 94],
    ])
    /// With afterburning, hot air and far-field faces, the defaults since 15 October 2026
    /// (validation.md, "The defaults since 15 October").
    public static let burningIncidentPeak = Table(byGrid: [
        [54, 55, 67, 66, 71, 70, 72, 73], [72, 74, 82, 78, 83, 82, 84, 84], [90, 89, 93, 87, 88, 90, 92, 92],
    ])
    public static let burningIncidentImpulse = Table(byGrid: [
        [133, 101, 102, 97, 101, 100, 101, 102], [116, 94, 95, 94, 100, 98, 98, 97],
        [114, 92, 89, 91, 97, 96, 95, 95],
    ])
    public static let burningReflectedPeak = Table(byGrid: [
        [17, 23, 35, 47, 61, 67, 72, 73], [32, 39, 56, 67, 79, 83, 84, 86], [59, 63, 82, 84, 90, 93, 94, 94],
    ])
    public static let burningReflectedImpulse = Table(byGrid: [
        [75, 82, 96, 103, 110, 111, 110, 109], [85, 93, 106, 110, 113, 110, 107, 106],
        [94, 103, 114, 113, 112, 107, 104, 103],
    ])
    /// Where the burning tables are recorded.
    public static let burningDocument = "validation.md#the-defaults-since-15-october"

    /// A column's range as "a–b%", from the `from`th distance out (1 is 1 m/kg^(1/3)).
    public static func span(_ table: Table, grid: Int, from: Int = 0) -> String {
        let column = table.byGrid[grid]!.dropFirst(from)
        return String(format: "%.0f–%.0f%%", column.min()!, column.max()!)
    }

    /// Close in: a 1 kg burst in the air, reflected under it, by free-air scaled distance.
    public static let closeDistances: [Double] = [0.3, 0.5, 0.75, 1]
    /// Cells of 40, 20, 10 and 5 mm on 1 kg, as cells per kg^(1/3).
    public static let closeGrids: [Double] = [0.04, 0.02, 0.01, 0.005]
    public static let closeReflectedPeak = Table(byGrid: [
        [25, 30, 40, 49], [45, 62, 66, 72], [78, 83, 98, 91], [92, 93, 100, 104],
    ])
    public static let closeReflectedImpulse = Table(byGrid: [
        [65, 75, 83, 89], [79, 86, 93, 94], [93, 98, 106, 92], [99, 103, 97, 94],
    ])
    /// The same bursts on today's air, afterburning, hot air and far-field faces (validation.md,
    /// "Close in", the second table).
    public static let closeBurningReflectedPeak = Table(byGrid: [
        [20, 25, 36, 46], [36, 54, 61, 69], [64, 83, 90, 88], [107, 101, 98, 104],
    ])
    public static let closeBurningReflectedImpulse = Table(byGrid: [
        [66, 77, 88, 99], [84, 85, 100, 103], [99, 96, 111, 102], [103, 104, 105, 104],
    ])

    /// A band read from the record as a single figure, with the words it is read from.
    public struct Figure: Sendable {
        public var id: String
        public var low: Double
        public var high: Double
        /// docs/ page and anchor; the quotes must lie under that heading.
        public var document: String
        /// Where the figure's numbers are read: one quote, or one for each end.
        public var quotes: [String]

        init(id: String, low: Double, high: Double, document: String, quote: String...) {
            self.id = id
            self.low = low
            self.high = high
            self.document = document
            quotes = quote
        }
    }

    /// Every single figure the bands use. `ErrorBandTests` checks each quote lies under its
    /// heading and holds the figure's numbers.
    public static let figures: [Figure] = [
        Figure(
            id: "envelopeGlassBreak", low: 0.40, high: 0.46, document: "validation.md#window-glass",
            quote: "0.40–0.46 of the measured time with fixed edges"),
        Figure(
            id: "envelopeConcreteFixed", low: 0.61, high: 1.03,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "0.61/1.19", "1.03/1.87"),
        Figure(
            id: "envelopeConcreteSimple", low: 1.19, high: 1.87,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "0.61/1.19", "1.03/1.87"),
        Figure(
            id: "envelopeBrick", low: 0.82, high: 2.54,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "(0.82–2.54)"),
        Figure(
            id: "envelopeInsideFill", low: 0.87, high: 2.23,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "(0.87–2.23 times the detailed peaks)"),
        Figure(
            id: "slabSolid", low: 1.04, high: 1.15, document: "validation.md#summary",
            quote: "solid elements 113–125 mm (104–115%) on 4 to 32 elements through"),
        Figure(
            id: "slabExtrapolated", low: 1.19, high: 1.19,
            document: "validation.md#convergence-on-todays-defaults",
            quote: "extrapolated 129 mm, 119%"),
        Figure(
            id: "slabLowerShot", low: 0.79, high: 0.88,
            document: "validation.md#the-contests-repeat-its-lower-shot-and-its-other-entries",
            quote: "the model reaches 79–88% of the measured peak on 4 to 16 elements"),
        Figure(
            id: "slabReynoldsOpen", low: 0.91, high: 1.06,
            document: "validation.md#structural-response-against-a-real-test",
            quote: "within 0.91–1.06, peaking at 27–30 ms"),
        Figure(
            id: "slabBlindHighStrength", low: 0.77, high: 1.06,
            document: "validation.md#blind-test-3-reynoldss-high-strength-slabs-in-the-blast-load-simulator",
            quote: "every ratio within 0.77–1.06"),
        Figure(
            id: "slabBlindOpenAir", low: 0.10, high: 0.25,
            document: "validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge",
            quote: "the model's blast peak is a tenth to a quarter"),
        Figure(
            id: "slabShell", low: 1.24, high: 1.24, document: "validation.md#summary",
            quote: "shells 135 mm (124%)"),
        Figure(
            id: "beamMoment", low: 1.0, high: 1.01, document: "validation.md#summary",
            quote: "peak moment 101% on 12 elements, failing at 44 mm against 42 mm, 100% on 24"),
        Figure(
            id: "closeInPermanent", low: 0.33, high: 0.5, document: "validation.md#summary",
            quote: "the slab left a third to a half as far down as measured"),
        Figure(
            id: "wuLargeToday", low: 0.91, high: 1.19,
            document: "validation.md#slabs-with-steel-in-both-faces",
            quote: "0.91 and 1.18–1.19 times the measured peak"),
        Figure(
            id: "debrisSpeedOverlap", low: 0.9, high: 2.3,
            document: "validation.md#slabs-under-contact-charges",
            quote: "the 20 cm slabs' far faces move 0.9–1.3 times the fit and the thicker 1.0–2.3"),
        Figure(
            id: "debrisSpeedBurning", low: 0.88, high: 1.82,
            document: "validation.md#slabs-under-contact-charges",
            quote: "the far face on the axis is 0.88–1.82 times the fit on today's air"),
        Figure(
            id: "wuSmall", low: 0.4, high: 0.7, document: "validation.md#summary",
            quote: "40–70% (too stiff) in the six under 0.2–0.8 kg where the tests spalled"),
        Figure(
            id: "chamberPressure", low: 0.9, high: 1.6, document: "validation.md#summary",
            quote: "peak wall pressures 0.9 to 1.6 times those measured"),
        Figure(
            id: "debrisSpeed", low: 1.1, high: 1.7, document: "validation.md#summary",
            quote: "the far face thrown 1.1–1.7 times as fast as the debris at first"),
        Figure(
            id: "roomDefault", low: 0.48, high: 1.14, document: "validation.md#summary",
            quote: "48% to 114% by default"),
        Figure(
            id: "roomBurningHot", low: 0.98, high: 1.08, document: "validation.md#summary",
            quote: "98% to 108% with afterburning and hot air"),
        Figure(
            id: "roomBurning", low: 1.24, high: 1.31, document: "validation.md#gas-pressure-in-a-closed-room",
            quote: "| 2 kg/m³           | 4.34 MPa | 3.50 MPa     | 124%        | 12%                     |",
            "| 0.25 kg/m³        | 1.15 MPa | 0.88 MPa     | 131%        | 73%                     |"),
        Figure(
            id: "roomHot", low: 0.43, high: 0.91, document: "validation.md#gas-pressure-in-a-closed-room",
            quote: "Hot air without afterburning gives 43% to 91%."),
        Figure(
            id: "rockingMoment", low: 0.89, high: 1.11, document: "validation.md#summary",
            quote: "moment within 11% to 14 mrad of rotation"),
        Figure(
            id: "rockingMomentLarge", low: 0.86, high: 0.95, document: "validation.md#summary",
            quote: "5–14% low beyond"),
        Figure(
            id: "rockingSettlement", low: 1.3, high: 1.7, document: "validation.md#summary",
            quote: "settlement 1.3–1.7 times that measured"),
        Figure(
            id: "shakenSettlement", low: 0.4, high: 1.3, document: "validation.md#summary",
            quote: "settlement 0.4–1.3 times"),
        Figure(
            id: "shakenRotation", low: 0.9, high: 1.1, document: "validation.md#summary",
            quote: "peak rotation within 10% where the test did not lurch one way"),
        Figure(
            id: "fireballTotal", low: 3, high: 5.5, document: "validation.md#summary",
            quote: "exceeds three to five and a half times"),
        Figure(
            id: "fireballCooling", low: 2, high: 3, document: "thermal-radiation.md#limitations",
            quote: "three to five times (two to three with the gas cooling)"),
        Figure(
            id: "cloudTop", low: 0.79, high: 1.21, document: "fireball-rise.md",
            quote: "to 4% on average and 21% shot by shot"),
        Figure(
            id: "ventedBackWall", low: 0.9, high: 1.8, document: "validation.md#summary",
            quote: "lit at the back wall, 0.9–1.8 times the measured peaks"),
        Figure(
            id: "ventedMiddle", low: 0.4, high: 0.6, document: "validation.md#summary",
            quote: "lit in the middle, 0.4–0.6"),
    ]

    public static func figure(_ id: String) -> Figure { figures.first { $0.id == id }! }

    /// The scaled distance (m/kg^(1/3)) within which the contest slab's band is withheld: blind,
    /// open-air slabs at 0.93 to 1.44 read a tenth to a quarter of meters that likely include the
    /// supports' movement, and the two nearest collapsed where the model's stood. The contest's load
    /// was a shock tube's, long and uniform.
    public static let blindSlabReach: Float = 1.5

    /// A result on a sequence of meshes against one measurement, from the convergence study on
    /// today's defaults; the quote is the study's row and must hold each pair and the measurement.
    public struct MeshSeries: Sendable {
        public var id: String
        public var measured: Double
        /// Elements through and the model's value on that mesh.
        public var byMesh: [(through: Int, value: Double)]
        /// The mesh that agreed with the test, which the record quotes elsewhere.
        public var calibrated: Int
        public var document: String
        public var quote: String

        /// The band on `through` elements: the ratios of the meshes either side, since none
        /// converges; nil outside the meshes run.
        public func band(on through: Int) -> (low: Double, high: Double)? {
            let meshes = byMesh.map(\.through)
            guard let first = meshes.first, let last = meshes.last, (first...last).contains(through) else {
                return nil
            }
            let below = meshes.lastIndex { $0 <= through }!
            let above = meshes.firstIndex { $0 >= through }!
            let span =
                below == above
                ? max(below - 1, 0)...min(above + 1, meshes.count - 1) : min(below, above)...max(below, above)
            let ratios = span.map { byMesh[$0].value / measured }
            return (ratios.min()!, ratios.max()!)
        }
    }

    public static let oa1 = MeshSeries(
        id: "oa1", measured: 332, byMesh: [(12, 437), (24, 344), (36, 348), (48, 369)], calibrated: 24,
        document: "validation.md#convergence-on-todays-defaults",
        quote: "| OA1 | peak load (332 kN) | 12: 437; 24: 344; 36: 348; 48: 369 kN |")

    /// The model's spread from uncertain inputs in a validation case, as a coefficient of variation.
    public struct Spread: Sendable {
        public var id: String
        public var coefficient: Double
        /// The table's row, which must hold "mean, coefficient%".
        public var quote: String
    }

    public static let spreadDocument = "validation.md#the-models-spread-from-uncertain-inputs"

    public static let spreads: [Spread] = [
        Spread(
            id: "slab", coefficient: 0.12,
            quote: "| Contest slab, peak (mm) | 108 | 113 | 107, 12% | 89–126 |"),
        Spread(
            id: "wuPeak", coefficient: 0.04,
            quote: "| Wu S8, peak (mm) | 18.0 | 14.4 | 14.3, 4% | 13.6–15.2 |"),
        Spread(
            id: "closeInGauge", coefficient: 0.08,
            quote: "| Chiquito S1–S3, gauge at 1 m (MPa) | 2.5 | 1.48 | 1.48, 8% | 1.32–1.66 |"),
        Spread(
            id: "wallPeak", coefficient: 0.02,
            quote: "| Kingery–Bulmash wall, reflected peak (kPa) | 1,060 (K–B) | 691 | 697, 2% | 672–715 |"),
        Spread(
            id: "wallImpulse", coefficient: 0.01,
            quote:
                "| Kingery–Bulmash wall, reflected impulse (Pa s) | 1,690 (K–B) | 1,710 | 1,710, 1% | 1,670–1,740 |"
        ),
    ]

    public static func spread(_ id: String) -> Double { spreads.first { $0.id == id }!.coefficient }

    /// A reference's own scatter, one standard deviation, read from the record.
    public struct Scatter: Sendable {
        public var id: String
        public var sigma: Double
        public var document: String
        /// Must lie under `document`'s heading and hold the figure.
        public var quote: String
    }

    public static let scatters: [Scatter] = [
        Scatter(
            id: "incidentPeak", sigma: 0.064,
            document: "validation.md#kingerybulmash-the-design-practice-standard",
            quote: "±6.4% of the peak overpressure"),
        Scatter(
            id: "incidentImpulse", sigma: 0.067,
            document: "validation.md#kingerybulmash-the-design-practice-standard",
            quote: "±6.7% of the positive impulse"),
        // Reflected values are calculated, not fitted; modern repeats' ±6–8%, the upper end taken.
        Scatter(
            id: "reflected", sigma: 0.08,
            document: "validation.md#kingerybulmash-the-design-practice-standard",
            quote: "Repeats lie within ±6–8% of their mean for the peak, the impulse and the duration"),
        // The contest shot the slab twice: 109 and 113 mm.
        Scatter(
            id: "slabRepeat", sigma: 0.03,
            document: "validation.md#the-contests-repeat-its-lower-shot-and-its-other-entries",
            quote: "a coefficient of variation of about 3% from the range of two"),
        Scatter(
            id: "room", sigma: 0.11, document: "validation.md#gas-pressure-in-a-closed-room",
            quote: "with a standard deviation of 11%"),
    ]

    public static func scatter(_ id: String) -> Double { scatters.first { $0.id == id }!.sigma }

    /// A result after failure across three roundings of the same arithmetic: the default build,
    /// without fused multiply-adds, and with relaxed math (validation.md, "Results after failure
    /// move with the rounding, not with harmless edits").
    public struct Rounding: Sendable {
        public var id: String
        public var values: [Double]
        public var document: String
        /// The record's row; must lie under `document`'s heading and hold every value.
        public var quote: String
        /// Half the range over its middle.
        public var halfRange: Double {
            let low = values.min()!
            let high = values.max()!
            return (high - low) / (high + low)
        }
    }

    public static let roundings: [Rounding] = [
        Rounding(
            id: "hupfaufSN142", values: [119.4, 120.9, 116.0],
            document: "validation.md#convergence-on-todays-defaults",
            quote:
                "| Hupfauf SN142: far face (m/s), elements failed | 119.4, 2,336 | 120.9, 2,307 | 116.0, 2,290 |"
        ),
        Rounding(
            id: "hupfaufSN131", values: [16.0, 15.2, 18.7],
            document: "validation.md#convergence-on-todays-defaults",
            quote: "| Hupfauf SN131 | 16.0, 758 | 15.2, 815 | 18.7, 761 |"),
        Rounding(
            id: "hupfaufSN142Burning", values: [62.9, 106.3, 61.5],
            document: "validation.md#slabs-under-contact-charges",
            quote:
                "| Hupfauf SN142 on today's air: far face (m/s), elements failed | 62.9, 2,478 | 106.3, 2,773 | 61.5, 2,272 |"
        ),
        Rounding(
            id: "hupfaufSN131Burning", values: [22.4, 27.7, 22.6],
            document: "validation.md#slabs-under-contact-charges",
            quote: "| Hupfauf SN131 on today's air | 22.4, 824 | 27.7, 881 | 22.6, 786 |"),
    ]

    /// The widest half-range among `ids`.
    public static func rounding(_ ids: String...) -> Double {
        roundings.filter { ids.contains($0.id) }.map(\.halfRange).max()!
    }
}

// MARK: - Reading a band from a table

extension ValidationTables {
    /// The band `table` gives at scaled cell `cell` and scaled distance `distance`: interpolated
    /// in the logarithm of the cell between compared grids, and spanning the compared distances
    /// either side. Nil, with the reason, outside what was compared.
    static func read(
        _ table: Table, grids: [Double], distances: [Double], cell: Double, distance: Double
    ) -> (low: Double, high: Double, scaled: Bool)? {
        guard distance >= distances.first! * 0.98, distance <= distances.last! * 1.02 else { return nil }
        // Grids are coarse first; the cell must lie within the coarsest compared (5% to spare).
        let compared = grids.indices.filter { table.byGrid[$0] != nil }
        guard let coarsest = compared.first, cell <= grids[coarsest] * 1.05 else { return nil }
        var row: [Double]
        var scaled = false
        if let finest = compared.last, cell <= grids[finest] * (1 + 1e-4) {
            row = table.byGrid[finest]!
        } else {
            let coarser = compared.last { grids[$0] >= cell * (1 - 1e-4) } ?? coarsest
            let finer = compared.first { grids[$0] < cell * (1 - 1e-4) } ?? coarser
            if coarser == finer || abs(grids[coarser] - cell) < cell * 1e-4 {
                row = table.byGrid[coarser]!
            } else {
                let t = log(grids[coarser] / cell) / log(grids[coarser] / grids[finer])
                row = zip(table.byGrid[coarser]!, table.byGrid[finer]!).map { $0 + ($1 - $0) * t }
                scaled = true
            }
        }
        let below = distances.lastIndex { $0 <= distance } ?? 0
        let above = distances.firstIndex { $0 >= distance } ?? distances.count - 1
        let span =
            below == above
            ? max(below - 1, 0)...min(above + 1, distances.count - 1)
            : min(below, above)...max(below, above)
        let values = span.map { row[$0] / 100 }
        return (values.min()!, values.max()!, scaled)
    }
}

// MARK: - Choosing the bands for a scene

extension StandingScene {
    /// The structures with the regime their scene gives them, as a run loads them.
    private var placedStructures: [StructureModel] {
        structures.map { $0.detectingRegime(in: inputs.scenario) }
    }

    /// The scene's regime: the most severe of its structures' (`StructuralRegime`, the user's
    /// override first), or, with only stationary envelopes, theirs by the same distances.
    var regime: String {
        let regimes = placedStructures.compactMap(\.regime)
        for severe in [StructuralRegime.confined, .inContact, .closeIn, .farField]
        where regimes.contains(severe) {
            return severe.title
        }
        if has(.closedBoundaries) || chargeEnclosed { return StructuralRegime.confined.title }
        guard let distance = structureDistance else { return "open air" }
        return (distance < 0.15 ? StructuralRegime.inContact : distance < 0.75 ? .closeIn : .farField).title
    }

    /// Whether a charge lies within a structure's outline, as in a chamber.
    private var chargeEnclosed: Bool {
        let charges = [inputs.scenario.charge] + (inputs.scenario.additionalCharges ?? [])
        return structures.contains { structure in
            guard let first = structure.solids.first else { return false }
            let low = structure.solids.reduce(first.min) { simd_min($0, $1.min) }
            let high = structure.solids.reduce(first.max) { simd_max($0, $1.max) }
            return charges.contains { all($0.position .> low) && all($0.position .< high) }
        }
    }

    /// Charges fire as Kingery–Bulmash's comparisons assume: no deflagration in their place, and
    /// flat ground.
    private var airComparable: String? {
        if has(.deflagration) {
            return "A deflagration fires in place of the charges; Kingery–Bulmash does not apply."
        }
        if has(.terrain) {
            return has(.terrainStaircase)
                ? "The comparisons were on flat ground; this scene has terrain, as a staircase of whole cells."
                : "The comparisons were on flat ground; this scene has terrain, its slopes checked against "
                    + "reflection theory only."
        }
        if has(.dissociatingAir) { return "Dissociating air has no comparison of its own." }
        if has(.hotAir) != has(.afterburning) {
            return has(.hotAir)
                ? "Hot air without afterburning was compared only in a closed room."
                : "Afterburning without hot air was compared only on 0.25 m cells."
        }
        return nil
    }

    private var burning: Bool { has(.afterburning) && has(.hotAir) }

    /// Boxes a gauge can sit on: blocks, structures and envelopes.
    private var surfaces: [Box] {
        let scenario = inputs.scenario
        return scenario.boxes + structures.flatMap(\.solids)
            + scenario.envelopeObjects.compactMap(\.envelope).flatMap(\.solids)
            + (scenario.importedModels ?? []).flatMap(\.rigidBoxes)
    }

    func gaugeBands() -> [GaugeBands] {
        let scenario = inputs.scenario
        let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
        let boxes = surfaces
        return scenario.gauges.map { gauge in
            let nearest = charges.min {
                simd_distance($0.position, gauge.position) / cbrt(max($0.mass, 1e-6))
                    < simd_distance($1.position, gauge.position) / cbrt(max($1.mass, 1e-6))
            }!
            let root = cbrt(Double(max(nearest.mass, 1e-6)))
            let distance = Double(simd_distance(nearest.position, gauge.position)) / root
            let (cell, reach) = shockCell(distance: distance, root: root)
            let onBox = boxes.contains {
                simd_distance(gauge.position, simd_clamp(gauge.position, $0.min, $0.max)) <= inputs.cellSize
            }
            let onGround = gauge.position.z <= inputs.cellSize
            var bands = GaugeBands(name: gauge.name, scaledDistance: distance, onSurface: onBox)
            if let reason = airComparable {
                bands.note = reason
                return bands
            }
            if boxes.contains(where: { Self.crosses($0, from: nearest.position, to: gauge.position) }) {
                bands.note = "Shielded from the charge, which no comparison was."
                return bands
            }
            let validity =
                String(
                    format: "%.2f m/kg^(1/3) from the charge, cells of %.3f m/kg^(1/3) near the shock",
                    distance,
                    cell) + reach
            func band(
                _ table: ValidationTables.Table, _ grids: [Double], _ distances: [Double],
                measure: BandMeasure,
                quantity: String, check: String, document: String, low: String
            ) -> ErrorBand? {
                ValidationTables.read(
                    table, grids: grids, distances: distances, cell: cell, distance: distance
                ).map {
                    ErrorBand(
                        measure: measure, quantity: quantity, low: $0.low, high: $0.high, lowIsUnsafe: true,
                        meaningLow: low, meaningHigh: "over-read", validity: validity, check: check,
                        document: document, scaled: $0.scaled)
                }
            }
            if distance < 0.3 {
                bands.note = "Closer than any comparison, which began at 0.3 m/kg^(1/3)."
            } else if distance < 0.75 {
                guard onBox || onGround else {
                    bands.note =
                        "Incident pressure close in was not compared; the curves rest on few tests there."
                    return bands
                }
                guard burning || !has(.afterburning) else {
                    bands.note = "Close in, afterburning was compared only with hot air."
                    return bands
                }
                let check =
                    "1 kg burst above rigid ground, reflected beneath it (blastbench closeair"
                    + (burning ? ", afterburning, hot air and far-field faces)" : ")")
                bands.onSurface = true
                bands.peak = band(
                    burning
                        ? ValidationTables.closeBurningReflectedPeak : ValidationTables.closeReflectedPeak,
                    ValidationTables.closeGrids,
                    ValidationTables.closeDistances, measure: .peakOverpressure,
                    quantity: "Reflected peak overpressure",
                    check: check, document: "validation.md#close-in", low: "under-resolved")
                bands.impulse = band(
                    burning
                        ? ValidationTables.closeBurningReflectedImpulse
                        : ValidationTables.closeReflectedImpulse,
                    ValidationTables.closeGrids,
                    ValidationTables.closeDistances, measure: .impulse, quantity: "Reflected impulse",
                    check: check,
                    document: "validation.md#close-in", low: "under-read")
                if bands.peak == nil {
                    bands.note = "Cells coarser than the close-in comparison's 40 mm per kg^(1/3)."
                }
            } else if distance > 6 * 1.02 {
                // Beyond the record's Kingery–Bulmash comparison, the large-scene one's, in the open.
                if distance > 40 * 1.02 {
                    bands.note = "Beyond the large-scene comparison, which stopped at 40 m/kg^(1/3)."
                } else if onBox {
                    bands.note =
                        "Reflected loads beyond 6 m/kg^(1/3) were not compared; the large scenes' were in the open."
                } else {
                    let check =
                        burning
                        ? "500 t surface burst with afterburning and hot air, 16 m cells refined twice (blastbench landscape --afterburn)"
                        : "500 t surface burst on uniform grids to 40 m/kg^(1/3) (blastbench landscape)"
                    let document = "large-scenes.md#against-kingerybulmash-to-40-mkg13"
                    if !burning {
                        bands.peak = band(
                            ValidationTables.farIncidentPeak, ValidationTables.farGrids,
                            ValidationTables.farDistances,
                            measure: .peakOverpressure, quantity: "Incident peak overpressure", check: check,
                            document: document, low: "peaks smeared over cells")
                    }
                    bands.impulse = band(
                        burning
                            ? ValidationTables.farBurningIncidentImpulse
                            : ValidationTables.farIncidentImpulse,
                        ValidationTables.farGrids, ValidationTables.farDistances, measure: .impulse,
                        quantity: "Incident impulse", check: check, document: document,
                        low: burning ? "under-read" : "under-read without afterburning")
                    if bands.peak == nil || bands.impulse == nil {
                        bands.note =
                            burning && bands.impulse != nil
                            ? "With afterburning, peaks beyond 6 m/kg^(1/3) were compared only where the refinement no longer followed the shock."
                            : "Cells coarser than any grid of the large-scene comparison (16 m for 500 t)."
                    }
                }
            } else {
                let check =
                    burning
                    ? "Kingery–Bulmash with afterburning, hot air and far-field faces, 100 kg (blastbench validate)"
                    : "Kingery–Bulmash, 100 kg surface burst (blastbench validate)"
                let document =
                    burning
                    ? ValidationTables.burningDocument
                    : "validation.md#kingerybulmash-the-design-practice-standard"
                let grids = ValidationTables.grids
                let distances = ValidationTables.distances
                if onBox {
                    bands.peak = band(
                        burning ? ValidationTables.burningReflectedPeak : ValidationTables.reflectedPeak,
                        grids,
                        distances, measure: .peakOverpressure,
                        quantity: "Reflected peak overpressure", check: check, document: document,
                        low: "peaks smeared over cells")
                    bands.impulse = band(
                        burning
                            ? ValidationTables.burningReflectedImpulse : ValidationTables.reflectedImpulse,
                        grids,
                        distances, measure: .impulse, quantity: "Reflected impulse", check: check,
                        document: document,
                        low: "under-read")
                } else {
                    bands.peak = band(
                        burning ? ValidationTables.burningIncidentPeak : ValidationTables.incidentPeak, grids,
                        distances,
                        measure: .peakOverpressure, quantity: "Incident peak overpressure", check: check,
                        document: document, low: "peaks smeared over cells")
                    bands.impulse = band(
                        burning ? ValidationTables.burningIncidentImpulse : ValidationTables.incidentImpulse,
                        grids,
                        distances, measure: .impulse, quantity: "Incident impulse", check: check,
                        document: document,
                        low: burning ? "under-read" : "under-read without afterburning")
                }
                if bands.peak == nil || bands.impulse == nil {
                    bands.note = "Cells coarser than any grid compared (0.5 m for 100 kg)."
                }
            }
            // The inputs' spread where the ensemble ran the case: a wall facing the charge, or the
            // close-in slab's gauges.
            let closeIn = bands.peak?.document == "validation.md#close-in"
            if bands.peak?.quantity == "Reflected peak overpressure" {
                bands.peak?.inputSpread = ValidationTables.spread(closeIn ? "closeInGauge" : "wallPeak")
            }
            if bands.impulse?.quantity == "Reflected impulse", !closeIn {
                bands.impulse?.inputSpread = ValidationTables.spread("wallImpulse")
            }
            // The reference's own scatter: Kingery's tests about their fit, repeats for the reflected
            // values, which were calculated; close in, repeats differed by far more.
            for (path, incident) in [
                (\GaugeBands.peak, "incidentPeak"), (\GaugeBands.impulse, "incidentImpulse"),
            ] {
                guard let band = bands[keyPath: path] else { continue }
                if band.document == "validation.md#close-in" {
                    bands[keyPath: path]?.validity +=
                        "; repeats this close differed by up to 40% in peak (Rae and McAfee)"
                } else {
                    bands[keyPath: path]?.referenceScatter = ValidationTables.scatter(
                        band.quantity.hasPrefix("Reflected") ? "reflected" : incident)
                }
            }
            // The burning time was fitted to the open blast's incident impulse: agreement there is
            // by construction.
            if burning, bands.impulse?.quantity == "Incident impulse" {
                bands.impulse?.validity += "; fitted: the burning time was chosen to match it"
            }
            return bands
        }
    }

    /// The cells, per cube root of the charge (`root`), that resolve the shock as it passes
    /// `distance` m/kg^(1/3) out, and a note when it is too weak there to be refined: each level
    /// follows the shock only while its incident overpressure, by Kingery–Bulmash, exceeds the
    /// level's reach (`ValidationTables.refinementReach`); beyond it the peaks fall to the coarser
    /// cells' share (docs/large-scenes.md).
    private func shockCell(distance: Double, root: Double) -> (cell: Double, note: String) {
        let configuration = inputs.configuration
        let coarse = Double(inputs.cellSize)
        guard configuration.refinement > 1 else { return (coarse / root, "") }
        let overpressure = RunCost.blast(range: distance * root, mass: root * root * root).overpressure
        let ratio = Double(configuration.refinement)
        let first = ValidationTables.refinementReach(threshold: Double(configuration.refinementThreshold))
        guard overpressure >= first else {
            return (
                coarse / root,
                String(
                    format: "; the shock, %.1f kPa here, too weak to be refined (above %.0f kPa)",
                    overpressure / 1000,
                    first / 1000)
            )
        }
        guard configuration.refinementLevels > 1 else { return (coarse / ratio / root, "") }
        let finer = ValidationTables.refinementReach(
            threshold: Double(configuration.refinementFinerThreshold ?? configuration.refinementThreshold))
        return overpressure >= finer
            ? (coarse / ratio / ratio / root, "")
            : (coarse / ratio / root, "; the shock too weak here for the second level")
    }

    /// Whether the straight path from `a` to `b` passes through `box`.
    static func crosses(_ box: Box, from a: SIMD3<Float>, to b: SIMD3<Float>) -> Bool {
        let direction = b - a
        var enter: Float = 0
        var leave: Float = 1
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-9 {
                if a[axis] <= box.min[axis] || a[axis] >= box.max[axis] { return false }
            } else {
                let t0 = (box.min[axis] - a[axis]) / direction[axis]
                let t1 = (box.max[axis] - a[axis]) / direction[axis]
                enter = max(enter, min(t0, t1))
                leave = min(leave, max(t0, t1))
                if enter >= leave { return false }
            }
        }
        return true
    }

    /// `band` as it holds on the mesh it was derived on: with that mesh recorded, or nil (and the
    /// reason in `unbanded`) where this scene's elements through lie outside `meshes`. No structural
    /// result converges on today's defaults, so a band carries no further than the meshes behind it.
    private func onMesh(
        _ band: ErrorBand, derived: String, meshes: ClosedRange<Int>?, unbanded: inout [String]
    ) -> ErrorBand? {
        var band = band
        band.derivedMesh = derived
        if let meshes {
            guard let through = elementsThrough else {
                unbanded.append("\(band.quantity): derived on \(derived); no solid elements here to compare.")
                return nil
            }
            guard meshes.contains(through) else {
                unbanded.append(
                    "\(band.quantity): derived on \(derived); not applicable on \(through) elements through, since "
                        + "no structural result converges on today's defaults.")
                return nil
            }
        }
        return band
    }

    /// A band from a single figure of the record.
    private func figure(
        _ id: String, _ measure: BandMeasure, _ quantity: String, lowIsUnsafe: Bool = true, low: String,
        high: String, validity: String, check: String
    ) -> ErrorBand {
        let figure = ValidationTables.figure(id)
        // The cases the ensemble ran, by the figure they share.
        let spreads = ["slabSolid": "slab", "wuSmall": "wuPeak", "wuLargeToday": "wuPeak"]
        // References whose own scatter is known: UFC 3-340-02's rooms.
        let scatters = ["roomDefault": "room", "roomBurning": "room", "roomBurningHot": "room"]
        return ErrorBand(
            measure: measure, quantity: quantity, low: figure.low, high: figure.high,
            lowIsUnsafe: lowIsUnsafe,
            meaningLow: low, meaningHigh: high, validity: validity, check: check, document: figure.document,
            scaled: false, inputSpread: spreads[id].map(ValidationTables.spread),
            referenceScatter: scatters[id].map(ValidationTables.scatter))
    }

    /// Several bands spanned as one: the lowest low and the highest high.
    private func span(_ bands: [ErrorBand], quantity: String) -> ErrorBand? {
        guard var first = bands.first else { return nil }
        first.low = bands.map(\.low).min()!
        first.high = bands.map(\.high).max()!
        first.quantity = quantity
        first.validity =
            bands.count == 1
            ? first.validity : "the \(bands.count) gauges together; each has its own band under its value"
        first.scaled = bands.contains(where: \.scaled)
        return first
    }

    /// Options set whose effect no band was measured with.
    private var unmeasuredStructuralOptions: [String] {
        let measured: Set<ModelOption> = [
            .shellElements, .footings, .cyclicSand, .inclinedBars, .interfaceBond, .importedStructure,
        ]
        return options.filter { option in
            let entry = StandingTable.entry(for: option)
            return entry.affects.contains(.structuralResponse) && !measured.contains(option)
                && !entry.affects.contains(.peakOverpressure)
        }.map { StandingTable.entry(for: $0).title }
    }

    /// How structures meshed from IFC buildings differ from what the shell model was compared on
    /// (reinforced concrete walls and slabs, every load-bearing element in the structure, of a
    /// material chosen rather than assumed); empty where they do not.
    var importedStructureDifferences: [String] {
        var differences: [String] = []
        for imported in inputs.scenario.importedModels ?? [] where imported.isStructural {
            guard let report = imported.structuralReport else {
                differences.append("\(imported.name) has no conversion report")
                continue
            }
            let assumed = report.assumedMaterials
            if !assumed.isEmpty {
                differences.append(
                    "\(imported.name): \(assumed.count) element\(assumed.count == 1 ? "" : "s") of an assumed material"
                )
            }
            let frame = report.members.filter {
                $0.role == .rigid && $0.notes.contains { note in note.hasPrefix("Not ") }
            }
            if !frame.isEmpty {
                differences.append(
                    "\(imported.name): \(frame.count) wall, slab or member\(frame.count == 1 ? "" : "s") kept rigid "
                        + "(inclined or not plate- or member-like)")
            }
            let beams = report.members.filter { $0.role == .beam }
            if !beams.isEmpty {
                differences.append("\(imported.name): beams from IFC sections, not compared")
            }
            let materials = Set(report.members.compactMap(\.material))
            let unlike = materials.filter { name in
                !(name.hasPrefix("Reinforced concrete") || name.hasPrefix("Concrete C"))
            }
            if !unlike.isEmpty {
                differences.append(
                    "\(imported.name): \(unlike.sorted().joined(separator: ", ")), not compared")
            }
            let untied = report.connections.filter { $0.kind.contains("untied") }
            if !untied.isEmpty {
                differences.append(
                    "\(imported.name): \(untied.count) pair\(untied.count == 1 ? "" : "s") of members left untied"
                )
            }
            let guessed = report.connections.filter { $0.kind.contains("inferred") }
            if !guessed.isEmpty {
                differences.append(
                    "\(imported.name): \(guessed.count) pair\(guessed.count == 1 ? "" : "s") tied at nearest nodes, a guess"
                )
            }
            let falling = report.members.filter {
                $0.notes.contains { $0.contains("will fall under gravity") }
            }
            if !falling.isEmpty {
                differences.append(
                    "\(imported.name): \(falling.count) member\(falling.count == 1 ? "" : "s") tied to nothing supported"
                )
            }
            let unfounded = report.supports.filter { $0.contains("foundation left out") }
            if !unfounded.isEmpty {
                differences.append(
                    "\(imported.name): \(unfounded.count) wall\(unfounded.count == 1 ? "" : "s") or column"
                        + "\(unfounded.count == 1 ? "" : "s") tied to the ground where the IFC has no foundation"
                )
            }
            // Each concrete member's reinforcement: the IFC's own, the stated default or none. Reports
            // made before reinforcement was read say only whether the default was asked for.
            let concrete = report.members.filter { $0.reinforcementSource != nil }
            if concrete.isEmpty {
                if imported.structuralOptions?.reinforcement == nil {
                    differences.append("\(imported.name): its concrete unreinforced")
                }
            } else {
                let none = concrete.filter { $0.reinforcementSource?.hasPrefix("None") == true }.count
                let defaulted = concrete.filter { $0.reinforcementAssumed == true }.count - none
                if none > 0 {
                    differences.append(
                        "\(imported.name): \(none) concrete member\(none == 1 ? "" : "s") unreinforced")
                }
                if defaulted > 0 {
                    differences.append(
                        "\(imported.name): \(defaulted) concrete shell\(defaulted == 1 ? "" : "s") with the default "
                            + "reinforcement, not the IFC's")
                }
            }
        }
        return differences
    }

    func bands(for kind: ResultKind) -> (bands: [ErrorBand]?, unbanded: [String]?) {
        var bands: [ErrorBand] = []
        var unbanded: [String] = []
        let mass = Double(inputs.scenario.charge.mass)
        switch kind {
        case .peakOverpressure, .impulse:
            let gauges = gaugeBands()
            let picked = gauges.compactMap { kind == .impulse ? $0.impulse : $0.peak }
            if let spanned = span(
                picked,
                quantity: kind == .impulse ? "Impulse at the gauges" : "Peak overpressure at the gauges")
            {
                bands.append(spanned)
            }
            unbanded += gauges.compactMap { gauge in gauge.note.map { "\(gauge.name): \($0)" } }
            if gauges.isEmpty { unbanded.append("No gauges: bands are given per gauge.") }
            if kind == .impulse, has(.closedBoundaries), airComparable == nil || burning {
                let id = burning ? "roomBurningHot" : has(.afterburning) ? "roomBurning" : "roomDefault"
                bands.append(
                    figure(
                        id, .gasPressure, "Gas pressure left in a closed room",
                        low: "under-read without afterburning",
                        high: "over-read", validity: "0.25 to 4 kg/m³ in a closed 6 m cube, read at 80 ms",
                        check: "UFC 3-340-02's gas pressure (blastbench gas)"))
            }
            if has(.deflagration) {
                bands += [
                    figure(
                        "ventedBackWall", .ventedPressure,
                        "Peak pressure in a vented room, lit at the back wall",
                        low: "flame too slow", high: "over-read",
                        validity:
                            "FM Global's 63.7 m³ chamber, digitised; the wrinkling constant fitted, and the "
                            + "instability's onset measured, by Bauwens et al. in this chamber; the peak uncertain by "
                            + "about ±20% on 0.1 m cells",
                        check: "Bauwens et al.'s vented deflagrations"),
                    figure(
                        "ventedMiddle", .ventedPressure, "Peak pressure in a vented room, lit in the middle",
                        low: "flame stalls", high: "over-read",
                        validity: "FM Global's 63.7 m³ chamber, digitised",
                        check: "Bauwens et al.'s vented deflagrations"),
                ]
            }
        case .structuralResponse:
            let unmeasured = unmeasuredStructuralOptions
            let reinforced = materialClasses.contains(.reinforcedConcrete)
            let imported = importedStructureDifferences
            if !imported.isEmpty {
                unbanded.append(
                    "Structure from IFC unlike what was compared: \(imported.joined(separator: "; ")).")
            } else if !unmeasured.isEmpty {
                unbanded.append(
                    "The comparisons were made with the defaults; set here: \(unmeasured.joined(separator: ", "))."
                )
            } else if !reinforced {
                unbanded.append("No measured comparison of a structure of this material.")
            } else if regime == "confined" {
                bands.append(
                    figure(
                        "chamberPressure", .wallPressure,
                        "Peak wall pressure inside", low: "under-read",
                        high: "over-read",
                        validity:
                            "a full-scale chamber; 0.1 m cells and elements; its roof's peak rises with the mesh "
                            + "(48 to 57 mm on 50 mm elements, the ideal gas) and on 25 mm elements the solution "
                            + "breaks down; with afterburning and hot air the wall pressures alike and the roof "
                            + "rising 50 mm, left 27 mm up, against 48 and 25 on the ideal gas",
                        check: "An internal explosion in a reinforced concrete chamber"))
                if let structure = structures.first, abs(structure.elementSize - 0.1) > 0.01 {
                    bands.removeLast()
                    unbanded.append(
                        "Peak wall pressure inside: derived on 0.1 m elements; not applicable on "
                            + String(format: "%.3g m", structure.elementSize)
                            + ", since no structural result converges on today's defaults.")
                } else {
                    bands[bands.count - 1].derivedMesh = "0.1 m elements and cells only"
                }
                unbanded.append(
                    "The chamber's roof is about twice as stiff as its test; its deflection has no band.")
            } else if regime == "in contact" {
                unbanded.append(
                    "Deflection under a charge in contact was not compared; debris was (see damage).")
            } else if regime == "close in" {
                if mass <= 0.8 {
                    bands +=
                        onMesh(
                            figure(
                                "wuSmall", .peakDeflection, "Peak deflection close in", low: "too stiff",
                                high: "too flexible",
                                validity:
                                    "0.2 to 0.8 kg at 0.43 m/kg^(1/3), slabs that spalled; with afterburning and hot "
                                    + "air S5 and D5 alike (2.3 mm against 4.0 and 4.1)",
                                check: "Wu et al.'s slabs with steel in both faces"),
                            derived: "8 elements through only", meshes: 8...8, unbanded: &unbanded
                        ).map { [$0] } ?? []
                } else if mass <= 2 {
                    bands +=
                        onMesh(
                            figure(
                                "wuLargeToday", .peakDeflection, "Peak deflection close in", low: "too stiff",
                                high: "too flexible",
                                validity:
                                    "1.6 kg at 0.43 m/kg^(1/3), two shots on one mesh (8 through), held at one edge; "
                                    + "on today's build, either air (16.3–16.5 mm on today's, 16.1–16.3 on the ideal "
                                    + "gas, against 18.0 and 13.9), the record's earlier −20% to +7% from an older one",
                                check: "Wu et al.'s slabs with steel in both faces"),
                            derived: "8 elements through only", meshes: 8...8, unbanded: &unbanded
                        ).map { [$0] } ?? []
                } else {
                    unbanded.append("Peak deflection under charges over 2 kg close in was not measured.")
                }
                if mass >= 2 {
                    bands +=
                        onMesh(
                            figure(
                                "closeInPermanent", .permanentDeflection, "Deflection left close in",
                                low: "too stiff",
                                high: "too flexible",
                                validity:
                                    "2 to 15 kg at 0.5 and 1 m; 6 elements through, fine air; P7 is left 112 to 146 mm "
                                    + "down on 6 to 12 and holed on 16; with afterburning and hot air the heavy "
                                    + "charges leave 110–196 mm against 340 and 510",
                                check: "Full-scale slabs under close-in charges"),
                            derived:
                                "6 elements through, calibrated; 6 to 12 leave P7 alike, and on 16 it holes",
                            meshes: 6...12, unbanded: &unbanded
                        ).map { [$0] } ?? []
                }
            } else if let distance = structureDistance, distance < ValidationTables.blindSlabReach {
                let blind = ValidationTables.figure("slabBlindOpenAir")
                unbanded.append(
                    String(
                        format:
                            "Peak deflection: %.2f m/kg^(1/3) from the charge, where blind open-air slabs "
                            + "(Mendonça, 0.93 to 1.44, on the ideal gas of the frozen 047cee3) read %.0f–%.0f%% of "
                            + "meters that likely include the supports' or rigid-body movement, and the two nearest, "
                            + "which collapsed, were left standing. The contest slab's band, from a shock tube's "
                            + "long uniform load, is not given within %.1f.",
                        distance, blind.low * 100, blind.high * 100, ValidationTables.blindSlabReach))
            } else if has(.shellElements) {
                var shell = figure(
                    "slabShell", .peakDeflection, "Peak deflection", low: "too stiff",
                    high: "too flexible",
                    validity: "one slab under a blast, shells", check: "A reinforced slab under a blast")
                shell.derivedMesh =
                    "the slab test's shells, one mesh, not refined: its safe side is not shown to hold on another"
                bands.append(shell)
            } else if let through = elementsThrough, (4...32).contains(through) {
                // Either way by load: too flexible under the contest's load, too stiff under its lower
                // shot; the band spans both, with the contest's repeat as the tests' own scatter.
                var band = figure(
                    "slabSolid", .peakDeflection, "Peak deflection", low: "too stiff",
                    high: "too flexible",
                    validity:
                        "one slab under a blast, 4 to 32 solid elements through (\(through) here): 104–115% under "
                        + "the contest's load, rising with the mesh towards about 119% (113, 121, 125 mm on 8, 16, "
                        + "32, and 124 on 32 with half the step), and 79–88% (too stiff) under its lower shot, "
                        + "a scaled record; 93–99% under the earlier rate laws. The mesh that agreed, 8 through, is "
                        + "the coarse end. Not allowed for: the test's bearings were 4–5 in wide where the model "
                        + "holds lines of nodes, and 1 in bearings already lower the peak 15–25%. Blind, open-air "
                        + "slabs at 0.93 to 1.44 m/kg^(1/3) collapsed where the model's stood, the rest reading a "
                        + "tenth to a quarter of meters that likely include the supports' movement, so it is not "
                        + "given within 1.5. Blind in the same rig, high-strength slabs (v0.3.0) read "
                        + String(
                            format: "%.0f–%.0f%%",
                            ValidationTables.figure("slabBlindHighStrength").low * 100,
                            ValidationTables.figure("slabBlindHighStrength").high * 100)
                        + " where they held, a little stiff, and one lightly reinforced slab broke through where "
                        + "the test held (the safe side). Against the lower shot's tabulated 80.5 mm, the upper "
                        + "reading the record does not keep, the model reads 71–78%. Open in the same rig, the "
                        + "contest's 8 in slabs (RSCR4–6) read "
                        + String(
                            format: "%.0f–%.0f%%",
                            ValidationTables.figure("slabReynoldsOpen").low * 100,
                            ValidationTables.figure("slabReynoldsOpen").high * 100)
                        + " on another shot's shape; on such a shape the lower shot reads 97% of its plateau, so "
                        + "the band's low edge may be the scaled record's shape more than the slab, which rests "
                        + "on that borrowed shape and is left as recorded",
                    check: "A reinforced slab under a blast, and its lower shot")
                band.low = ValidationTables.figure("slabLowerShot").low
                band.high = ValidationTables.figure("slabExtrapolated").high
                band.referenceScatter = ValidationTables.scatter("slabRepeat")
                band.derivedMesh =
                    "4 to 32 elements through, calibrated on 8; 32 holds on half the step; not converged"
                bands.append(band)
            } else {
                unbanded.append(
                    "\(elementsThrough ?? 0) solid elements through the thinnest member, outside the 4 to 32 compared."
                )
            }
            if has(.footings) {
                bands += [
                    figure(
                        "rockingMoment", .footingMoment, "Footing moment to 14 mrad", lowIsUnsafe: false,
                        low: "too weak", high: "too strong",
                        validity:
                            "a surface footing rocked slowly on dry sand of 80 MPa, an estimate twice the "
                            + "default's",
                        check: "FoRCy SSG02_03"),
                    figure(
                        has(.cyclicSand) ? "rockingSettlement" : "shakenSettlement", .footingSettlement,
                        "Footing settlement", low: "too little", high: "too much",
                        validity:
                            "a surface footing on dry sand of 80 MPa, twice the default's; the cyclic sand "
                            + "was made the default after the shaken tests, and its heave under the heel fitted "
                            + "on one test's settlement (FoRCy)",
                        check: has(.cyclicSand) ? "FoRCy SSG02_03" : "FoRDy, eight events"),
                ]
            }
        case .structuralDamage:
            if materialClasses.contains(.reinforcedConcrete), unmeasuredStructuralOptions.isEmpty,
                !has(.shellElements), let through = elementsThrough
            {
                // OA1 on 12 to 48 elements through, from the convergence study: the band spans the
                // meshes either side of this one, since none converges.
                let series = ValidationTables.oa1
                if let read = series.band(on: through) {
                    bands.append(
                        ErrorBand(
                            measure: .shearCapacity, quantity: "Strength in shear", low: read.low,
                            high: read.high,
                            lowIsUnsafe: false, meaningLow: "too weak", meaningHigh: "too strong",
                            validity:
                                "a beam without stirrups (OA1) on \(through) elements through, spanning the "
                                + "meshes either side",
                            check: "Vecchio and Shim's OA1", document: series.document, scaled: true,
                            derivedMesh:
                                "12, 24, 36 and 48 elements through (132%, 104%, 105% and 111% on the 11 October "
                                + "defaults; 132% and 103% on 12 and 24 with the 100 µs window), calibrated on 24; "
                                + "not converged"))
                } else {
                    unbanded.append(
                        "Strength in shear: derived on 12 to 48 elements through; not applicable on \(through), "
                            + "since no structural result converges on today's defaults.")
                }
            } else {
                unbanded.append(
                    "Shear strength was compared only for reinforced concrete solid elements on defaults.")
            }
            if regime == "in contact", !unmeasuredStructuralOptions.isEmpty {
                unbanded.append(
                    "Far face's speed against the debris's: compared on the defaults; set here: "
                        + unmeasuredStructuralOptions.joined(separator: ", ") + ".")
            } else if regime == "in contact" {
                var debris = figure(
                    "debrisSpeed", .debrisSpeed, "Far face's speed against the debris's",
                    low: "debris too slow",
                    high: "debris too fast",
                    validity:
                        "slabs 20–30 cm under contact charges, 12 elements through; after failure, so one draw "
                        + "among roundings (the far face 116–121 m/s on SN142, 15–19 on SN131)",
                    check: "Hupfauf's slabs under contact charges")
                debris.roundingSpread = ValidationTables.rounding("hupfaufSN142", "hupfaufSN131")
                if burning {
                    // Derived again on today's air: the far face on the axis at 0.5 ms against the fit,
                    // with the outline counted by overlap (the default since 16 October) or at centres.
                    let overlap = inputs.configuration.structureMaskOverlap
                    debris = figure(
                        overlap ? "debrisSpeedOverlap" : "debrisSpeedBurning", .debrisSpeed,
                        "Far face's speed against the debris's",
                        low: "debris too slow",
                        high: "debris too fast",
                        validity:
                            "slabs 20–30 cm under contact charges, 12 elements through, on today's air "
                            + (overlap
                                ? "with the outline counted by overlap (the 20 cm slabs 0.9–1.3 of the fit, the thicker "
                                    + "1.0–2.3, moving as much between builds as between outlines)"
                                : "with the outline at the elements' centres (the 20 cm slabs near the fit, 0.9–1.2, "
                                    + "where on the ideal gas 1.2–1.9)") + "; after failure, so one "
                            + "draw among roundings (the far face 61.5–106.3 m/s on SN142, 22.4–27.7 on SN131); "
                            + "SN131's close agreement rests partly on crushed bare elements' hourglass forces, not a "
                            + "physical tie, and those forces run SN144 away in two of six roundings and outlines "
                            + "(two options stop it, neither a default)",
                        check: "Hupfauf's slabs under contact charges")
                    debris.roundingSpread = ValidationTables.rounding(
                        "hupfaufSN142Burning", "hupfaufSN131Burning")
                }
                if has(.afterburning) && !burning {
                    unbanded.append(
                        "Far face's speed against the debris's: compared on the ideal gas and with afterburning "
                            + "and hot air together, not afterburning alone.")
                } else {
                    bands +=
                        onMesh(
                            debris, derived: "12 elements through only", meshes: 12...12, unbanded: &unbanded
                        )
                        .map { [$0] } ?? []
                }
            }
            unbanded.append("Failed elements and collapse have no band.")
        case .envelopeExposure:
            if let distance = structureDistance, airComparable == nil {
                let cell = Double(fineCell) / cbrt(Double(max(inputs.scenario.charge.mass, 1e-6)))
                if let read = ValidationTables.read(
                    burning ? ValidationTables.burningReflectedImpulse : ValidationTables.reflectedImpulse,
                    grids: ValidationTables.grids, distances: ValidationTables.distances, cell: cell,
                    distance: Double(distance))
                {
                    bands.append(
                        ErrorBand(
                            measure: .impulse, quantity: "Reflected impulse on the nearest face",
                            low: read.low,
                            high: read.high, lowIsUnsafe: true, meaningLow: "under-read",
                            meaningHigh: "over-read",
                            validity: String(
                                format: "a rigid wall facing the charge at %.2f m/kg^(1/3)", distance),
                            check: burning
                                ? "Kingery–Bulmash on today's defaults, 100 kg" : "Kingery–Bulmash, 100 kg",
                            document: burning
                                ? ValidationTables.burningDocument
                                : "validation.md#kingerybulmash-the-design-practice-standard",
                            scaled: read.scaled, referenceScatter: ValidationTables.scatter("reflected")))
                } else {
                    unbanded.append("The nearest face lies outside the compared distances or cells.")
                }
            } else {
                unbanded.append(airComparable ?? "No building faces.")
            }
            unbanded.append("Faces shielded or turned from the charge were not compared.")
        case .envelopeDamage:
            let page = "building-envelopes.md#one-way-damage-single-degree-of-freedom"
            let check = "The same buildings free to respond, 0.125 m shells"
            bands.append(
                figure(
                    "envelopeGlassBreak", .breakageTime, "When a pane breaks", lowIsUnsafe: false,
                    low: "too early", high: "too late",
                    validity: "4 mm annealed panes of 0.89 m² in a rigid frame, every one broken by a long "
                        + "wave reflected at about 33 kPa",
                    check: "Monk and Clubley's twelve timed panes, Shoeburyness"))
            bands += [
                figure(
                    "envelopeConcreteFixed", .peakDeflection, "Concrete wall rotation, fixed edges",
                    low: "too stiff",
                    high: "too soft", validity: "the wall facing the charge, 0.2 m, 50–500 kg", check: check),
                figure(
                    "envelopeConcreteSimple", .peakDeflection,
                    "Concrete wall rotation, simply supported edges",
                    low: "too stiff", high: "too soft",
                    validity: "the wall facing the charge, 0.2 m, 50–500 kg",
                    check: check),
                figure(
                    "envelopeBrick", .peakDeflection, "Brick wall rotation", low: "too stiff",
                    high: "too soft",
                    validity: "0.215 m smeared brick, 2–50 kg, past 0.1°", check: check),
                figure(
                    "envelopeInsideFill", .insidePressure, "Inside peak through broken panes",
                    low: "under-read",
                    high: "over-read", validity: "a 6 × 6 × 4 m room behind four panes, 10–500 kg",
                    check: check),
            ].map { band in
                var band = band
                band.derivedMesh = "0.125 m shells, 8 layers"
                band.document = page
                return band
            }
            unbanded.append("Roofs, and walls beside a failing one, go beyond both concrete bounds: no band.")
        case .thermal:
            if !burning {
                unbanded.append(
                    "Energy radiated: compared with afterburning and hot air, today's defaults; without both the "
                        + "fireball is gone within 50 ms, or with afterburning alone radiates 29% against 21%."
                )
            } else if inputs.thermal?.fireball == .volume {
                bands.append(
                    figure(
                        has(.radiativeCooling) ? "fireballCooling" : "fireballTotal", .radiatedEnergy,
                        "Energy radiated", lowIsUnsafe: true, low: "too dim", high: "too bright",
                        validity: "a 100 t TNT shot, the volume", check: "DREO's TNT fireball"))
            } else {
                unbanded.append("Only the volume's radiation was compared with a measurement.")
            }
        case .cloud:
            if has(.afterburning) && !has(.hotAir) {
                unbanded.append(
                    "Cloud's top: Church's clouds were compared with afterburning and hot air together, today's "
                        + "defaults; afterburning alone was not run against them.")
            } else if has(.afterburning) {
                bands.append(
                    figure(
                        "cloudTop", .cloudTop, "Cloud's top", lowIsUnsafe: true, low: "too low",
                        high: "too high",
                        validity: "54 to 1,270 kg of TNT, half a minute to two minutes; 21% is a geometric "
                            + "spread, not a bound, with afterburning whose burning time was fitted to the open blast",
                        check: "Church's 22 detonations"))
            } else {
                unbanded.append("The comparison with Church's clouds was made with afterburning on.")
            }
        case .groundShock:
            unbanded.append(
                "One measured surface burst, too far off to band: the vertical velocity 20 to 80 times the "
                    + "measured, near and past where the ground's wave outruns the air.")
        case .freestandingMotion, .fragments, .surfaceHeating:
            unbanded.append("Nothing measured to band it.")
        }
        return (bands, unbanded)
    }

    func regimes(for kind: ResultKind) -> [RegimeAdvice] {
        let place = regime
        var advice: [RegimeAdvice] = []
        func add(_ option: String, _ suits: Bool?, _ note: String, _ suggestion: String?, _ document: String)
        {
            advice.append(
                RegimeAdvice(
                    regime: place, option: option, suits: suits, note: note, suggestion: suggestion,
                    document: document))
        }
        switch kind {
        case .structuralResponse, .structuralDamage:
            guard !structures.isEmpty else { return [] }
            if has(.bondSlip) {
                add(
                    "Bars that slip", false,
                    "Right where perfect bond splits a beam along its bars under a light drop, but too stiff nearly "
                        + "everywhere else: the slab 11% short, a beam in shear 47–51% strong.",
                    "Leave bars bonded (the default) under a blast.",
                    "validation.md#bars-that-slip-across-the-tests")
            }
            if placedStructures.contains(where: \.pressedInterlockFromRegime) {
                add(
                    "Pressed interlock", true,
                    "On by the confined regime's defaults: the chamber's roof edge 49 / 25 mm against 38 / 16 without "
                        + "it (95 measured).",
                    nil, "validation.md#one-crack-sheared-along-its-measured-path")
            } else if has(.pressedInterlock) {
                add(
                    "Pressed interlock", place == "confined",
                    place == "confined"
                        ? "The one member it moves the right way is the chamber: its roof edge 49 / 25 mm against 38 / 16 "
                            + "by default (95 measured)."
                        : "Right for a crack sheared in a push-off test, but every member it moves it moves the wrong "
                            + "way except the chamber, breaking beams under impact.",
                    place == "confined" ? nil : "Turn it off outside a confined explosion.",
                    "validation.md#one-crack-sheared-along-its-measured-path")
            } else if place == "confined", !placedStructures.contains(where: \.appliesPressedInterlock) {
                add(
                    "Pressed interlock", nil,
                    "In a confined explosion the record's one improvement from it: the chamber's roof edge 49 / 25 mm "
                        + "against 38 / 16 by default (95 measured).",
                    "Compare a run with pressed interlock.",
                    "validation.md#one-crack-sheared-along-its-measured-path")
            }
            if has(.removesFragments) {
                add(
                    "Fragments removed", place == "far field" ? false : nil,
                    place == "far field"
                        ? "Far from the charge it damages members that held: a struck beam went 25% further."
                        : "It holes slabs both where the tests did and where they did not: Hupfauf's 20 cm slabs, "
                            + "holed in the tests, and his 30 cm ones, which held.",
                    place == "far field"
                        ? "Turn it off away from the charge."
                        : "Run with and without it to bracket the hole.",
                    "validation.md#holes-under-close-in-and-contact-charges")
            } else if place == "in contact" || place == "close in" {
                add(
                    "Fragments removed", nil,
                    "Without it no slab is ever holed; with it, slabs near size are holed but so are some that held.",
                    "Run with and without it to bracket a hole.",
                    "validation.md#holes-under-close-in-and-contact-charges")
            }
            if let through = elementsThrough, materialClasses.contains(.reinforcedConcrete),
                !has(.shellElements)
            {
                if place == "close in" || place == "in contact" {
                    add(
                        "Elements through", nil,
                        "Close in, 6 elements through held the slab where 8 broke its hinge: a mesh chosen by its "
                            + "agreement, not converged. A spall needs 12 (\(through) here).",
                        nil, "validation.md#slabs-under-close-in-charges")
                } else if through < 24 {
                    add(
                        "Elements through", nil,
                        "No structural result converges on today's defaults: the meshes that agree (8 through for "
                            + "the slab, 24 for a beam in shear) are the coarse end; in shear 132% on 12, 104% on 24 "
                            + "and 111% on 48 (\(through) here).",
                        kind == .structuralDamage
                            ? "Compare two meshes where shear failure matters; the answer moves with both."
                            : nil,
                        "validation.md#convergence-on-todays-defaults")
                }
            }
            if has(.shellSectionShear) {
                add(
                    "Shells' section shear check", false,
                    "Under the slab test's blast the check broke the slab where it held.",
                    "Turn it off under a blast.",
                    "validation.md#a-beam-failing-in-shear")
            }
            if has(.alternativeRateLaws) {
                add(
                    "Bars without their strain-rate law", nil,
                    "The bars' strength was compared under a blast only with the CEB's strain-rate law; without "
                        + "it they were not.",
                    nil, "concrete-model.md#strain-rate-effects")
            }
            if place == "in contact" {
                add(
                    "The charge as hot air", nil,
                    "In contact the hot-air charge gives about twice the products' impulse, holing thick slabs that held.",
                    nil, "validation.md#slabs-under-contact-charges")
            }
        case .impulse, .peakOverpressure:
            guard !has(.deflagration) else { return [] }
            if place == "confined" {
                if !has(.afterburning) {
                    add(
                        "Afterburning and hot air", false,
                        "Confined, the default gas leaves 48% to 114% of the design curve's pressure.",
                        "Turn on afterburning and hot air: 98% to 108%, nothing fitted.",
                        "validation.md#gas-pressure-in-a-closed-room")
                } else if !has(.hotAir) {
                    add(
                        "Hot air", false, "Afterburning alone leaves a closed room's gas 24–31% high.",
                        "Add hot air: 98% to 108%.", "validation.md#gas-pressure-in-a-closed-room")
                } else {
                    add(
                        "Afterburning and hot air", true,
                        "A closed room's gas within 8% of the design curve.", nil,
                        "validation.md#gas-pressure-in-a-closed-room")
                }
            } else if kind == .impulse {
                add(
                    "Afterburning", nil,
                    has(.afterburning)
                        ? "In the open the incident impulse is within 6% beyond 1 m/kg^(1/3) on 0.25 m cells "
                            + "(fitted), but the reflected impulse on walls 6–13% high in the middle ranges."
                        : "In the open the reflected impulse on walls is within 6%, but the incident impulse 13–22% low: "
                            + "low for objects the wave passes over.",
                    has(.afterburning) ? nil : "Turn afterburning on where the incident impulse matters.",
                    has(.afterburning) ? ValidationTables.burningDocument : "validation.md#afterburning")
            }
        case .envelopeExposure, .envelopeDamage, .freestandingMotion, .thermal, .surfaceHeating, .cloud,
            .fragments, .groundShock:
            break
        }
        return advice
    }
}
