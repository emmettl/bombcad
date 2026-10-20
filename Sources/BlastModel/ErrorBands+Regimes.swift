import Foundation
import simd

// The advice on options by the scene's regime.
// Split from ErrorBands.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingScene {
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
            if let pitch = inputs.scenario.congestion?.map(\.pitch).min() {
                // Congestion's grid (docs/congestion-model.md#merge): cells no larger than the pitch.
                let suits = inputs.cellSize <= pitch * 1.01
                add(
                    "Congestion's cells", suits,
                    suits
                        ? "Cells no larger than the arrays' pitch: against MERGE's rigs the peaks moved by under a "
                            + "third as the cells halved, the finer pitches within 0.43 to 1.16 of the measured and "
                            + "the coarser 2.8 to 5.2 times high."
                        : "Cells larger than the arrays' pitch count more obstacles each: against MERGE's rigs the "
                            + "peak grew five to twelve times as the cells went from 0.6 to 2.5 pitches across.",
                    suits
                        ? nil
                        : String(format: "Use cells of %.2f m or less, the arrays' smallest pitch.", pitch),
                    "congestion-model.md#merge")
            }
            guard !has(.deflagration) else { return advice }
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
        case .collapse, .envelopeExposure, .envelopeDamage, .freestandingMotion, .thermal, .surfaceHeating,
            .cloud,
            .fragments, .groundShock, .crater, .blastInjury:
            break
        }
        return advice
    }
}
