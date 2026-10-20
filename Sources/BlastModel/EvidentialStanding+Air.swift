import Foundation
import simd

// Air: the standing's entries, fields and results for the air's part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of the air's options; `entry(for:)` sends them here.
    static func airEntry(for option: ModelOption) -> Entry {
        let structure: [ResultKind] = [.structuralResponse, .structuralDamage, .collapse]
        let air: [ResultKind] = [.peakOverpressure, .impulse]
        switch option {
        case .afterburning:
            return Entry(
                title: "Afterburning", affects: air + [.thermal, .cloud], limit: nil,
                note: "The products burn in the air they mix with; the burning time was fitted to "
                    + "Kingery–Bulmash's incident impulse. The default, with hot air, since 15 October 2026.",
                document: "air-blast-model.md#afterburning")
        case .hotAir:
            return Entry(
                title: "Hot air", affects: air + [.thermal], limit: nil,
                note: "Air stores energy in molecular vibration, its γ falling towards 1.29 near 3000 K. The "
                    + "default, with afterburning, since 15 October 2026.",
                document: "air-blast-model.md#hot-air")
        case .dissociatingAir:
            return Entry(
                title: "Dissociating air", affects: air + [.thermal], limit: nil,
                note: "Oxygen and nitrogen also dissociate when hot; it changes little and has no "
                    + "comparison of its own.",
                document: "air-blast-model.md#dissociating-air")
        case .radiativeCooling:
            return Entry(
                title: "Gas losing what it radiates", affects: [.thermal, .cloud], limit: nil,
                note: "The luminous gas cools as the fireball's volume radiates, by default since 19 October "
                    + "2026: against a 41 kg test the fireball reaches its measured size and fades within the "
                    + "second, where without it the gas holds near 2,500 K; it still radiates more than TNT's "
                    + "measured 4–7%. The cloud's comparison with Church's was made without it, and its tops "
                    + "come down a few per cent.",
                document: "thermal-radiation.md#the-gas-losing-what-it-radiates")
        case .gravity:
            return Entry(
                title: "Gravity in the air", affects: air + [.thermal, .cloud], limit: nil,
                note: "The air rests in a hydrostatic atmosphere, still to the bit, its energy kept to 1e-6; "
                    + "a hot bubble rises within 10% of the cloud's integral model and blast loads move by "
                    + "under 0.1%. Dial Pack's fireball rises under it but stays 600 to 900 K too hot.",
                document: "air-blast-model.md#gravity")
        case .subgridMixing:
            return Entry(
                title: "Sub-grid mixing", affects: air + [.thermal, .cloud], limit: nil,
                note: "An eddy viscosity after Smagorinsky, kept out of shocks; mass and energy kept to 1e-6 "
                    + "and blast loads within 0.5%, but on metre cells it changes a mixing layer, a rising "
                    + "thermal and Dial Pack's fireball little: the grid's resolved eddies do the mixing.",
                document: "air-blast-model.md#sub-grid-mixing")
        case .afterburnLimit:
            return Entry(
                title: "Afterburning's extinction limit", affects: air + [.thermal, .cloud], limit: nil,
                note: "Products burn only above 800 K and where they could reach 1,500 K; closed rooms are "
                    + "unchanged but the open incident impulse falls by 8 to 9%, to 86–91% of Kingery-Bulmash's, and "
                    + "Dial Pack's fireball is no cooler.",
                document: "air-blast-model.md#an-extinction-limit-for-afterburning")
        case .mixedAfterburning:
            return Entry(
                title: "Mixing-limited afterburning", affects: air + [.thermal, .cloud], limit: nil,
                note:
                    "Products burn no faster than the sub-grid turbulence mixes oxygen in (an eddy-break-up "
                    + "rate), with sub-grid mixing on; judged on Dial Pack's fireball only (emmettl/bombcad-work#22).",
                document: "thermal-radiation.md#mixing-limited-afterburning-20-october-2026")
        case .shockRefinement:
            return Entry(
                title: "Shock refinement", affects: air + structure + [.envelopeExposure], limit: nil,
                note: "Air refined by 2 near the shock gives about the peaks and impulses of the uniform "
                    + "grid twice as fine.",
                document: "validation.md#with-refinement")
        case .twoLevelRefinement:
            return Entry(
                title: "Two levels of shock refinement", affects: air + structure + [.envelopeExposure],
                limit: nil,
                note: "Two levels by 2 give the peaks and impulses of a grid four times as fine, within 3%.",
                document: "validation.md#with-refinement")
        case .adaptiveSubsteps:
            return Entry(
                title: "Adaptive substeps", affects: air + structure + [.envelopeExposure], limit: nil,
                note: "Each refined level takes only the substeps its own waves need: the open blast's peaks "
                    + "move 1 to 2.5% (up, towards Kingery-Bulmash), impulses and arrivals under 1%, inside the "
                    + "6 to 8% scatter of the references; close in, where the patches hold the fastest wave, "
                    + "nothing changes.",
                document: "air-blast-model.md#refining-near-the-shock")
        case .mappedCharge:
            return Entry(
                title: "Finely resolved start", affects: air + structure + [.envelopeExposure], limit: nil,
                note:
                    "The charge mapped onto the grid from a fine one-dimensional burst, as runs start since 18 "
                    + "October 2026: from 1 m/kg^(1/3), incident peaks 83–117% of Kingery–Bulmash for 10 and 100 kg "
                    + "on 0.25–0.5 m cells and 63–99% for 1 kg, where the balloon leaves 32–84% and 11–47%, its fireball's "
                    + "mixing fitted once on 10 kg; impulses within 5–15%. The comparisons of structures, envelopes "
                    + "and rooms were "
                    + "run on the balloon start and are not yet run again on this one.",
                document: "air-blast-model.md#a-finely-resolved-start")
        case .structureFixedInAir:
            return Entry(
                title: "Structure fixed in the air", affects: air + structure, limit: .approximation,
                note: "The air sees the structure as it was at the start, so breaches do not vent; the "
                    + "comparisons coupled both ways.",
                document: "structural-model.md#coupling-to-the-air")
        case .structureCutCells:
            return Entry(
                title: "Structures' outlines as cut cells", affects: air + structure, limit: .approximation,
                note:
                    "A structure's solid outline, as built, cuts the cells it crosses on unrefined air: a wall's "
                    + "impulse follows its place within a cell to 2.6% where the whole cells step by up to 6%, but "
                    + "its peak force runs up to 12% above that line a tenth of a cell off the lattice, and on "
                    + "coarse air its faces read higher than whole cells do (1,253 against 1,032 N s on 0.25 m "
                    + "cells, 1,165 against 1,125 on 0.03 m). No measurement was compared; the comparisons ran on "
                    + "whole cells.",
                document: "structural-model.md#coupling-to-the-air")
        case .stationaryWalls:
            return Entry(
                title: "Stationary walls", affects: structure, limit: .approximation,
                note: "Moving parts do not push the air as pistons; the comparisons let them.",
                document: "structural-model.md#coupling-to-the-air")
        case .closedBoundaries:
            return Entry(
                title: "Reflecting domain faces", affects: air, limit: nil,
                note: "Faces of the domain other than the ground reflect, as walls of a closed room.",
                document: "validation.md#gas-pressure-in-a-closed-room")
        case .copiedOpenFaces:
            return Entry(
                title: "Open faces that copy", affects: air, limit: nil,
                note: "The open faces copy the air inside outward instead of standing still air beyond: "
                    + "a domain hardly bigger than the fireball traps its burning products (Wang's gauges "
                    + "3.8 times the impulse of a domain four times as wide), and one losing air drains below "
                    + "ambient. Far-field faces replaced them for every run on 15 October; the bands were derived "
                    + "with these.",
                document: "validation.md#afterburning-by-default-what-it-would-cost-and-move")
        case .terrain:
            return Entry(
                title: "Terrain",
                affects: air + structure + [
                    .envelopeExposure, .thermal, .freestandingMotion, .fragments, .groundShock,
                ],
                limit: .approximation,
                note:
                    "Rigid and smooth, cut through the cells: on 100–400 cells "
                    + "the triple point's angle within 0.25° of three-shock theory at 30–45° and Mach "
                    + "reflection 1–3° late; shielding behind ridges is consistency-checked only, and peaks "
                    + "focused far behind a round hill do not converge.",
                document: "terrain.md#limitations")
        case .terrainStaircase:
            return Entry(
                title: "Terrain as a staircase", affects: air + [.envelopeExposure], limit: .approximation,
                note:
                    "The staircase, when chosen, keeps the terrain as whole cells: it delays Mach "
                    + "reflection off a slope by 3–11° and under-reads the triple point's angle by 20–75% on "
                    + "100–400 cells, and windward faces' peaks read 1.3–1.5 times the cut cells', growing "
                    + "with resolution.",
                document: "terrain.md#cut-cells")
        case .wallReadGauges:
            return Entry(
                title: "Gauges read at the wall", affects: [.peakOverpressure, .impulse],
                limit: .approximation,
                note:
                    "A gauge within a cell of a wall reads the pressure at it (two shocks, the cell's gas against "
                    + "its mirror) instead of the cell's mean: reflected peaks 69–93% of Kingery–Bulmash on 0.25 m "
                    + "cells for 100 kg (32–88% read from the cell), but impulses 113–131% close in on 0.05 m "
                    + "cells and 119–143% on 0.02 m, as the read counts the cell's speed towards the wall as gas "
                    + "brought to rest. The reflected bands were derived from the cell's mean, so they do not apply.",
                document: "air-blast-model.md#reflected-peaks-at-a-wall")
        default:
            preconditionFailure("\(option) is not one of the air's options")
        }
    }

    /// The fields of the air's inputs; part of `fields`.
    static let airFields: [String: Field] = [
        // The air solver.
        "SolverConfiguration.bodyCouplingLayout": .numerical,
        "SolverConfiguration.bodyCouplingTileCapacity": .numerical,
        // Off, a run stops where independent bodies come close; what it gives up to there is the same.
        "SolverConfiguration.interBodyContact": .numerical,
        "SolverConfiguration.gamma": .input,
        "SolverConfiguration.cfl": .numerical,
        "SolverConfiguration.ambientPressure": .input,
        "SolverConfiguration.reflectiveFaces": .option([.closedBoundaries]),
        "SolverConfiguration.riemannSolver": .numerical,
        "SolverConfiguration.limiterTheta": .numerical,
        "SolverConfiguration.densityFloor": .numerical,
        "SolverConfiguration.pressureFloor": .numerical,
        "SolverConfiguration.startupSteps": .numerical,
        "SolverConfiguration.twoWayCoupling": .option([.structureFixedInAir]),
        "SolverConfiguration.movingWalls": .option([.stationaryWalls]),
        // Off, a structure swings under its own weight as the blast arrives; the comparisons that
        // carry their weight move by 1 mm or less with it (structural-model.md, "Settling under
        // its own weight").
        "SolverConfiguration.settlesStructures": .numerical,
        "SolverConfiguration.skipStillAir": .numerical,
        "SolverConfiguration.airModel": .option([.hotAir, .dissociatingAir]),
        "SolverConfiguration.afterburning": .option([.afterburning]),
        "SolverConfiguration.afterburnEnergy": .input,
        "SolverConfiguration.afterburnTime": .option([.afterburning]),
        "SolverConfiguration.mappedCharge": .option([.mappedCharge]),
        "SolverConfiguration.mappedChargeCells": .numerical,
        "SolverConfiguration.mappedChargeScaledReach": .numerical,
        "SolverConfiguration.mappedChargeBurns": .numerical,
        "SolverConfiguration.mappedChargeMixing": .numerical,
        "SolverConfiguration.mappedChargeProducts": .numerical,
        "SolverConfiguration.airSleepThreshold": .numerical,
        "SolverConfiguration.airSleepCrossings": .numerical,
        "SolverConfiguration.debrisReach": .numerical,
        "SolverConfiguration.openFaces": .option([.copiedOpenFaces]),
        "SolverConfiguration.structureCutCells": .option([.structureCutCells]),
        "SolverConfiguration.gaugesReadWallPressure": .option([.wallReadGauges]),
        "SolverConfiguration.minimumBalloonCells": .numerical,
        "SolverConfiguration.refinement": .option([.shockRefinement, .twoLevelRefinement]),
        "SolverConfiguration.refinementThreshold": .numerical,
        "SolverConfiguration.refinementHoldsEnvelopes": .numerical,
        "SolverConfiguration.refinementHoldsStructures": .numerical,
        "SolverConfiguration.refinementCeiling": .numerical,
        "SolverConfiguration.refinementConfinedTo": .numerical,
        "SolverConfiguration.refinementMargin": .numerical,
        "SolverConfiguration.refinementLevels": .option([.twoLevelRefinement]),
        "SolverConfiguration.refinementOwnSteps": .option([.adaptiveSubsteps]),
        "SolverConfiguration.refinementFinerThreshold": .numerical,
        "SolverConfiguration.refinementMemory": .numerical,
        "SolverConfiguration.refinementStartMemory": .numerical,
        "SolverConfiguration.structureMaskSampling": .numerical,
        "SolverConfiguration.structureMaskFill": .numerical,
        "SolverConfiguration.structureMaskOverlap": .numerical,
        "SolverConfiguration.radiativeCooling": .option([.radiativeCooling]),
        "SolverConfiguration.gravity": .option([.gravity]),
        "SolverConfiguration.mixing": .option([.subgridMixing]),
        "SolverConfiguration.periodicSides": .numerical,
        "SolverConfiguration.afterburnLimit": .option([.afterburnLimit]),
        "SolverConfiguration.afterburnMixing": .option([.mixedAfterburning]),
        "SolverConfiguration.terrainCutCells": .option([.terrainStaircase]),
        "SolverConfiguration.groundStiffness": .option([.softGround]),
        "SolverConfiguration.ground": .option([.groundCoupling]),
    ]
}

