import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's runs: building the solvers and stepping them. Split from SimulationModel.swift
// (emmettl/bombcad-work#52).
extension SimulationModel {
    /// Stops drawing the vent panels that have released.
    func showOpenedVentPanels(_ solver: BlastSolver) {
        let times = solver.ventPanelOpenTimes
        let opened = times.filter { $0 != nil }.count
        guard opened != openedVentPanels else { return }
        openedVentPanels = opened
        let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
        renderer?.setVentPanels(zip(panels, times).compactMap { $1 == nil ? $0.box : nil })
        sceneVersion += 1
    }

    func requestRebuild() {
        envelopeExposure = []
        envelopeDamage = []
        envelopeDamageIsEstimate = false
        farFieldDamage = []
        inspectedEnvelope = nil
        farFieldGlass = []
        farField = nil
        farFieldStatus = ""
        envelopeGlassChances = []
        envelopeDebris = nil
        envelopeExposureStatus = ""
        envelopeVentingStatus = ""
        if batchInFlight {
            isLoadingInputs = true
            // The GPU still owns the solver's buffers; rebuild when the batch lands.
            rebuildPending = true
        } else {
            rebuild()
        }
    }

    /// Sets the air's charge model and refinement from the settings; takes effect when the
    /// scenario is loaded.
    private func configureAir(_ solver: BlastSolver) {
        ProjectRunSettings.configureAir(
            &solver.configuration, detailedCharge: settings.detailedCharge, sharpShocks: settings.sharpShocks,
            shockLevels: settings.shockLevels, gravity: settings.gravity,
            shockThreshold: settings.shockThreshold, adaptiveSubsteps: settings.adaptiveSubsteps,
            terrainCutCells: settings.terrainCutCells,
            groundStiffness: settings.softGround ? settings.groundStiffness : nil,
            ground: settings.ground == .rigid ? nil : settings.ground,
            outlineByOverlap: settings.outlineByOverlap, settlesStructures: settings.settlesStructures,
            mappedStart: settings.mappedStart, refinementCeiling: settings.refinementCeiling,
            // The gas's own radiation, whatever the thermal overlay reckons: the overlay changes
            // nothing in the air.
            radiativeCooling: settings.radiativeCooling ? RadiativeCooling() : nil,
            refinementRegions: settings.sharpShocks && !settings.refineToward.isEmpty
                ? settings.scenario.refinementCorridors(toward: settings.refineToward) : nil)
        solver.configuration.fitRefinementMemory(solver.grid, memory: advisorMemory)
        // A mapped start begins no later than halfway through the run, so that the grid has the rest.
        solver.mappedStartLatest = duration / 2
    }

