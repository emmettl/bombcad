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

    /// Half the band's width over its middle: differences between runs smaller than this cannot be
    /// told apart against measurement.
    public var relativeHalfWidth: Double { (high - low) / (high + low) }
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
    /// With afterburning and hot air: the refinement table's uniform 0.25 and 0.125 m columns, and
    /// the incident impulse on 0.25 m cells.
    public static let burningIncidentPeak = Table(byGrid: [
        nil, [72, 74, 82, 78, 83, 82, 84, 83], [90, 89, 93, 87, 88, 91, 92, 92],
    ])
    public static let burningIncidentImpulse = Table(byGrid: [nil, [116, 94, 95, 94, 99, 98, 98, 96], nil])
    public static let burningReflectedImpulse = Table(byGrid: [
        nil, [85, 93, 106, 110, 113, 110, 107, 106], [94, 103, 114, 113, 112, 107, 104, 103],
    ])

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
            id: "slabSolid", low: 1.05, high: 1.15, document: "validation.md#summary",
            quote: "solid elements 113–124 mm (105–115%) on 4 to 32 elements through"),
        Figure(
            id: "slabShell", low: 1.25, high: 1.25, document: "validation.md#summary",
            quote: "shells 135 mm (125%)"),
        Figure(
            id: "beamMoment", low: 0.97, high: 0.99, document: "validation.md#summary",
            quote: "peak moment 97–99%, failure at 38–52 mm against 42 mm"),
        Figure(
            id: "shearFine", low: 1.11, high: 1.15, document: "validation.md#summary",
            quote: "11–15% strong on fine meshes"),
        Figure(
            id: "shearCoarse", low: 1.37, high: 1.37, document: "validation.md#a-beam-failing-in-shear",
            quote: "| 12 elements through           | 456 kN (137%)   | 10.4 mm |"),
        Figure(
            id: "closeInPermanent", low: 0.33, high: 0.5, document: "validation.md#summary",
            quote: "the slab left a third to a half as far down as measured"),
        Figure(
            id: "wuLarge", low: 0.8, high: 1.07, document: "validation.md#summary",
            quote: "within −20% to +7% at the peak under 1.6 kg at 0.43 m/kg^(1/3)"),
        Figure(
            id: "wuSmall", low: 0.4, high: 0.7, document: "validation.md#summary",
            quote: "40–70% under 0.2–0.8 kg where the tests spalled"),
        Figure(
            id: "chamberPressure", low: 0.9, high: 1.6, document: "validation.md#summary",
            quote: "peak wall pressures 0.9 to 1.6 times those measured"),
        Figure(
            id: "debrisSpeed", low: 1.2, high: 1.9, document: "validation.md#summary",
            quote: "the far face thrown 1.2–1.9 times as fast as the debris at first"),
        Figure(
            id: "roomDefault", low: 0.48, high: 1.14, document: "validation.md#summary",
            quote: "48% to 114% of the design curve by default"),
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
            quote: "moment within 11% to 14 mrad of rotation, 5–16% low beyond"),
        Figure(
            id: "rockingMomentLarge", low: 0.84, high: 0.95, document: "validation.md#summary",
            quote: "moment within 11% to 14 mrad of rotation, 5–16% low beyond"),
        Figure(
            id: "rockingSettlement", low: 1.7, high: 2.2, document: "validation.md#summary",
            quote: "settlement 1.7–2.2 times that measured"),
        Figure(
            id: "shakenSettlement", low: 0.6, high: 1.5, document: "validation.md#summary",
            quote: "settlement 0.6–1.5 times, peak rotation within 22% where the test did not lurch one way"),
        Figure(
            id: "shakenRotation", low: 0.78, high: 1.22, document: "validation.md#summary",
            quote: "settlement 0.6–1.5 times, peak rotation within 22% where the test did not lurch one way"),
        Figure(
            id: "fireballTotal", low: 3, high: 5, document: "validation.md#summary",
            quote: "100 t, whose total the volume exceeds three to five times"),
        Figure(
            id: "fireballCooling", low: 2, high: 3, document: "thermal-radiation.md#limitations",
            quote: "three to five times (two to three with the gas cooling)"),
        Figure(
            id: "cloudTop", low: 0.79, high: 1.21, document: "fireball-rise.md",
            quote: "to 4% on average and 21% shot by shot"),
        Figure(
            id: "ventedBackWall", low: 0.55, high: 0.6, document: "validation.md#summary",
            quote: "lit at the back wall, 55–60% of the measured peaks"),
        Figure(
            id: "ventedMiddle", low: 0.143, high: 0.2, document: "validation.md#summary",
            quote: "lit in the middle, a fifth to a seventh"),
    ]

    public static func figure(_ id: String) -> Figure { figures.first { $0.id == id }! }
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
    /// The scene's regime, by where its structure lies from the charge and what encloses it.
    var regime: String {
        if has(.closedBoundaries) || chargeEnclosed { return "confined" }
        guard let distance = structureDistance else { return structures.isEmpty ? "open air" : "far field" }
        return distance < 0.15 ? "in contact" : distance < 0.75 ? "close in" : "far field"
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
        if has(.terrain) { return "The comparisons were on flat ground; this scene has terrain." }
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
            + (scenario.importedModels ?? []).filter { $0.isAttached && $0.behavior == .rigid }
            .flatMap { $0.preview.boxes }
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
            let cell = Double(fineCell) / root
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
            let validity = String(
                format: "%.2f m/kg^(1/3) from the charge, cells of %.3f m/kg^(1/3) near the shock", distance,
                cell)
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
                guard !has(.afterburning) else {
                    bands.note = "Close in, the comparison was without afterburning."
                    return bands
                }
                let check = "1 kg burst above rigid ground, reflected beneath it (blastbench closeair)"
                bands.onSurface = true
                bands.peak = band(
                    ValidationTables.closeReflectedPeak, ValidationTables.closeGrids,
                    ValidationTables.closeDistances, measure: .peakOverpressure,
                    quantity: "Reflected peak overpressure",
                    check: check, document: "validation.md#close-in", low: "under-resolved")
                bands.impulse = band(
                    ValidationTables.closeReflectedImpulse, ValidationTables.closeGrids,
                    ValidationTables.closeDistances, measure: .impulse, quantity: "Reflected impulse",
                    check: check,
                    document: "validation.md#close-in", low: "under-read")
                if bands.peak == nil {
                    bands.note = "Cells coarser than the close-in comparison's 40 mm per kg^(1/3)."
                }
            } else if distance > 6 * 1.02 {
                bands.note = "Beyond the open-air comparison, which stopped at 6 m/kg^(1/3)."
            } else {
                let check =
                    burning
                    ? "Kingery–Bulmash with afterburning and hot air, 100 kg (blastbench validate --afterburn --air thermal)"
                    : "Kingery–Bulmash, 100 kg surface burst (blastbench validate)"
                let document =
                    burning
                    ? "validation.md#afterburning"
                    : "validation.md#kingerybulmash-the-design-practice-standard"
                let grids = ValidationTables.grids
                let distances = ValidationTables.distances
                if onBox {
                    bands.peak =
                        burning
                        ? nil
                        : band(
                            ValidationTables.reflectedPeak, grids, distances, measure: .peakOverpressure,
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
                    bands.note =
                        burning
                        ? "With afterburning, cells coarser than 0.25 m for 100 kg, and reflected peaks, were not compared."
                        : "Cells coarser than any grid compared (0.5 m for 100 kg)."
                }
            }
            return bands
        }
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

    /// A band from a single figure of the record.
    private func figure(
        _ id: String, _ measure: BandMeasure, _ quantity: String, lowIsUnsafe: Bool = true, low: String,
        high: String, validity: String, check: String
    ) -> ErrorBand {
        let figure = ValidationTables.figure(id)
        return ErrorBand(
            measure: measure, quantity: quantity, low: figure.low, high: figure.high,
            lowIsUnsafe: lowIsUnsafe,
            meaningLow: low, meaningHigh: high, validity: validity, check: check, document: figure.document,
            scaled: false)
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
            .shellElements, .footings, .cyclicSand, .inclinedBars, .interfaceBond,
        ]
        return options.filter { option in
            let entry = StandingTable.entry(for: option)
            return entry.affects.contains(.structuralResponse) && !measured.contains(option)
                && !entry.affects.contains(.peakOverpressure)
        }.map { StandingTable.entry(for: $0).title }
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
                        validity: "FM Global's 63.7 m³ chamber, digitised",
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
            if !unmeasured.isEmpty {
                unbanded.append(
                    "The comparisons were made with the defaults; set here: \(unmeasured.joined(separator: ", "))."
                )
            } else if !reinforced {
                unbanded.append("No measured comparison of a structure of this material.")
            } else if regime == "confined" {
                bands.append(
                    figure(
                        "chamberPressure", .wallPressure, "Peak wall pressure inside", low: "under-read",
                        high: "over-read", validity: "a full-scale chamber; 0.1 m cells and elements",
                        check: "An internal explosion in a reinforced concrete chamber"))
                unbanded.append(
                    "The chamber's roof is about twice as stiff as its test; its deflection has no band.")
            } else if regime == "in contact" {
                unbanded.append(
                    "Deflection under a charge in contact was not compared; debris was (see damage).")
            } else if regime == "close in" {
                if mass <= 0.8 {
                    bands.append(
                        figure(
                            "wuSmall", .peakDeflection, "Peak deflection close in", low: "too stiff",
                            high: "too flexible",
                            validity: "0.2 to 0.8 kg at 0.43 m/kg^(1/3), slabs that spalled",
                            check: "Wu et al.'s slabs with steel in both faces"))
                } else if mass <= 2 {
                    bands.append(
                        figure(
                            "wuLarge", .peakDeflection, "Peak deflection close in", low: "too stiff",
                            high: "too flexible", validity: "1.6 kg at 0.43 m/kg^(1/3), 8 elements through",
                            check: "Wu et al.'s slabs with steel in both faces"))
                } else {
                    unbanded.append("Peak deflection under charges over 2 kg close in was not measured.")
                }
                if mass >= 2 {
                    bands.append(
                        figure(
                            "closeInPermanent", .permanentDeflection, "Deflection left close in",
                            low: "too stiff",
                            high: "too flexible",
                            validity: "2 to 15 kg at 0.5 and 1 m; 6 elements through, fine air",
                            check: "Full-scale slabs under close-in charges"))
                }
            } else if has(.shellElements) {
                bands.append(
                    figure(
                        "slabShell", .peakDeflection, "Peak deflection", low: "too stiff",
                        high: "too flexible",
                        validity: "one slab under a blast, shells", check: "A reinforced slab under a blast"))
            } else if let through = elementsThrough, (4...32).contains(through) {
                bands.append(
                    figure(
                        "slabSolid", .peakDeflection, "Peak deflection", low: "too stiff",
                        high: "too flexible",
                        validity: "one slab under a blast, 4 to 32 solid elements through (\(through) here)",
                        check: "A reinforced slab under a blast"))
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
                        validity: "a surface footing rocked slowly on dry sand",
                        check: "FoRCy SSG02_03"),
                    figure(
                        has(.cyclicSand) ? "rockingSettlement" : "shakenSettlement", .footingSettlement,
                        "Footing settlement", low: "too little", high: "too much",
                        validity: "a surface footing on dry sand, rocked or shaken",
                        check: has(.cyclicSand) ? "FoRCy SSG02_03" : "FoRDy, eight events"),
                ]
            }
        case .structuralDamage:
            if materialClasses.contains(.reinforcedConcrete), unmeasuredStructuralOptions.isEmpty,
                !has(.shellElements), let through = elementsThrough
            {
                if through >= 24 {
                    bands.append(
                        figure(
                            "shearFine", .shearCapacity, "Strength in shear", lowIsUnsafe: false,
                            low: "too weak",
                            high: "too strong",
                            validity: "a beam without stirrups, 24 or 36 elements through",
                            check: "Vecchio and Shim's OA1"))
                } else if through >= 12 {
                    var band = figure(
                        "shearCoarse", .shearCapacity, "Strength in shear", lowIsUnsafe: false,
                        low: "too weak",
                        high: "too strong", validity: "a beam without stirrups, \(through) elements through",
                        check: "Vecchio and Shim's OA1")
                    // 137% on 12 through, 111% on 24: interpolated by the elements through.
                    let t = Double(through - 12) / 12
                    band.high = 1.37 + (1.11 - 1.37) * t
                    band.low = band.high
                    band.scaled = true
                    bands.append(band)
                } else {
                    unbanded.append(
                        "\(through) elements through: coarser than the 12 compared in shear, which were 37% strong."
                    )
                }
            } else {
                unbanded.append(
                    "Shear strength was compared only for reinforced concrete solid elements on defaults.")
            }
            if regime == "in contact" {
                bands.append(
                    figure(
                        "debrisSpeed", .debrisSpeed, "Far face's speed against the debris's",
                        low: "debris too slow",
                        high: "debris too fast",
                        validity: "slabs 20–30 cm under contact charges, 12 elements through",
                        check: "Hupfauf's slabs under contact charges"))
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
                            check: "Kingery–Bulmash, 100 kg",
                            document: "validation.md#kingerybulmash-the-design-practice-standard",
                            scaled: read.scaled))
                } else {
                    unbanded.append("The nearest face lies outside the compared distances or cells.")
                }
            } else {
                unbanded.append(airComparable ?? "No building faces.")
            }
            unbanded.append("Faces shielded or turned from the charge were not compared.")
        case .thermal:
            if inputs.thermal?.fireball == .volume {
                bands.append(
                    figure(
                        has(.radiativeCooling) ? "fireballCooling" : "fireballTotal", .radiatedEnergy,
                        "Energy radiated", lowIsUnsafe: true, low: "too dim", high: "too bright",
                        validity: "a 100 t TNT shot, the volume", check: "DREO's TNT fireball"))
            } else {
                unbanded.append("Only the volume's radiation was compared with a measurement.")
            }
        case .cloud:
            if has(.afterburning) {
                bands.append(
                    figure(
                        "cloudTop", .cloudTop, "Cloud's top", lowIsUnsafe: true, low: "too low",
                        high: "too high",
                        validity: "54 to 1,270 kg of TNT, half a minute to two minutes, shot by shot",
                        check: "Church's 22 detonations"))
            } else {
                unbanded.append("The comparison with Church's clouds was made with afterburning on.")
            }
        case .freestandingMotion, .fragments, .groundShock, .surfaceHeating:
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
            if has(.pressedInterlock) {
                add(
                    "Pressed interlock", place == "confined",
                    place == "confined"
                        ? "The one member it moves the right way is the chamber: its roof edge 49 / 25 mm against 38 / 16 "
                            + "by default (95 measured)."
                        : "Right for a crack sheared in a push-off test, but every member it moves it moves the wrong "
                            + "way except the chamber, breaking beams under impact.",
                    place == "confined" ? nil : "Turn it off outside a confined explosion.",
                    "validation.md#one-crack-sheared-along-its-measured-path")
            } else if place == "confined" {
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
                        "Elements through", through == 6 || through >= 12 ? true : nil,
                        "Close in, 6 elements through held the slab where 8 broke its hinge, and a spall needs 12 "
                            + "(\(through) here).",
                        through == 6 || through >= 12
                            ? nil : "Use 6 through for the slab's bending, or 12 for spall.",
                        "validation.md#slabs-under-close-in-charges")
                } else if through < 24 {
                    add(
                        "Elements through", kind == .structuralResponse ? true : false,
                        "8 through are enough for bending, but shear needs about 24 (137% strong on 12; \(through) here).",
                        kind == .structuralDamage
                            ? "Mesh finer, about 24 through, where shear failure matters." : nil,
                        "validation.md#a-beam-failing-in-shear")
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
                    "Other strain-rate laws", nil,
                    "Malvar and Ross's tension law brings the slab to 93–99% but leaves heavy drops a quarter too stiff "
                        + "and the close-in slab far short.",
                    nil, "validation.md#beams-struck-by-a-falling-weight")
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
                        ? "In the open the incident impulse is within 4–6% (fitted), but the reflected impulse on walls "
                            + "6–15% high in the middle ranges."
                        : "In the open the reflected impulse on walls is within 6%, but the incident impulse 13–22% low: "
                            + "low for objects the wave passes over.",
                    has(.afterburning) ? nil : "Turn afterburning on where the incident impulse matters.",
                    "validation.md#afterburning")
            }
        case .envelopeExposure, .freestandingMotion, .thermal, .surfaceHeating, .cloud, .fragments,
            .groundShock:
            break
        }
        return advice
    }
}