extension StandingScene {
    func peakOverpressure() -> ResultStanding {
        if has(.deflagration) { return deflagrationResult(.peakOverpressure) }
        // Today's defaults burn the products in hot air, compared on their own tables.
        let burning = has(.afterburning) && has(.hotAir)
        let incident = Self.columns.mapValues {
            ValidationTables.span(
                burning ? ValidationTables.burningIncidentPeak : ValidationTables.incidentPeak, grid: $0)
        }
        let reflected = Self.columns.mapValues {
            ValidationTables.span(
                burning ? ValidationTables.burningReflectedPeak : ValidationTables.reflectedPeak, grid: $0)
        }
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.compared
        var summary: String
        switch grid {
        case .coarser:
            level = .approximation
            summary =
                "Reads low, the unsafe side: the cells are coarser than any compared with Kingery–Bulmash, "
                + "whose coarsest grid gave \(incident["0.5"]!) of the incident peak."
        default:
            let key = grid == .fine ? "0.125" : grid == .medium ? "0.25" : "0.5"
            summary =
                "Reads low, the unsafe side, as shocks are smeared: Kingery–Bulmash's incident peak "
                + "\(incident[key]!), reflected \(reflected[key]!)\(burning ? " with afterburning and hot air" : ""), "
                + "on air as fine for this charge as the comparison's \(grid.cells) were for 100 kg."
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, a fit to many surface bursts whose scatter is not given; 100 kg from 0.75 to "
                        + "6 m/kg^(1/3) (blastbench validate"
                        + (burning ? ", afterburning, hot air and far-field faces)" : ")"),
                    "Incident peak \(incident[key]!) and reflected \(reflected[key]!) on \(grid.cells)",
                    burning
                        ? ValidationTables.burningDocument
                        : "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        var resolution: [String] = []
        if closeIn, let first = gaugeDistances.first, first < 0.75 {
            let table =
                burning ? ValidationTables.closeBurningReflectedPeak : ValidationTables.closeReflectedPeak
            if let cells = closeInCells, let column = Self.closeColumn(cells) {
                evidence.append(
                    StandingEvidence(
                        "1 kg burst above rigid ground, 0.3 to 1 m/kg^(1/3)"
                            + (burning ? ", on today's air" : ", the ideal gas") + " (blastbench closeair)",
                        "Reflected peak \(ValidationTables.span(table, grid: column)) on \(millimetres(cells)) "
                            + "cells per kg^(1/3)",
                        "validation.md#close-in"))
            } else {
                level = max(level, .approximation)
                resolution.append(
                    String(
                        format: "A gauge %.2f m/kg^(1/3) from the charge is close in, where 40 mm cells per "
                            + "kg^(1/3), the coarsest compared, gave %@ of the reflected peak.",
                        first, ValidationTables.span(table, grid: 0)))
            }
        }
        resolution.append(
            "Air: \(cellDescription); the comparison's 0.5, 0.25 and 0.125 m cells for 100 kg were 0.108, 0.054 "
                + "and 0.027 m/kg^(1/3).")
        if let range = gaugeRange { resolution.append("Gauges lie \(range) from the charge.") }
        if let distance = structureDistance, (0.75...1.3).contains(distance) {
            evidence.append(
                StandingEvidence(
                    "Yao et al.'s 4 × 5 m slabs, the reflected pressure at the top face's centre, 0.8 to 1.26 "
                        + "m/kg^(1/3) on today's air",
                    "Within 11% at 1.0 and 1.26 m/kg^(1/3), 19% low at 0.8; read off plots",
                    "validation.md#yaos-large-slabs"))
        }
        evidence += terrainEvidence
        return result(
            .peakOverpressure, level, summary, evidence: evidence, assumptions: sourceAssumptions,
            resolution: resolution, documents: ["validation.md#blast-loads-against-empirical-references"])
    }

    func impulse() -> ResultStanding {
        if has(.deflagration) { return deflagrationResult(.impulse) }
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.compared
        var summary: String
        let burns = has(.afterburning)
        let hot = has(.hotAir) || has(.dissociatingAir)
        // Today's defaults burn the products in hot air, compared on their own tables.
        let burning = burns && has(.hotAir)
        let reflected = Self.columns.mapValues {
            ValidationTables.span(
                burning ? ValidationTables.burningReflectedImpulse : ValidationTables.reflectedImpulse,
                grid: $0)
        }
        let key = grid == .fine ? "0.125" : grid == .medium ? "0.25" : "0.5"
        let incident =
            burning
            ? "incident impulse \(ValidationTables.span(ValidationTables.burningIncidentImpulse, grid: Self.columns[key]!, from: 1)) "
                + "beyond 1 m/kg^(1/3) (the burning time fitted to it)"
            : burns
                ? "incident impulse 96–101% beyond 1 m/kg^(1/3) (the burning time fitted to it)"
                : "incident impulse 13–22% low on every grid (the unsafe side for what the wave passes over), "
                    + "for want of afterburning"
        switch grid {
        case .coarser:
            level = .approximation
            summary =
                "Reads low on cells coarser than any compared: on the coarsest compared Kingery–Bulmash's "
                + "reflected impulse was \(reflected["0.5"]!), and its \(incident)."
        default:
            summary =
                "On walls, either way: Kingery–Bulmash's reflected impulse \(reflected[key]!) on the comparison's "
                + "\(grid.cells) for 100 kg ("
                + (burning
                    ? "3–14% high beyond 1.5 m/kg^(1/3) on 0.25 m or finer, not fitted"
                    : "within 6% beyond 1.5 m/kg^(1/3) on 0.25 m or finer") + "); \(incident)."
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, a fit to many surface bursts whose scatter is not given; 100 kg from 0.75 to "
                        + "6 m/kg^(1/3) (blastbench validate"
                        + (burning ? ", afterburning, hot air and far-field faces)" : ")"),
                    "Reflected impulse \(reflected[key]!) on \(grid.cells)",
                    burning
                        ? ValidationTables.burningDocument
                        : "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        if burning {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, incident impulse, on today's defaults",
                    "\(ValidationTables.span(ValidationTables.burningIncidentImpulse, grid: 1, from: 1)) beyond 1 "
                        + "m/kg^(1/3) on 0.25 m cells, fitted: the burning time was chosen on it",
                    ValidationTables.burningDocument))
        } else if burns {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash with afterburning alone (blastbench validate --afterburn)",
                    "Incident impulse 96–101% beyond 1 m/kg^(1/3), fitted; reflected 6–15% high in the "
                        + "middle ranges, not fitted",
                    "validation.md#afterburning"))
        } else {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, incident impulse", "78–87% from 1 m/kg^(1/3) out, on every grid",
                    "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        if has(.closedBoundaries) {
            let room =
                burns && hot
                ? "98–108% of the design curve, read by hand and its scatter not given; the burning time, fitted "
                    + "to the open blast, hardly matters here (with the extinction limit 104–117%)"
                : burns
                    ? "124–131% of the design curve"
                    : hot
                        ? "43–91% of the design curve, low for light charges (the unsafe side)"
                        : "48–114% of the design curve, half for light charges (the unsafe side)"
            evidence.append(
                StandingEvidence(
                    "Gas pressure in a closed room against UFC 3-340-02 (blastbench gas)", room,
                    "validation.md#gas-pressure-in-a-closed-room"))
        }
        var resolution: [String] = []
        if closeIn {
            let table =
                burning
                ? ValidationTables.closeBurningReflectedImpulse : ValidationTables.closeReflectedImpulse
            if let cells = closeInCells, let column = Self.closeColumn(cells) {
                evidence.append(
                    StandingEvidence(
                        "1 kg burst above rigid ground, 0.3 to 1 m/kg^(1/3)"
                            + (burning ? ", on today's air" : ", the ideal gas") + " (blastbench closeair)",
                        "Reflected impulse \(ValidationTables.span(table, grid: column)) on \(millimetres(cells)) "
                            + "cells per kg^(1/3)",
                        "validation.md#close-in"))
            } else {
                level = max(level, .approximation)
                resolution.append(
                    "Close in, 40 mm cells per kg^(1/3), the coarsest compared, gave "
                        + "\(ValidationTables.span(table, grid: 0)) of the reflected impulse; these are coarser."
                )
            }
        }
        evidence += terrainEvidence
        var assumptions = sourceAssumptions
        assumptions.append("Real ground is not rigid: the ground here reflects perfectly.")
        return result(
            .impulse, level, summary, evidence: evidence, assumptions: assumptions, resolution: resolution,
            documents: [
                "validation.md#blast-loads-against-empirical-references", "air-blast-model.md#limitations",
            ])
    }
}
