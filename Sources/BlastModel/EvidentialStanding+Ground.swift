import Foundation
import simd

// Ground: the standing's entries, fields and results for the ground shock's part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of the ground shock's options; `entry(for:)` sends them here.
    static func groundEntry(for option: ModelOption) -> Entry {
        switch option {
        case .soilColumn:
            return Entry(
                title: "Layered soil column", affects: [.groundShock], limit: .illustrative,
                note: "A layered soil column under each point, solved through the ground's overpressure "
                    + "history; checked against closed-form solutions; against Xia's 1 t burst its vertical "
                    + "velocity 20 to 80 times the measured, under Prairie Flat's 500 t a fifth of it near the "
                    + "surface.",
                document: "ground-shock.md#the-soil-column")
        case .halfSpace:
            return Entry(
                title: "Half-space", affects: [.groundShock], limit: .illustrative,
                note:
                    "An axisymmetric half-space under the charge, elastic or with soil that yields, driven by "
                    + "the air's ground pressures and a direct source; checked against Lamb's problem, Cole and "
                    + "Huth's moving load, Haskell's dispersion and the bilinear column; against Xia's 1 t burst "
                    + "still far too high in the vertical; past Prairie Flat's outrunning limit within two times.",
                document: "ground-shock-outrunning.md")
        default:
            preconditionFailure("\(option) is not one of the ground shock's options")
        }
    }

    /// The fields of the ground shock's inputs; part of `fields`.
    static let groundFields: [String: Field] = [
        "GroundShockSpec.soil": .input,
        "GroundShockSpec.points": .input,
        "GroundShockSpec.line": .input,
        "GroundShockSpec.depths": .input,
        "GroundShockSpec.arrivalThreshold": .input,
        "GroundShockSpec.origin": .input,
        "GroundShockSpec.model": .option([.soilColumn, .halfSpace]),
        "GroundShockSpec.halfSpace": .input,
        "GroundShockSpec.profile": .input,
        "GroundSoil.density": .input,
        "GroundSoil.waveSpeed": .input,
    ]
}

extension StandingScene {
    func crater() -> ResultStanding {
        result(
            .crater, .approximation,
            "Cooper's cube-root scaling for the apparent crater's radius by soil and height of burst, with "
                + "Kinney and Graham's one-sigma scatter of a third; the depth is a rule of thumb, slumped below a "
                + "shallow water table.",
            evidence: [
                StandingEvidence(
                    "Six measured craters: three 500-ton TNT shots at Suffield, Sailor Hat, Minor Scale and Beirut",
                    "Five of six apparent diameters within a third (the Suffield shots 1.04–1.26); the three wet "
                        + "sites' depths 0.84–1.41 of the estimate with the water table near the surface",
                    "cratering.md#against-measured-craters")
            ],
            assumptions: [
                "The crater does not act on the blast: it forms after the blast has gone, so the air keeps the "
                    + "ground as it was.",
                "Bursts on or above the ground, not buried ones.",
                "Depth and lip are rules of thumb; below a water table the walls are taken to slump to 10–15°, "
                    + "and flowing fill can leave a shallower crater still.",
            ], documents: ["cratering.md#limitations"])
    }

