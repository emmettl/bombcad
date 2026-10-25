import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

/// The air's cell size: one of the three presets, saved by name as they always were, or any
/// other size, saved as "cell:" and the size in metres, which readers from before other sizes
/// refuse rather than misread.
struct Resolution: RawRepresentable, Hashable, Identifiable, Sendable {
    let cellSize: Float

    static let coarse = Resolution(preset: 0.5)
    static let medium = Resolution(preset: 0.25)
    static let fine = Resolution(preset: 0.125)
    /// The presets, coarsest first.
    static let allCases: [Resolution] = [.coarse, .medium, .fine]
    /// The sizes a cell may have, in metres.
    static let sizes: ClosedRange<Float> = 0.01...200

    private init(preset cellSize: Float) { self.cellSize = cellSize }

    /// A cell of `cellSize` metres, as a preset when it is one's size; nil outside `sizes`.
    init?(cellSize: Float) {
        guard cellSize.isFinite, Self.sizes.contains(cellSize) else { return nil }
        self.cellSize = cellSize
    }

    init?(rawValue: String) {
        switch rawValue {
        case "coarse": self = .coarse
        case "medium": self = .medium
        case "fine": self = .fine
        default:
            guard rawValue.hasPrefix("cell:"), let size = Float(rawValue.dropFirst(5)),
                let resolution = Resolution(cellSize: size)
            else { return nil }
            self = resolution
        }
    }

    /// A preset's name, or a size from the command line: a preset's name, its raw value, or metres.
    init?(text: String) {
        if let resolution = Resolution(rawValue: text) {
            self = resolution
        } else if let metres = Float(
            text.replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)),
            let resolution = Resolution(cellSize: metres)
        {
            self = resolution
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch cellSize {
        case 0.5: "coarse"
        case 0.25: "medium"
        case 0.125: "fine"
        default: "cell:" + String(format: "%g", Double(cellSize))
        }
    }

    var id: String { rawValue }
    var isPreset: Bool { Self.allCases.contains(self) }

    var title: String {
        switch self {
        case .coarse: "Coarse · 0.5 m"
        case .medium: "Medium · 0.25 m"
        case .fine: "Fine · 0.125 m"
        default: "Cells of " + Self.metres(cellSize)
        }
    }

    static func metres(_ value: Float) -> String { String(format: "%g m", Double(value)) }

    /// The scaled cells offered for a charge: in metres per cube root of the kilogram, coarse
    /// enough for impulse and arrival in the open, and finer for peaks (see docs/large-scenes.md).
    static let scaledCells: [Float] = [0.2, 0.1, 0.05]

    /// A cell of `scaled` m/kg^(1/3) for `mass` kg, to two significant figures; nil where that is
    /// under a metre, where the presets serve a small charge's scene instead.
    static func scaled(_ scaled: Float, mass: Float) -> Resolution? {
        let size = scaled * cbrt(max(mass, 0))
        guard size >= 1 else { return nil }
        let digits = pow(10, floor(log10(size)) - 1)
        return Resolution(cellSize: Float((Double(size) / Double(digits)).rounded() * Double(digits)))
    }

    /// What a grid picker offers for a charge of `mass` kg: the scaled cells coarser than the
    /// presets, the presets, and `current` whatever it is, coarsest first.
    static func choices(mass: Float, current: Resolution) -> [Resolution] {
        var choices = scaledCells.compactMap { scaled($0, mass: mass) } + allCases
        if !choices.contains(current) { choices.append(current) }
        var seen = Set<Resolution>()
        return choices.filter { seen.insert($0).inserted }.sorted { $0.cellSize > $1.cellSize }
    }

    /// `title`, with the cell's size per cube root of the charge's mass when it is not a preset.
    func title(mass: Float) -> String {
        guard !isPreset, mass > 0 else { return title }
        return title + String(format: " · %.2g m/kg^(1/3)", Double(cellSize / cbrt(mass)))
    }