    func rebuild(keepingRecentTimeline: Bool = false) {
        isLoadingInputs = true
        defer { isLoadingInputs = false }
        discardTimeline(keepingRecent: keepingRecentTimeline)
        continuedFrom = nil
        stopFragments()
        stopGroundShock()
        envelopeExposure = []
        envelopeDamage = []
        envelopeDamageIsEstimate = false
        farFieldDamage = []
        inspectedEnvelope = nil
        farFieldGlass = []
        farField = nil
        farFieldStatus = ""
        envelopeGlassChances = []
        envelopeDebris = nil
        envelopeExposureStatus = ""
        envelopeVentingStatus = ""
        stopThermal()
        stopCloud()
        completedRunSettings = nil
        loadedRunSettings = nil
        isRunning = false
        rebuildPending = false
        guard !importsNeedResampling else { return }
        guard let device, let commandQueue, let renderer else { return }

        let scenario = settings.scenario
        let grid = scenario.grid(cellSize: settings.resolution.cellSize)
        do {
            if let solver, solver.grid == grid {
                configureAir(solver)
                try solver.load(scenario)
            } else {
                solver = nil
                // State (two copies), peak, impulse, mask and the visualisation volume, and with
                // afterburning two copies of the fuel and oxygen; the structure's mesh is small by
                // comparison.
                let refined = settings.sharpShocks
                let required =
                    grid.cellCount * (settings.detailedCharge ? 73 : 57)
                    + grid.cellCount * (scenario.deflagration == nil ? 0 : 20)
                    + (refined ? SolverConfiguration().refinementStartMemory ?? 0 : 0)
                // The view's volume texture holds at most 2,048 cells along a side.
                guard max(grid.nx, grid.ny, grid.nz) <= 2048 else {
                    throw BlastError.allocationFailed(
                        "\(max(grid.nx, grid.ny, grid.nz)) cells along a side, more than the view's 2,048; "
                            + "choose a coarser grid")
                }
                guard UInt64(required) < device.recommendedMaxWorkingSetSize / 10 * 7 else {
                    throw BlastError.allocationFailed(
                        "\(grid.cellCount / 1_000_000) million cells; try a coarser resolution")
                }
                // In a pool of its own: what building a solver autoreleases keeps it alive until a
                // pool drains, and a headless worker's runs, one after another, kept every one's
                // memory (`SolverMemoryTests`).
                let created = try autoreleasepool { () throws -> BlastSolver in
                    let created = try BlastSolver(
                        device: device, commandQueue: commandQueue, scenario: scenario,
                        cellSize: settings.resolution.cellSize)
                    // Always: even with both options off the air takes the far-field faces (and
                    // gravity) from the settings, not the bare core's.
                    configureAir(created)
                    try created.load(scenario)
                    return created
                }
                solver = created
            }
            // The blast's injury at a standing person's height, from the run's own peaks (`InjuryField`):
            // probes that leave the air as it is.
            if let solver, solver.stepCount == 0 {
                injuryField = nil
                try? solver.configureExposurePlane(heightM: Self.standingHeight, arrivalThresholdPa: 1_000)
            }
            if let solver, !scenario.envelopeObjects.isEmpty {
                // Envelopes are stationary whatever else moves: a structure beside them never takes
                // the air at their faces, and its debris passes them by (one way).
                do {
                    try solver.configureEnvelopeExposure(objects: scenario.envelopeObjects)
                    // The components' histories feed their one-way damage, so the app keeps them for
                    // every run of envelopes; headless runs only when asked.
                    if let options = envelopeHistoryOptions
                        ?? (envelopeHistoriesByDefault
                            ? Self.defaultEnvelopeHistory(duration: duration, memory: advisorMemory) : nil)
                    {
                        try solver.configureEnvelopeComponents(
                            objects: scenario.envelopeObjects, options: options)
                        if settings.ventsGlazing && scenario.hasEnvelopePanes {
                            do {
                                try solver.configureEnvelopeVenting(objects: scenario.envelopeObjects) {
                                    scenario.envelopeConstruction(for: $0)
                                }
                                // Close-in charges breach concrete by UFC 3-340-02's curves; the
                                // main charge's casing, if it is cased, from its fragments.
                                var main = scenario.charge
                                main.delay = nil
                                try solver.setEnvelopeCloseIn(
                                    charges: [(main, fragmentSpec?.casingMass ?? 0)]
                                        + (scenario.additionalCharges ?? []).map { ($0, 0) },
                                    constructions: { scenario.envelopeConstruction(for: $0) })
                            } catch {
                                envelopeVentingStatus =
                                    "Glazing not vented (\(error.localizedDescription)): the inside is the one-way fill's."
                            }
                        }
                    }
                    envelopeExposure = solver.envelopeExposureSummaries() ?? []
                } catch {
                    envelopeExposureStatus = "Surface results unavailable: \(error.localizedDescription)"
                }
            }
            errorMessage = nil
        } catch {
            solver = nil
            errorMessage = "\(error)"
        }

        handledSettings = settings
        loadedRunSettings = solver == nil ? nil : ProjectRunSettings(model: self)
        self.scenario = scenario
        self.grid = solver?.grid
        memoryFootprint = solver?.memoryFootprint ?? 0
        structureSummary = solver?.bodySummary()
        structureSubsteps = solver?.structureSubsteps ?? 0
        structureHistory = []
        bodyHistories = [:]
        structureRecord = []
        bodyRecords = [:]
        structuresInContactFrom = nil
        bodySummaries = Dictionary(
            uniqueKeysWithValues: (solver?.bodies ?? []).compactMap { body in
                body.summary().map { (body.id, $0) }
            })
        // The first sample after the run's start: a mapped start's clock starts at its solution's time.
        nextStructureSampleTime = (floor((solver?.time ?? 0) / sampleInterval + 1e-6) + 1) * sampleInterval
        lastSampleTime = nil
        chargeIsBlocked = scenario.chargeIsBlocked
        openedVentPanels = 0
        time = 0
        stepCount = 0
        stats = SimulationStats()
        liveStats = SimulationStats()
        blastGPUSeconds = 0
        batchSize = 4
        traces = scenario.gauges.enumerated().map { GaugeTrace(id: $0.offset, name: $0.element.name) }
        if let solver {
            renderer.setScene(scenario, solver: solver)
            applyFarFieldColours()
            sceneVersion += 1
        }
    }

