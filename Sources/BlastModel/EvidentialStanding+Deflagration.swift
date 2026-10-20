import Foundation
import simd

// Deflagration: the standing's entries, fields and results for a gas deflagration's part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of a gas deflagration's options; `entry(for:)` sends them here.
    static func deflagrationEntry(for option: ModelOption) -> Entry {
        let structure: [ResultKind] = [.structuralResponse, .structuralDamage, .collapse]
        let air: [ResultKind] = [.peakOverpressure, .impulse]
        switch option {
        case .deflagration:
            return Entry(
                title: "Gas deflagration", affects: air + structure + [.envelopeExposure],
                limit: .illustrative,
                note: "A methane or propane cloud's flame: checked against the thin-flame model in a closed "
                    + "vessel and wrinkled by sub-grid turbulence and its measured cellular instability; in FM "
                    + "Global's vented chamber it reaches 0.9–1.8 times the tests' peaks lit at the back wall, "
                    + "0.4–0.6 lit in the middle, and below the (conservative) venting correlations. An open, "
                    + "congested cloud, as at a process plant, has been compared with no test: congestion speeds "
                    + "real flames to hundreds of metres a second, beyond what it resolves.",
                document: "deflagration.md#limitations")
        case .congestion:
            return Entry(
                title: "Congestion below the grid", affects: air + structure + [.envelopeExposure],
                limit: .illustrative,
                note:
                    "Pipes and bars too small for the cells take room, resist the air, make turbulence and fold "
                    + "a flame, as PDRFoam's porous cells and sub-grid flame do. Against MERGE's rigs the finer "
                    + "pitches come within 0.4 to 1.2 of the measured peaks but the coarser three to five times "
                    + "too high, half the pitch giving no more where MERGE's gave seven times.",
                document: "congestion-model.md")
        case .ventPanels:
            return Entry(
                title: "Vent panels", affects: air + structure + [.envelopeExposure], limit: .approximation,
                note: "Massless, instantaneous; verified only to open at the release pressure.",
                document: "deflagration.md#vent-panels")
        default:
            preconditionFailure("\(option) is not one of a gas deflagration's options")
        }
    }

    /// The fields of a gas deflagration's inputs; part of `fields`.
    static let deflagrationFields: [String: Field] = [
        "Deflagration.gas": .input,
        "Deflagration.concentration": .input,
        "Deflagration.region": .input,
        "Deflagration.ignition": .input,
        "Deflagration.acceleration": .option([.deflagration]),
        "FlameAcceleration.factor": .option([.deflagration]),
        "FlameAcceleration.instability": .option([.deflagration]),
        "FlameAcceleration.externalFactor": .option([.deflagration]),
        "FlameAcceleration.turbulence": .option([.deflagration]),
        "FlameAcceleration.thermodiffusive": .option([.deflagration]),
        "FlameAcceleration.initialTurbulence": .option([.deflagration]),
        "FlameAcceleration.youngFlame": .option([.deflagration]),
        "FlameTurbulence.scale": .option([.deflagration]),
        "VentPanel.box": .input,
        "VentPanel.releasePressure": .input,
    ]
}

extension StandingScene {
    /// The deflagration's checks: no charge fires, so the comparisons with Kingery–Bulmash do not
    /// apply.
    /// Hydrogen's and town gas's own comparisons, where the scene burns them.
    private func fuelEvidence(_ gas: FlammableGas?) -> [StandingEvidence] {
        switch gas {
        case .hydrogen?:
            return [
                StandingEvidence(
                    "FM Global's 63.7 m³ chamber, lean hydrogen of 12.1–19.7% (Bauwens, Chao and Dorofeev, 2011)",
                    "1.24–2.96 of the measured peaks with the flame's 1/Le response, nothing fitted (0.19–0.39 "
                        + "without it); in a closed sphere K_G 0.89–0.99 of the measured",
                    "deflagration.md#checks"),
                StandingEvidence(
                    "HySEA's 20 ft containers, lean hydrogen of 15% and 21% (Skjold et al., 2017)",
                    "Vented through the doors within the repeats' scatter (0.72–1.42); through the roof 0.19–0.45, "
                        + "the unsafe side",
                    "deflagration.md#checks"),
            ]
        case .townGas?:
            return [
                StandingEvidence(
                    "Town gas (Bartknecht's 60/40 hydrogen and methane) in a closed sphere",
                    "K_G about 0.77 of the measured; not compared vented", "deflagration.md#checks"),
                StandingEvidence(
                    "Ronan Point's flat on town gas, against the inquiry's estimates",
                    "12 kPa against the 21 kPa put on the flank, and nothing collapses: the unsafe side",
                    "large-panel-flats.md#against-the-inquirys-estimates"),
            ]
        default:
            return []
        }
    }

