import Foundation
import simd

// Hazards: the standing's entries, fields and results for freestanding objects' and fragments' part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of freestanding objects' and fragments' options; `entry(for:)` sends them here.
    static func hazardEntry(for option: ModelOption) -> Entry {
        switch option {
        case .freestandingBoxes:
            return Entry(
                title: "Freestanding boxes", affects: [.freestandingMotion], limit: .verified,
                note: "Rigid boxes checked against statics, contact mechanics and theory.",
                document: "freestanding-objects.md#checks")
        case .freestandingCars:
            return Entry(
                title: "Simplified cars", affects: [.freestandingMotion], limit: .illustrative,
                note: "An illustrative saloon on locked tyres with rigid suspension.",
                document: "freestanding-objects.md")
        default:
            preconditionFailure("\(option) is not one of freestanding objects' and fragments' options")
        }
    }

    /// The fields of freestanding objects' and fragments' inputs; part of `fields`.
    static let hazardFields: [String: Field] = [
        "FragmentSpec.casingMass": .input,
        "FragmentSpec.count": .input,
        "FragmentSpec.casing": .input,
        "FragmentSpec.axis": .input,
        "FragmentSpec.spread": .input,
        "FragmentSpec.gurneyVelocity": .input,
        "FragmentSpec.fragmentDensity": .input,
        "FragmentSpec.tracers": .input,
        "FragmentSpec.tracerRegion": .input,
        "FragmentSpec.seed": .numerical,
        "FragmentSpec.wallThickness": .input,
        "FragmentSpec.innerDiameter": .input,
        "FragmentSpec.explosive": .input,
        "FragmentSpec.mottCoefficient": .input,
        "FragmentSpec.massExponent": .input,
    ]
}

extension StandingScene {
    func freestandingMotion() -> ResultStanding {
        // A car's gap to the ground off the motion run's cell faces: taken a cell narrower or
        // wider, which can turn its overturning (freestanding-objects.md).
        let gaps = FreestandingMotion.unresolvedGaps(scenario: inputs.scenario).map { gap in
            String(
                format:
                    "%@'s %.2f m gap to the ground lies between the faces of the motion run's %.3g m cells (%@): "
                    + "whether it overturns may differ on finer cells.",
                gap.name, gap.gap, gap.cell, gap.reason)
        }
        return result(
            .freestandingMotion, .verified,
            "Checked against statics, contact mechanics and theory; nothing compared with a blast test.",
            evidence: [
                StandingEvidence(
                    "Still air, flight and contact checks",
                    "No load in still air; contact conserves momentum to 1 "
                        + "part in 10⁹; reruns bit-identical", "freestanding-objects.md#checks")
            ],
            assumptions: [
                "Computed apart from the ordinary run, on air cropped around the objects.",
                "Every object takes the air's load on fine cells around it; objects that touch share whole "
                    + "cells.",
                "The air's load after about 0.4 s, with an object steeply tilted, is not converged.",
                "Furniture is solid boxes.",
            ], resolution: gaps,
            documents: [
                "freestanding-objects.md#limitations-and-future-work"
            ]
                + (gaps.isEmpty
                    ? []
                    : ["freestanding-objects.md#which-outcomes-the-whole-cell-outline-flips-20-october-2026"])
        )
    }

