import Foundation
import simd

// Building envelopes' bands and figures.
// Split from ErrorBands.swift (emmettl/bombcad-work#50); see that file for the types.

extension ValidationTables {
    /// Building envelopes' figures. Part of `figures`, in its order.
    static let envelopeFigures: [Figure] = [
        Figure(
            id: "envelopeGlassBreak", low: 0.82, high: 1.07, document: "validation.md#window-glass",
            quote: "0.82–1.07 of the measured time"),
        Figure(
            id: "envelopeConcreteFixed", low: 0.61, high: 1.03,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "0.61/1.19", "1.03/1.87"),
        Figure(
            id: "envelopeConcreteSimple", low: 1.19, high: 1.87,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "0.61/1.19", "1.03/1.87"),
        Figure(
            id: "envelopeSlabMeasured", low: 0.97, high: 2.59,
            document: "building-envelopes.md#slabs-held-on-their-edges",
            quote: "reads 0.97–2.59 of the"),
        Figure(
            id: "envelopeSlabCloseIn", low: 0.45, high: 1.42,
            document: "building-envelopes.md#slabs-held-on-their-edges",
            quote: "Wu's slabs at 0.45–1.42 simply supported"),
        Figure(
            id: "envelopeBrick", low: 0.82, high: 2.54,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "(0.82–2.54)"),
        Figure(
            id: "envelopeInsideFill", low: 0.75, high: 1.60,
            document: "building-envelopes.md#one-way-damage-single-degree-of-freedom",
            quote: "(0.75–1.60 times the"),
        Figure(
            id: "envelopeInsideVented", low: 0.31, high: 1.22,
            document: "validation.md#inside-buildings-against-ufc-3-340-02s-loads-through-openings",
            quote: "0.31 to 0.58", "1.03 to 1.22 in the deep one"),
        Figure(
            id: "envelopeInsideFillUFC", low: 0.15, high: 0.42,
            document: "validation.md#inside-buildings-against-ufc-3-340-02s-loads-through-openings",
            quote: "0.15 to 0.42 of the UFC's back-wall load"),
    ]
}

extension StandingScene {
    /// `bands(for:)`'s case .envelopeExposure.
    func envelopeExposureBands(bands: inout [ErrorBand], unbanded: inout [String]) {
        let mass = Double(inputs.scenario.charge.mass)
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
    }

