import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's envelopes and damage: the buildings' exposure and damage, their colours, and
// the far field's buildings judged after a run. Split from SimulationModel.swift
// (emmettl/bombcad-work#52).
extension SimulationModel {
    var canExportEnvelopeExposure: Bool {
        !isRunning && !batchInFlight && !isLoadingInputs && !rebuildPending
            && settings.scenario == scenario && stepCount > 0 && !envelopeExposure.isEmpty
    }

    /// Each envelope component's pressure history, as `--envelope-histories` writes it.
    func envelopeHistoriesData() throws -> Data {
        guard canExportEnvelopeExposure, let histories = solver?.envelopeComponentHistories() else {
            throw ProjectFileError.invalid("Pause a run with envelope component histories before exporting.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(histories)
    }

    func envelopeResultsData() throws -> Data {
        guard canExportEnvelopeExposure, let snapshots = solver?.envelopeExposureSnapshot() else {
            throw ProjectFileError.invalid(
                "Pause a run with available building surface results before exporting.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshots)
    }
    /// Whether there is a run's damage to judge the doubt of (not the quick estimate's).
    var canJudgeEnvelopeDoubt: Bool {
        !envelopeDamage.isEmpty && !envelopeDamageIsEstimate && !isRunning
    }

    /// Judges the doubt away from the main thread: two more judgements of every building's loads.
    private func judgeEnvelopeDoubt() {
        guard envelopeDoubt == nil, !judgingEnvelopeDoubt, canJudgeEnvelopeDoubt else { return }
        judgingEnvelopeDoubt = true
        let (loads, scenario, generation) = (envelopeLoads, settings.scenario, envelopeLoadsGeneration)
        // The cells and air of the run the loads came from, as its standing takes them.
        let inputs = (completedRunSettings ?? ProjectRunSettings(model: self)).standingInputs(scenario)
        let (cellSize, configuration) = (inputs.cellSize, inputs.configuration)
        Task { [weak self] in
            let doubt = await Task.detached(priority: .userInitiated) {
                EnvelopeDoubt.assess(
                    loads: loads, scenario: scenario, cellSize: cellSize, configuration: configuration,
                    constructions: { scenario.envelopeConstruction(for: $0) })
            }.value
            guard let self else { return }
            self.judgingEnvelopeDoubt = false
            // Loads judged afresh meanwhile: this doubt is stale, and the next colouring asks again.
            guard self.envelopeLoadsGeneration == generation else {
                self.applyEnvelopeDamageColours()
                return
            }
            self.envelopeDoubt = doubt
            self.applyEnvelopeDamageColours()
        }
    }

    func applyEnvelopeDamageColours() {
        defer { applyFarFieldColours() }
        // A replay colours the buildings as its frame was.
        if playback != nil {
            showReplayedLayers()
            return
        }
        if !protectionPlanChances.isEmpty {
            renderer?.setEnvelopeDamage(protectionPlanChances.mapValues { EnvelopeChanceColour.code($0) })
            return
        }
        guard showsEnvelopeDamage else {
            renderer?.setEnvelopeDamage([:])
            return
        }
        if envelopeColouring == .couldFlip {
            if let envelopeDoubt {
                renderer?.setEnvelopeDamage(
                    Dictionary(
                        uniqueKeysWithValues: envelopeDoubt.buildings.map {
                            ($0.id, EnvelopeDoubtColour.code($0.verdict))
                        }))
                return
            }
            judgeEnvelopeDoubt()
        }
        if envelopeColouring.isStructure, !envelopeStructureChances.isEmpty {
            // Each building by its walls' or roof's chance, the same on every side.
            renderer?.setEnvelopeDamage(
                Dictionary(
                    uniqueKeysWithValues: envelopeStructureChances.map { c in
                        let chance =
                            switch envelopeColouring {
                            case .wallsModerate: c.wallsModerate
                            case .wallsHeavy: c.wallsHeavy
                            default: c.roofModerate
                            }
                        return (
                            c.owner,
                            EnvelopeChanceColour.code([
                                (0, -1, chance), (0, 1, chance), (1, -1, chance), (1, 1, chance),
                            ])
                        )
                    }))
            return
        }
        if envelopeColouring.isChance, !envelopeGlassChances.isEmpty {
            // Each side by its chance, from the quick estimate's draws.
            renderer?.setEnvelopeDamage(chanceCodes(envelopeGlassChances))
            return
        }
        renderer?.setEnvelopeDamage(
            Dictionary(uniqueKeysWithValues: envelopeDamage.map { ($0.id, EnvelopeDamageColour.code($0)) }))
    }

    /// Each building's colour code by its sides' glass chances, as the view's colouring asks.
    private func chanceCodes(_ chances: [FacadeLoadSurrogate.SideGlass]) -> [UUID: Int] {
        Dictionary(grouping: chances, by: \.owner).mapValues { sides in
            EnvelopeChanceColour.code(
                sides.map { side -> (Int, Int, Double) in
                    let chance: Double =
                        switch envelopeColouring {
                        case .someBroken: side.someBroken
                        case .blownOut: side.blownOut
                        case .openingsBlownOut: side.openingsBlownOut
                        default: side.thrownPast3b
                        }
                    return (side.axis, side.outward, chance)
                })
        }
    }

    func applyFarFieldColours() {
        let codes: [UUID: Int] =
            !showsEnvelopeDamage
            ? [:]
            : envelopeColouring.isChance && !farFieldGlass.isEmpty
                ? chanceCodes(farFieldGlass)
                : Dictionary(
                    uniqueKeysWithValues: farFieldDamage.map { ($0.id, EnvelopeDamageColour.code($0)) })
        renderer?.setFarField(farFieldSet, damage: codes)
    }

    /// Judges the far set on the far field carried from the run just finished, away from the main
    /// thread (`HybridFarField.judge`); a run started meanwhile discards it.
    func judgeFarField() {
        guard let set = farFieldSet, let solver, stepCount > 0,
            let histories = solver.envelopeComponentHistories()
        else { return }
        let (near, cellSize, steps) = (scenario, grid?.cellSize ?? settings.resolution.cellSize, stepCount)
        let uncertainty = farFieldUncertainty
        judgingFarField = true
        farFieldStatus = "Judging the far field…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try HybridFarField.judge(
                    near: near, far: set, histories: histories, cellSize: cellSize, nearBeyond: false,
                    glass: uncertainty)
            }
            await MainActor.run {
                guard let self else { return }
                self.judgingFarField = false
                guard self.farFieldSet == set, self.stepCount == steps, !self.isRunning else { return }
                switch result {
                case .success(let judged):
                    self.farFieldDamage = judged.buildings
                    self.farFieldGlass = judged.glass
                    self.farField = judged.farField
                    self.farFieldStatus =
                        String(
                            format:
                                "Far field estimate: %d buildings beyond %.0f m in %.1f s, matched to the run's %d façade strips (peak ×%.2f, impulse ×%.2f at the hand-over).",
                            judged.buildings.count, Double(set.handoverM), judged.seconds, judged.nearStrips,
                            judged.farField.peak, judged.farField.impulse)
                        + (judged.outsideFit > 0
                            ? " \(judged.outsideFit) components lie beyond the distances the surrogate was fitted over: their loads are extrapolated."
                            : "")
                case .failure(let error):
                    self.farFieldDamage = []
                    self.farFieldGlass = []
                    self.farFieldStatus = "The far field could not be judged: \(error)"
                }
                self.applyFarFieldColours()
            }
        }
    }

    /// What the view colours envelopes by: their damage, or (from a quick estimate) each side's
    /// chance that some glass breaks, that it is blown out, that glass is thrown past 3 m, or that
    /// its openings, frames and doors with them, are blown out (fitted to Beirut's survey).
    enum EnvelopeColouring: String, CaseIterable, Identifiable {
        case damage = "Damage"
        case someBroken = "Chance glass breaks"
        case blownOut = "Chance blown out"
        case thrownPast3b = "Chance glass thrown past 3 m (GSA 3b)"
        /// Fitted to Beirut's survey, not physics (`OpeningsFragility`).
        case openingsBlownOut = "Chance openings blown out (fitted to Beirut)"
        /// Whether cells twice as fine could change each building's outcome (`EnvelopeDoubt`).
        case couldFlip = "Could finer cells change it"
        /// Each building's chance its worst wall is damaged moderately or worse, or heavily or worse
        /// (illustrative for concrete), or its roof moderately or worse (`StructureChance`).
        case wallsModerate = "Chance walls damaged (moderate or worse)"
        case wallsHeavy = "Chance walls heavy or worse (illustrative for concrete)"
        case roofModerate = "Chance roof damaged (moderate or worse)"
        var id: Self { self }
        /// Each building side's glass chance, from the quick estimate or the far field.
        var isChance: Bool { self != .damage && self != .couldFlip && !isStructure }
        /// Each building's walls' or roof's chance, from the quick estimate.
        var isStructure: Bool { self == .wallsModerate || self == .wallsHeavy || self == .roofModerate }
    }

    /// A first look at the envelope buildings' damage without running the air
    /// (`FacadeLoadSurrogate`): seconds for a district, shown as an estimate until a run's
    /// damage replaces it.
    func quickEstimate() {
        let scenario = settings.scenario
        guard !scenario.envelopeObjects.isEmpty, !estimatingEnvelopeDamage else { return }
        let cellSize = settings.resolution.cellSize
        estimatingEnvelopeDamage = true
        envelopeDamageStatus = "Estimating…"
        // Nine times in ten within the factor: 1.645 standard deviations of its logarithm.
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(quickEstimateYieldWithin) / 1.645)
        Task { [weak self] in
            let (loads, buildings, outside, chances, structure, seconds) = await Task.detached(
                priority: .userInitiated
            ) {
                let estimate = FacadeLoadSurrogate.estimate(scene: scenario, cellSize: cellSize)
                let (buildings, damageS, _) = FacadeLoadSurrogate.damage(
                    estimate, constructions: { scenario.envelopeConstruction(for: $0) })
                let (chances, chancesS) = FacadeLoadSurrogate.glassProbabilities(
                    scene: scenario, cellSize: cellSize, uncertainty: uncertainty)
                let (structure, structureS) = FacadeLoadSurrogate.structureProbabilities(
                    estimate, mass: Double(scenario.charge.mass), cellSize: cellSize,
                    constructions: { scenario.envelopeConstruction(for: $0) }, uncertainty: uncertainty)
                return (
                    estimate.loads, buildings, estimate.outsideFit, chances, structure,
                    estimate.seconds + damageS + chancesS + structureS
                )
            }.value
            guard let self else { return }
            self.estimatingEnvelopeDamage = false
            // A run judged meanwhile, or the scene changed: the estimate is stale.
            guard self.settings.scenario == scenario, self.stepCount == 0 else {
                self.envelopeDamageStatus = ""
                return
            }
            self.envelopeDamage = buildings
            self.envelopeLoads = loads
            self.envelopeGlassChances = chances
            self.envelopeStructureChances = structure
            self.envelopeDamageIsEstimate = true
            self.envelopeDamageStatus = String(
                format: "Quick estimate in %.1f s: not a run. Run the scene for its damage.", seconds)
            if outside > 0 {
                self.envelopeDamageStatus += String(
                    format:
                        " %d of %d components lie nearer or further than the distances it was fitted over: their loads are extrapolated.",
                    outside, loads.count)
            }
            self.applyEnvelopeDamageColours()
        }
    }