    func fragments() -> ResultStanding {
        let evidence = [
            StandingEvidence(
                "Cooper's worked examples 27.7 and 27.8 (Mott's counts, Gurney's speed)",
                "The same, to rounding",
                "fragments.md#against-coopers-data"),
            StandingEvidence(
                "Cooper's Fig. 27.13: a cast-iron aerial bomb's counted fragments, 0.13 to 8.8 g",
                "Mott's form within a factor of 1.36 (rms), too many small and too many of the largest; "
                    + "Grady's exponential (massExponent 1) within 1.12", "fragments.md#against-coopers-data"),
            StandingEvidence(
                "Hansche and Rinehart's measured drag of tumbling cubes, Mach 0.5 to 3.5 (as Moxnes et al. 2017 restate it)",
                "The drag curve itself; Hoerner's fixed orientations (Cooper's Figs. 27.15–27.18) put the "
                    + "distance to 79 J 30% shorter to 50% longer", "fragments.md#against-coopers-data"),
            StandingEvidence(
                "UFC 3-340-02's worked Examples 4A-10 to 4A-12 (fragments into concrete), and its steel "
                    + "plate equation against THOR's mild steel",
                "The examples within 1%; the two steel methods' speeds to perforate within 2%; no "
                    + "penetration test compared", "fragments.md#what-fragments-do-to-what-they-strike"),
            StandingEvidence(
                "DoD 4145.26-M's hazardous fragment distances for single items in the open, from DDESB's test "
                    + "protocol (a 155 mm projectile 126.5 m, a 500 lb bomb 204.2 m), the items from public totals",
                "0.58–1.02 and 0.77–1.02 in flight, short (the unsafe side) to level, as the walls assumed go "
                    + "from thick to thin; landings on the ground alone would be a sixth to a fifteenth",
                "fragments.md#against-dods-distances"),
            StandingEvidence(
                "DDESB Technical Paper 12 (Zaker, 1975): its density on a surface normal to the rays, its "
                    + "procedure, and Sternberg's steel cylinders' masses (its Table 1)",
                "Its procedure on the same fragments gives 1.05–1.21 times the flown distance (it lets no "
                    + "fragment fall); Mott's scaling with Cooper's B gives 1.00–1.36 times the mean mass of "
                    + "Sternberg's fragments over a grain", "fragments.md#against-ddesb-tp-12"),
        ]
        let shared = [
            "One way: fragments do not push back on the air or the structure, and stop where they first hit.",
            "Tumbling cubes of the casing's steel, no break-up or ricochet. What they strike is judged one "
                + "way by UFC 3-340-02 (concrete; masonry as concrete of its strength, for want of its own "
                + "method), THOR (metal plates) and a measured breaking momentum (glass); a fragment stops at "
                + "the first surface, through or not, and does not load it.",
            "Hazard distance: the DDESB's, where fragments of 79 J or more fall below one per 55.7 m² on a "
                + "surface across their paths near the horizontal (or on open ground, if further), in 8 directions; "
                + "0.58–1.02 of DoD's test-derived distances for two items, up to two-fifths short (the unsafe "
                + "side), the casing's wall deciding; no fragment-by-fragment arena data compared.",
        ]
        guard inputs.fragments?.mottFactor != nil else {
            return result(
                .fragments, .illustrative,
                "Their number is chosen, not derived: give the casing's thickness and diameter for Mott's.",
                evidence: evidence,
                assumptions: ["The number of fragments is the description's, sharing the casing's mass."]
                    + shared,
                documents: ["fragments.md#limitations"])
        }
        return result(
            .fragments, .approximation,
            "Mott's masses and number, Gurney's speed and measured drag: the recognised method, checked against "
                + "Cooper's data; no arena test of speeds or ranges.",
            evidence: evidence,
            assumptions: [
                "Mott's B for mild steel cylinders, Cooper's Table 27.2; other metals and shapes are not covered."
            ] + shared, documents: ["fragments.md#limitations"])
    }

    func blastInjury() -> ResultStanding {
        result(
            .blastInjury, .approximation,
            "Published injury curves applied to the run's own peaks at standing height, and the safety "
                + "standards' K-factor distances beside them: policy distances, not predictions.",
            evidence: [
                StandingEvidence(
                    "Teland's 50% lethality distances by Bass's and Bowen's curves for 0.5–1,500 kg of TNT "
                        + "(FFI-rapport 2012/00539, Table 12.1)",
                    "Within 6% and 5% from the Kingery–Bulmash free field", "hazards.md#checks"),
                StandingEvidence(
                    "10 kg on open ground, the run's own peaks at 1.5 m on 0.25 m cells against the free field",
                    "The eardrums' reach 0.87–0.88 of it; the lungs' 0.69 and, for 50% lethality, 0.48: close in "
                        + "the cells' peaks read low (the unsafe side)", "hazards.md#checks"),
                StandingEvidence(
                    "Envelope debris against Keys's brick walls (2016) and the Kasun cubicle (80 kg inside)",
                    "Keys: the debris's mean reach 0.31–0.59 m against 0.23–0.64 m, its far tail short (1.0–1.5 m "
                        + "against 3–6 m); Kasun: launched at up to 118–131 m/s against the Klotz Group's 124 m/s, "
                        + "its walls venting the gas, but hazardous debris to 129 m against the tests' 290–315 m, "
                        + "the unsafe side (DoD's structure distance, 268 m, governs); Kasun III's launch "
                        + "speeds 44–49 m/s against 52 measured (6.9 kg PETN), 171–192 against 224 (110 kg)",
                    "hazards.md#debris-from-failed-envelope-components"),
            ],
            assumptions: [
                "The curves come from animal tests under ideal (Friedlander) pulses, scaled to a 70 kg adult; "
                    + "the run's pulses, reflected and channelled, are taken as triangular, their duration twice "
                    + "the impulse over the peak.",
                "Eardrums by UFC 3-340-02 (5 and 15 psi); the lung's threshold by Bowen (a fifth of his 50% "
                    + "lethality), 50% lethality by Bass (under 30 ms); no tertiary injury from being thrown.",
                "A person standing in the open, or against a wall facing the charge, which sees the reflected "
                    + "pressure; probes beside a solid are not read.",
                "K-factor distances (DoD 4145.26-M) are for a bare charge in the open, whatever the scene; the "
                    + "minimum safe distance is never shorter than K40, for a cased charge DoD's default "
                    + "fragment distance, and for a charge inside a building DESR 6055.09's structure debris "
                    + "distance; BombCAD's fragment and envelope debris distances, which read short, are estimates "
                    + "beside them.",
                "Envelope debris: each failed component's pieces leave at its one-way model's speed at failure "
                    + "(UFC 3-340-02 §4-58.2.1) over its mechanism's shape, square to its sections as turned; "
                    + "what each construction breaks into is assumed, and pieces neither bounce nor roll.",
                "Not for medical triage or casualty estimates.",
            ], documents: ["hazards.md#limitations"])
    }
}
