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
                    + "velocity 20 to 80 times the measured.",
                document: "ground-shock.md#the-soil-column")
        case .halfSpace:
            return Entry(
                title: "Half-space", affects: [.groundShock], limit: .illustrative,
                note:
                    "An axisymmetric half-space under the charge, elastic or with soil that yields, driven by "
                    + "the air's ground pressures and a direct source; checked against Lamb's problem, Cole and "
                    + "Huth's moving load, Haskell's dispersion and the bilinear column; against Xia's 1 t burst "
                    + "still far too high in the vertical.",
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
                + "against one measured surface burst, its vertical velocity 15 to 90 times too high (the safe "
                + "side), its horizontal within one and a half (elastic) to two and a half (yielding) times "
                + "at 21 m but 10 to 20 times too high at 42 m.",
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
                    + "one measured surface burst, its vertical velocity 20 to 80 times too high (the safe side), "
                    + "while the horizontal motion that dominated it is not modelled (the unsafe side)."
                : "The design manuals' one-dimensional air-induced ground shock; against one measured surface "
                    + "burst, its vertical velocity 20 to 80 times too high (the safe side), while the horizontal "
                    + "motion that dominated it is not modelled (the unsafe side).",
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
                        "ground-shock.md#against-measured-ground-motion")
                ],
            assumptions: [
                "Away from the charge only; no direct-induced shock or crater.",
                "No motion carried by the ground's own wave where it outruns the air, which dominated the one "
                    + "measured test.",
                "The ground stays rigid for the air.",
                "Not for design, buried services or vibration limits.",
            ], documents: ["ground-shock.md#limitations"])
    }
}
