import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's controls: opening a preset, a scenario or a document, and the run's playback.
// Split from SimulationModel.swift (emmettl/bombcad-work#52).
extension SimulationModel {
    func toggleRun() {
        guard !sweep.isActive else { return }
        // A run on another Mac is paused there (`toggleRemotePause`).
        if remoteRun?.isActive == true {
            toggleRemotePause()
            return
        }
        if !isRunning, let host = runHost {
            startRemoteRun(on: host)
            return
        }
        if isRunning {
            isRunning = false
        } else {
            run()
        }
    }

    func run() {
        guard solver != nil, runtimeInputsMatch, !isLoadingInputs, !rebuildPending, !isRunning,
            !isPreparingImports, !importsNeedResampling
        else { return }
        if (solver?.time ?? 0) >= duration - 1e-9 {
            rebuild()
        }
        completedRunSettings = nil
        if isRefiningCloseCalls { cancelCloseCalls(status: "Close-call refinement stopped: a run began.") }
        // Before the first step (a mapped start's clock starts at its solution's time).
        if solver?.stepCount == 0, lastSampleTime == nil {
            // The structures at rest under their own weight first, so that the first sample, and
            // every deflection after it, starts from them as they stood.
            solver?.settleStructures()
            if structureRecord.isEmpty, let summary = structureSummary {
                structureRecord = [
                    StructureSample(id: 0, time: 0, deflection: Double(summary.maxDisplacement) * 1000)
                ]
            }
            if let solver, samples {
                for body in solver.bodies {
                    if let summary = body.summary() {
                        bodyRecords[body.id] = [
                            StructureSample(
                                id: 0, time: 0, deflection: Double(summary.maxDisplacement) * 1000)
                        ]
                    }
                }
                lastSampleTime = 0
                onSample?(solver)
            }
            structureHistory = structureRecord
            bodyHistories = bodyRecords
            if let solver {
                placeAutomatically()
                setFragmentPaneHoles(solver)
                startFragments(solver)
                startGroundShock(solver)
                startThermal(solver)
            }
        }
        if playback != nil { stopReplay() }
        if let solver, solver.stepCount == 0, timelineRecorder == nil { startTimeline(solver) }
        isRunning = true
        restartPacing()
        pump()
    }

    func reset() {
        if remoteRun?.isActive == true {
            stopRemoteRun()
            return
        }
        if sweep.isActive {
            sweep.cancel()
            return
        }
        if importsNeedResampling {
            settingsChanged()
            return
        }
        requestRebuild()
    }

    func resetCamera() {
        camera = .framing(scenario)
    }

    /// A direction the camera orbits in from the keyboard or an assistive app.
    enum Orbit { case left, right, up, down }

    /// The camera turned a step (15°) about its target, as a drag would turn it.
    func orbitCamera(_ direction: Orbit) {
        let step = Float.pi / 12
        switch direction {
        case .left: camera.orbit(deltaAzimuth: step, deltaElevation: 0)
        case .right: camera.orbit(deltaAzimuth: -step, deltaElevation: 0)
        case .up: camera.orbit(deltaAzimuth: 0, deltaElevation: step)
        case .down: camera.orbit(deltaAzimuth: 0, deltaElevation: -step)
        }
    }

    /// The view zooms out as far as `farthestZoom`, so that a domain kilometres across is seen whole.
    var zoomLimits: ClosedRange<Float> { OrbitCamera.defaultZoomLimits.lowerBound...farthestZoom }

    /// The camera a step nearer its target or farther from it, within the view's limits.
    func zoomCamera(in nearer: Bool) {
        camera.zoom(by: nearer ? 0.8 : 1.25, within: zoomLimits)
    }