    func halfSpaceGroundShock() -> ResultStanding {
        result(
            .groundShock, .illustrative,
            "A half-space about the charge, checked against Lamb's problem, Cole and Huth and Haskell; "
                + "against Xia's 1 t burst its vertical velocity 15 to 90 times too high (the safe side), its "
                + "horizontal within one and a half to two and a half times at 21 m but 10 to 20 times too high "
                + "at 42 m; against Prairie Flat's 500 t, past where the ground's wave outran the air, the motion "
                + "ahead of the blast within a factor of two at 15 of 16 records, banded at a factor of three, "
                + "but inside it within two at only 21 of 34.",
            evidence: [
                StandingEvidence(
                    "The axisymmetric solver against Lamb's problem, Cole and Huth's moving load and Haskell's "
                        + "Rayleigh dispersion",
                    "Within 8% of Lamb's surface pulse; 5–8% behind a superseismic front; 4% in phase speed",
                    "ground-shock-outrunning.md#stage-1-the-solver-and-its-checks"),
                StandingEvidence(
                    "Xia et al.'s 1 t surface burst, 0.5 m deep at 21 and 42 m",
                    "Vertical 15–60 times the measured accelerations' integral; horizontal 1.5 times at 21 m, "
                        + "15–20 times at 42 m",
                    "ground-shock-outrunning.md#stage-2-against-xia-et-al"),
                StandingEvidence(
                    "Soil that yields, against the bilinear column and the same burst",
                    "The column within 4–6%; at Xia's gauges vertical 16–90 times, horizontal 2.1–2.4 times at "
                        + "21 m and 10–11 times at 42 m; falling as R^(-1.5) against the measured R^(-3.3) to "
                        + "R^(-3.8)",
                    "ground-shock-outrunning.md#stage-3-soil-that-yields"),
                StandingEvidence(
                    "Prairie Flat, 500 t of TNT on two measured layers, 84 to 1,150 ft out and 1.5 to 17 ft deep",
                    "Past the outrunning limit, peaks down and out within three times at all 16 records, a "
                        + "geometric mean of 1.15; inside it, within two at 21 of 34 vertical records, a third of "
                        + "the measured 1.5 ft down",
                    "ground-shock-outrunning.md#against-prairie-flat-20-october-2026"),
            ],
            assumptions: [
                "Axisymmetric about the charge: no buildings or terrain. Elastic unless its layers are given "
                    + "a friction angle or unloading speed; then compaction and a Mohr–Coulomb cone, untested "
                    + "against measured soil.",
                "The charge's direct source: on elastic soil calibrated once against UFC 3-340-01 at "
                    + "8 ft/lb^(1/3), its waves falling away as r^(-1/2) against UFC's r^(-2.5); on yielding soil "
                    + "the crater's share of the energy, within 0.3–1.7 times UFC from 4 to 16 ft/lb^(1/3).",
                "One way: the ground stays rigid for the air.",
                "Not for design, buried services or vibration limits.",
            ], documents: ["ground-shock-outrunning.md"])
    }

    func groundShock() -> ResultStanding {
        let column = has(.soilColumn)
        if has(.halfSpace) { return halfSpaceGroundShock() }
        return result(
            .groundShock, .illustrative,
            column
                ? "A layered soil column under each point, checked against closed-form solutions; against "
                    + "Xia's 1 t burst, its vertical velocity 20 to 80 times too high (the safe side), the horizontal "
                    + "motion that dominated it not modelled (the unsafe side); under Prairie Flat's 500 t, where "
                    + "it claims to hold, within a factor of two at 13 of 34 records, a fifth of the measured 1.5 "
                    + "ft down (the unsafe side), its arrivals within 10%."
                : "The design manuals' one-dimensional air-induced ground shock; against Xia's 1 t burst, its "
                    + "vertical velocity 20 to 80 times too high (the safe side), the horizontal motion that "
                    + "dominated it not modelled (the unsafe side); under Prairie Flat's 500 t, where it claims to "
                    + "hold, within a factor of two at 14 of 34 records, a fifth of the measured 1.5 ft down (the "
                    + "unsafe side), its arrivals within 10%.",
            evidence: (column
                ? [
                    StandingEvidence(
                        "Uniform, layered and bilinear soil columns against closed-form solutions",
                        "Within 1% for pulses, reflections and resonance; 3–8% for bilinear unloading",
                        "ground-shock.md#checks")
                ] : [])
                + [
                    StandingEvidence(
                        "Xia et al.'s 1 t surface burst, 0.5 m deep at 21 and 42 m",
                        "Vertical velocity 20–30 and 50–80 times the measured accelerations' integral; "
                            + "within three times a clipped velocity gauge; the measured motion mostly horizontal",
                        "ground-shock.md#against-measured-ground-motion"),
                    StandingEvidence(
                        "Prairie Flat, 500 t of TNT, 84 to 400 ft out where the air outran the ground, 1.5 to 17 ft "
                            + "deep",
                        "Vertical within two times at 13–14 of 34 records: 0.15–0.29 of the measured 1.5 ft down, "
                            + "1.0–2.3 at 17 ft; arrivals within 10% at 18–20 of 24",
                        "ground-shock.md#against-prairie-flat"),
                    StandingEvidence(
                        "The same on the soil measured at Watching Hill, its loading and unloading curves by layer",
                        "Vertical within two times at 26 of 34 records (the column unloading as measured), but "
                            + "arrivals within 10% at only 6 of 24: the stress comes late at the soil's loading stiffness",
                        "ground-shock.md#on-the-soil-measured-at-watching-hill-20-october-2026"),
                ],
            assumptions: [
                "Away from the charge only; no direct-induced shock or crater.",
                "No motion carried by the ground's own wave where it outruns the air, which dominated Xia's "
                    + "test; points the wave reaches first are labelled outrun, by arrival through the layers.",
                "One loading stiffness per layer: a crushable, air-filled near surface, as at Prairie Flat, "
                    + "loads far softer than its arrival speed says.",
                "The ground stays rigid for the air.",
                "Not for design, buried services or vibration limits.",
            ], documents: ["ground-shock.md#limitations"])
    }
}
