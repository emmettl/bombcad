import Foundation
import simd

// The air's bands: the gauges' peaks and impulses, a closed room's and a vented room's figures.
// Split from ErrorBands.swift (emmettl/bombcad-work#50); see that file for the types.

extension ValidationTables {
    /// A closed room's gas pressure. Part of `figures`, in its order.
    static let airFigures: [Figure] = [
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
    ]

    /// Vented deflagrations. Part of `figures`, in its order.
    static let deflagrationFigures: [Figure] = [
        Figure(
            id: "ventedHydrogen", low: 1.24, high: 2.96, document: "deflagration.md#checks",
            quote: "the peaks are 1.24–2.96 of the measured"),
        Figure(
            id: "ventedHydrogenRoof", low: 0.19, high: 0.45, document: "deflagration.md#checks",
            quote: "still on the unsafe side, 0.19–0.45"),
        Figure(
            id: "ventedHydrogenWithoutLewis", low: 0.19, high: 0.39, document: "deflagration.md#checks",
            quote: "lean hydrogen vented at 0.19–0.39 of the measured peaks"),
        Figure(
            id: "ventedBackWall", low: 0.9, high: 1.8, document: "validation.md#summary",
            quote: "lit at the back wall, 0.9–1.8 times the measured peaks"),
        Figure(
            id: "ventedMiddle", low: 0.4, high: 0.6, document: "validation.md#summary",
            quote: "lit in the middle, 0.4–0.6"),
    ]
}

extension StandingScene {
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
            if has(.structureCutCells),
                structures.flatMap(\.solids).contains(where: {
                    simd_distance(gauge.position, simd_clamp(gauge.position, $0.min, $0.max))
                        <= inputs.cellSize
                })
            {
                bands.note =
                    "Beside a structure's cut cells, while the reflected bands were derived on whole cells: its "
                    + "faces read higher on coarse air (structural-model.md, \"Coupling to the air\")."
                return bands
            }
            if onBox && has(.wallReadGauges) {
                bands.note =
                    "Read at the wall, while the reflected bands were derived from the cell beside it: its peaks "
                    + "come nearer Kingery–Bulmash and its impulses overshoot close in (air-blast-model.md, "
                    + "\"Reflected peaks at a wall\")."
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
                    mapped
                    ? "Kingery–Bulmash on the mapped start, with afterburning, hot air and far-field faces, 100 kg "
                        + "(blastbench validate)"
                    : burning
                        ? "Kingery–Bulmash with afterburning, hot air and far-field faces, 100 kg (blastbench validate)"
                        : "Kingery–Bulmash, 100 kg surface burst (blastbench validate)"
                let document =
                    mapped
                    ? ValidationTables.mappedDocument
                    : burning
                        ? ValidationTables.burningDocument
                        : "validation.md#kingerybulmash-the-design-practice-standard"
                let grids = ValidationTables.grids
                let distances = ValidationTables.distances
                if onBox {
                    bands.peak = band(
                        mapped
                            ? ValidationTables.mappedReflectedPeak
                            : burning
                                ? ValidationTables.burningReflectedPeak : ValidationTables.reflectedPeak,
                        grids,
                        distances, measure: .peakOverpressure,
                        quantity: "Reflected peak overpressure", check: check, document: document,
                        low: "peaks smeared over cells")
                    bands.impulse = band(
                        mapped
                            ? ValidationTables.mappedReflectedImpulse
                            : burning
                                ? ValidationTables.burningReflectedImpulse
                                : ValidationTables.reflectedImpulse,
                        grids,
                        distances, measure: .impulse, quantity: "Reflected impulse", check: check,
                        document: document,
                        low: "under-read")
                } else {
                    bands.peak = band(
                        mapped
                            ? ValidationTables.mappedIncidentPeak
                            : burning ? ValidationTables.burningIncidentPeak : ValidationTables.incidentPeak,
                        grids,
                        distances,
                        measure: .peakOverpressure, quantity: "Incident peak overpressure", check: check,
                        document: document, low: "peaks smeared over cells")
                    bands.impulse = band(
                        mapped
                            ? ValidationTables.mappedIncidentImpulse
                            : burning
                                ? ValidationTables.burningIncidentImpulse : ValidationTables.incidentImpulse,
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

    /// `bands(for:)`'s case .peakOverpressure, .impulse.
    func airBands(for kind: ResultKind, bands: inout [ErrorBand], unbanded: inout [String]) {
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
        // The vented bands are FM Global's chamber's: a room with a vent panel, the flame not sped up
        // by a fitted factor or congestion, and peak pressures only.
        let ventedRoom =
            !(inputs.scenario.ventPanels ?? []).isEmpty && !has(.congestion)
            && (inputs.scenario.deflagration?.acceleration.factor ?? 1) == 1
        if has(.deflagration), kind == .impulse {
            unbanded.append("A deflagration's impulse was not compared; its vented peaks were.")
        } else if has(.deflagration), !ventedRoom {
            unbanded.append(
                "Peak pressure: compared only in a vented room on the unscaled flame; this cloud is open, "
                    + "congested or its flame sped up by a fitted factor.")
        } else if has(.deflagration), inputs.scenario.deflagration?.gas == .hydrogen {
            let lewis = inputs.scenario.deflagration?.acceleration.thermodiffusive != nil
            // With the 1/Le response the model has been 1.24–2.96 in FM Global's chamber, the safe
            // side, but 0.19–0.45 in HySEA's containers vented through their roofs, the unsafe
            // side; the standing cannot tell those vents apart, so the band spans both.
            var band = figure(
                lewis ? "ventedHydrogen" : "ventedHydrogenWithoutLewis", .ventedPressure,
                "Peak pressure in a vented room, lean hydrogen",
                low: "flame too slow", high: "over-read",
                validity: lewis
                    ? "FM Global's 63.7 m³ chamber, 12.1–19.7% hydrogen lit in the middle and at the back "
                        + "wall, 0.1 m cells, with the flame's 1/Le response, nothing fitted: 1.24–2.96, the "
                        + "safe side; HySEA's containers vented through their doors within their scatter, "
                        + "through their roof 0.19–0.45, the unsafe side"
                    : "FM Global's 63.7 m³ chamber, 12.1–19.7% hydrogen lit in the middle and at the back "
                        + "wall, 0.1 m cells; lean hydrogen's measured growth law, without the flame's "
                        + "thermodiffusive response",
                check: "Bauwens, Chao and Dorofeev's vented lean hydrogen")
            if lewis {
                band.low = ValidationTables.figure("ventedHydrogenRoof").low
                band.check = "Bauwens, Chao and Dorofeev's vented lean hydrogen, and HySEA's containers"
            }
            bands.append(band)
        } else if has(.deflagration), inputs.scenario.deflagration?.gas == .townGas {
            unbanded.append(
                "Peak pressure in a vented room: town gas was compared only in a closed sphere and against "
                    + "Ronan Point's estimate, not vented.")
        } else if has(.deflagration) {
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
    }
}
