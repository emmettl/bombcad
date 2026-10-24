import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's timeline and saved states (checkpoints). Split from SimulationModel.swift
// (emmettl/bombcad-work#52).
extension SimulationModel {
    func startTimeline(_ solver: BlastSolver) {
        let preferences = AppPreferences.load()
        // A sweep's cases are kept as results, not to replay.
        guard recordsTimelines, preferences.recordsTimelines, !sweep.isActive, var inputs = loadedRunSettings
        else { return }
        inputs.duration = duration
        do {
            let recorder = try RunTimelineRecorder(
                solver: solver, fingerprint: SavedSimulationRun.fingerprint(scenario, settings: inputs),
                duration: duration, budgetBytes: preferences.timelineBudgetMB << 20,
                checkpointBudgetBytes: preferences.checkpointBudgetMB << 20)
            recorder.endTime = duration
            timelineRecorder = recorder
            savedStates = []
            let spacing = duration / Double(Self.automaticCheckpoints)
            nextAutomaticCheckpoint =
                preferences.checkpointBudgetMB > 0 && spacing > 0
                ? (floor(solver.time / spacing + 1e-6) + 1) * spacing : .infinity
            timelineStarted = .now
            recordTimeline(solver)
        } catch {
            timelineRecorder = nil
        }
    }

    func recordTimeline(_ solver: BlastSolver, last: Bool = false) {
        timelineRecorder?.recordIfDue(
            solver, fragments: fragments?.fragmentLive ?? fragmentLive, freestanding: freestandingBoxes(),
            layers: { self.timelineLayers(solver) }, force: last)
    }