    /// `bands(for:)`'s case .envelopeDamage.
    func envelopeDamageBands(bands: inout [ErrorBand], unbanded: inout [String]) {
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
                "envelopeSlabMeasured", .peakDeflection,
                "Concrete panel deflection against measurement, simply supported, measured load",
                low: "too stiff", high: "too soft",
                validity:
                    "one-way 102 mm slabs under the blast load simulator's measured loads, 37–109 MPa; "
                    + "the fixed bound reads a tenth or less, so the measured lies between",
                check: "The contest slab and Reynolds's six"),
            figure(
                "envelopeSlabCloseIn", .peakDeflection,
                "Concrete panel deflection against measurement, simply supported, the model's close-in load",
                low: "too stiff", high: "too soft",
                validity:
                    "100 mm slabs on two edges, 0.2–1.6 kg at 0.43 m/kg^(1/3), the load the model's air",
                check: "Wu et al.'s slabs"),
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
        // The inside's walls against UFC 3-340-02's loads through openings: the air's, glazing
        // vented, or the one-way fill's, which stands in where venting cannot run.
        let ufc = "UFC 3-340-02 §2-15.4's loads on the walls inside"
        let box = "a rigid box struck head-on through an open front window, 14–23% of the wall, 2–16 psi"
        if inputs.ventsGlazing && inputs.scenario.hasEnvelopePanes {
            bands.removeAll { $0.quantity == "Inside peak through broken panes" }
            bands.append(
                figure(
                    "envelopeInsideVented", .insidePressure,
                    "Peak pressure on the walls inside, glazing vented",
                    low: "under-read", high: "over-read", validity: box, check: ufc))
        } else if inputs.scenario.hasEnvelopePanes {
            bands.append(
                figure(
                    "envelopeInsideFillUFC", .insidePressure,
                    "Peak pressure on the walls inside, one-way fill", low: "under-read",
                    high: "over-read",
                    validity: box, check: ufc))
        }
        unbanded.append("Roofs, and walls beside a failing one, go beyond both concrete bounds: no band.")
        // Each band only where the scene has its construction (walls or roof), panes for glass.
        let kinds = Set(
            inputs.scenario.envelopeObjects.flatMap { object -> [EnvelopeConstruction.Kind] in
                let construction = inputs.scenario.envelopeConstruction(for: object.id)
                return [construction.walls, construction.roof]
            })
        let concrete = kinds.contains(.reinforcedConcrete) || kinds.contains(.reinforcedBlockwork)
        let concreteBands: Set<String> = [
            "Concrete wall rotation, fixed edges", "Concrete wall rotation, simply supported edges",
            "Concrete panel deflection against measurement, simply supported, measured load",
            "Concrete panel deflection against measurement, simply supported, the model's close-in load",
        ]
        if !concrete {
            bands.removeAll { concreteBands.contains($0.quantity) }
            unbanded.removeAll { $0.hasPrefix("Roofs, and walls beside a failing one") }
        }
        if !kinds.contains(.unreinforcedMasonry) {
            bands.removeAll { $0.quantity == "Brick wall rotation" }
        }
        if !inputs.scenario.hasEnvelopePanes {
            bands.removeAll { $0.quantity == "When a pane breaks" || $0.quantity.contains("panes") }
        }
        if kinds.contains(.profiledSteelSheeting) {
            unbanded.append(
                "Profiled steel sheeting, by UFC's cold-formed panel method on the middle strip of its ribs: "
                    + "an approximation, no band. Against ADBLAST's ten screwed cladding shots it reads "
                    + "0.65–1.09 of the measured deflection, and its screws held as measured.")
        }
        if kinds.contains(.crossLaminatedTimber) {
            unbanded.append(
                "Cross-laminated timber, one way and graded by TR-18-06.2's ductility limits: no test of a "
                    + "CLT envelope's damage level compared; Tyndall's buildings were compared with the "
                    + "detailed model.")
        }
        if inputs.scenario.envelopeObjects.contains(where: {
            inputs.scenario.envelopeConstruction(for: $0.id).laminate != nil
        }) {
            unbanded.append(
                "Laminated glass once cracked, held or gone: compared with Osnes's, Zhang's and Hooper's panes "
                    + "(building-envelopes.md#laminated-glass), no band; its cracking is the annealed glass's."
            )
        }
        if inputs.scenario.envelopeObjects.contains(where: {
            inputs.scenario.envelopeConstruction(for: $0.id).film != nil
        }) {
            unbanded.append(
                "Security film once the glass cracks, held or gone by its anchorage: graded against the open "
                    + "GSA reports' filmed panes (building-envelopes.md#security-film), no band."
            )
        }
        if inputs.scenario.envelopeObjects.contains(where: {
            inputs.scenario.envelopeConstruction(for: $0.id).wallLiner != nil
        }) {
            unbanded.append(
                "Polyurea liners on masonry: compared with one lined wall's shots (Ciornei), no band; the "
                    + "masonry under them does not arch (building-envelopes.md#polyurea-liners-on-masonry)."
            )
        }
        let freestanding = inputs.scenario.envelopeObjects.contains { object in
            object.envelope?.components(owner: object.id).contains(where: \.isFreestanding) ?? false
        }
        if freestanding {
            unbanded.append(
                "Freestanding walls are judged as cantilevers from their foot, outside these bands (derived "
                    + "on panels held on their edges); compared with Alsubaei's and Keys's measured walls "
                    + "instead (building-envelopes.md#freestanding-walls).")
        }
    }
}