    /// Judges each envelope building from the recorder's histories so far, if it records them.
    func refreshEnvelopeDamage() {
        lastEnvelopeDamage = .now
        defer { envelopeDamageCost = ContinuousClock.now - lastEnvelopeDamage }
        guard let histories = solver?.envelopeComponentHistories(), !histories.isEmpty else { return }
        // A vented pane's faces open with its glass: its history up to then is its load.
        let vented = solver?.envelopeVentingSnapshot()
        updateEnvelopeDamage(
            loads: histories.filter { !$0.invalid || vented?.keeps($0) == true }
                .map(EnvelopeComponentLoad.init),
            vented: vented)
    }

    /// Judges each envelope building from its components' loads (and with venting the air's
    /// panes and rooms), and colours it in the view.
    func updateEnvelopeDamage(loads: [EnvelopeComponentLoad], vented: EnvelopeVentingSnapshot? = nil) {
        let scenario = settings.scenario
        let rooms = Dictionary(
            uniqueKeysWithValues: scenario.envelopeObjects.map {
                ($0.id, EnvelopeDamageAssessment.roomVolume(of: $0.envelope!))
            })
        // Fragments striking the buildings: the landed ones once in, the live ones meanwhile.
        let strikes =
            fragmentStrikes
            ?? (fragments?.fragmentLive ?? fragmentLive)?.impacts.filter { $0.penetration != nil }
        envelopeDamage = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { scenario.envelopeConstruction(for: $0) }, rooms: rooms,
            strikes: strikes, vented: vented)
        envelopeDamageIsEstimate = false
        envelopeGlassChances = []
        envelopeStructureChances = []
        envelopeLoads = loads
        applyEnvelopeDamageColours()
    }

    /// Throws the debris of the envelope components judged failed and flies it to where it lands,
    /// for the hazard and the minimum safe distance: when a run stops, not while it runs.
    func refreshEnvelopeDebris() {
        envelopeDebris =
            envelopeDamage.isEmpty
            ? nil : solver?.envelopeDebris(scenario: scenario, loads: envelopeLoads, damage: envelopeDamage)
    }

    /// The structures' rubble flown on to where it lands, judged as a hazard; nil unless a
    /// structure makes rubble (`StructureModel.rubbleParticles`).
    func debrisResult() -> DebrisResult? { solver?.debris(scenario: scenario) }

    func envelopeDamageData() throws -> Data {
        guard !envelopeDamage.isEmpty else {
            throw ProjectFileError.invalid(
                "Run a scene with envelope buildings before exporting their damage.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(envelopeDamage)
    }
    /// The Macs the run's companions are set to run on; for one placed automatically, every Mac
    /// set for sweeps.
    var wantedHosts: Set<String> {
        Set(
            [fragmentsHost, thermalHost, groundShockHost].compactMap { $0 }.flatMap {
                $0 == ConsumerPlacement.automatic ? automaticHosts : [$0]
            })
    }
    /// The Macs a companion placed automatically may go to: those set for sweeps.
    var automaticHosts: [String] {
        AppPreferences.hosts(UserDefaults.standard.string(forKey: AppPreferences.Key.sweepHosts) ?? "")
    }
    /// Whether the run's companions, the fragments, the thermal radiation and the ground shock,
    /// have every frame sent, so that the run can be kept.
    var companionsCaughtUp: Bool {
        [fragments, thermal, groundShock].allSatisfy { $0?.caughtUp ?? true } && !followingCloud
    }
    static let undoLimit = 100

    static func defaultDuration(for scenario: Scenario) -> Double {
        // A structure keeps moving long after the blast wave has left the domain.
        let crossing = (scenario.acousticCrossingTime * 100).rounded(.up) / 100
        return scenario.structure == nil ? crossing : max(crossing, 0.25)
    }
}