    /// The layers a recorded frame keeps as the view shows them now: the vent panels opened and
    /// the panes broken, each envelope building's damage colour (raised to "glass broken" as soon
    /// as a pane of it breaks, ahead of the next judgement), the thermal paint reckoned so far and
    /// the cloud once handed over.
    func timelineLayers(_ solver: BlastSolver) -> TimelineLayers {
        var layers = TimelineLayers()
        let panels = solver.ventPanelOpenTimes.map { $0 != nil }
        let panes = solver.envelopePanesBroken()
        if !panels.isEmpty || !panes.isEmpty { layers.vents = .here(.init(panels: panels, panes: panes)) }
        let objects = scenario.envelopeObjects
        if !objects.isEmpty {
            if timelinePaneOwners?.count != panes.count {
                let index = Dictionary(
                    objects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
                timelinePaneOwners = solver.envelopePaneOwners.map { index[$0] ?? -1 }
            }
            var codes = [UInt8](repeating: 0, count: objects.count)
            if !envelopeDamageIsEstimate {
                let judged = Dictionary(
                    envelopeDamage.map { ($0.id, EnvelopeDamageColour.code($0)) },
                    uniquingKeysWith: { a, _ in a })
                for (n, object) in objects.enumerated() { codes[n] = UInt8(clamping: judged[object.id] ?? 0) }
            }
            for (pane, broken) in zip(timelinePaneOwners ?? [], panes) where broken && pane >= 0 {
                codes[pane] = max(codes[pane], 2)
            }
            if codes.contains(where: { $0 != 0 }) { layers.envelopeCodes = .here(codes) }
        }
        if let live = thermal?.thermalLive, live.frames > 0 {
            layers.thermal = .here(
                .init(
                    frames: live.frames, fluence: live.fluence, peakIrradiance: live.peakIrradiance,
                    peakTemperature: live.peakTemperature))
        }
        if let handOver = handedOverCloud, handOver.mass > 0 {
            layers.cloud = .here(
                .init(
                    time: handOver.time, centre: handOver.centre,
                    radius: Float(cbrt(3 * handOver.volume / (4 * .pi))), mass: handOver.mass))
        }
        return layers
    }

    func finishTimeline() {
        guard let recorder = timelineRecorder, let solver else { return }
        recordTimeline(solver, last: true)
        solver.viewFieldCapture = nil
        timelineRecorder = nil
        let wall = ContinuousClock.now - timelineStarted
        Task { [weak self] in
            let folder = await recorder.finish()
            self?.timelineCost = (
                recorder.frames, recorder.captureSeconds, recorder.cappedSeconds, recorder.bytes,
                Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18
            )
            // A run continued from the last one's saved state leaves that run's recording behind:
            // gone now, unless it was kept.
            if let self, let old = self.recentTimeline, old != folder, !self.runFolders.values.contains(old) {
                try? FileManager.default.removeItem(at: old)
            }
            self?.recentTimeline = folder
        }
    }

    /// Forgets the run under way's recording, and the last run's unless it was kept (or
    /// `keepingRecent`, to continue from it).
    func discardTimeline(keepingRecent: Bool = false) {
        stopReplay()
        timelineRecorder?.discard()
        timelineRecorder = nil
        solver?.viewFieldCapture = nil
        savedStates = []
        saveRequested = false
        pauseAfterSave = false
        nextAutomaticCheckpoint = .infinity
        guard !keepingRecent else { return }
        if let recent = recentTimeline, !runFolders.values.contains(recent) {
            try? FileManager.default.removeItem(at: recent)
        }
        recentTimeline = nil
    }

    /// Where `run`'s timeline lies: staged since it was kept, or in the saved package.
    func timelineFolder(for run: SavedSimulationRun) -> URL? {
        if let folder = runFolders[run.id] { return folder }
        guard let packageURL else { return nil }
        let folder = packageURL.appending(
            path: "\(RunTimelineManifest.folder)/\(run.id.uuidString.lowercased())",
            directoryHint: .isDirectory)
        let manifest = folder.appending(path: RunTimelineManifest.fileName)
        return FileManager.default.fileExists(atPath: manifest.path) ? folder : nil
    }

    /// The kept runs that can be replayed.
    var replayableRuns: [SavedSimulationRun] { savedRuns.filter { timelineFolder(for: $0) != nil } }

    /// Replays `run`'s timeline in the view, or the last run's for nil, showing its last frame.
    func replay(_ run: SavedSimulationRun?) {
        guard !isRunning, let device, let renderer, let commandQueue,
            let folder = run.map(timelineFolder) ?? recentTimeline
        else { return }
        stopReplay()
        do {
            let player = try RunTimelinePlayer(folder: folder, device: device)
            let shown = run?.scenario ?? scenario
            let craters = (run?.settings ?? completedRunSettings ?? loadedRunSettings)?.craters(over: shown)
            let playback = TimelinePlayback(
                player: player, title: run?.name ?? "This run", scenario: shown, kept: run.map(\.cloud),
                craters: craters ?? [], commandQueue: commandQueue)
            renderer.setScene(shown, view: player.upload.view)
            remoteRun?.isShown = false
            playback.onShow = { [weak self] in self?.showReplayedLayers() }
            self.playback = playback
            try playback.show(playback.positions - 1)
            sceneVersion += 1
        } catch {
            errorMessage = "This run's recording could not be read: \(error.localizedDescription)"
            playback = nil
            restoreLiveView()
        }
    }

    /// Draws the replayed frame's vent panels and envelope colours as they were then; a recording
    /// of 0.6.0, which kept neither, shows no panels and no colours.
    func showReplayedLayers() {
        guard let playback else { return }
        showLayers(playback.layers, scenario: playback.scenario, recordsLayers: playback.recordsLayers)
    }

    /// Draws `layers`' vent panels and envelope colours over `scenario`; without `recordsLayers`,
    /// no panels and no colours.
    func showLayers(_ layers: TimelineLayers, scenario: Scenario, recordsLayers: Bool) {
        guard let renderer else { return }
        let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
        if let opened = layers.vents.value?.panels, opened.count == panels.count {
            renderer.setVentPanels(zip(panels, opened).compactMap { $1 ? nil : $0.box })
        } else {
            renderer.setVentPanels(recordsLayers ? panels.map(\.box) : [])
        }
        let objects = scenario.envelopeObjects
        if showsEnvelopeDamage, let codes = layers.envelopeCodes.value, codes.count == objects.count {
            renderer.setEnvelopeDamage(
                Dictionary(
                    zip(objects, codes).filter { $1 != 0 }.map { ($0.id, Int($1)) },
                    uniquingKeysWith: { a, _ in a }))
        } else {
            renderer.setEnvelopeDamage([:])
        }
        sceneVersion += 1
    }

    /// The replayed frame's thermal paint of `quantity`, from the receivers' values recorded with
    /// it; nil before any were reckoned, or where the scene's receivers are not those recorded.
    func replayedThermalPaint(_ quantity: ThermalQuantity) -> SurfacePaint? {
        guard let playback else { return nil }
        if let cache = replayPaintCache, cache.index == playback.index, cache.quantity == quantity {
            return cache.paint
        }
        let paint = thermalPaint(playback.layers.thermal.value, quantity)
        replayPaintCache = (playback.index, quantity, paint)
        return paint
    }

    /// The thermal paint of `quantity` from the receivers' values recorded or sent; nil for none,
    /// or where the scene's receivers are not those recorded.
    func thermalPaint(_ recorded: TimelineLayers.Thermal?, _ quantity: ThermalQuantity) -> SurfacePaint? {
        var paint: SurfacePaint?
        if let recorded, recorded.fluence.count == thermalReceivers.count {
            var live = ThermalLive(receivers: 0)
            live.frames = recorded.frames
            live.fluence = recorded.fluence
            live.peakIrradiance = recorded.peakIrradiance
            live.peakTemperature = recorded.peakTemperature
            let values: [Float]? =
                switch quantity {
                case .fluence: live.fluence
                case .peakIrradiance: live.peakIrradiance
                case .surfaceTemperature, .ignition:
                    reckonedSpec.flatMap { heatingResult(live, spec: $0) }.map { heating in
                        quantity == .ignition
                            ? heating.ignition.map(Float.init)
                            : heating.peakTemperature.map { $0 - heating.ambient }
                    }
                }
            paint = values.map { SurfacePaint(grids: thermalGrids, shades: $0.map(quantity.shade)) }
        }
        return paint
    }

    /// The craters the view shades into the ground. Replaying, the run's, each as dug by the time
    /// shown, so that it grows as the replay plays and fills in again when it is scrubbed back.
    /// Live, each whole once the run has ended, as before; while a run goes on, grown to its time
    /// those it will have finished forming by the end, so that they too end whole.
    var shownCraters: [CraterEstimate] {
        if let playback {
            let time = Float(playback.time)
            return playback.craters.compactMap { $0.grown(atTime: time) }
        }
        if completedRunSettings != nil { return craters }
        guard time > 0, let inputs = loadedRunSettings else { return [] }
        return inputs.craters(over: scenario).filter { Double($0.formedAt) <= duration }
            .compactMap { $0.grown(atTime: Float(time)) }
    }

    /// The cloud the view draws: while replaying a recording that keeps it, the run's from the
    /// frame it was handed over in, and none before.
    var shownCloud: CloudResult? {
        guard let playback else { return cloud }
        let runs = playback.kept ?? cloud
        guard playback.recordsLayers else { return runs }
        return playback.layers.cloud.value == nil ? nil : runs
    }

    /// Back to the scene and the solver's state.
    func stopReplay() {
        guard let playback else { return }
        playback.pause()
        self.playback = nil
        restoreLiveView()
    }

    func restoreLiveView() {
        guard let renderer, let solver else { return }
        renderer.setScene(scenario, solver: solver)
        remoteRun?.isShown = false
        // The scene drew every panel closed again: show those opened, however many.
        openedVentPanels = -1
        showOpenedVentPanels(solver)
        applyEnvelopeDamageColours()
        sceneVersion += 1
    }

    /// Why the run under way cannot save its state, or nil if it can: states are saved into its
    /// recording, and the fragments, ground shock and thermal paint fed alongside are not saved.
    var saveStateUnavailable: String? {
        if timelineRecorder == nil { return "Only a recorded run saves its state (Settings ▸ Replay)." }
        if fragments != nil || groundShock != nil || thermal != nil {
            return "A run with fragments, ground shaking or the thermal paint cannot save its state yet."
        }
        if solver?.firings.isEmpty == false {
            return "A run whose delayed charges have begun to fire cannot save its state yet."
        }
        return nil
    }

    /// The solver's state digest (`BlastSolver.stateDigest`), to check a continued run against.
    var solverStateDigest: UInt64? { solver?.stateDigest() }

    /// Whether Save State Here can be chosen now.
    var canSaveState: Bool {
        saveStateUnavailable == nil && !saveRequested && !rebuildPending && stepCount > 0
            && time < duration - 1e-9
    }

    /// Saves the run's state at the next 64-step boundary, into its recording, to continue from
    /// later; a paused run runs on to it and pauses again.
    func saveStateHere() {
        guard canSaveState, let solver else { return }
        saveRequested = true
        if !isRunning, !batchInFlight, solver.stepCount.isMultiple(of: BlastSolver.checkpointInterval) {
            saveCheckpointIfDue(solver)
        } else if !isRunning {
            pauseAfterSave = true
            run()
        }
    }

    func checkpointDue(_ solver: BlastSolver) -> Bool {
        timelineRecorder != nil && (saveRequested || solver.time >= nextAutomaticCheckpoint - 1e-12)
    }

    /// Saves the state if one is due and the run stands on a 64-step boundary between batches.
    func saveCheckpointIfDue(_ solver: BlastSolver) {
        guard checkpointDue(solver), !batchInFlight,
            solver.stepCount.isMultiple(of: BlastSolver.checkpointInterval), let recorder = timelineRecorder
        else { return }
        let pinned = saveRequested
        saveRequested = false
        if solver.time >= nextAutomaticCheckpoint - 1e-12 {
            let spacing = duration / Double(Self.automaticCheckpoints)
            nextAutomaticCheckpoint = (floor(solver.time / spacing + 1e-6) + 1) * spacing
        }
        defer {
            if pinned, pauseAfterSave {
                pauseAfterSave = false
                isRunning = false
                publishProgress()
            }
        }
        if let reason = saveStateUnavailable {
            nextAutomaticCheckpoint = .infinity
            if pinned { errorMessage = reason }
            return
        }
        let path = RunTimelineRecorder.checkpointPath(step: solver.stepCount)
        do {
            let header = try solver.saveCheckpoint(to: recorder.folder.appending(path: path), scene: scenario)
            let entry = RunTimelineManifest.Entry(
                kind: .checkpoint, time: header.time, step: header.stepCount, path: path,
                bytes: header.storedBytes, pinned: pinned ? true : nil)
            // One automatic state alone past their space: no more this run.
            if recorder.addCheckpoint(entry).contains(entry) { nextAutomaticCheckpoint = .infinity }
            savedStates = recorder.checkpoints
        } catch {
            nextAutomaticCheckpoint = .infinity
            if pinned { errorMessage = "The run's state could not be saved: \(error)" }
        }
    }

    /// The saved state a replay at its time would continue from: the latest at or before it.
    func checkpointToContinue(_ playback: TimelinePlayback) -> RunTimelineManifest.Entry? {
        playback.player.manifest.checkpoint(atOrBefore: playback.time)
    }

    /// Carries the run being replayed on from its latest saved state at or before the time shown:
    /// the solver takes the state back, the same to the bit as the run had it, and runs on from
    /// there. The scene and settings must be the run's.
    func continueFromReplay() {
        guard let playback, let entry = checkpointToContinue(playback) else { return }
        let folder = playback.player.folder
        continueRun(from: folder.appending(path: entry.path), sameRun: folder == recentTimeline)
    }

    /// Takes back the state saved in `checkpoint`; `sameRun` keeps the run's records (the
    /// structure's deflections) up to its time, as the last run's are still at hand.
    func continueRun(from checkpoint: URL, sameRun: Bool) {
        guard !isRunning, !batchInFlight, !rebuildPending, !sweep.isActive else { return }
        if fragmentSpec != nil || groundShockSpec != nil || thermalSpec != nil {
            errorMessage =
                "A run with fragments, ground points or thermal receivers cannot be continued from a saved state yet."
            return
        }
        let records = sameRun ? (structureRecord, bodyRecords) : ([], [:])
        stopReplay()
        rebuild(keepingRecentTimeline: true)
        guard let solver else { return }
        do {
            try solver.restoreCheckpoint(from: checkpoint, scene: scenario)
        } catch {
            rebuild(keepingRecentTimeline: true)
            errorMessage =
                "This run cannot be continued from its saved state (the scene or settings may have changed since): \(error)"
            return
        }
        let now = solver.time
        structureRecord = records.0.filter { $0.time <= now + 1e-9 }
        bodyRecords = records.1.mapValues { $0.filter { $0.time <= now + 1e-9 } }
        structureHistory = structureRecord
        bodyHistories = bodyRecords
        structureSummary = solver.bodySummary()
        lastSampleTime = now
        nextStructureSampleTime = (floor(now / sampleInterval + 1e-6) + 1) * sampleInterval
        continuedFrom = now
        solver.refreshVisualization()
        restoreLiveView()
        publishProgress()
        publishTraces()
        startTimeline(solver)
    }
}