    func restartPacing() {
        paceOriginWall = playbackNow()
        paceOriginTime = solver?.time ?? time
        lastBatchCompletion = .now
    }

    /// Commits the next batch of steps if the run is active and the GPU is free.
    func pump() {
        guard isRunning, !batchInFlight, let solver else { return }
        if holdBatches?() == true || thermalIsBehind {
            publishProgressIfBehind(solver)
            if !waitingForHold {
                waitingForHold = true
                Task {
                    try? await Task.sleep(for: .milliseconds(2))
                    waitingForHold = false
                    pump()
                }
            }
            return
        }

        // Steps are cut short only to land on the end and on samples, which are the same at any
        // speed. The playback clock only says when the next batch may start and how many steps
        // it takes: cutting steps to it made a paced run take many more, shorter steps than one
        // as fast as possible, and different ones each time.
        var limit = duration
        if samples { limit = min(limit, nextStructureSampleTime) }
        var target = limit
        if speed != .unlimited {
            let wall = (playbackNow() - paceOriginWall).seconds
            target = min(limit, paceOriginTime + wall / speed.rawValue)
        }
        let remaining = target - solver.time
        guard remaining > 1e-9 else {
            if solver.time >= duration - 1e-9 {
                finish()
            } else if !waitingForPace {
                publishProgressIfBehind(solver)
                // Ahead of the playback clock: check again shortly.
                waitingForPace = true
                Task {
                    try? await Task.sleep(for: .milliseconds(4))
                    waitingForPace = false
                    pump()
                }
            }
            return
        }

        // Steps past the limit would be wasted work, so only encode as many as are needed; to
        // the playback clock, just enough to reach it.
        let timeStep = liveStats.timeStep
        let needed = timeStep > 0 ? Int((remaining / timeStep).rounded(.up)) + (target < limit ? 0 : 1) : 2
        var steps = max(1, min(batchSize, needed))
        // Fragments take a frame a millisecond: keep batches within one, so that frames are too,
        // by taking fewer steps, never shorter ones, so the air is the same as without them.
        if fragments != nil || thermal != nil, timeStep > 0 {
            steps = min(steps, max(1, Int(Self.fragmentFrameInterval / timeStep)))
        }
        // The fireball's frames likewise: end the batch just past the next millisecond.
        if thermal != nil, timeStep > 0 {
            steps = min(steps, max(1, Int(((nextFireballTime - solver.time) / timeStep).rounded(.up))))
        }
        // A state to save: to the next 64-step boundary, where it is saved between batches.
        if checkpointDue(solver) {
            let interval = BlastSolver.checkpointInterval
            steps = min(steps, interval - solver.stepCount % interval)
        }
        prepareBatch?(solver, limit)
        guard
            let commandBuffer = solver.encodeBatch(steps: steps, timeLimit: limit, updateVisualization: true)
        else {
            errorMessage = "Could not create a Metal command buffer."
            isRunning = false
            return
        }
        batchInFlight = true
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuSeconds = buffer.gpuEndTime - buffer.gpuStartTime
            let failed = buffer.error != nil
            Task { @MainActor in
                self?.batchCompleted(gpuSeconds: gpuSeconds, failed: failed)
            }
        }
        commandBuffer.commit()
    }

    private func batchCompleted(gpuSeconds: Double, failed: Bool) {
        guard let solver else { return }
        batchInFlight = false
        let result = solver.completeBatch()
        let finished = solver.time >= duration - 1e-9
        showOpenedVentPanels(solver)
        sendFragmentFrame(solver, last: finished)
        sendGroundShockFrame(solver, last: finished)
        sendFireball(solver)
        recordTimeline(solver)
        saveCheckpointIfDue(solver)

        let now = ContinuousClock.now
        let wall = (now - lastBatchCompletion).seconds
        lastBatchCompletion = now
        if gpuSeconds > 0 { blastGPUSeconds += gpuSeconds }
        if result.steps > 0, gpuSeconds > 0 {
            let stepRate = Double(result.steps) / gpuSeconds
            let blend = liveStats.stepsPerSecond == 0 ? 1 : 0.1
            liveStats.stepsPerSecond += blend * (stepRate - liveStats.stepsPerSecond)
            liveStats.cellUpdatesPerSecond = liveStats.stepsPerSecond * Double(solver.grid.cellCount)
            liveStats.timeStep = result.lastTimeStep
            if result.elapsed > 0, wall > 0 {
                let ratio = wall / result.elapsed
                liveStats.slowMotion += (liveStats.slowMotion == 0 ? 1 : 0.1) * (ratio - liveStats.slowMotion)
            }
            // Aim for roughly 10 ms of GPU work per batch so the display stays fluid.
            let ideal = 0.010 * stepRate
            batchSize = min(max(Int(ideal.rounded()), 1), 64)
        }

        if result.couplingCapacityExceeded {
            errorMessage =
                "Local coupling storage could not cover the moving geometry. Reset the run or use a smaller scene."
            isRunning = false
        } else if failed || !result.isStable {
            errorMessage = "The solution became unstable. Reset, or try a smaller charge or a finer grid."
            isRunning = false
        }
        if !isRunning || finished || (now - lastProgressPublication).seconds >= Self.progressInterval {
            publishProgress()
        }
        recordSampleIfDue(solver)
        if (now - lastTracePublication).seconds > 0.1 || !isRunning {
            publishTraces()
        }
        if rebuildPending {
            rebuild()
            return
        }
        if finished {
            finish()
        }
        pump()
    }

    /// Shows the solver's time, step count and rates.
    func publishProgress() {
        guard let solver else { return }
        lastProgressPublication = .now
        time = solver.time
        stepCount = solver.stepCount
        stats = liveStats
    }

    /// Shows the solver's progress if the last batch's has not been shown, before the run waits.
    private func publishProgressIfBehind(_ solver: BlastSolver) {
        if time != solver.time || stepCount != solver.stepCount { publishProgress() }
    }

    func finish() {
        isRunning = false
        saveRequested = false
        pauseAfterSave = false
        finishTimeline()
        firingNotes = (solver?.firings ?? []).map { firing in
            let how =
                switch firing.how {
                case .balloon: "as a ball of hot gas"
                case .mapped: "from its one-dimensional solution"
                case .balloonInsteadOfMapped: "as a ball of hot gas, not mapped"
                }
            return String(
                format: "The charge fired at %.2f ms was laid %@ at %.2f ms.",
                firing.charge.firingTime * 1000, how,
                firing.laidAt * 1000) + (firing.note.map { " " + $0 } ?? "")
        }
        if let solver, let snapshot = solver.exposureSnapshot() {
            injuryField = InjuryField(
                snapshot, centre: SIMD2(scenario.charge.position.x, scenario.charge.position.y),
                ambient: Double(scenario.atmosphere.pressure))
        }
        publishTraces()
        refreshEnvelopeDebris()
        judgeFarField()
        if fragments != nil || thermal != nil || groundShock != nil {
            let (gpu, elapsed) = (blastGPUSeconds, time)
            Task { [weak self] in await self?.recordCosts(blastGPUSeconds: gpu, elapsed: elapsed) }
        }
        // The fragments' last frames may still be in flight: show them once they are in.
        if let fragments {
            let limit = catchUpLimits.fragments
            Task { [weak self] in
                let start = ContinuousClock.now
                while fragments.report.frame < fragments.sent - 1, CatchUpLimits.within(limit, since: start) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard self?.fragments === fragments else { return }
                self?.updateFragmentStatus()
                // Those still in flight fly on to land, for the hazard: the run is over, and
                // another starts afresh with new fragments.
                let landed = try? await fragments.fragments(frameInterval: Self.fragmentFrameInterval)
                guard let self, self.fragments === fragments, let landed, let hazard = landed.hazard else {
                    return
                }
                self.fragmentHazard = hazard
                self.fragmentStrikes = landed.impacts.filter { $0.penetration != nil }
                self.updateFragmentStatus()
                if !self.envelopeDamage.isEmpty {
                    self.refreshEnvelopeDamage()
                    self.refreshEnvelopeDebris()
                }
            }
        }
        if let thermal {
            let limit = catchUpLimits.thermal
            Task { [weak self] in
                let start = ContinuousClock.now
                while !thermal.caughtUp, CatchUpLimits.within(limit, since: start) {
                    try? await Task.sleep(for: .milliseconds(20))
                    if self?.thermal === thermal { self?.updateThermalStatus() }
                }
                if self?.thermal === thermal { self?.updateThermalStatus() }
            }
        }
        if let groundShock {
            let limit = catchUpLimits.groundShock
            Task { [weak self] in
                let start = ContinuousClock.now
                while !groundShock.caughtUp, CatchUpLimits.within(limit, since: start) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if self?.groundShock === groundShock { self?.updateGroundShockStatus() }
            }
        }
        if errorMessage == nil, var inputs = loadedRunSettings {
            inputs.duration = duration
            completedRunSettings = inputs
        }
        if errorMessage == nil, let solver, solver.time >= duration - 1e-9 { followCloud(solver) }
    }

    /// Records the structure's deflection, and hands the solver to `onSample`, if a sample falls
    /// due now: at every one, whether or not it is shown then.
    private func recordSampleIfDue(_ solver: BlastSolver) {
        guard samples, lastSampleTime != solver.time,
            solver.time >= nextStructureSampleTime - 1e-9 || solver.time >= duration - 1e-9
        else { return }
        let summaries = summarise(solver)
        let summary = summaries.structure
        stopIfSolverFailed(solver, summary: summary)
        guard summary?.hasBlownUp != true else { return }
        if let summary, structureRecord.last?.time != solver.time * 1000 {
            structureRecord.append(
                StructureSample(
                    id: structureRecord.count, time: solver.time * 1000,
                    deflection: Double(summary.maxDisplacement) * 1000))
        }
        for (id, summary) in summaries.bodies where bodyRecords[id]?.last?.time != solver.time * 1000 {
            var history = bodyRecords[id] ?? []
            history.append(
                StructureSample(
                    id: history.count, time: solver.time * 1000,
                    deflection: Double(summary.maxDisplacement) * 1000))
            bodyRecords[id] = history
        }
        nextStructureSampleTime =
            (floor(solver.time / sampleInterval + 1e-6) + 1) * sampleInterval
        lastSampleTime = solver.time
        onSample?(solver)
    }

    /// Each body's summary, and the structure's as `BlastSolver.bodySummary()` combines them,
    /// from one pass over each body's mesh: taken once for the whole and again for each body, the
    /// passes were most of a debug build's structural run (19 October 2026).
    private func summarise(_ solver: BlastSolver) -> (
        structure: StructureSummary?, bodies: [(id: UUID, summary: StructureSummary)]
    ) {
        let bodies = solver.bodies.compactMap { body in body.summary().map { (id: body.id, summary: $0) } }
        let structure = bodies.reduce(StructureSummary?.none) { total, body in
            total.map { $0.combined(with: body.summary) } ?? body.summary
        }
        return (structure, bodies)
    }

    /// Stops the run where the solver can no longer go on.
    private func stopIfSolverFailed(_ solver: BlastSolver, summary: StructureSummary?) {
        if solver.interObjectContactDetected {
            errorMessage =
                "Independent structures entered overlapping envelopes or resolved cells. Inter-object contact is unsupported; reset and separate the bodies."
            isRunning = false
        }
        if solver.couplingCapacityExceeded {
            errorMessage =
                "Local coupling storage could not cover the moving geometry. The run stopped before a completed result could be captured."
            isRunning = false
        }
        if summary?.hasBlownUp == true {
            errorMessage = "The structure became numerically unstable. Reset and try a smaller charge."
            isRunning = false
        }
    }

    /// Shows the structure's state and histories, and copies the gauge histories into chart-sized
    /// traces, keeping the extremes of each bucket: at most ten times a second while running, as
    /// the charts and the readouts are drawn again each time.
    func publishTraces() {
        guard let solver else { return }
        lastTracePublication = .now
        envelopeExposure = solver.envelopeExposureSummaries() ?? []
        // SDOF over every component is cheap but not free: at most once a second while running
        // (less often where it takes long), and once more when the run stops.
        if !isRunning || ContinuousClock.now - lastEnvelopeDamage > max(.seconds(1), envelopeDamageCost * 20)
        {
            refreshEnvelopeDamage()
        }
        recordSampleIfDue(solver)
        let summaries = summarise(solver)
        structureSummary = summaries.structure
        bodySummaries = Dictionary(uniqueKeysWithValues: summaries.bodies.map { ($0.id, $0.summary) })
        stopIfSolverFailed(solver, summary: structureSummary)
        if structuresInContactFrom == nil, solver.bodiesInContact { structuresInContactFrom = solver.time }
        structureHistory = structureRecord
        bodyHistories = bodyRecords
        updateFragmentStatus()
        updateGroundShockStatus()
        updateThermalStatus()
        let ambient = scenario.atmosphere.pressure
        // Enough for the chart's width: each point is the extreme of its bucket, so peaks show, and
        // Charts takes tens of milliseconds a redraw at a thousand points a gauge.
        let maxPoints = 300
        for (index, history) in solver.gaugeHistories.enumerated() where index < traces.count {
            let bucket = max(1, (history.count + maxPoints - 1) / maxPoints)
            var points: [GaugePoint] = []
            points.reserveCapacity(history.count / bucket + 1)
            var peak = 0.0
            var start = 0
            while start < history.count {
                let end = min(start + bucket, history.count)
                var best = history[start]
                for sample in history[start..<end]
                where abs(sample.pressure - ambient) > abs(best.pressure - ambient) {
                    best = sample
                }
                let overpressure = Double(best.pressure - ambient) / 1000
                peak = max(peak, overpressure)
                points.append(
                    GaugePoint(id: points.count, time: best.time * 1000, overpressure: overpressure))
                start = end
            }
            traces[index].points = points
            traces[index].peak = peak
        }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
