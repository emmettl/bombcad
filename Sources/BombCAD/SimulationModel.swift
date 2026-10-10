import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

enum Resolution: String, CaseIterable, Identifiable, Sendable {
    case coarse
    case medium
    case fine

    var id: String { rawValue }

    var cellSize: Float {
        switch self {
        case .coarse: 0.5
        case .medium: 0.25
        case .fine: 0.125
        }
    }

    var title: String {
        switch self {
        case .coarse: "Coarse · 0.5 m"
        case .medium: "Medium · 0.25 m"
        case .fine: "Fine · 0.125 m"
        }
    }
}

/// How much slower than real time the simulation is played back.
enum PlaybackSpeed: Double, CaseIterable, Identifiable, Sendable {
    case x25 = 25
    case x50 = 50
    case x100 = 100
    case x250 = 250
    case x1000 = 1000
    case unlimited = 0

    var id: Double { rawValue }

    var title: String {
        self == .unlimited ? "As fast as possible" : "\(Int(rawValue))× slow motion"
    }
}

/// Everything that requires the simulation to be rebuilt when it changes.
struct SimulationSettings: Equatable {
    /// The layout most recently chosen from the built-in list.
    var preset = ScenarioPreset.streetCanyon
    /// The scenario as edited: it starts as a copy of the preset and can then be changed freely.
    var scenario = ScenarioPreset.streetCanyon.scenario
    var resolution = Resolution.medium
    /// Burn the charge's products in the air, and let hot air store energy in molecular
    /// vibration: closer to tests, about twice as slow.
    var detailedCharge = false
    /// Refine the air twice over where the shock is, so that peak pressures come out as on a grid
    /// twice as fine.
    var sharpShocks = false
    /// With `sharpShocks`, the levels of refinement: 2 refines the refined air again, so that the
    /// peaks come out as on a grid four times as fine.
    var shockLevels = 1
    /// Gravity in the air: it starts at rest in a hydrostatic atmosphere and hot gas rises.
    var gravity = false

    var chargeMass: Float {
        get { scenario.charge.mass }
        set { scenario.charge.mass = newValue }
    }

    var chargePosition: SIMD3<Float> {
        get { scenario.charge.position }
        set { scenario.charge.position = newValue }
    }

    /// Material of the deformable structure, for scenarios that have one.
    var material: StructureMaterial {
        get { scenario.structure?.material ?? .reinforcedConcrete }
        set { scenario.structure?.material = newValue }
    }

    /// Solid size to return to when a structure meshed with shells goes back to solids.
    var solidElementSize: Float = 0.0625

    /// How the deformable structure is meshed. Shells are 250 mm across; going back to solids
    /// restores the size the structure had before.
    var elementKind: ElementKind {
        get { scenario.structure?.elementKind ?? .solid }
        set {
            guard var structure = scenario.structure, structure.elementKind != newValue else { return }
            if newValue == .shell {
                solidElementSize = structure.elementSize
                structure.elementSize = Self.shellSize
            } else {
                structure.elementSize = solidElementSize
            }
            structure.elementKind = newValue
            scenario.structure = structure
        }
    }

    static let shellSize: Float = 0.25
}

/// The part of the layout picked out for editing.
enum EditSelection: Hashable {
    case block(UUID)
    case solid(SceneObject.ComponentReference)
    case opening(SceneObject.ComponentReference)
    case support(SceneObject.ComponentReference)
    case part(StructureModel.SourcePart)
    case gauge(Int)
    case imported(UUID)
}

struct GaugePoint: Identifiable {
    let id: Int
    /// Milliseconds since detonation.
    var time: Double
    /// Overpressure in kPa.
    var overpressure: Double
}

struct GaugeTrace: Identifiable {
    let id: Int
    var name: String
    var points: [GaugePoint] = []
    /// Largest overpressure so far, in kPa.
    var peak: Double = 0
}

/// The structure's response at one moment of the run.
struct StructureSample: Identifiable {
    let id: Int
    /// Milliseconds since detonation.
    var time: Double
    /// Largest deflection of the intact structure, in millimetres.
    var deflection: Double
}

struct SimulationStats {
    /// Cells advanced by one time step per second of GPU time.
    var cellUpdatesPerSecond: Double = 0
    var stepsPerSecond: Double = 0
    /// Wall-clock seconds per simulated second actually achieved.
    var slowMotion: Double = 0
    /// Size of the latest time step in seconds.
    var timeStep: Double = 0
}

/// Owns the solver and renderer and drives them from the main actor. GPU work is committed
/// without blocking; completion handlers hop back here to schedule the next batch.
@MainActor
@Observable
final class SimulationModel {
    var settings = SimulationSettings()
    /// Freestanding objects' computed motion (see `FreestandingObjectsSection`).
    let freestanding = FreestandingMotionState()
    @ObservationIgnored var projectArchive: ProjectArchive?
    var projectDocumentID = UUID()
    var renderSettings = RenderSettings()
    var camera: OrbitCamera
    var speed = PlaybackSpeed.x100 {
        didSet { restartPacing() }
    }
    /// Simulated time at which the run stops, in seconds.
    var duration: Double
    private(set) var savedRuns: [SavedSimulationRun] = []
    @ObservationIgnored private var loadedRunSettings: ProjectRunSettings?
    /// Observed: `canKeepRun` reads nothing else until a run completes, so a view showing it
    /// must learn of the completion through this.
    private var completedRunSettings: ProjectRunSettings?
    static let structureSampleInterval = 0.001
    /// Called with the solver every `structureSampleInterval` of simulated time from time zero,
    /// while no batch is in flight. A run with a structure stops there anyway to sample it; one
    /// without stops there only while this is set.
    @ObservationIgnored var onSample: ((BlastSolver) -> Void)?
    /// How often `onSample` is called in a run without a structure, a whole number of
    /// `structureSampleInterval`s: each sample stops the run, so the fewer the better.
    @ObservationIgnored var airSampleInterval = structureSampleInterval
    /// Called with the solver and the batch's time limit just before each batch is encoded, after
    /// any hold: the place to set `frameRequest` for a batch that may end on a frame.
    @ObservationIgnored var prepareBatch: ((BlastSolver, Double) -> Void)?
    /// While this says so, the run waits before its next batch: a consumer of its frames has
    /// fallen behind. Checked every couple of milliseconds; the main thread is not blocked.
    @ObservationIgnored var holdBatches: (() -> Bool)?
    @ObservationIgnored private var waitingForHold = false
    @ObservationIgnored private var lastSampleTime: Double?
    /// Vent panels the renderer has been told have opened.
    @ObservationIgnored private var openedVentPanels = 0
    private var samples: Bool { structureSummary != nil || onSample != nil }
    private var sampleInterval: Double {
        structureSummary != nil ? Self.structureSampleInterval : airSampleInterval
    }
    @ObservationIgnored private var nextStructureSampleTime = structureSampleInterval
    /// The block or wall being edited, which the view outlines.
    var selection: EditSelection?
    var selectedStructureID: UUID?
    var editedObject: SceneObject? {
        let scene = settings.scenario
        switch selection {
        case .solid(let ref), .opening(let ref), .support(let ref): return scene.object(id: ref.objectID)
        case .part(let ref): return scene.structuralObject(sourceID: ref.modelID)
        case .imported(let id):
            if let object = scene.structuralObject(sourceID: id) { return object }
        default: break
        }
        return selectedStructureID.flatMap { scene.object(id: $0) }.flatMap { $0.structure == nil ? nil : $0 }
            ?? scene.structuralObject
    }
    var editedStructure: StructureModel? { editedObject?.structure }
    var editedMaterial: StructureMaterial { editedStructure?.material ?? .reinforcedConcrete }
    var editedElementKind: ElementKind { editedStructure?.elementKind ?? .solid }
    var editedSolidElementSize: Float { editedObject?.preferredSolidElementSize ?? settings.solidElementSize }
    func rememberSolidElementSize(_ size: Float, objectID: UUID? = nil) {
        guard let id = objectID ?? editedObject?.id else { return }
        do { try settings.scenario.setPreferredSolidElementSize(id: id, size: size) } catch {
            errorMessage = error.localizedDescription
        }
        if settings.scenario.structuralObject?.id == id { settings.solidElementSize = size }
    }
    func selectStructure(id: UUID?) {
        selectedStructureID = id
        selection = nil
    }

