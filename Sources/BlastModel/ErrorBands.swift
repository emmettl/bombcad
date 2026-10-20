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

    /// On the mapped start, the default since 18 October 2026, with afterburning, hot air and
    /// far-field faces (validation.md, "The mapped start").
    public static let mappedIncidentPeak = Table(byGrid: [
        [119, 108, 116, 104, 104, 101, 103, 78], [115, 116, 113, 101, 103, 83, 86, 87],
        [116, 117, 113, 87, 91, 93, 94, 95],
    ])
    public static let mappedIncidentImpulse = Table(byGrid: [
        [128, 96, 96, 100, 108, 105, 103, 106], [127, 96, 95, 98, 105, 106, 106, 106],
        [127, 95, 93, 97, 104, 104, 103, 104],
    ])
    public static let mappedReflectedPeak = Table(byGrid: [
        [15, 22, 34, 45, 60, 68, 72, 74], [32, 40, 55, 64, 77, 83, 87, 88], [57, 62, 76, 83, 92, 95, 97, 97],
    ])
    public static let mappedReflectedImpulse = Table(byGrid: [
        [70, 79, 97, 103, 114, 115, 115, 114], [85, 95, 107, 111, 118, 118, 117, 115],
        [96, 102, 113, 115, 119, 117, 114, 113],
    ])
    /// Where the mapped start's tables are recorded.
    public static let mappedDocument = "validation.md#the-mapped-start-18-october"

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

        /// "75–84%".
        public var percent: String { String(format: "%.0f–%.0f%%", low * 100, high * 100) }
        /// "0.84–0.99".
        public var ratio: String { String(format: "%.2f–%.2f", low, high) }
    }

    /// Every single figure the bands use. `ErrorBandTests` checks each quote lies under its
    /// heading and holds the figure's numbers.
    public static let figures: [Figure] =
        envelopeFigures + structureFigures + airFigures + foundationFigures + thermalFigures
        + deflagrationFigures + districtFigures

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
            quote: "| Contest slab, peak (mm) | 109 | 113 | 106, 12% | 89–126 |"),
        Spread(
            id: "wuPeak", coefficient: 0.04,
            quote: "| Wu S8, peak (mm) | 18.0 | 16.2 | 16.1, 4% | 15.3–17.1 |"),
        Spread(
            id: "closeInGauge", coefficient: 0.07,
            quote: "| Chiquito S1–S3, gauge at 1 m (MPa) | 2.5 | 1.45 | 1.45, 7% | 1.29–1.61 |"),
        Spread(
            id: "wallPeak", coefficient: 0.02,
            quote: "| Kingery–Bulmash wall, reflected peak (kPa) | 1,060 (K–B) | 677 | 678, 2% | 655–696 |"),
        Spread(
            id: "wallImpulse", coefficient: 0.02,
            quote:
                "| Kingery–Bulmash wall, reflected impulse (Pa s) | 1,690 (K–B) | 1,880 | 1,880, 2% | 1,830–1,920 |"
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
    var placedStructures: [StructureModel] {
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
    var airComparable: String? {
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

    var burning: Bool { has(.afterburning) && has(.hotAir) }
    /// On today's air and the mapped start, the default since 18 October 2026.
    var mapped: Bool { burning && has(.mappedCharge) }

    /// Boxes a gauge can sit on: blocks, structures and envelopes.
    var surfaces: [Box] {
        let scenario = inputs.scenario
        return scenario.boxes + structures.flatMap(\.solids)
            + scenario.envelopeObjects.compactMap(\.envelope).flatMap(\.solids)
            + (scenario.importedModels ?? []).flatMap(\.rigidBoxes)
    }

    /// The cells, per cube root of the charge (`root`), that resolve the shock as it passes
    /// `distance` m/kg^(1/3) out, and a note when it is too weak there to be refined: each level
    /// follows the shock only while its incident overpressure, by Kingery–Bulmash, exceeds the
    /// level's reach (`ValidationTables.refinementReach`); beyond it the peaks fall to the coarser
    /// cells' share (docs/large-scenes.md).
    func shockCell(distance: Double, root: Double) -> (cell: Double, note: String) {
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
    func onMesh(
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
    func figure(
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
    func span(_ bands: [ErrorBand], quantity: String) -> ErrorBand? {
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
    var unmeasuredStructuralOptions: [String] {
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
        switch kind {
        case .peakOverpressure, .impulse:
            airBands(for: kind, bands: &bands, unbanded: &unbanded)
        case .structuralResponse:
            structuralResponseBands(bands: &bands, unbanded: &unbanded)
        case .structuralDamage:
            structuralDamageBands(bands: &bands, unbanded: &unbanded)
        case .envelopeExposure:
            envelopeExposureBands(bands: &bands, unbanded: &unbanded)
        case .envelopeDamage:
            envelopeDamageBands(bands: &bands, unbanded: &unbanded)
        case .thermal:
            thermalBands(bands: &bands, unbanded: &unbanded)
        case .cloud:
            cloudBands(bands: &bands, unbanded: &unbanded)
        case .groundShock:
            unbanded.append(
                "Two measured surface bursts, too far off to band: at Xia's the vertical velocity 20 to 80 times "
                    + "the measured near and past where the ground's wave outruns the air; at Prairie Flat's, inside "
                    + "that limit, within a factor of two at under half the records."
            )
        case .blastInjury:
            unbanded.append(
                "Checked against the curves' own published distances and the free field, not against injury data."
            )
        case .freestandingMotion, .fragments, .surfaceHeating:
            unbanded.append("Nothing measured to band it.")
        case .collapse:
            unbanded.append(
                "Collapse was compared once for slabs, blind, and missed, and for brick houses only by survey "
                    + "category: no band, and the local damage's bands do not apply to it.")
        case .crater:
            unbanded.append(
                "The apparent diameter's one-sigma scatter is a third either way (Kinney and Graham's 200 "
                    + "accidental explosions), given with each crater; its depth has no band.")
        }
        return (bands, unbanded)
    }
}