    /// The next finer cell: the next preset, or half the size.
    var finer: Resolution? {
        switch self {
        case .coarse: .medium
        case .medium: .fine
        case .fine: nil
        default: Resolution(cellSize: cellSize / 2)
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
    /// vibration: closer to tests, 1.3 to 2 times as slow. On by default since 15 October 2026;
    /// a saved project keeps its own.
    var detailedCharge = true
    /// Refine the air twice over where the shock is, so that peak pressures come out as on a grid
    /// twice as fine.
    var sharpShocks = false
    /// With `sharpShocks`, the levels of refinement: 2 refines the refined air again, so that the
    /// peaks come out as on a grid four times as fine.
    var shockLevels = 1
    /// With `sharpShocks`, the jump across a cell that refines it, as a share of its pressure:
    /// lower follows a weakening shock further, at a cost (see docs/large-scenes.md).
    var shockThreshold: Float = 0.1
    /// With `sharpShocks`, no air refined more than this many metres above the ground; nil for none.
    var refinementCeiling: Float?
    /// With `sharpShocks`, each refined level takes only the substeps its own waves need
    /// (`SolverConfiguration.refinementOwnSteps`): the advisor turns it on where it pays.
    var adaptiveSubsteps = false
    /// Gravity in the air: it starts at rest in a hydrostatic atmosphere and hot gas rises.
    var gravity = false
    /// The terrain cut through the cells where the air is not refined; false for a staircase of
    /// whole cells.
    var terrainCutCells = true
    /// The structures' outline in the air counted by each element's overlap with the cells, as
    /// since 16 October 2026 (`SolverConfiguration.structureMaskOverlap`); false for each element
    /// counted at its centre, as before.
    var outlineByOverlap = true
    /// Envelopes' glazing breaks in the air and the blast fills their rooms
    /// (`BlastSolver.configureEnvelopeVenting`), by default since 17 October 2026; off, or where it
    /// cannot run, the one-way fill.
    var ventsGlazing = true
    /// The structures brought to rest under their own weight before the blast
    /// (`SolverConfiguration.settlesStructures`), as since 17 October 2026; false for their weight
    /// taken as the run starts, as before.
    var settlesStructures = true
    /// With afterburning and hot air, a lone charge starts from a fine one-dimensional burst mapped
    /// onto the grid (`SolverConfiguration.mappedCharge`), by default since 18 October 2026; off, as
    /// before, from a sphere of hot gas a few cells across.
    var mappedStart = true
    /// With afterburning and hot air, the fireball's gas loses the heat it radiates
    /// (`SolverConfiguration.radiativeCooling`, the thermal description's medium), by default since
    /// 19 October 2026; off, as before, it keeps it and stays hot.
    var radiativeCooling = true
    /// The scene's objects the refinement goes toward (`ProjectRunSettings.refineToward`); empty to
    /// refine anywhere.
    var refineToward: [UUID] = []
    /// Debris lands on soil, a Winkler bed of `groundStiffness` (Pa/m), instead of the hard ground.
    var softGround = false
    var groundStiffness = SolverConfiguration.soilSubgradeModulus
    /// What the ground is made of: rigid, or earth or rock that a charge near it digs a crater in
    /// and gives part of its energy to.
    var ground = GroundType.rigid
    /// The water table under it, metres down, where shallow enough to cut the crater's depth; nil
    /// where deep.
    var waterTable: Float?

    var chargeMass: Float {
        get { scenario.charge.mass }
        set { scenario.charge.mass = newValue }
    }

    /// A mass from the charge's logarithmic slider: whole kilograms below 100, two significant
    /// figures above.
    static func roundedMass(_ kilograms: Double) -> Float {
        guard kilograms >= 100 else { return Float(max(kilograms, 1).rounded()) }
        let step = pow(10, floor(log10(kilograms)) - 1)
        return Float((kilograms / step).rounded() * step)
    }

    /// A mass as kilograms, tonnes or kilotonnes.
    static func massText(_ kilograms: Float) -> String {
        switch kilograms {
        case ..<1000: String(format: "%.0f kg", kilograms)
        case ..<1_000_000: String(format: "%g t", Double(kilograms / 1000))
        default: String(format: "%g kt", Double(kilograms / 1_000_000))
        }
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
    /// A building, an exposure-only envelope or a structure, picked to refine toward.
    case building(UUID)
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
    var savedRuns: [SavedSimulationRun] = []
    @ObservationIgnored var loadedRunSettings: ProjectRunSettings?
    /// Observed: `canKeepRun` reads nothing else until a run completes, so a view showing it
    /// must learn of the completion through this.
    var completedRunSettings: ProjectRunSettings?

    /// The craters the finished run's charges dug, to shade into the ground; none before a run ends,
    /// for a crater forms after the blast, or on rigid ground.
    var craters: [CraterEstimate] { completedRunSettings?.craters(over: scenario) ?? [] }
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
    @ObservationIgnored var waitingForHold = false
    @ObservationIgnored var lastSampleTime: Double?
    /// Vent panels the renderer has been told have opened.
    @ObservationIgnored var openedVentPanels = 0
    var samples: Bool { structureSummary != nil || onSample != nil }
    var sampleInterval: Double {
        structureSummary != nil ? Self.structureSampleInterval : airSampleInterval
    }
    @ObservationIgnored var nextStructureSampleTime = structureSampleInterval
    /// The block or wall being edited, which the view outlines.
    var selection: EditSelection?
    var selectedStructureID: UUID?

    var inspectedImportID: UUID?
    /// While set, a click on the ground in the view moves the charge there.
    var isPlacingCharge = false
    /// Shows the sheet for exporting the project's run for rendering.
    var showsRenderExport = false
    /// The parameter sweep's and the kept runs' comparison sheets, which the chart's buttons and
    /// the menus open.
    var showsParameterSweep = false
    var showsRunComparison = false
    /// The Infer Charge sheet, and its observers and posterior, kept while the window is open.
    var showsChargeInference = false
    /// The Protective Design sheet, and its target, changes and plans, kept while the window is open.
    var showsProtectivePlanner = false
    @ObservationIgnored lazy var protectionPlanner = ProtectionPlannerModel()
    /// The plan Protective Design shows: each building's sides' residual chances; empty for none.
    var protectionPlanChances: [UUID: [(axis: Int, outward: Int, chance: Double)]] = [:]
    /// Kept runs' timelines staged on disk until the project is saved (`ProjectDocument.runFolders`).
    var runFolders: [UUID: URL] = [:]
    /// The project's package on disk, once saved: where a reopened project's kept runs keep their
    /// timelines (`runs/<run id>/`).
    var packageURL: URL?
    /// Whether runs are recorded to replay: in a project's window, when Settings ask for it; never
    /// in a headless run, a sweep's worker or a watched run.
    @ObservationIgnored var recordsTimelines = false
    /// Records the run under way for replay (`RunTimelineRecorder`), when Settings ask for it.
    @ObservationIgnored var timelineRecorder: RunTimelineRecorder?
    /// The last run's recording, until another run starts; a kept run takes it into `runFolders`.
    var recentTimeline: URL?
    /// A run being replayed in the view in place of the solver's state, or nil.
    var playback: TimelinePlayback?
    /// Where Run sends the blast: nil for this Mac, or a paired Mac nearby, `nearby:<name>`
    /// (emmettl/bombcad-work#73).
    var runHost: String?
    /// The blast running on another Mac and watched here, or the last one, until put away.
    var remoteRun: RemoteRun?
    /// The connection the last remote run finished on, left open for the next run on that Mac, so
    /// that a rerun with edits sends only what changed (emmettl/bombcad-work#73 stage 3).
    @ObservationIgnored var remoteSession: (host: String, client: SweepWorkerClient)?
    /// How a remote run reaches its Mac, given the host and a held run to resume; tests reach a
    /// server in their own process.
    @ObservationIgnored var remoteConnect: @MainActor (String, UUID?) async throws -> SweepWorkerClient =
        SimulationModel.connectRemote
    /// How long a remote run may go without a word from its Mac before its connection is taken as
    /// dropped (the link can fail without either end hearing); nil waits, as the tests ask.
    @ObservationIgnored var remoteSilenceLimit: Duration? = .seconds(60)
    /// Told each time a remote run's frame is drawn, for tests.
    @ObservationIgnored var onRemoteFrame: ((RemoteRun) -> Void)?
    /// What recording the last run cost: its frames, the main thread's seconds capturing them, and
    /// the bytes kept; and the run's wall-clock seconds.
    @ObservationIgnored var timelineCost:
        (frames: Int, seconds: Double, afterFirst: Double, bytes: Int, wall: Double)?
    @ObservationIgnored var timelineStarted = ContinuousClock.now
    /// A state to save at the next 64-step boundary (Save State Here), and whether the run pauses
    /// once it is saved; the time of the run's next automatic one (seven along a run, while they
    /// fit their space in Settings ▸ Replay).
    @ObservationIgnored var saveRequested = false
    @ObservationIgnored var pauseAfterSave = false
    @ObservationIgnored var nextAutomaticCheckpoint = Double.infinity
    /// The states the run under way has saved, to continue from (`RunTimelineManifest`'s checkpoints).
    var savedStates: [RunTimelineManifest.Entry] = []
    /// The time the run under way was continued from a saved state, if it was.
    var continuedFrom: Double?
    /// Saved states the run takes, automatically: one every `duration / automaticCheckpoints`.
    static let automaticCheckpoints = 8
    let chargeInference = ChargeInferenceModel()
    /// Asked of the views that own them from the menus, and cleared there: choosing a model to
    /// import, naming the run to keep, and saving the results as CSV.
    var requestsModelImport = false
    var requestsKeptRun = false
    var requestsResultsExport = false

    var isRunning = false {
        didSet {
            // The doubt is judged once a run has stopped, on its last loads.
            if oldValue, !isRunning, envelopeColouring == .couldFlip { applyEnvelopeDamageColours() }
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
    var time: Double = 0
    var stepCount = 0
    var traces: [GaugeTrace] = []
    var stats = SimulationStats()
    @ObservationIgnored var liveStats = SimulationStats()
    /// The GPU's time on the blast's batches since the run began, in seconds, as each command
    /// buffer's start and end on the GPU give it; work sharing the GPU stretches it.
    @ObservationIgnored var blastGPUSeconds = 0.0
    @ObservationIgnored var lastProgressPublication = ContinuousClock.now
    static let progressInterval = 1.0 / 60
    var grid: Grid?
    /// Damage and deflection of the deformable structure, if the scenario has one.
    var structureSummary: StructureSummary?
    var structureSubsteps = 0
    /// Deflection of the structure through the run, a sample every `structureSampleInterval`,
    /// and of each structure, as last shown, at most ten times a second while running.
    var structureHistory: [StructureSample] = []
    var bodyHistories: [UUID: [StructureSample]] = [:]
    /// The same, up to the latest sample.
    @ObservationIgnored var structureRecord: [StructureSample] = []
    @ObservationIgnored var bodyRecords: [UUID: [StructureSample]] = [:]
    var bodySummaries: [UUID: StructureSummary] = [:]
    /// The run's time when its independent structures came close and began to meet through
    /// contact, in seconds; nil while they are apart.
    var structuresInContactFrom: Double?
    /// Largest deflection recorded so far, in millimetres.
    var peakDeflection: Double { structureHistory.map(\.deflection).max() ?? 0 }
    var memoryFootprint = 0
    var chargeIsBlocked = false
    var errorMessage: String?
    var isPreparingImports = false
    var isLoadingInputs = false
    /// Layouts before the most recent edits, newest last, and those undone since.
    var undoStack: [SimulationInputs] = []
    var redoStack: [SimulationInputs] = []
    var canUndo: Bool { !sweep.isActive && (!undoStack.isEmpty || currentInputs != settledInputs) }
    var canRedo: Bool { !sweep.isActive && !redoStack.isEmpty }

    @ObservationIgnored let device: MTLDevice?
    @ObservationIgnored let commandQueue: MTLCommandQueue?
    @ObservationIgnored let renderer: SceneRenderer?
    /// Counts the scenes handed to the renderer, which keeps them outside Observation, so a view
    /// that draws only on change draws each new one.
    var sceneVersion = 0
    @ObservationIgnored var solver: BlastSolver?
    @ObservationIgnored var scenario: Scenario
    @ObservationIgnored var batchInFlight = false
    @ObservationIgnored var rebuildPending = false
    @ObservationIgnored var waitingForPace = false
    @ObservationIgnored var rebuildTask: Task<Void, Never>?
    @ObservationIgnored var batchSize = 4
    @ObservationIgnored var paceOriginWall = ContinuousClock.now
    /// The playback clock, which says how far a paced run may have got: the wall clock, unless a
    /// test drives it, to check the pacing whatever else keeps the GPU busy.
    @ObservationIgnored var playbackNow: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    @ObservationIgnored var paceOriginTime: Double = 0
    @ObservationIgnored var lastBatchCompletion = ContinuousClock.now
    @ObservationIgnored var lastTracePublication = ContinuousClock.now
    /// The layout as of the last recorded edit. Edits are recorded once they settle, so that
    /// typing a number or dragging a slider is one step to undo, not dozens.
    @ObservationIgnored var settledInputs: SimulationInputs?
    @ObservationIgnored var handledSettings: SimulationSettings?
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
    @ObservationIgnored var fragmentEdit: Task<Void, Never>?
    @ObservationIgnored var isApplyingInputs = false
    /// The Mac, of those set for sweeps in Settings, to fly the fragments on; nil for this one.
    var fragmentsHost: String?
    /// Where the fragments of the run stand: how many are in flight and landed.
    var fragmentStatus = ""
    /// Where the run's fragments landed against the hazardous-fragment criteria, once the run has
    /// ended and those still in flight have been flown on to land.
    var fragmentHazard: GroundHazard?
    /// The blast's injury at a standing person's height over the run, once it has ended.
    var injuryField: InjuryField?
    /// A standing person's chest and head, m: where the injury's probes are.
    static let standingHeight: Float = 1.5
    /// The fragments whose holes open panes in the air, with venting on, when not the project's
    /// own (`fragmentSpec`): a headless run's `--fragments`.
    @ObservationIgnored var paneHoleSpec: FragmentSpec?
    /// The run's fragments that struck something judged (`FragmentImpact.penetration`), once
    /// landed; while the run goes, the live ones stand in. Envelope damage takes them.
    @ObservationIgnored var fragmentStrikes: [FragmentImpact]?
    /// The run's fragments, in flight and landed, to draw.
    var fragmentLive: FragmentLive?
    @ObservationIgnored var fragments: (any FrameConsumer)?
    @ObservationIgnored var fragmentTime = -1.0
    static let fragmentFrameInterval = 0.001
    @ObservationIgnored var fragmentLaunchSpeed: Float = 1
    /// The fragments the current run flies, as they were when it started.
    @ObservationIgnored var flownSpec: FragmentSpec?
    /// Connections to the Macs the companions run on, by host, shared by those on the same one.
    @ObservationIgnored var workers: [String: SweepWorkerClient] = [:]
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
    @ObservationIgnored var cloudEdit: Task<Void, Never>?
    /// Where the cloud of the run just finished went, once followed.
    var cloud: CloudResult?
    /// The cloud being followed, after the run has reached its end.
    @ObservationIgnored var cloudTask: Task<Void, Never>?
    /// The hot gas the run handed over to the cloud model at its end, for its recording's last frame.
    @ObservationIgnored var handedOverCloud: CloudHandOver?
    /// Whether the cloud is being followed now.
    var followingCloud = false
    @ObservationIgnored var groundShockEdit: Task<Void, Never>?
    /// How the ground has moved so far in the run, at each point, and a line saying so.
    var groundShockLive: GroundShockResult?
    var envelopeExposure: [EnvelopeExposureSummary] = []
    var envelopeExposureStatus = ""
    /// Record each envelope component's pressure history too (headless `--envelope-histories`);
    /// nil records none, at no cost.
    @ObservationIgnored var envelopeHistoryOptions: EnvelopeHistoryOptions?
    /// Whether runs of envelopes record their components' histories, for their one-way damage,
    /// without `envelopeHistoryOptions` asking: the app's runs do; headless runs only when asked.
    @ObservationIgnored var envelopeHistoriesByDefault = true
    /// Each envelope building's one-way damage from its components' loads so far
    /// (`EnvelopeDamageAssessment`), and why there is none when there is none.
    var envelopeDamage: [EnvelopeBuildingDamage] = []
    /// The debris of the envelope components that failed, thrown and landed, once a run has
    /// stopped (`EnvelopeDebris`); nil where none failed.
    var envelopeDebris: EnvelopeDebris?
    /// The loads the damage was last judged on, for the debris and the doubt.
    @ObservationIgnored var envelopeLoads: [EnvelopeComponentLoad] = [] {
        didSet {
            envelopeDoubt = nil
            envelopeLoadsGeneration += 1
        }
    }
    @ObservationIgnored var envelopeLoadsGeneration = 0
    /// Whether cells twice as fine could change each building's outcome (`EnvelopeDoubt`), worked
    /// out from the run's loads when the view is coloured by it; nil until then, and once the
    /// loads change.
    var envelopeDoubt: EnvelopeDoubt?
    var judgingEnvelopeDoubt = false
    var envelopeDamageStatus = ""
    /// True while `envelopeDamage` is the surrogate's quick estimate rather than a run's
    /// (`quickEstimate`).
    var envelopeDamageIsEstimate = false
    /// True while the quick estimate is being made.
    var estimatingEnvelopeDamage = false
    /// Why the glazing is not vented though asked to be, or empty.
    var envelopeVentingStatus = ""
    /// How each charge fired after the main one was laid down in the last run, and when.
    var firingNotes: [String] = []
    /// Whether the view colours envelopes by their damage (over the air's paint) once judged.
    var showsEnvelopeDamage = true {
        didSet { applyEnvelopeDamageColours() }
    }

    // MARK: - The far field

    /// A district's buildings beyond its near field (New District's near field and far field): kept
    /// beside the scene, outside its air, drawn after it and judged after each run.
    var farFieldSet: FarFieldSet? {
        didSet {
            guard farFieldSet != oldValue else { return }
            farFieldDamage = []
            farFieldGlass = []
            farField = nil
            farFieldStatus = ""
            applyFarFieldColours()
        }
    }
    /// The far buildings' damage from the last run's far field, its match and how it went.
    var farFieldDamage: [EnvelopeBuildingDamage] = []
    var farField: HybridFarField?
    var farFieldStatus = ""
    var judgingFarField = false
    /// The far buildings' glass chances on the far field, side by side (`HybridFarField.judge`).
    var farFieldGlass: [FacadeLoadSurrogate.SideGlass] = []
    /// What the far field's glass chances are drawn over: its scatter and the glass's strength.
    @ObservationIgnored var farFieldUncertainty = FacadeLoadSurrogate.Uncertainty()

    var envelopeColouring = EnvelopeColouring.damage {
        didSet { applyEnvelopeDamageColours() }
    }

    /// Each building side's glass chances from the quick estimate (`FacadeLoadSurrogate`'s
    /// draws), the glass alone; empty without one.
    var envelopeGlassChances: [FacadeLoadSurrogate.SideGlass] = []
    /// Each building's chances that its walls and roof are damaged, from the quick estimate's
    /// draws (`FacadeLoadSurrogate.structureProbabilities`); empty without one.
    var envelopeStructureChances: [FacadeLoadSurrogate.StructureChance] = []
    /// The people in the scene and those the quick estimate expects hurt (emmettl/bombcad-work#41,
    /// `OccupantInjury`): illustrative; nil without the estimate's glass chances.
    var peopleEstimate: OccupantInjury.Estimate?
    /// What the people's figures assume: the time of day, a factor on the density, and the use of
    /// buildings whose tags say none.
    var occupancy = OccupantInjury.Assumptions() {
        didSet { if occupancy != oldValue { refreshPeople() } }
    }
    /// Whether the walls' and roofs' chances shown are the look's own (a preview of the glass
    /// alone leaves the last full look's, for another place of the charge).
    @ObservationIgnored var peopleUsesStructure = true
    /// The people's estimate pinned to compare others with, and what it was for: the charge, the
    /// assumptions and the buildings' constructions (`SimulationModel+People.swift`).
    var peopleBaseline: PeopleBaseline?
    /// How far the quick estimate's charge may be off: its yield within this factor either way,
    /// nine times in ten; 1 for exactly the scene's.
    var quickEstimateYieldWithin = 1.5
    /// Whether the quick estimate takes the learned field model's peak at the ground-floor façade
    /// strips, for their damage, glass and walls (emmettl/bombcad-work#67; `LearnedField`). Off
    /// unless chosen, and remembered; without its weights the estimate is the surrogate's alone.
    /// Turned on through `setLearnedPeaks`, which offers to download the weights when they are not
    /// there (`SimulationModel+LearnedField.swift`).
    var quickEstimateLearnedPeaks = UserDefaults.standard.bool(forKey: SimulationModel.learnedPeaksKey) {
        didSet {
            learnedDefaults.set(quickEstimateLearnedPeaks, forKey: Self.learnedPeaksKey)
            if envelopeDamageIsEstimate, !envelopeDamage.isEmpty { requestLook(preview: false) }
        }
    }
    /// Where the option and the weights' path are kept (a test's own store in tests).
    @ObservationIgnored var learnedDefaults = UserDefaults.standard
    /// Whether the quick estimate and the far field take the façade terms and load scatter of 23
    /// October 2026, fitted on runs whose top drained the far loads (`FacadeLoadSurrogate.TermSet
    /// .fitted`), in place of the clear-top terms adopted on 25 October (emmettl/bombcad-work#99):
    /// to reproduce an earlier estimate. Off unless chosen, and remembered.
    var quickEstimateFirstFitTerms = UserDefaults.standard.bool(forKey: SimulationModel.firstFitTermsKey) {
        didSet {
            learnedDefaults.set(quickEstimateFirstFitTerms, forKey: Self.firstFitTermsKey)
            if envelopeDamageIsEstimate, !envelopeDamage.isEmpty { requestLook(preview: false) }
            if !farFieldDamage.isEmpty { judgeFarField() }
        }
    }
    static let firstFitTermsKey = "quickEstimate.firstFitTerms"
    /// Whether the glass chances' pulses arrive with a front (`FacadeLoadSurrogate.TermSet
    /// .clearTopFront`, emmettl/bombcad-work#103): a candidate, off unless chosen, and remembered.
    /// The terms of 23 October, where chosen, take precedence.
    var quickEstimateGlassFront = UserDefaults.standard.bool(forKey: SimulationModel.glassFrontKey) {
        didSet {
            learnedDefaults.set(quickEstimateGlassFront, forKey: Self.glassFrontKey)
            if envelopeDamageIsEstimate, !envelopeDamage.isEmpty { requestLook(preview: false) }
            if !farFieldDamage.isEmpty { judgeFarField() }
        }
    }
    static let glassFrontKey = "quickEstimate.glassFront"
    /// Whether the façade terms take the far terms for façades deep in a city
    /// (`FacadeLoadSurrogate.TermSet.deepCity`, with the glass front `.deepCityFront`;
    /// emmettl/bombcad-work#104): a candidate, off unless chosen, and remembered. The terms of 23
    /// October, where chosen, take precedence.
    var quickEstimateDeepCity = UserDefaults.standard.bool(forKey: SimulationModel.deepCityKey) {
        didSet {
            learnedDefaults.set(quickEstimateDeepCity, forKey: Self.deepCityKey)
            if envelopeDamageIsEstimate, !envelopeDamage.isEmpty { requestLook(preview: false) }
            if !farFieldDamage.isEmpty { judgeFarField() }
        }
    }
    static let deepCityKey = "quickEstimate.deepCity"
    /// The façade terms and load scatter the quick estimate and the far field take.
    var surrogateTerms: FacadeLoadSurrogate.TermSet {
        if quickEstimateFirstFitTerms { return .fitted }
        if quickEstimateDeepCity { return quickEstimateGlassFront ? .deepCityFront : .deepCity }
        return quickEstimateGlassFront ? .clearTopFront : .adopted
    }
    /// Whether the far field carries the near run's match flat, with no trend with distance: the
    /// far set's own choice (`FarFieldSet.matchFlat`, saved with the project), on for New District's
    /// sets since 25 October 2026 (emmettl/bombcad-work#99) and off for those saved before.
    var farFieldMatchFlat: Bool {
        get { farFieldSet?.matchFlat == true }
        set {
            guard var set = farFieldSet, (set.matchFlat == true) != newValue else { return }
            let judged = !farFieldDamage.isEmpty
            set.matchFlat = newValue
            farFieldSet = set
            if judged { judgeFarField() }
        }
    }
    /// Where downloaded weights are kept: Application Support (a test's own folder in tests).
    @ObservationIgnored var learnedHome = LearnedField.defaultWeightsURL
    /// While the user is asked whether to download the weights; while they download; what the
    /// download last said (kept until the option is next asked for).
    var offersLearnedDownload = false
    var learnedDownloadInFlight = false
    var learnedDownloadStatus = ""
    @ObservationIgnored var learnedDownloadTask: Task<Void, Never>?
    /// The check on this Mac (`LearnedFieldCheck`, run as `BombCAD field-model check`): while it
    /// runs, and what it last said.
    var learnedCheckInFlight = false
    var learnedCheckReport: [String] = []
    static let learnedPeaksKey = "quickEstimate.learnedFieldPeaks"
    /// A path for the learned field model's weights other than the default
    /// (`LearnedField.weightsURL`; `BOMBCAD_FIELD_MODEL` comes first).
    static let learnedWeightsKey = "quickEstimate.learnedFieldWeights"
    /// What the learned field model said at the last estimate that asked for it: the strips it gave
    /// its peak to and its time, or why it could not be used.
    var learnedPeaksStatus = ""
    /// The learned field model's networks, once loaded, with the files they came from (the levels
    /// network's only with field model 2's second file); and the plan they see of the district,
    /// laid out once for every place of the charge.
    @ObservationIgnored var learnedNetwork:
        (url: URL, network: LearnedFieldNetwork, levelsURL: URL?, levels: LearnedFieldNetwork?)?
    @ObservationIgnored var learnedEstimator: (scene: Scenario, estimator: LearnedField.Estimator)?
    /// While the charge is dragged in the view (Place Charge on): the scene is loaded again only
    /// once it is let go, and a quick estimate on screen follows it (`beginDrag`).
    var isDraggingCharge = false
    /// True while the estimate shown is a preview made while dragging: only the colouring shown
    /// is worked out, on each building side's component nearest the charge.
    var envelopeEstimateIsPreview = false
    /// The district laid out for the quick estimate at any place of the charge
    /// (`FacadeLoadSurrogate.Prepared`), with the scene it was laid out from (its charge at the
    /// origin) and the cells.
    @ObservationIgnored var preparedDistrict:
        (scene: Scenario, cellSize: Float, prepared: FacadeLoadSurrogate.Prepared)?
    /// Whether the estimate follows the charge being dragged; the look being worked out; the place
    /// waiting for the next; the last shown, with its scene and what it worked out; and whether to
    /// show it again once the scene is loaded again after a drag.
    @ObservationIgnored var estimateFollowsCharge = false
    @ObservationIgnored var lookInFlight = false
    @ObservationIgnored var lookWaiting: (charge: SIMD3<Float>, preview: Bool)?
    @ObservationIgnored var followedLook:
        (scene: Scenario, look: FacadeLoadSurrogate.Prepared.Look, parts: FacadeLoadSurrogate.Prepared.Parts)?
    @ObservationIgnored var restoresFollowedLook = false
    /// Whether a full look's close calls are refined by the solver in the background, within
    /// `closeCallBudgetS` of wall-clock time (`refineCloseCalls`); the refinement's state, how far
    /// it has got, and the buildings whose results are the run's.
    var refinesCloseCalls = true
    var closeCallBudgetS = 120.0
    var isRefiningCloseCalls = false
    var closeCallProgress = 0.0
    var closeCallStatus = ""
    var refinedBuildings: Set<UUID> = []
    @ObservationIgnored var closeCallRun: ThresholdRefinementRun?
    @ObservationIgnored var closeCallScene: Scenario?
    @ObservationIgnored var closeCallRefined: ThresholdRefinement.Refined?

    @ObservationIgnored var lastEnvelopeDamage = ContinuousClock.now
    /// How long the last judgement took: a district's runs into seconds, so while running it is
    /// made again only after twenty times that.
    @ObservationIgnored var envelopeDamageCost = Duration.zero

    var groundShockStatus = ""
    @ObservationIgnored var groundShock: (any FrameConsumer)?
    @ObservationIgnored var groundShockTime = -1.0
    /// The ground points the current run estimates, as they were when it started.
    @ObservationIgnored var estimatedGroundSpec: GroundShockSpec?
    @ObservationIgnored var thermalEdit: Task<Void, Never>?
    /// The Mac, of those set for sweeps, to reckon the thermal radiation on; nil for this one.
    var thermalHost: String?
    /// The Mac, of those set for sweeps, to estimate the ground's shaking on; nil for this one.
    var groundShockHost: String?
    /// Where the run's thermal radiation stands: the largest fireball and the highest fluence.
    var thermalStatus = ""
    /// Frames of the run's thermal radiation reckoned so far, as last published: the receivers
    /// change with it, though they are read outside Observation.
    var thermalReckoned = 0
    @ObservationIgnored var thermal: (any FrameConsumer)?
    /// Where the current run's thermal radiation is reckoned, laid out here as wherever it runs.
    @ObservationIgnored var thermalReceivers: [ThermalReceiver] = []
    /// The same receivers by surface, the grids the view paints.
    @ObservationIgnored var thermalGrids: [ThermalSurfaceGrid] = []
    /// The material each receiver's surface was given, where their heating is reckoned.
    @ObservationIgnored var thermalHeating: SurfaceHeating.Layout?
    /// The thermal radiation the current run reckons, as it was when it started, and the
    /// fireball at each frame sent.
    @ObservationIgnored var reckonedSpec: ThermalSpec?
    @ObservationIgnored var fireballFrames: [FireballFrame] = []
    @ObservationIgnored var nextFireballTime = 0.0
    @ObservationIgnored var thermalPaintCache: (frames: Int, quantity: ThermalQuantity, paint: SurfacePaint)?
    /// A replayed frame's paint, by the frame and the quantity.
    @ObservationIgnored var replayPaintCache: (index: Int, quantity: ThermalQuantity, paint: SurfacePaint?)?
    /// Each venting pane's building in the run under way (`BlastSolver.envelopePaneOwners`), as an
    /// index among the scene's envelope buildings, for its recording; nil until first needed.
    @ObservationIgnored var timelinePaneOwners: [Int]?
    /// What the companions cost, kept between runs for those placed automatically; nil keeps it
    /// for this model only, as in tests. The app keeps it in the user's caches.
    @ObservationIgnored var costStore: ConsumerCostStore?
    @ObservationIgnored var measuredCosts: [String: ConsumerCosts] = [:]
    /// Where the current run's companions placed automatically went, by name ("local" or a host),
    /// and the key their costs are kept under.
    @ObservationIgnored var automaticPlaces: [String: String] = [:]
    @ObservationIgnored var runCostKey: String?

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
            farFieldSet = document.farField
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
                settings.terrainCutCells = run.cutsTerrain(over: scenario)
                settings.outlineByOverlap = run.countsByOverlap(over: scenario)
                settings.ventsGlazing = run.ventsGlazing(over: scenario)
                settings.settlesStructures = run.settlesStructures(over: scenario)
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

    // MARK: - Editing the layout

    /// The envelope building clicked in the view, the scene's or the far set's, whose judgement the
    /// sidebar shows (`InspectedEnvelopeSection`); nil for none.
    var inspectedEnvelope: UUID?

    /// How long the end of a run waits for its companions' last frames: each, before what has
    /// come in is shown and the wait given up (the status then says how many frames are left), and
    /// all of them, before the run's costs are left unrecorded. Nil waits however long it takes,
    /// as the tests ask (`.unbounded`), so that a loaded Mac cannot fail them; the app keeps these.
    struct CatchUpLimits: Equatable {
        var fragments: Duration? = .seconds(30)
        var thermal: Duration? = .seconds(120)
        var groundShock: Duration? = .seconds(60)
        var costs: Duration? = .seconds(60)

        static let unbounded = CatchUpLimits(fragments: nil, thermal: nil, groundShock: nil, costs: nil)

        /// Whether `start`, the moment the wait began, is still within `limit`.
        static func within(_ limit: Duration?, since start: ContinuousClock.Instant) -> Bool {
            limit.map { start.duration(to: .now) < $0 } ?? true
        }
    }
    var catchUpLimits = CatchUpLimits()
}