    private var deflagrationEvidence: [StandingEvidence] {
        [
            StandingEvidence(
                "A closed sphere of stoichiometric methane against the thin-flame model (blastbench "
                    + "deflagration vessel)",
                "Burns out at the AICC pressure the heat was fitted to, energy conserved to 1e-5; laminar rise "
                    + "times within 1–3% on 48 cells across the radius, the default (cellular) flame's 13–14% "
                    + "ahead; K_G 60 bar m/s against 76 on 96 cells, which a four-cell front cannot resolve "
                    + "(verified)",
                "deflagration.md#a-closed-sphere"),
            StandingEvidence(
                "A laminar flame lit at a tube's closed end",
                "Runs at the expansion ratio times the burning velocity within 10% (verified)",
                "deflagration.md#a-closed-sphere"),
            StandingEvidence(
                "Vented rooms against EN 14994, NFPA 68 and Molkov (blastbench deflagration vented)",
                "A seventh to a twenty-second of Molkov's best fit, which FM Global's tests show conservative; "
                    + "trend with vent area A^-0.9 against A^-2",
                "deflagration.md#vented-rooms-against-the-correlations"),
            StandingEvidence(
                "FM Global's 63.7 m³ chamber, Bauwens et al. 2008 (six tests, digitised)",
                "Lit at the back wall, 0.9–1.8 times the measured peaks; lit in the middle, 0.4–0.6, the "
                    + "flame stalling towards the back wall; geometric mean 0.76",
                "deflagration.md#bauwens-chaffee-and-dorofeev-2008"),
            StandingEvidence(
                "BP Texas City 2005 (CSB), a layout after it",
                "The model's own flame gives 0.01 psi at 37 m against the CSB's 2.5–2.8: congestion's "
                    + "acceleration is not resolved. With the burning velocity times 6.5, fitted there to 2.4 psi: "
                    + "3.2 psi on today's defaults, not refitted, the brick control room failing at 1.7 psi "
                    + "(1.5–2.5, heavily damaged)",
                "process-plant-explosion.md#results"),
        ]
    }

    /// Peak overpressure or impulse from a gas cloud's deflagration.
    func deflagrationResult(_ kind: ResultKind) -> ResultStanding {
        var resolution = ["Air: \(cellDescription); the flame is about four cells thick."]
        if !(inputs.scenario.ventPanels ?? []).isEmpty {
            resolution.append("Vent panels have no mass and release at once.")
        }
        if let factor = inputs.scenario.deflagration?.acceleration.factor, factor != 1 {
            resolution.append(
                "The burning velocity is raised \(String(format: "%g", factor)) times, a fit standing for what "
                    + "the model does not resolve: the pressures follow it steeply, as about its third power."
            )
        }
        let gas = inputs.scenario.deflagration?.gas
        let fuel =
            gas == .hydrogen
            ? "Lean hydrogen, with its flame's 1/Le response, reads 1.24–2.96 of FM Global's vented tests and "
                + "within the scatter of HySEA's containers vented through their doors, but 0.19–0.45 of those vented "
                + "through their roof, the unsafe side; K_G in a closed sphere 0.89–0.99 of the measured. For methane, "
            : gas == .townGas
                ? "Town gas, half hydrogen, was compared only in a closed sphere (K_G about 0.77 of the measured) "
                    + "and at Ronan Point, where the flat's 12 kPa is below the inquiry's 21 on the flank, the "
                    + "unsafe side; not vented. For methane, "
                : ""
        // Methane's comparisons, after another fuel's own where the scene burns one.
        let methane =
            "reads low, the unsafe side, where a vented room is lit in the middle: 0.4–0.6 of FM Global's "
            + "tests (0.9–1.8 lit at the back wall), the back of the flame stalling; all fall below EN 14994 "
            + "and NFPA 68, and a peak is uncertain by about ±20% on 0.1 m cells. The wrinkling's one "
            + "constant was fitted, and the instability's onset measured, in that chamber. In a closed "
            + "vessel the laminar rise times come within 1–3% of the thin-flame model, partly two errors "
            + "crossing, and K_G cannot converge on the four-cell front. An open, congested cloud (a process "
            + "plant's racks and vessels) has been compared with no test: there congestion speeds a real "
            + "flame to Mach 0.4–0.7 (Baker–Strehlow–Tang, medium to high congestion), which the flame "
            + "here does not reach, so its pressures are a lower bound, possibly several times low."
        return result(
            kind, .illustrative,
            fuel.isEmpty ? methane.prefix(1).uppercased() + methane.dropFirst() : fuel + methane,
            evidence: deflagrationEvidence + fuelEvidence(gas) + terrainEvidence,
            assumptions: [
                "Burnt and unburnt gas are treated as air; the heat released is the share of the heat of "
                    + "combustion that reaches the stoichiometric AICC pressure.",
                "The flame is wrinkled by sub-grid turbulence from the air's σ-model mixing through Bradley's "
                    + "correlation, and by its cellular instability from the onset radius measured in FM Global's "
                    + "chamber, held beyond four onset radii; a young flame is slow until it is about seventeen "
                    + "cells across.",
            ], resolution: resolution,
            documents: [
                "deflagration.md#checks", "deflagration.md#limitations",
                "process-plant-explosion.md#what-the-model-can-and-cannot-represent",
            ])
    }
}
