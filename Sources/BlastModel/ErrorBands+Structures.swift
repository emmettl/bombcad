import Foundation
import simd

// The structures' bands and figures.
// Split from ErrorBands.swift (emmettl/bombcad-work#50); see that file for the types.

extension ValidationTables {
    /// The structures' figures: slabs, beams, close-in damage and debris. Part of `figures`, in its order.
    static let structureFigures: [Figure] = [
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
            id: "wuLargeToday", low: 0.90, high: 1.19,
            document: "validation.md#slabs-with-steel-in-both-faces",
            quote: "0.90 and 1.19 times the measured peak"),
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
    ]

    /// Footings rocked and shaken. Part of `figures`, in its order.
    static let foundationFigures: [Figure] = [
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
    ]
}

extension StandingScene {
    /// `bands(for:)`'s case .structuralResponse.
    func structuralResponseBands(bands: inout [ErrorBand], unbanded: inout [String]) {
        let mass = Double(inputs.scenario.charge.mass)
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
                        + "rising 50 mm, left 27 mm up, against 48 and 25 on the ideal gas; with the open "
                        + "faces at the clearance rule, 47 and 25",
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
                                + "on the mapped start with the open faces at the clearance rule, 16.2 and 16.6 mm in "
                                + "all three roundings against 18.0 and 13.9 (16.3–16.5 in the harness's box on the "
                                + "balloon, 16.1–16.3 on the ideal gas), the record's earlier −20% to +7% from an older "
                                + "build",
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
                                + "charges leave 110–196 mm against 340 and 510, P7 121 mm on the mapped start",
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
    }

    /// `bands(for:)`'s case .structuralDamage.
    func structuralDamageBands(bands: inout [ErrorBand], unbanded: inout [String]) {
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
    }
}