    func addIndependentStructure() {
        let scene = settings.scenario
        let centre = scene.domainSize / 2
        let x =
            scene.structuralObjects.compactMap { $0.structure?.bounds.max.x }.max().map { $0 + 1 } ?? centre.x
        var body = StructureModel(
            solids: [Box(x: x...(x + 0.25), y: (centre.y - 2)...(centre.y + 2), height: 3)],
            elementSize: settings.solidElementSize)
        body.autoReinforce()
        do {
            let id = try settings.scenario.addStructureObject(
                body, name: "Structure \(scene.structuralObjects.count + 1)")
            selectStructure(id: id)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeEditedStructure() {
        guard let object = editedObject else { return }
        if let source = object.sourceModelID {
            guard settings.scenario.importedModels?.first(where: { $0.id == source })?.isAttached != true
            else {
                errorMessage = "Detach or remove this imported model through its source controls."
                return
            }
        }
        do { try settings.scenario.updateStructureObject(id: object.id, model: nil) } catch {
            errorMessage = error.localizedDescription
            return
        }
        selectedStructureID = nil
        selection = nil
    }

    func useEditedEnvelope() {
        guard !isPreparingImports, let object = editedObject else { return }
        do {
            var scene = settings.scenario
            try scene.useEnvelope(id: object.id)
            try scene.validateObjectOwnership()
            settings.scenario = scene
            selectedStructureID = nil
            selection = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeEnvelope(id: UUID) {
        guard !isPreparingImports, settings.scenario.object(id: id)?.envelope != nil else { return }
        do { try settings.scenario.removeObject(id: id) } catch { errorMessage = error.localizedDescription }
    }

    var inspectedImportID: UUID?
    /// While set, a click on the ground in the view moves the charge there.
    var isPlacingCharge = false
    /// Shows the sheet for exporting the project's run for rendering.
    var showsRenderExport = false

    private(set) var isRunning = false {
        didSet {
            guard isRunning != (runActivity != nil) else { return }
            if isRunning {
                // A run is work the user is waiting for, even with the window behind another app:
                // without this, macOS moves a background app's main thread to the efficiency cores
                // on a busy Mac, and each batch's round trip, and each redraw of the chart, takes
                // several times as long.
                runActivity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiated, reason: "Running a blast simulation")
            } else if let runActivity {
                ProcessInfo.processInfo.endActivity(runActivity)
                self.runActivity = nil
            }
        }
    }
    @ObservationIgnored private var runActivity: NSObjectProtocol?
    /// The solver's time, step count and rates, as last shown: while running, at most every
    /// `progressInterval`, not after every batch, since everything that shows them is drawn again.
    private(set) var time: Double = 0
    private(set) var stepCount = 0
    private(set) var traces: [GaugeTrace] = []
    private(set) var stats = SimulationStats()
    @ObservationIgnored private var liveStats = SimulationStats()
    /// The GPU's time on the blast's batches since the run began, in seconds, as each command
    /// buffer's start and end on the GPU give it; work sharing the GPU stretches it.
    @ObservationIgnored private(set) var blastGPUSeconds = 0.0
    @ObservationIgnored private var lastProgressPublication = ContinuousClock.now
    private static let progressInterval = 1.0 / 60
    private(set) var grid: Grid?
    /// Damage and deflection of the deformable structure, if the scenario has one.
    private(set) var structureSummary: StructureSummary?
    private(set) var structureSubsteps = 0
    /// Deflection of the structure through the run, a sample every `structureSampleInterval`,
    /// and of each structure, as last shown, at most ten times a second while running.
    private(set) var structureHistory: [StructureSample] = []
    private(set) var bodyHistories: [UUID: [StructureSample]] = [:]
    /// The same, up to the latest sample.
    @ObservationIgnored private var structureRecord: [StructureSample] = []
    @ObservationIgnored private var bodyRecords: [UUID: [StructureSample]] = [:]
    private(set) var bodySummaries: [UUID: StructureSummary] = [:]
    /// Largest deflection recorded so far, in millimetres.
    var peakDeflection: Double { structureHistory.map(\.deflection).max() ?? 0 }
    private(set) var memoryFootprint = 0
    private(set) var chargeIsBlocked = false
    private(set) var errorMessage: String?
    private(set) var isPreparingImports = false
    private(set) var isLoadingInputs = false
    /// Layouts before the most recent edits, newest last, and those undone since.
    private(set) var undoStack: [SimulationInputs] = []
    private(set) var redoStack: [SimulationInputs] = []
    var canUndo: Bool { !sweep.isActive && (!undoStack.isEmpty || currentInputs != settledInputs) }
    var canRedo: Bool { !sweep.isActive && !redoStack.isEmpty }

    @ObservationIgnored let device: MTLDevice?
    @ObservationIgnored let commandQueue: MTLCommandQueue?
    @ObservationIgnored let renderer: SceneRenderer?
    /// Counts the scenes handed to the renderer, which keeps them outside Observation, so a view
    /// that draws only on change draws each new one.
    private(set) var sceneVersion = 0
    @ObservationIgnored private var solver: BlastSolver?
    @ObservationIgnored private var scenario: Scenario
    @ObservationIgnored private var batchInFlight = false
    @ObservationIgnored private var rebuildPending = false
    @ObservationIgnored private var waitingForPace = false
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var batchSize = 4
    @ObservationIgnored private var paceOriginWall = ContinuousClock.now
    @ObservationIgnored private var paceOriginTime: Double = 0
    @ObservationIgnored private var lastBatchCompletion = ContinuousClock.now
    @ObservationIgnored private var lastTracePublication = ContinuousClock.now
    /// The layout as of the last recorded edit. Edits are recorded once they settle, so that
    /// typing a number or dragging a slider is one step to undo, not dozens.
    @ObservationIgnored private var settledInputs: SimulationInputs?
    @ObservationIgnored private var handledSettings: SimulationSettings?
    @ObservationIgnored lazy var sweep = ParameterSweep(model: self)
    /// The project's fragments, if it flies any: a cased charge's fragments and tracers, flown
    /// one way through the blast from the start of each run and drawn over it. Saved with the
    /// project; changes take effect from the next run, and settle into a step to undo.
    var fragmentSpec: FragmentSpec? {
        didSet {
            guard fragmentSpec != oldValue, !isApplyingInputs else { return }
            fragmentEdit?.cancel()
            fragmentEdit = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                recordEdit()
            }
        }
    }
    @ObservationIgnored private var fragmentEdit: Task<Void, Never>?
    @ObservationIgnored private var isApplyingInputs = false
    /// The Mac, of those set for sweeps in Settings, to fly the fragments on; nil for this one.
    var fragmentsHost: String?
    /// Where the fragments of the run stand: how many are in flight and landed.
    private(set) var fragmentStatus = ""
    /// The run's fragments, in flight and landed, to draw.
    private(set) var fragmentLive: FragmentLive?
    @ObservationIgnored private(set) var fragments: (any FrameConsumer)?
    @ObservationIgnored private var fragmentTime = -1.0
    private static let fragmentFrameInterval = 0.001
    @ObservationIgnored private var fragmentLaunchSpeed: Float = 1
    /// The fragments the current run flies, as they were when it started.
    @ObservationIgnored private var flownSpec: FragmentSpec?
    /// Connections to the Macs the companions run on, by host, shared by those on the same one.
    @ObservationIgnored private var workers: [String: SweepWorkerClient] = [:]
    /// The project's ground points, if it has any: where to estimate the ground's shaking from
    /// the overpressure on the ground, one way, through each run. Saved with the project, like
    /// the fragments; changes take effect from the next run and settle into a step to undo.
    var groundShockSpec: GroundShockSpec? {
        didSet {
            guard groundShockSpec != oldValue, !isApplyingInputs else { return }
            groundShockEdit?.cancel()
            groundShockEdit = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                recordEdit()
            }
        }
    }
    /// The fireball's thermal radiation, if the project reckons it: found from the run's luminous
    /// gas at batch ends, its radiation on the scene reckoned here or on the Mac set for sweeps,
    /// and drawn over the blast. Saved with the project; changes take effect from the next run,
    /// and settle into a step to undo.
    var thermalSpec: ThermalSpec? {
        didSet {
            guard thermalSpec != oldValue, !isApplyingInputs else { return }
            thermalEdit?.cancel()
            thermalEdit = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                recordEdit()
            }
        }
    }
    /// The fireball's rise and cloud, if the project follows it: the hot gas left at the end of a
    /// run handed over to the cloud model and followed for minutes after, and drawn over the
    /// scene. Saved with the project; changes take effect from the next run, and settle into a
    /// step to undo.
    var cloudSpec: CloudSpec? {
        didSet {
            guard cloudSpec != oldValue, !isApplyingInputs else { return }
            cloudEdit?.cancel()
            cloudEdit = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                recordEdit()
            }
        }
    }
    @ObservationIgnored private var cloudEdit: Task<Void, Never>?
    /// Where the cloud of the run just finished went, once followed.
    private(set) var cloud: CloudResult?
    /// The cloud being followed, after the run has reached its end.
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    /// Whether the cloud is being followed now.
    private(set) var followingCloud = false
    @ObservationIgnored private var groundShockEdit: Task<Void, Never>?
    /// How the ground has moved so far in the run, at each point, and a line saying so.
    private(set) var groundShockLive: GroundShockResult?
    private(set) var envelopeExposure: [EnvelopeExposureSummary] = []
    private(set) var envelopeExposureStatus = ""

    var canExportEnvelopeExposure: Bool {
        !isRunning && !batchInFlight && !isLoadingInputs && !rebuildPending
            && settings.scenario == scenario && stepCount > 0 && !envelopeExposure.isEmpty
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
    private(set) var groundShockStatus = ""
    @ObservationIgnored private(set) var groundShock: (any FrameConsumer)?
    @ObservationIgnored private var groundShockTime = -1.0
    /// The ground points the current run estimates, as they were when it started.
    @ObservationIgnored private var estimatedGroundSpec: GroundShockSpec?
    @ObservationIgnored private var thermalEdit: Task<Void, Never>?
    /// The Mac, of those set for sweeps, to reckon the thermal radiation on; nil for this one.
    var thermalHost: String?
    /// The Mac, of those set for sweeps, to estimate the ground's shaking on; nil for this one.
    var groundShockHost: String?
    /// Where the run's thermal radiation stands: the largest fireball and the highest fluence.
    private(set) var thermalStatus = ""
    /// Frames of the run's thermal radiation reckoned so far, as last published: the receivers
    /// change with it, though they are read outside Observation.
    private(set) var thermalReckoned = 0
    @ObservationIgnored private(set) var thermal: (any FrameConsumer)?
    /// Where the current run's thermal radiation is reckoned, laid out here as wherever it runs.
    @ObservationIgnored private(set) var thermalReceivers: [ThermalReceiver] = []
    /// The same receivers by surface, the grids the view paints.
    @ObservationIgnored private var thermalGrids: [ThermalSurfaceGrid] = []
    /// The material each receiver's surface was given, where their heating is reckoned.
    @ObservationIgnored private var thermalHeating: SurfaceHeating.Layout?
    /// The thermal radiation the current run reckons, as it was when it started, and the
    /// fireball at each frame sent.
    @ObservationIgnored private var reckonedSpec: ThermalSpec?
    @ObservationIgnored private var fireballFrames: [FireballFrame] = []
    @ObservationIgnored private var nextFireballTime = 0.0
    @ObservationIgnored private var thermalPaintCache:
        (frames: Int, quantity: ThermalQuantity, paint: SurfacePaint)?
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
    /// What the companions cost, kept between runs for those placed automatically; nil keeps it
    /// for this model only, as in tests. The app keeps it in the user's caches.
    @ObservationIgnored var costStore: ConsumerCostStore?
    @ObservationIgnored private var measuredCosts: [String: ConsumerCosts] = [:]
    /// Where the current run's companions placed automatically went, by name ("local" or a host),
    /// and the key their costs are kept under.
    @ObservationIgnored private(set) var automaticPlaces: [String: String] = [:]
    @ObservationIgnored private var runCostKey: String?
    /// Whether the run's companions, the fragments, the thermal radiation and the ground shock,
    /// have every frame sent, so that the run can be kept.
    var companionsCaughtUp: Bool {
        [fragments, thermal, groundShock].allSatisfy { $0?.caughtUp ?? true } && !followingCloud
    }
    private static let undoLimit = 100

    init(document: ProjectDocument? = nil, playbackSpeed: PlaybackSpeed = .x100) {
        let scenario = document?.scenario ?? SimulationSettings().scenario
        self.scenario = scenario
        camera = .framing(scenario)
        duration = Self.defaultDuration(for: scenario)
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        do {
            renderer = try device.map { try SceneRenderer(device: $0) }
        } catch {
            renderer = nil
            errorMessage = "Could not build the renderer: \(error)"
        }
        if let document {
            settings.scenario = scenario
            savedRuns = document.savedRuns
            fragmentSpec = document.fragments
            groundShockSpec = document.groundShock
            thermalSpec = document.thermal
            cloudSpec = document.cloud
            projectArchive = document.archive
            projectDocumentID = document.documentID
            if let run = document.runSettings {
                settings.resolution = Resolution(rawValue: run.resolution)!
                settings.detailedCharge = run.detailedCharge
                settings.sharpShocks = run.sharpShocks
                settings.shockLevels = run.shockLevels ?? 1
                settings.gravity = run.gravity ?? false
                settings.solidElementSize = run.solidElementSize
                duration = run.duration
            }
            if let view = document.viewSettings {
                camera = view.camera
                renderSettings = view.rendering
            }
        }
        speed = playbackSpeed
        if device == nil {
            errorMessage = "This Mac has no Metal device."
        }
        settledInputs = currentInputs
        // Autosave can capture the chosen grid before retained-source sampling finishes.
        // Resume that work when opening a new document session, before building a solver.
        if importsNeedResampling {
            settingsChanged()
        } else {
            rebuild()
        }
    }

    private static func defaultDuration(for scenario: Scenario) -> Double {
        // A structure keeps moving long after the blast wave has left the domain.
        let crossing = (scenario.acousticCrossingTime * 100).rounded(.up) / 100
        return scenario.structure == nil ? crossing : max(crossing, 0.25)
    }

    // MARK: - Controls

    func toggleRun() {
        guard !sweep.isActive else { return }
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
        if solver?.time == 0, lastSampleTime == nil {
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
                startFragments(solver)
                startGroundShock(solver)
                startThermal(solver)
            }
        }
        isRunning = true
        restartPacing()
        pump()
    }

    func reset() {
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

    /// Switches to a built-in layout, adopting its charge, camera and duration.
    func select(_ preset: ScenarioPreset) {
        // A preset replaces the scene within this project; retained assets support undo.
        settings.preset = preset
        adopt(preset.scenario)
    }

    /// Replaces the layout with one loaded from a file.
    func open(_ scenario: Scenario) {
        sweep.abandon()
        handledSettings = nil
        savedRuns = []
        projectArchive = nil
        projectDocumentID = UUID()
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
        projectArchive = document.archive
        projectDocumentID = document.documentID
        if let run = document.runSettings {
            settings.resolution = Resolution(rawValue: run.resolution)!
            settings.detailedCharge = run.detailedCharge
            settings.sharpShocks = run.sharpShocks
            settings.shockLevels = run.shockLevels ?? 1
            settings.gravity = run.gravity ?? false
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
            let resolution = Resolution.allCases.first(where: { $0.cellSize == h })
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
    private var importsNeedResampling: Bool {
        (settings.scenario.importedModels ?? []).contains {
            $0.isAttached && $0.preview.cellSize != settings.resolution.cellSize
        }
    }
    func settingsChanged() {
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

    // MARK: - Undo

    /// Makes the current layout a step that can be undone back to, if it has changed.
    func recordEdit() {
        guard !sweep.isActive else { return }
        let inputs = currentInputs
        guard let previous = settledInputs, inputs != previous else {
            settledInputs = inputs
            return
        }
        undoStack.append(previous)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        settledInputs = inputs
    }

    func undo() {
        guard !sweep.isActive else { return }
        recordEdit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentInputs)
        settledInputs = previous
        applyInputs(previous)
    }

    func redo() {
        guard !sweep.isActive, let next = redoStack.popLast() else { return }
        undoStack.append(currentInputs)
        settledInputs = next
        applyInputs(next)
    }

    var currentInputs: SimulationInputs {
        SimulationInputs(
            scenario: settings.scenario, settings: ProjectRunSettings(model: self), fragments: fragmentSpec,
            groundShock: groundShockSpec,
            thermal: thermalSpec, cloud: cloudSpec)
    }

    /// Inputs from the undo history, fragments and all.
    private func applyInputs(_ inputs: SimulationInputs) {
        fragmentEdit?.cancel()
        groundShockEdit?.cancel()
        thermalEdit?.cancel()
        cloudEdit?.cancel()
        isApplyingInputs = true
        fragmentSpec = inputs.fragments
        groundShockSpec = inputs.groundShock
        thermalSpec = inputs.thermal
        cloudSpec = inputs.cloud
        isApplyingInputs = false
        applyExperimentInputs(inputs)
    }

    private var runtimeInputsMatch: Bool {
        guard var loaded = loadedRunSettings else { return false }
        loaded.duration = duration
        return scenario == settings.scenario && loaded == ProjectRunSettings(model: self)
    }

    var hasPendingGPUWork: Bool { batchInFlight || rebuildPending || isPreparingImports || isLoadingInputs }
    var experimentIsReady: Bool {
        runtimeInputsMatch && !hasPendingGPUWork && !isRunning && time == 0 && errorMessage == nil
    }

    func useRunInputs(id: UUID) throws {
        guard !sweep.isActive, let run = savedRuns.first(where: { $0.id == id }) else {
            throw ProjectFileError.invalid("Finish the sweep before restoring a saved run's inputs.")
        }
        let inputs = SimulationInputs(
            scenario: run.scenario, settings: run.settings, fragments: run.fragments?.spec,
            groundShock: run.groundShock?.spec,
            thermal: run.thermal?.spec, cloud: run.cloud?.spec)
        try inputs.validate()
        recordEdit()
        if inputs != currentInputs {
            undoStack.append(currentInputs)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            redoStack.removeAll()
        }
        settledInputs = inputs
        applyInputs(inputs)
        camera = .framing(inputs.scenario)
    }

    /// Experiment cases bypass debounce and undo. Their owner preserves the document's baseline.
    func applyExperimentInputs(_ inputs: SimulationInputs) {
        isLoadingInputs = true
        rebuildTask?.cancel()
        isRunning = false
        completedRunSettings = nil
        selection = nil
        inspectedImportID = nil
        settings.scenario = inputs.scenario
        settings.resolution = Resolution(rawValue: inputs.settings.resolution)!
        settings.detailedCharge = inputs.settings.detailedCharge
        settings.sharpShocks = inputs.settings.sharpShocks
        settings.shockLevels = inputs.settings.shockLevels ?? 1
        settings.gravity = inputs.settings.gravity ?? false
        settings.solidElementSize = inputs.settings.solidElementSize
        duration = inputs.settings.duration
        handledSettings = settings
        if importsNeedResampling {
            settingsChanged()
        } else {
            isPreparingImports = false
            requestRebuild()
        }
    }

    var domainSize: SIMD3<Float> { settings.scenario.domainSize }

    // MARK: - Editing the layout

    /// The box picked out for editing, if it still exists.
    var highlightedBox: Box? {
        let scenario = settings.scenario
        switch selection {
        case .block(let id): return scenario.object(id: id)?.fixedBox
        case .solid(let reference):
            guard let index = scenario.componentIndex(reference) else { return nil }
            guard let solids = scenario.object(id: reference.objectID)?.structure?.solids,
                solids.indices.contains(index)
            else { return nil }
            return solids[index]
        case .opening(let reference):
            guard let index = scenario.componentIndex(reference) else { return nil }
            guard let openings = scenario.object(id: reference.objectID)?.structure?.openings,
                openings.indices.contains(index)
            else {
                return nil
            }
            return openings[index]
        case .support(let reference):
            guard let index = scenario.componentIndex(reference) else { return nil }
            guard let supports = scenario.object(id: reference.objectID)?.structure?.supports,
                supports.indices.contains(index)
            else {
                return nil
            }
            return supports[index]
        case .part(let reference):
            guard let body = scenario.structuralObject(sourceID: reference.modelID)?.structure,
                let part = StructureEditing.parts(in: scenario).first(where: { $0.id == reference })
            else { return nil }
            return StructureEditing.bounds(of: part.regions, in: body)
        case .gauge(let index):
            guard scenario.gauges.indices.contains(index) else { return nil }
            let position = scenario.gauges[index].position
            return Box(min: position - 0.25, max: position + 0.25)
        case .imported(let id):
            guard let imported = scenario.importedModels?.first(where: { $0.id == id && $0.isAttached })
            else { return nil }
            let volumes =
                imported.behavior == .deformable
                ? scenario.structuralObject(sourceID: id)?.structure?.solids ?? [] : imported.preview.boxes
            return volumes.first.map { first in
                volumes.dropFirst().reduce(first) {
                    Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
                }
            }
        case nil: return nil
        }
    }
    var inspectedImport: ImportedModel? {
        settings.scenario.importedModels?.first { $0.id == inspectedImportID }
    }
    func inspectImport(id: UUID) {
        guard let imported = settings.scenario.importedModels?.first(where: { $0.id == id }) else { return }
        isRunning = false
        selection = imported.isAttached ? .imported(id) : nil
        inspectedImportID = id
    }

    /// Whether another gauge can be added; the solver records at most `BlastSolver.maxGauges`.
    var canAddGauge: Bool { settings.scenario.gauges.count < BlastSolver.maxGauges }

    /// Adds a gauge 1.5 m above the middle of the ground.
    func addGauge() {
        guard canAddGauge else { return }
        let centre = settings.scenario.domainSize / 2
        let name = "Gauge \(settings.scenario.gauges.count + 1)"
        settings.scenario.gauges.append(Gauge(name, at: SIMD3(centre.x, centre.y, 1.5)))
        selection = .gauge(settings.scenario.gauges.count - 1)
    }

    /// Adds gauges 1.5 m above the ground on a line from the charge, where it has the most room,
    /// at the scaled distances of the Kingery-Bulmash curves that fit in the domain, as many as the
    /// solver can record; gauges already there by those names are kept.
    func addGaugeLine() {
        let scenario = settings.scenario
        let names = Set(scenario.gauges.map(\.name))
        let line = scenario.gaugeLine(direction: scenario.roomiestGaugeLineDirection).filter {
            !names.contains($0.name)
        }
        let room = BlastSolver.maxGauges - scenario.gauges.count
        guard room > 0, !line.isEmpty else { return }
        settings.scenario.gauges.append(contentsOf: line.prefix(room))
        selection = nil
    }

    func removeGauge(at index: Int) {
        guard settings.scenario.gauges.indices.contains(index) else { return }
        settings.scenario.gauges.remove(at: index)
        selection = nil
    }

    /// Adds a rigid block in the middle of the domain.
    func addBlock() {
        guard settings.scenario.rigidBoxes.count < SceneRenderer.maxBoxes else {
            errorMessage = "The layout has reached the 2,048 rigid region limit."
            return
        }
        let centre = settings.scenario.domainSize / 2
        let id = settings.scenario.addFixedObject(
            Box(x: (centre.x - 3)...(centre.x + 3), y: (centre.y - 3)...(centre.y + 3), height: 9),
            name: "Block \(settings.scenario.fixedObjects.count + 1)")
        selection = .block(id)
    }

    func removeBlock(at index: Int) {
        guard settings.scenario.fixedObjects.indices.contains(index) else { return }
        removeBlock(id: settings.scenario.fixedObjects[index].id)
    }

    func removeBlock(id: UUID) {
        do { try settings.scenario.removeObject(id: id) } catch {
            errorMessage = error.localizedDescription
            return
        }
        if selection == .block(id) { selection = nil }
    }

    func updateBlock(id: UUID, box: Box) {
        guard settings.scenario.object(id: id)?.fixedBox != nil else { return }
        do { try settings.scenario.updateFixedObject(id: id, box: box) } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateBlock(id: UUID) {
        guard settings.scenario.rigidBoxes.count < SceneRenderer.maxBoxes else {
            errorMessage = "The layout has reached the 2,048 rigid region limit."
            return
        }
        do { selection = .block(try settings.scenario.duplicateFixedObject(id: id)) } catch {
            errorMessage = error.localizedDescription
        }
    }

    func componentSelection(_ kind: SceneObject.ComponentKind, at index: Int) -> EditSelection? {
        let references = editedObject?.references(kind) ?? []
        guard references.indices.contains(index) else { return nil }
        switch kind {
        case .solid: return .solid(references[index])
        case .opening: return .opening(references[index])
        case .support: return .support(references[index])
        }
    }

    struct ComponentRow: Identifiable {
        var reference: SceneObject.ComponentReference
        var index: Int
        var id: SceneObject.ComponentReference { reference }
    }

    func componentRows(_ kind: SceneObject.ComponentKind) -> [ComponentRow] {
        (editedObject?.references(kind) ?? []).enumerated().map {
            ComponentRow(reference: $0.element, index: $0.offset)
        }
    }

    /// A stale editor row must never fall through to another component's array index.
    func editComponent(
        _ reference: SceneObject.ComponentReference,
        _ change: (inout StructureModel, Int) -> Void
    ) {
        guard let index = settings.scenario.componentIndex(reference) else { return }
        editStructure(objectID: reference.objectID, retainingComponents: true) { change(&$0, index) }
    }

    func removeComponent(_ reference: SceneObject.ComponentReference) {
        guard let index = settings.scenario.componentIndex(reference) else { return }
        editStructure(objectID: reference.objectID, removing: reference) { body in
            switch reference.kind {
            case .solid: body.removeSolid(at: index)
            case .opening: body.openings.remove(at: index)
            case .support: body.removeSupport(at: index)
            }
        }
        selection = nil
    }

    /// Adds a 250 mm wall, 4 m long and 3 m high, to the deformable structure, creating the
    /// structure if the layout has none.
    func addWall() {
        let centre = settings.scenario.domainSize / 2
        let wall = Box(x: centre.x...(centre.x + 0.25), y: (centre.y - 2)...(centre.y + 2), height: 3)
        editStructure { $0.solids.append(wall) }
        selection = componentSelection(.solid, at: (editedStructure?.solids.count ?? 1) - 1)
    }

    func removeSolid(at index: Int) {
        let references = editedObject?.references(.solid) ?? []
        guard references.indices.contains(index) else { return }
        editStructure(removing: references[index]) { $0.removeSolid(at: index) }
        selection = nil
    }

    /// Sets the material of one piece of the structure; nil returns it to the structure's own.
    func setMaterial(_ material: StructureMaterial?, ofSolid index: Int, objectID: UUID? = nil) {
        editStructure(objectID: objectID) { $0.setMaterial(material, of: index) }
    }

    /// Meshes one piece of the structure with solid elements or shells. A structure of both
    /// kinds keeps solid elements at their own size and shells at theirs.
    func setElementKind(_ kind: ElementKind, ofSolid index: Int, objectID: UUID? = nil) {
        let target = objectID.flatMap { settings.scenario.object(id: $0) } ?? editedObject
        let solidSize = target?.preferredSolidElementSize ?? settings.solidElementSize
        if let target, let body = target.structure, body.elementKind == .solid {
            rememberSolidElementSize(body.elementSize, objectID: target.id)
        }
        editStructure(objectID: target?.id) { structure in
            structure.setElementKind(kind, of: index)
            if structure.isMixed {
                structure.elementSize = structure.elementKind == .solid ? structure.elementSize : solidSize
                structure.shellElementSize = SimulationSettings.shellSize
                // The size is that of the solid elements, whichever kind the rest of the body is.
                if structure.elementKind == .shell {
                    let kinds = structure.solids.indices.map { structure.elementKind(of: $0) }
                    structure.elementKind = .solid
                    structure.solidElementKind = []
                    for (n, own) in kinds.enumerated() { structure.setElementKind(own, of: n) }
                }
            } else {
                // All one kind again: that is the body's kind, at its own size.
                let kind =
                    structure.solids.indices.first.map { structure.elementKind(of: $0) }
                    ?? structure.elementKind
                structure.solidElementKind = []
                structure.shellElementSize = nil
                if kind != structure.elementKind {
                    structure.elementKind = kind
                    structure.elementSize = kind == .shell ? SimulationSettings.shellSize : solidSize
                }
            }
        }
    }

    /// Sets how one piece of the structure is reinforced.
    func setReinforcement(_ spec: Reinforcement, ofSolid index: Int, objectID: UUID? = nil) {
        editStructure(objectID: objectID) { $0.setReinforcement(spec, of: index) }
    }

    /// Adds an opening (a window or door) to cut out of the structure.
    func addOpening() {
        guard let body = editedStructure, !body.solids.isEmpty else { return }
        let target = selectedStructureBounds ?? body.solids[0]
        let centre = (target.min + target.max) / 2
        var half = simd_min(target.size / 4, SIMD3<Float>(repeating: 0.5))
        let thin = (0..<3).min { target.size[$0] < target.size[$1] } ?? 0
        half[thin] = target.size[thin] / 2 + settings.resolution.cellSize
        let opening = Box(min: centre - half, max: centre + half)
        editStructure { $0.openings.append(opening) }
        selection = componentSelection(.opening, at: (editedStructure?.openings.count ?? 1) - 1)
    }

    func removeOpening(at index: Int) {
        let references = editedObject?.references(.opening) ?? []
        guard references.indices.contains(index) else { return }
        editStructure(removing: references[index]) { structure in
            guard structure.openings.indices.contains(index) else { return }
            structure.openings.remove(at: index)
        }
        selection = nil
    }

    /// Changes the deformable structure and re-derives its reinforcement from the new shapes.
    /// A structure left with no solids is removed.
    func editStructure(
        objectID: UUID? = nil, removing reference: SceneObject.ComponentReference? = nil,
        retainingComponents: Bool = false, _ change: (inout StructureModel) -> Void
    ) {
        guard !isPreparingImports else { return }
        do {
            settings.scenario = try StructureEditing.changing(
                settings.scenario, objectID: objectID ?? editedObject?.id,
                removing: reference, retainingComponents: retainingComponents, change)
        } catch { errorMessage = error.localizedDescription }
    }

    var structuralParts: [StructureEditing.Part] {
        StructureEditing.parts(in: settings.scenario).filter { $0.objectID == editedObject?.id }
    }

    var selectedStructureBounds: Box? {
        switch selection {
        case .solid, .part: highlightedBox
        case .imported(let id):
            settings.scenario.importedModels?.first(where: { $0.id == id })?.behavior == .deformable
                ? highlightedBox : nil
        default: nil
        }
    }

    func setPartMaterial(_ material: StructureMaterial?, for part: StructureModel.SourcePart) {
        guard !isPreparingImports else { return }
        do {
            settings.scenario = try StructureEditing.settingMaterial(
                material, for: part, in: settings.scenario)
        } catch { errorMessage = error.localizedDescription }
    }

    func setPartReinforcement(_ spec: Reinforcement, for part: StructureModel.SourcePart) {
        guard let selected = structuralParts.first(where: { $0.id == part }), !selected.regions.isEmpty else {
            return
        }
        editStructure { body in
            for index in selected.regions { body.setReinforcement(spec, of: index) }
        }
    }

    func setStructureMaterial(_ material: StructureMaterial) {
        editStructure { $0.material = material }
    }

    func setFixedBase(_ fixed: Bool) {
        let imported = settings.scenario.importedModels?.first {
            $0.behavior == .deformable && $0.canRegenerate(editedStructure)
        }
        editStructure { body in
            body.fixedBase = fixed
            if let imported {
                body.supports = imported.supports(fixedBase: fixed)
                body.supportAnchorages = fixed && body.baseAnchorage != nil ? [body.baseAnchorage] : []
            }
        }
    }

    func setBaseAnchorage(_ law: Anchorage?) {
        let imported = settings.scenario.importedModels?.first {
            $0.behavior == .deformable && $0.canRegenerate(editedStructure)
        }
        editStructure { body in
            body.baseAnchorage = law
            if imported != nil {
                body.supportAnchorages = law == nil || !body.fixedBase ? [] : [law]
            }
        }
    }

    func supportBearingArea(at index: Int) -> Float? {
        guard runtimeInputsMatch, !hasPendingGPUWork, !isRunning, let solver else { return nil }
        guard let id = editedObject?.id, let body = solver.body(id: id) else { return nil }
        return (body.solids?.supportBearingArea(at: index) ?? 0)
            + (body.shells?.supportBearingArea(at: index) ?? 0)
    }

    func setSupportAnchorage(_ law: Anchorage?, at index: Int) {
        editStructure { $0.setAnchorage(law, ofSupport: index) }
    }

    func addSupport() {
        guard let body = editedStructure, !body.solids.isEmpty else { return }
        let target = selectedStructureBounds ?? body.bounds
        let thickness = max(body.elementSize, 0.01)
        let support = Box(
            min: target.min - SIMD3(repeating: thickness * 0.01),
            max: SIMD3(
                target.max.x + thickness * 0.01, target.max.y + thickness * 0.01,
                target.min.z + thickness * 0.5))
        editStructure { $0.supports.append(support) }
        selection = componentSelection(.support, at: (editedStructure?.supports.count ?? 1) - 1)
    }

    func removeSupport(at index: Int) {
        let references = editedObject?.references(.support) ?? []
        guard references.indices.contains(index) else { return }
        editStructure(removing: references[index]) { body in
            body.removeSupport(at: index)
        }
        selection = nil
    }

    /// Handles a click in the view, at a point in normalised device coordinates. In placing
    /// mode it moves the selected gauge there, or the charge if no gauge is selected.
    func click(ndc: SIMD2<Float>, aspectRatio: Float) {
        guard !sweep.isActive else { return }
        if !isPlacingCharge {
            guard time == 0, !isRunning, !isPreparingImports else { return }
            let ray = camera.ray(ndc: ndc, aspectRatio: aspectRatio)
            if let id = ScenePicking.importedModel(
                in: settings.scenario, origin: ray.origin, direction: ray.direction)
            {
                inspectImport(id: id)
            } else if case .imported = selection {
                selection = nil
            }
            return
        }
        guard isPlacingCharge, let point = camera.groundPoint(ndc: ndc, aspectRatio: aspectRatio) else {
            return
        }
        let size = settings.scenario.domainSize
        // Snap to 0.25 m so the charge stays aligned with every grid resolution.
        let snapped = (point * Float(4)).rounded(.toNearestOrEven) / Float(4)
        let x = min(max(snapped.x, 1), size.x - 1)
        let y = min(max(snapped.y, 1), size.y - 1)
        if case .gauge(let index) = selection, settings.scenario.gauges.indices.contains(index) {
            settings.scenario.gauges[index].position.x = x
            settings.scenario.gauges[index].position.y = y
        } else {
            settings.chargePosition.x = x
            settings.chargePosition.y = y
        }
    }

    // MARK: - Export

    /// The run's histories as comma-separated values: every recorded sample of every gauge,
    /// then the structure's largest deflection at each sample, one row per sample.
    func resultsCSV() -> String {
        var lines = ["series,time (ms),value,unit"]
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        if let solver {
            let ambient = Double(scenario.atmosphere.pressure)
            for (index, history) in solver.gaugeHistories.enumerated() where index < scenario.gauges.count {
                let name = field(scenario.gauges[index].name)
                for sample in history {
                    lines.append(
                        "\(name),\(String(format: "%.4f", sample.time * 1000)),"
                            + "\(String(format: "%.4f", (Double(sample.pressure) - ambient) / 1000)),kPa")
                }
            }
        }
        for sample in structureRecord {
            lines.append(
                "Largest deflection,\(String(format: "%.4f", sample.time)),\(String(format: "%.3f", sample.deflection)),mm"
            )
        }
        if scenario.structuralObjects.count > 1 {
            for object in scenario.structuralObjects {
                let label = field("\(object.name) [\(object.id.uuidString)] deflection")
                for sample in bodyRecords[object.id] ?? [] {
                    lines.append("\(label),\(sample.time),\(sample.deflection),mm")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var canKeepRun: Bool {
        guard let completed = completedRunSettings else { return false }
        var current = ProjectRunSettings(model: self)
        current.duration = completed.duration
        return !isRunning && !batchInFlight && !rebuildPending && !isPreparingImports && !isLoadingInputs
            && errorMessage == nil && stepCount > 0 && current == completed
            && settings.scenario == scenario && savedRuns.count < SavedSimulationRun.maximumRuns
    }

    func keepRun(named name: String) throws {
        guard canKeepRun, let solver, let inputs = completedRunSettings else {
            throw ProjectFileError.invalid("Complete a stable run before keeping its results.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedRuns.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        else {
            throw ProjectFileError.invalid("Choose a unique name for this run.")
        }
        let keys = SavedSimulationRun.Gauge.keys(Array(scenario.gauges.prefix(BlastSolver.maxGauges)))
        let gauges = zip(keys, solver.gaugeHistories).map { key, history in
            SavedSimulationRun.Gauge(
                key: key,
                points: history.map {
                    .init(
                        time: $0.time,
                        value: (Double($0.pressure) - Double(scenario.atmosphere.pressure)) / 1000)
                })
        }
        let response = structureSummary.map { summary in
            SavedSimulationRun.Structure(
                points: structureRecord.map {
                    .init(time: $0.time / 1000, value: $0.deflection)
                }, failedFraction: Double(summary.erodedFraction),
                maximumDamage: Double(summary.maxDamage))
        }
        var flown: SavedSimulationRun.Fragments?
        if let fragments, let spec = flownSpec {
            guard fragments.caughtUp, let live = fragments.fragmentLive else {
                throw ProjectFileError.invalid("The fragments are still landing; keep the run in a moment.")
            }
            flown = SavedSimulationRun.Fragments(
                spec: spec, launchSpeed: Double(fragmentLaunchSpeed), impacts: live.impacts,
                airborne: (0..<live.fragmentCount).filter { !live.landed[$0] }.count)
        }
        var reckoned: ThermalResult?
        if let thermal, let spec = reckonedSpec {
            guard thermal.caughtUp, let live = thermal.thermalLive else {
                throw ProjectFileError.invalid(
                    "The thermal radiation is still being reckoned; keep the run in a moment.")
            }
            reckoned = ThermalResult(
                spec: spec, receivers: thermalReceivers, peakIrradiance: live.peakIrradiance,
                fluence: live.fluence, fireball: fireballFrames,
                chargeEnergy: ThermalExposure.chargeEnergy(FragmentScene(scenario)),
                heating: heatingResult(live, spec: spec))
        }
        var run = SavedSimulationRun(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            solverVersion: scenario.structuralObjects.count > 1
                ? SavedSimulationRun.multiBodySolverVersion : SavedSimulationRun.solverVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "development",
            deviceName: device?.name ?? "Unknown Metal device", scenario: scenario, settings: inputs,
            inputSHA256: try SavedSimulationRun.fingerprint(scenario, settings: inputs),
            elapsedTime: time, stepCount: stepCount, gauges: gauges, structure: response,
            bodyResponses: scenario.structuralObjects.count > 1
                ? scenario.structuralObjects.map { object in
                    let summary = bodySummaries[object.id]!
                    return SavedSimulationRun.BodyResponse(
                        id: object.id, name: object.name,
                        response: .init(
                            points: (bodyRecords[object.id] ?? []).map {
                                .init(time: $0.time / 1000, value: $0.deflection)
                            },
                            failedFraction: Double(summary.erodedFraction),
                            maximumDamage: Double(summary.maxDamage)))
                } : nil)
        run.fragments = flown
        run.envelopeExposure = solver.envelopeExposureSummaries()
        if let groundShock, let spec = estimatedGroundSpec {
            guard groundShock.caughtUp, var result = groundShock.groundShockLive else {
                throw ProjectFileError.invalid(
                    "The ground's shaking is still being estimated; keep the run in a moment.")
            }
            result.place(on: scenario.terrain)
            // What is drawn, as what is kept.
            updateGroundShockStatus()
            result.frameTimes = nil
            for n in result.points.indices {
                result.points[n].history = []
                for d in result.points[n].responses.indices { result.points[n].responses[d].history = nil }
            }
            run.groundShock = SavedSimulationRun.GroundShock(spec: spec, result: result)
        }
        run.thermal = reckoned
        if followingCloud {
            throw ProjectFileError.invalid("The cloud is still being followed; keep the run in a moment.")
        }
        run.cloud = cloud
        run.standing = run.derivedStanding()
        try run.validate()
        // Reject an oversized capture before it can make the document unsavable.
        var document = ProjectDocument(model: self)
        document.savedRuns.append(run)
        _ = try document.makeArchive()
        savedRuns.append(run)
    }

    /// Keeps a run made elsewhere, as by a sweep worker on another Mac, with the checks
    /// `keepRun` makes.
    func addRun(_ run: SavedSimulationRun) throws {
        guard savedRuns.count < SavedSimulationRun.maximumRuns,
            !savedRuns.contains(where: {
                $0.id == run.id || $0.name.localizedCaseInsensitiveCompare(run.name) == .orderedSame
            })
        else {
            throw ProjectFileError.invalid("There is no room for \(run.name), or its name is taken.")
        }
        try run.validate()
        var document = ProjectDocument(model: self)
        document.savedRuns.append(run)
        _ = try document.makeArchive()
        savedRuns.append(run)
    }

    /// Puts the runs named in `names` in that order, in the places they already take.
    func orderRuns(_ names: [String]) {
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let places = savedRuns.indices.filter { rank[savedRuns[$0].name] != nil }
        let ordered = places.map { savedRuns[$0] }.sorted { rank[$0.name]! < rank[$1.name]! }
        for (place, run) in zip(places, ordered) { savedRuns[place] = run }
    }

    func renameRun(id: UUID, name: String) throws {
        guard !sweep.isActive else {
            throw ProjectFileError.invalid("Wait for the sweep to finish before renaming a run.")
        }
        guard let index = savedRuns.firstIndex(where: { $0.id == id }) else {
            throw ProjectFileError.invalid("This saved run is no longer available.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectFileError.invalid("Enter a run name.") }
        guard trimmed.count <= 120 else {
            throw ProjectFileError.invalid("Run names must be 120 characters or fewer.")
        }
        guard
            !savedRuns.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            })
        else {
            throw ProjectFileError.invalid("A saved run already uses that name. Choose a unique name.")
        }
        savedRuns[index].name = trimmed
    }

    func removeRun(id: UUID) {
        guard !sweep.isActive else { return }
        savedRuns.removeAll { $0.id == id }
    }

    func restoreRun(_ run: SavedSimulationRun) {
        guard !sweep.isActive else { return }
        guard savedRuns.count < SavedSimulationRun.maximumRuns,
            !savedRuns.contains(where: {
                $0.id == run.id || $0.name.localizedCaseInsensitiveCompare(run.name) == .orderedSame
            })
        else { return }
        savedRuns.append(run)
    }

    // MARK: - Ground shock

    /// Starts estimating the ground's shaking for a run beginning now, if the project has
    /// ground points within its domain.
    private func startGroundShock(_ solver: BlastSolver) {
        stopGroundShock()
        guard let spec = groundShockSpec else { return }
        guard (try? spec.validate(domain: scenario.domainSize)) != nil else {
            groundShockStatus =
                "Some ground points lie outside the domain; move them to estimate the shaking."
            return
        }
        if let host = host(groundShockHost, name: "ground"), let worker = workers[host] {
            groundShock = remoteConsumer(worker, kind: .groundShock(spec, live: true))
        } else {
            groundShock = LocalFrameConsumer(.groundShock(spec, live: true))
        }
        estimatedGroundSpec = spec
        sendGroundShockFrame(solver)
        updateGroundShockStatus()
    }

    private func stopGroundShock() {
        groundShock?.cancel()
        groundShock = nil
        estimatedGroundSpec = nil
        groundShockTime = -1
        groundShockLive = nil
        groundShockStatus = ""
    }

    /// The air on the ground now: at the start, then once a run passes each millisecond, and at
    /// the end (`last`), as the fragments get theirs. A sample a point, taken in line: the peaks
    /// are the solver's own, kept every step, so the frames miss none of them, and the batches
    /// are not shortened for them, so the air is untouched.
    private func sendGroundShockFrame(_ solver: BlastSolver, last: Bool = false) {
        guard groundShock != nil, solver.time > groundShockTime + 1e-9 else { return }
        let interval = Self.fragmentFrameInterval
        let next = groundShockTime < 0 ? 0 : (floor(groundShockTime / interval + 1e-6) + 1) * interval
        guard last || solver.time >= next - 1e-9 else { return }
        groundShockTime = solver.time
        guard let groundShock, let spec = estimatedGroundSpec else { return }
        let region = spec.region(cellSize: solver.grid.cellSize)
        groundShock.send(.ground(solver.groundSlice(low: region.low, high: region.high)))
    }

    private func updateGroundShockStatus() {
        guard let groundShock, var result = groundShock.groundShockLive else { return }
        result.place(on: scenario.terrain)
        if groundShockLive != result { groundShockLive = result }
        let open = result.points.filter { !$0.covered }
        let reached = open.filter { $0.arrival != nil }
        var text = "The blast has reached \(reached.count) of \(result.points.count) points"
        if let top = reached.max(by: {
            $0.surfaceVelocity(in: result.soil) < $1.surfaceVelocity(in: result.soil)
        }) {
            text += String(
                format: "; the ground moves fastest under (%.1f, %.1f), %.0f mm/s down",
                top.position.x, top.position.y, top.surfaceVelocity(in: result.soil) * 1000)
        }
        let covered = result.points.count - open.count
        if covered > 0 { text += "; \(covered) under a block or the structure" }
        let outrun = reached.filter { $0.regime == .outrunning }.count
        if outrun > 0 { text += "; outrun by the ground's wave at \(outrun)" }
        if !groundShock.caughtUp {
            text += " · \(groundShock.sent - 1 - groundShock.report.frame) frames to estimate"
        }
        let place = groundShock.placement
        if !place.isEmpty { text += " ·" + place }
        groundShockStatus = text
    }

    // MARK: - Fragments

    /// Starts flying the project's fragments for a run beginning now, if it has any.
    private func startFragments(_ solver: BlastSolver) {
        guard let spec = fragmentSpec, spec.count + spec.tracers > 0, (try? spec.validate()) != nil else {
            return
        }
        stopFragments()
        let scene = FragmentScene(scenario)
        let consumer: any FrameConsumer
        if let host = host(fragmentsHost, name: "fragments"), let worker = workers[host] {
            consumer = remoteConsumer(worker, kind: .fragments(spec, scene, live: true))
        } else {
            consumer = LocalFrameConsumer(.fragments(spec, scene, live: true))
        }
        fragments = consumer
        flownSpec = spec
        fragmentLaunchSpeed = spec.launchSpeed(chargeMass: scenario.charge.mass)
        fragmentLive = consumer.fragmentLive
        fragmentTime = -1
        // The consumer may fall up to four frames behind; then the run waits for it.
        holdBatches = { consumer.sent - 1 - consumer.report.frame > 4 }
        sendFragmentFrame(solver)
        updateFragmentStatus()
    }

    private func stopFragments() {
        // The gate is the fragments' only while they run; a headless run may set its own.
        if fragments != nil { holdBatches = nil }
        fragments?.cancel()
        fragments = nil
        flownSpec = nil
        fragmentLive = nil
        fragmentStatus = ""
    }

    /// The air now, for the fragments: at the start, then once a run passes each millisecond, as a
    /// headless run sends it, not after every batch, which took a copy of the air on the main
    /// thread while the GPU waited; and at the end (`last`).
    private func sendFragmentFrame(_ solver: BlastSolver, last: Bool = false) {
        guard let fragments, solver.time > fragmentTime + 1e-9 else { return }
        let interval = Self.fragmentFrameInterval
        let next = fragmentTime < 0 ? 0 : (floor(fragmentTime / interval + 1e-6) + 1) * interval
        guard last || solver.time >= next - 1e-9 else { return }
        fragmentTime = solver.time
        let region = fragments.report.region(
            for: fragments.sent, interval: interval, domain: scenario.domainSize,
            cellSize: solver.grid.cellSize)
        fragments.send(.air(solver.airSlice(region: region.box, stride: region.stride)))
    }

    private func updateFragmentStatus() {
        guard let live = fragments?.fragmentLive else { return }
        fragmentLive = live
        let landed = live.impacts.count
        let flying = (0..<live.fragmentCount).filter { !live.landed[$0] }.count
        let energy = live.impacts.map(\.energy).max() ?? 0
        var text = "\(flying) fragments in flight, \(landed) landed"
        if energy > 0 {
            text +=
                energy >= 1e6
                ? String(format: ", hardest %.1f MJ", energy / 1e6)
                : String(format: ", hardest %.0f kJ", energy / 1e3)
        }
        let place = fragments?.placement ?? ""
        if !place.isEmpty { text += " ·" + place }
        fragmentStatus = text
    }

    /// A companion on the Mac set for sweeps that carries on here if that Mac fails it, or on its
    /// own there if its frames cannot be kept.
    private func remoteConsumer(_ worker: SweepWorkerClient, kind: ConsumerKind) -> any FrameConsumer {
        (try? ResilientFrameConsumer(client: worker, kind: kind, ownsClient: false))
            ?? RemoteFrameConsumer(client: worker, kind: kind, ownsClient: false)
    }

    // MARK: - Placing companions by cost

    /// The Mac a companion set to run on `setting` runs on in a run starting now; nil for this
    /// one.
    private func host(_ setting: String?, name: String) -> String? {
        guard setting == ConsumerPlacement.automatic else { return setting }
        return automaticPlaces[name].flatMap { $0 == "local" ? nil : $0 }
    }

    /// The companions the project runs, by name, as a run starting now would start them.
    private var companionKinds: [String: ConsumerKind] {
        let scene = FragmentScene(scenario)
        var kinds: [String: ConsumerKind] = [:]
        if let spec = fragmentSpec { kinds["fragments"] = .fragments(spec, scene, live: true) }
        if let spec = thermalSpec { kinds["thermal"] = .thermal(spec, scene, live: true) }
        if let spec = groundShockSpec { kinds["ground"] = .groundShock(spec, live: true) }
        return kinds
    }

    private func costs(for key: String) -> ConsumerCosts {
        measuredCosts[key] ?? costStore?.costs(for: key) ?? ConsumerCosts()
    }

    private func keep(_ costs: ConsumerCosts, for key: String) {
        measuredCosts[key] = costs
        costStore?.record(costs, for: key)
    }

    /// Where each companion set to Automatic goes in a run starting now: by `ConsumerPlacement`'s
    /// plan, among this Mac and the Macs connected, from what the last run and the probes
    /// measured; this Mac until something has been.
    private func placeAutomatically() {
        let settings = ["fragments": fragmentsHost, "thermal": thermalHost, "ground": groundShockHost]
        runCostKey = ConsumerCostStore.key(currentInputs, frameInterval: 0.001)
        automaticPlaces = [:]
        guard settings.values.contains(ConsumerPlacement.automatic), let key = runCostKey else { return }
        let kinds = companionKinds
        let hosts = workers.keys.sorted()
        var choices: [String: [String]] = [:]
        for name in kinds.keys {
            let setting = settings[name] ?? nil
            choices[name] =
                setting == ConsumerPlacement.automatic
                ? ["local"] + hosts : [setting.flatMap { workers[$0] == nil ? nil : $0 } ?? "local"]
        }
        let plan = ConsumerPlacement.plan(choices, kinds: kinds, costs: costs(for: key))
        automaticPlaces = plan.places.filter { settings[$0.key] == ConsumerPlacement.automatic }
    }

    /// Probes the thermal radiation, if placed automatically, here and on each Mac connected, so
    /// that the next run is placed by each Mac's speed now.
    func probeAutomatic() async {
        guard thermalHost == ConsumerPlacement.automatic, !isRunning, let kind = companionKinds["thermal"],
            let spec = thermalSpec, (try? spec.validate()) != nil,
            let key = ConsumerCostStore.key(currentInputs, frameInterval: 0.001)
        else { return }
        var costs = costs(for: key)
        await ConsumerProbe.probe(
            "thermal", kind: kind, inputs: currentInputs,
            workers: workers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, into: &costs)
        keep(costs, for: key)
    }

    /// What the run's companions cost, a millisecond of simulated time, once each has every
    /// frame in: each where it ran, and the blast's GPU time, less that of companions here
    /// sharing its GPU.
    private func recordCosts(blastGPUSeconds: Double, elapsed: Double) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while !companionsCaughtUp, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard companionsCaughtUp, let key = runCostKey, elapsed > 0 else { return }
        let frames = elapsed / 0.001
        var costs = costs(for: key)
        var blast = blastGPUSeconds
        for (name, consumer) in [("fragments", fragments), ("thermal", thermal), ("ground", groundShock)] {
            guard let consumer, consumer.sent > 0, (consumer as? ResilientFrameConsumer)?.fallback == nil
            else {
                continue
            }
            let site =
                (consumer as? ResilientFrameConsumer)?.host ?? (consumer as? RemoteFrameConsumer)?.host
                ?? "local"
            let gpu = (consumer as? LocalFrameConsumer)?.gpuSeconds.map { $0 > 0 }
            costs.measured(
                name, kind: consumer.kind, place: site, seconds: consumer.seconds / frames, usesGPU: gpu)
            if site == "local", gpu == true { blast -= consumer.seconds }
        }
        costs.frameSeconds = max(blast, 0) / frames
        if let radius = fireballFrames.map(\.radius).max(), radius > 0 { costs.fireballRadius = radius }
        keep(costs, for: key)
    }

    /// Runs the companions set for `host` through `worker` from the next run, as if connected to
    /// it; for tests.
    func useWorker(_ worker: SweepWorkerClient, host: String) {
        workers[host] = worker
    }

    /// Connects to each of `hosts`, of those the companions are set to run on, sharing one
    /// connection between those on the same Mac, and lets the others go.
    func connectWorkers(_ hosts: Set<String>) async {
        for (host, worker) in workers where !hosts.contains(host) {
            worker.close()
            workers[host] = nil
        }
        for host in hosts.sorted() where workers[host] == nil {
            setPlacementStatus(
                on: host, fragments: "Connecting to \(host)…", thermal: "Connecting to \(host)…",
                ground: "Connecting to \(host)…")
            do {
                let worker = try await RemoteSweepWorker.connect(host: host)
                guard wantedHosts.contains(host) else {
                    worker.close()
                    continue
                }
                workers[host]?.close()
                workers[host] = worker
                setPlacementStatus(
                    on: host, fragments: "Fragments will fly on \(host) from the next run.",
                    thermal: "The thermal radiation will be reckoned on \(host) from the next run.",
                    ground: "The ground's shaking will be estimated on \(host) from the next run.")
            } catch {
                let reason = error.localizedDescription
                setPlacementStatus(
                    on: host, fragments: "Fragments fly here: \(reason)", thermal: "Reckoned here: \(reason)",
                    ground: "Estimated here: \(reason)")
            }
        }
        await probeAutomatic()
    }

    /// Says how the connection to `host` stands, in the status of each companion set to run there.
    private func setPlacementStatus(on host: String, fragments: String, thermal: String, ground: String) {
        if fragmentsHost == host { fragmentStatus = fragments }
        if thermalHost == host { thermalStatus = thermal }
        if groundShockHost == host { groundShockStatus = ground }
    }

    // MARK: - Thermal radiation

    /// Starts reckoning the project's thermal radiation for a run beginning now, if it has any.
    private func startThermal(_ solver: BlastSolver) {
        stopThermal()
        guard let spec = thermalSpec, (try? spec.validate()) != nil else { return }
        let scene = FragmentScene(scenario)
        if let host = host(thermalHost, name: "thermal"), let worker = workers[host] {
            thermal = remoteConsumer(worker, kind: .thermal(spec, scene, live: true))
        } else {
            thermal = LocalFrameConsumer(.thermal(spec, scene, live: true))
        }
        thermalGrids = ThermalExposure.surfaceGrids(scene: scene, spec: spec)
        thermalReceivers = thermalGrids.flatMap(\.receivers)
        thermalHeating =
            spec.heating.enabled
            ? SurfaceHeating.Layout(spec: spec.heating, grids: thermalGrids, scene: scene) : nil
        reckonedSpec = spec
        nextFireballTime = 0
        sendFireball(solver)
        updateThermalStatus()
    }

    private func stopThermal() {
        thermal?.cancel()
        thermal = nil
        thermalReceivers = []
        thermalGrids = []
        thermalHeating = nil
        reckonedSpec = nil
        fireballFrames = []
        thermalPaintCache = nil
        thermalStatus = ""
        thermalReckoned = 0
    }

    /// The fireball now, for the thermal radiation, at the first batch's end in each millisecond
    /// and at the run's end.
    private func sendFireball(_ solver: BlastSolver) {
        guard let thermal, let spec = reckonedSpec,
            solver.time >= nextFireballTime - 1e-9 || solver.time >= duration - 1e-9,
            solver.time > (fireballFrames.last?.time ?? -1) + 1e-9
        else { return }
        let frame = solver.fireball(for: spec)
        fireballFrames.append(frame.withoutShape)
        thermal.send(.fireball(frame))
        nextFireballTime = (floor(solver.time / 0.001 + 1e-6) + 1) * 0.001
    }

    /// The thermal radiation or the ground shock has fallen too far behind the run, which waits
    /// for it.
    private var thermalIsBehind: Bool {
        [thermal, groundShock].contains { consumer in
            consumer.map { $0.sent - 1 - $0.report.frame > 4 } ?? false
        }
    }

    private func updateThermalStatus() {
        guard let thermal else { return }
        let live = thermal.thermalLive ?? ThermalLive(receivers: thermalReceivers.count)
        if thermalReckoned != live.frames { thermalReckoned = live.frames }
        var text: String
        if let largest = fireballFrames.max(by: { $0.volume < $1.volume }), largest.volume > 0 {
            text = String(format: "Fireball up to %.1f m across", 2 * largest.radius)
            if let now = fireballFrames.last, now.volume > 0 {
                text += String(format: ", %.0f K now", now.temperature)
            }
        } else {
            text = "No gas luminous yet"
        }
        let dose = live.fluence.max() ?? 0
        text += String(format: " · fluence up to %.1f kJ/m² over ", dose / 1000)
        text += "\(thermalReceivers.count.formatted()) receivers"
        if let spec = reckonedSpec, let heating = heatingResult(live, spec: spec) {
            let hottest = heating.peakTemperature.max() ?? heating.ambient
            text += String(format: " · surfaces up to %.0f K", hottest)
            let flagged = heating.ignition.filter { $0 != 0 }.count
            if flagged > 0 { text += " · \(flagged.formatted()) past ignition thresholds (illustrative)" }
        }

        if live.frames < thermal.sent { text += " · \(thermal.sent - live.frames) frames to reckon" }
        let place = thermal.placement
        if !place.isEmpty { text += " ·" + place }
        thermalStatus = text
    }

    // MARK: - The cloud

    /// Hands the hot gas left at the run's end over to the cloud model, if the project follows
    /// it, and follows the cloud away from this thread; a few milliseconds for ten minutes.
    private func followCloud(_ solver: BlastSolver) {
        guard let spec = cloudSpec, (try? spec.validate()) != nil, cloud == nil, !followingCloud else {
            return
        }
        let handOver = solver.cloudHandOver(hotterThan: spec.handOverTemperature)
        followingCloud = true
        cloudTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CloudResult(spec: spec, handOver: handOver)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cloud = result
            self.followingCloud = false
            self.cloudTask = nil
        }
    }

    private func stopCloud() {
        cloudTask?.cancel()
        cloudTask = nil
        followingCloud = false
        cloud = nil
    }

    /// Frames the view on the cloud: the whole of its path up to where it stopped rising, if that
    /// is near enough to see whole, and otherwise the cloud where it stopped.
    func frameCloud() {
        guard let cloud, cloud.handOver.mass > 0 else { return }
        camera = CloudOverlay.framing(cloud)
    }

    // MARK: - Building

    /// Stops drawing the vent panels that have released.
    private func showOpenedVentPanels(_ solver: BlastSolver) {
        let times = solver.ventPanelOpenTimes
        let opened = times.filter { $0 != nil }.count
        guard opened != openedVentPanels else { return }
        openedVentPanels = opened
        let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
        renderer?.setVentPanels(zip(panels, times).compactMap { $1 == nil ? $0.box : nil })
        sceneVersion += 1
    }

    private func requestRebuild() {
        envelopeExposure = []
        envelopeExposureStatus = ""
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
            shockLevels: settings.shockLevels, gravity: settings.gravity)
    }

    private func rebuild() {
        isLoadingInputs = true
        defer { isLoadingInputs = false }
        stopFragments()
        stopGroundShock()
        envelopeExposure = []
        envelopeExposureStatus = ""
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
                    + (refined ? SolverConfiguration().refinementMemory : 0)
                guard UInt64(required) < device.recommendedMaxWorkingSetSize / 10 * 7 else {
                    throw BlastError.allocationFailed(
                        "\(grid.cellCount / 1_000_000) million cells; try a coarser resolution")
                }
                let created = try BlastSolver(
                    device: device, commandQueue: commandQueue, scenario: scenario,
                    cellSize: settings.resolution.cellSize)
                if settings.detailedCharge || settings.sharpShocks {
                    configureAir(created)
                    try created.load(scenario)
                }
                solver = created
            }
            if let solver, !scenario.envelopeObjects.isEmpty {
                if scenario.structuralObjects.isEmpty {
                    do {
                        try solver.configureEnvelopeExposure(objects: scenario.envelopeObjects)
                        envelopeExposure = solver.envelopeExposureSummaries() ?? []
                    } catch {
                        envelopeExposureStatus = "Surface results unavailable: \(error.localizedDescription)"
                    }
                } else {
                    envelopeExposureStatus =
                        "Surface results require a scene containing only stationary envelopes. This scene also has deformable structures."
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
        bodySummaries = Dictionary(
            uniqueKeysWithValues: (solver?.bodies ?? []).compactMap { body in
                body.summary().map { (body.id, $0) }
            })
        nextStructureSampleTime = sampleInterval
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
            sceneVersion += 1
        }
    }

    // MARK: - Stepping

    private func restartPacing() {
        paceOriginWall = .now
        paceOriginTime = solver?.time ?? time
        lastBatchCompletion = .now
    }

    /// Commits the next batch of steps if the run is active and the GPU is free.
    private func pump() {
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
            let wall = (ContinuousClock.now - paceOriginWall).seconds
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
    private func publishProgress() {
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

    private func finish() {
        isRunning = false
        publishTraces()
        if fragments != nil || thermal != nil || groundShock != nil {
            let (gpu, elapsed) = (blastGPUSeconds, time)
            Task { [weak self] in await self?.recordCosts(blastGPUSeconds: gpu, elapsed: elapsed) }
        }
        // The fragments' last frames may still be in flight: show them once they are in.
        if let fragments {
            Task { [weak self] in
                let deadline = ContinuousClock.now + .seconds(30)
                while fragments.report.frame < fragments.sent - 1, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if self?.fragments === fragments { self?.updateFragmentStatus() }
            }
        }
        if let thermal {
            Task { [weak self] in
                let deadline = ContinuousClock.now + .seconds(120)
                while !thermal.caughtUp, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                    if self?.thermal === thermal { self?.updateThermalStatus() }
                }
                if self?.thermal === thermal { self?.updateThermalStatus() }
            }
        }
        if let groundShock {
            Task { [weak self] in
                let deadline = ContinuousClock.now + .seconds(60)
                while !groundShock.caughtUp, ContinuousClock.now < deadline {
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
        let summary = solver.bodySummary()
        stopIfSolverFailed(solver, summary: summary)
        guard summary?.hasBlownUp != true else { return }
        if let summary, structureRecord.last?.time != solver.time * 1000 {
            structureRecord.append(
                StructureSample(
                    id: structureRecord.count, time: solver.time * 1000,
                    deflection: Double(summary.maxDisplacement) * 1000))
        }
        for body in solver.bodies {
            if let summary = body.summary(), bodyRecords[body.id]?.last?.time != solver.time * 1000 {
                var history = bodyRecords[body.id] ?? []
                history.append(
                    StructureSample(
                        id: history.count, time: solver.time * 1000,
                        deflection: Double(summary.maxDisplacement) * 1000))
                bodyRecords[body.id] = history
            }
        }
        nextStructureSampleTime =
            (floor(solver.time / sampleInterval + 1e-6) + 1) * sampleInterval
        lastSampleTime = solver.time
        onSample?(solver)
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
    private func publishTraces() {
        guard let solver else { return }
        lastTracePublication = .now
        envelopeExposure = solver.envelopeExposureSummaries() ?? []
        recordSampleIfDue(solver)
        structureSummary = solver.bodySummary()
        bodySummaries = Dictionary(
            uniqueKeysWithValues: solver.bodies.compactMap { body in body.summary().map { (body.id, $0) } })
        stopIfSolverFailed(solver, summary: structureSummary)
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

extension SimulationModel {
    /// Draws the run's particles: in flight, coloured by speed; tracers; and where fragments
    /// landed, coloured by their energy. Each is a position and a code, the kind (0 a fragment, 1
    /// a tracer, 2 a landing) plus a value from 0 to 1.
    func fragmentDots(showFragments: Bool, showTracers: Bool) -> [SIMD4<Float>] {
        // Straight from the consumer, so the dots move with every frame drawn.
        guard let live = fragments?.fragmentLive ?? fragmentLive else { return [] }
        var dots: [SIMD4<Float>] = []
        dots.reserveCapacity(live.positions.count)
        for n in live.positions.indices {
            let fragment = n < live.fragmentCount
            if fragment, showFragments, !live.landed[n] {
                dots.append(SIMD4(live.positions[n], min(live.speeds[n] / fragmentScale, 0.999)))
            } else if !fragment, showTracers, !live.landed[n] {
                dots.append(SIMD4(live.positions[n], 1))
            }
        }
        if showFragments {
            for impact in live.impacts {
                // log10 of the energy over 7 decades: 1 J to 10 MJ.
                dots.append(SIMD4(impact.position, 2 + min(max(log10(max(impact.energy, 1)) / 7, 0), 0.999)))
            }
        }
        return dots
    }

    private var fragmentScale: Float { max(fragmentLaunchSpeed, 1) }

    /// Draws the ground points as the run has left them, or before a run where they will be.
    func groundShockDots() -> [SIMD4<Float>] {
        groundShockLive?.dots ?? groundShockSpec?.dots(on: settings.scenario.terrain) ?? []
    }

    /// Paints the thermal radiation so far onto the ground and the faces, its fluence or its peak
    /// irradiance on the view's scale, interpolated between the receivers.
    func thermalPaint(_ quantity: ThermalQuantity) -> SurfacePaint? {
        guard let thermal, let live = thermal.thermalLive else { return nil }
        if let cache = thermalPaintCache, cache.frames == live.frames, cache.quantity == quantity {
            return cache.paint
        }
        let values: [Float]
        switch quantity {
        case .fluence: values = live.fluence
        case .peakIrradiance: values = live.peakIrradiance
        case .surfaceTemperature, .ignition:
            guard let spec = reckonedSpec, let heating = heatingResult(live, spec: spec) else { return nil }
            values =
                quantity == .ignition
                ? heating.ignition.map(Float.init) : heating.peakTemperature.map { $0 - heating.ambient }
        }
        let paint = SurfacePaint(grids: thermalGrids, shades: values.map(quantity.shade))
        thermalPaintCache = (live.frames, quantity, paint)
        return paint
    }

    /// The surfaces' heating so far, with the materials they were given and the ignition thresholds
    /// they passed; nil where it is not reckoned or has not come in.
    private func heatingResult(_ live: ThermalLive, spec: ThermalSpec) -> SurfaceHeatingResult? {
        guard let thermalHeating, live.peakTemperature.count == thermalHeating.material.count else {
            return nil
        }
        return thermalHeating.result(
            peakTemperature: live.peakTemperature, fluence: live.fluence, ambient: spec.heating.ambient)
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