    /// What the 3D view shows, in words, for an assistive app: the scene, its source, what is in
    /// it, the time and what the surfaces are painted with.
    var viewportSummary: String {
        let scene = settings.scenario
        let size = scene.domainSize
        var parts = ["\(scene.name), \(String(format: "%.0f × %.0f × %.0f m", size.x, size.y, size.z))"]
        if scene.deflagration != nil {
            parts.append("a gas cloud")
        } else {
            let at = settings.chargePosition
            parts.append(
                "\(SimulationSettings.massText(settings.chargeMass)) of TNT at \(String(format: "%.0f, %.0f, %.1f m", at.x, at.y, at.z))"
            )
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        let contents = [
            count(scene.structuralObjects.count, "structure", "structures"),
            count(scene.envelopeObjects.count, "building envelope", "building envelopes"),
            count(scene.fixedObjects.count, "block", "blocks"),
            count(
                (scene.rigidObjects?.count ?? 0) + (scene.rigidCars?.count ?? 0), "freestanding object",
                "freestanding objects"),
            count(scene.gauges.count, "gauge", "gauges"),
        ].compactMap { $0 }
        if !contents.isEmpty { parts.append(contents.joined(separator: ", ")) }
        let state =
            isRunning ? "running" : time == 0 ? "ready" : time >= duration - 1e-9 ? "finished" : "paused"
        parts.append(String(format: "t = %.1f ms, %@", time * 1000, state))
        parts.append("surfaces show \(renderSettings.mode.title.lowercased())")
        if let wave = liveWaveSummary { parts.append(wave) }
        return parts.joined(separator: "; ")
    }

    /// Switches to a built-in layout, adopting its charge, camera and duration.
    func select(_ preset: ScenarioPreset) {
        // A preset replaces the scene within this project; retained assets support undo.
        settings.preset = preset
        sceneLocation = nil
        adopt(preset.scenario)
    }

    /// Replaces the layout with one loaded from a file.
    func open(_ scenario: Scenario) {
        sweep.abandon()
        handledSettings = nil
        savedRuns = []
        projectArchive = nil
        projectDocumentID = UUID()
        sceneLocation = nil
        adopt(scenario)
        undoStack.removeAll()
        redoStack.removeAll()
        settledInputs = currentInputs
        settingsChanged()
    }

    /// Restores a project at time zero, including numerical settings and view preferences.
    func open(_ document: ProjectDocument) {
        sweep.abandon()
        handledSettings = nil
        rebuildTask?.cancel()
        isRunning = false
        renderSettings = RenderSettings()
        adopt(document.scenario)
        savedRuns = document.savedRuns
        fragmentSpec = document.fragments
        groundShockSpec = document.groundShock
        thermalSpec = document.thermal
        cloudSpec = document.cloud
        farFieldSet = document.farField
        sceneLocation = document.location
        chargeMarking.restore(document.chargeMarks)
        projectArchive = document.archive
        projectDocumentID = document.documentID
        if let run = document.runSettings {
            settings.resolution = Resolution(rawValue: run.resolution)!
            settings.detailedCharge = run.detailedCharge
            settings.sharpShocks = run.sharpShocks
            settings.shockLevels = run.shockLevels ?? 1
            settings.shockThreshold = run.shockThreshold ?? 0.1
            settings.refinementCeiling = run.refinementCeiling
            settings.adaptiveSubsteps = run.adaptiveSubsteps ?? false
            settings.gravity = run.gravity ?? false
            settings.terrainCutCells = run.cutsTerrain(over: document.scenario)
            settings.outlineByOverlap = run.countsByOverlap(over: document.scenario)
            settings.ventsGlazing = run.ventsGlazing(over: document.scenario)
            settings.settlesStructures = run.settlesStructures(over: document.scenario)
            settings.mappedStart = run.startsMapped
            settings.radiativeCooling = run.cools
            settings.refineToward = run.refineToward ?? []
            settings.softGround = run.groundStiffness != nil
            settings.groundStiffness = run.groundStiffness ?? SolverConfiguration.soilSubgradeModulus
            settings.ground = run.ground ?? .rigid
            settings.waterTable = run.waterTable
            settings.solidElementSize = run.solidElementSize
            duration = run.duration
        }
        if let view = document.viewSettings {
            camera = view.camera
            renderSettings = view.rendering
        }
        undoStack.removeAll()
        redoStack.removeAll()
        settledInputs = currentInputs
        isPlacingCharge = false
        settingsChanged()
    }

    private func adopt(_ scenario: Scenario) {
        settings.scenario = scenario
        inspectedImportID = nil
        if let h = scenario.importedModels?.first(where: { $0.isAttached })?.preview.cellSize,
            let resolution = Resolution(cellSize: h)
        {
            settings.resolution = resolution
        }
        selection = nil
        camera = .framing(scenario)
        duration = Self.defaultDuration(for: scenario)
        // Structure scenarios are viewed from close by, where the wave would hide the building
        // and the pressures are higher.
        let closeUp = scenario.structure != nil
        renderSettings.waveOpacity = closeUp ? 0.06 : RenderSettings().waveOpacity
        renderSettings.pressureScale = closeUp ? 1000 : RenderSettings().pressureScale
    }

    /// Call when `settings` changes; records the edit and rebuilds once the edits settle.
    var importsNeedResampling: Bool {
        (settings.scenario.importedModels ?? []).contains {
            $0.needsSampling(cellSize: settings.resolution.cellSize)
        }
    }
    func settingsChanged() {
        // A charge being dragged, or a control the estimate follows held, is loaded once it is let go
        // (`endDrag`, `endAdjustingEstimate`); meanwhile the estimate follows as a preview.
        guard !isDraggingCharge else { return }
        guard !isAdjustingEstimate else {
            adjustedEstimate()
            return
        }
        guard settings != handledSettings || importsNeedResampling else { return }
        isLoadingInputs = true
        rebuildTask?.cancel()
        isPreparingImports = importsNeedResampling
        if isPreparingImports { isRunning = false }
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if importsNeedResampling {
                let source = settings.scenario
                let h = settings.resolution.cellSize
                let sampling = Task.detached(priority: .userInitiated) {
                    Result { try source.resamplingImports(cellSize: h) }
                }
                let result = await withTaskCancellationHandler(
                    operation: { await sampling.value }, onCancel: { sampling.cancel() })
                guard !Task.isCancelled, settings.scenario == source, settings.resolution.cellSize == h else {
                    return
                }
                isPreparingImports = false
                switch result {
                case .success(let updated):
                    settings.scenario = updated
                    if let body = updated.structure { settings.solidElementSize = body.elementSize }
                case .failure(let error):
                    isLoadingInputs = false
                    errorMessage =
                        "Could not resample retained sources: \(error.localizedDescription) Simulation is paused; choose another grid or detach the affected model."
                    return
                }
            }
            isPreparingImports = false
            recordEdit()
            requestRebuild()
        }
    }
    func detachImport(id: UUID) {
        settings.scenario.detachImport(id: id)
        settingsChanged()
    }
    func removeImport(id: UUID) {
        guard let imported = settings.scenario.importedModels?.first(where: { $0.id == id }) else { return }
        if imported.isAttached && imported.behavior == .deformable {
            guard let owner = settings.scenario.structuralObject(sourceID: id),
                imported.canRegenerate(owner.structure)
            else {
                errorMessage = "Detach this edited structure before removing its source."
                return
            }
            try? settings.scenario.updateStructureObject(id: owner.id, model: nil)
        }
        for object in settings.scenario.structuralObjects {
            var body = object.structure!
            body.solidSourceParts = body.solidSourceParts.map { $0?.modelID == id ? nil : $0 }
            try? settings.scenario.updateStructureObject(id: object.id, model: body)
        }
        settings.scenario.importedModels?.removeAll { $0.id == id }
        settings.scenario.clearSourceOwnership(id: id)
        selection = nil
        settingsChanged()
    }
}
