import BlastCore
import BlastRender
import Foundation
import Metal
import Observation
import simd

enum Resolution: String, CaseIterable, Identifiable {
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
enum PlaybackSpeed: Double, CaseIterable, Identifiable {
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
}

/// The part of the layout picked out for editing.
enum EditSelection: Hashable {
    case block(Int)
    case solid(Int)
    case opening(Int)
    case gauge(Int)
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
    var renderSettings = RenderSettings()
    var camera: OrbitCamera
    var speed = PlaybackSpeed.x100 {
        didSet { restartPacing() }
    }
    /// Simulated time at which the run stops, in seconds.
    var duration: Double
    /// The block or wall being edited, which the view outlines.
    var selection: EditSelection?
    /// While set, a click on the ground in the view moves the charge there.
    var isPlacingCharge = false

    private(set) var isRunning = false
    private(set) var time: Double = 0
    private(set) var stepCount = 0
    private(set) var traces: [GaugeTrace] = []
    private(set) var stats = SimulationStats()
    private(set) var grid: Grid?
    /// Damage and deflection of the deformable structure, if the scenario has one.
    private(set) var structureSummary: StructureSummary?
    private(set) var structureSubsteps = 0
    /// Deflection of the structure through the run, sampled about ten times a second.
    private(set) var structureHistory: [StructureSample] = []
    /// Largest deflection recorded so far, in millimetres.
    var peakDeflection: Double { structureHistory.map(\.deflection).max() ?? 0 }
    private(set) var memoryFootprint = 0
    private(set) var chargeIsBlocked = false
    private(set) var errorMessage: String?
    /// Layouts before the most recent edits, newest last, and those undone since.
    private(set) var undoStack: [Scenario] = []
    private(set) var redoStack: [Scenario] = []
    var canUndo: Bool { !undoStack.isEmpty || settings.scenario != settledScenario }
    var canRedo: Bool { !redoStack.isEmpty }

    @ObservationIgnored let device: MTLDevice?
    @ObservationIgnored let commandQueue: MTLCommandQueue?
    @ObservationIgnored let renderer: SceneRenderer?
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
    @ObservationIgnored private var settledScenario: Scenario
    private static let undoLimit = 100

    init() {
        let scenario = SimulationSettings().scenario
        self.scenario = scenario
        settledScenario = scenario
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
        if device == nil {
            errorMessage = "This Mac has no Metal device."
        }
        rebuild()
    }

    private static func defaultDuration(for scenario: Scenario) -> Double {
        // A structure keeps moving long after the blast wave has left the domain.
        let crossing = (scenario.acousticCrossingTime * 100).rounded(.up) / 100
        return scenario.structure == nil ? crossing : max(crossing, 0.25)
    }

    // MARK: - Controls

    func toggleRun() {
        if isRunning {
            isRunning = false
        } else {
            run()
        }
    }

    func run() {
        guard solver != nil, !isRunning else { return }
        if time >= duration - 1e-9 {
            rebuild()
        }
        isRunning = true
        restartPacing()
        pump()
    }

    func reset() {
        requestRebuild()
    }

    func resetCamera() {
        camera = .framing(scenario)
    }

    /// Switches to a built-in layout, adopting its charge, camera and duration.
    func select(_ preset: ScenarioPreset) {
        settings.preset = preset
        adopt(preset.scenario)
    }

    /// Replaces the layout with one loaded from a file.
    func open(_ scenario: Scenario) {
        adopt(scenario)
        settingsChanged()
    }

    private func adopt(_ scenario: Scenario) {
        settings.scenario = scenario
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
    func settingsChanged() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            recordEdit()
            requestRebuild()
        }
    }

    // MARK: - Undo

    /// Makes the current layout a step that can be undone back to, if it has changed.
    func recordEdit() {
        guard settings.scenario != settledScenario else { return }
        undoStack.append(settledScenario)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
        settledScenario = settings.scenario
    }

    /// Returns the layout to how it was before the last edit.
    func undo() {
        // An edit still settling counts as the last edit.
        recordEdit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings.scenario)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings.scenario)
        restore(next)
    }

    private func restore(_ scenario: Scenario) {
        settledScenario = scenario
        settings.scenario = scenario
        if highlightedBox == nil { selection = nil }
        settingsChanged()
    }

    var domainSize: SIMD3<Float> { settings.scenario.domainSize }

    // MARK: - Editing the layout

    /// The box picked out for editing, if it still exists.
    var highlightedBox: Box? {
        let scenario = settings.scenario
        switch selection {
        case .block(let index): return scenario.boxes.indices.contains(index) ? scenario.boxes[index] : nil
        case .solid(let index):
            guard let solids = scenario.structure?.solids, solids.indices.contains(index) else { return nil }
            return solids[index]
        case .opening(let index):
            guard let openings = scenario.structure?.openings, openings.indices.contains(index) else {
                return nil
            }
            return openings[index]
        case .gauge(let index):
            guard scenario.gauges.indices.contains(index) else { return nil }
            let position = scenario.gauges[index].position
            return Box(min: position - 0.25, max: position + 0.25)
        case nil: return nil
        }
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

    func removeGauge(at index: Int) {
        guard settings.scenario.gauges.indices.contains(index) else { return }
        settings.scenario.gauges.remove(at: index)
        selection = nil
    }

    /// Adds a rigid block in the middle of the domain.
    func addBlock() {
        let centre = settings.scenario.domainSize / 2
        settings.scenario.boxes.append(
            Box(x: (centre.x - 3)...(centre.x + 3), y: (centre.y - 3)...(centre.y + 3), height: 9))
        selection = .block(settings.scenario.boxes.count - 1)
    }

    func removeBlock(at index: Int) {
        guard settings.scenario.boxes.indices.contains(index) else { return }
        settings.scenario.boxes.remove(at: index)
        selection = nil
    }

    /// Adds a 250 mm wall, 4 m long and 3 m high, to the deformable structure, creating the
    /// structure if the layout has none.
    func addWall() {
        let centre = settings.scenario.domainSize / 2
        let wall = Box(x: centre.x...(centre.x + 0.25), y: (centre.y - 2)...(centre.y + 2), height: 3)
        editStructure { $0.solids.append(wall) }
        selection = .solid((settings.scenario.structure?.solids.count ?? 1) - 1)
    }

    func removeSolid(at index: Int) {
        editStructure { $0.removeSolid(at: index) }
        selection = nil
    }

    /// Sets how one piece of the structure is reinforced.
    func setReinforcement(_ spec: Reinforcement, ofSolid index: Int) {
        editStructure { $0.setReinforcement(spec, of: index) }
    }

    /// Adds an opening (a window or door) to cut out of the structure.
    func addOpening() {
        guard let first = settings.scenario.structure?.solids.first else { return }
        let centre = (first.min + first.max) / 2
        let opening = Box(min: centre - SIMD3(0.5, 0.5, 0.5), max: centre + SIMD3(0.5, 0.5, 0.5))
        editStructure { $0.openings.append(opening) }
        selection = .opening((settings.scenario.structure?.openings.count ?? 1) - 1)
    }

    func removeOpening(at index: Int) {
        editStructure { structure in
            guard structure.openings.indices.contains(index) else { return }
            structure.openings.remove(at: index)
        }
        selection = nil
    }

    /// Changes the deformable structure and re-derives its reinforcement from the new shapes.
    /// A structure left with no solids is removed.
    func editStructure(_ change: (inout StructureModel) -> Void) {
        var structure = settings.scenario.structure ?? StructureModel(solids: [], elementSize: 0.0625)
        change(&structure)
        structure.autoReinforce()
        settings.scenario.structure = structure.solids.isEmpty ? nil : structure
    }

    /// Handles a click in the view, at a point in normalised device coordinates. In placing
    /// mode it moves the selected gauge there, or the charge if no gauge is selected.
    func click(ndc: SIMD2<Float>, aspectRatio: Float) {
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
    /// then the structure's peak deflection, one row per sample.
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
        for sample in structureHistory {
            lines.append(
                "Peak deflection,\(String(format: "%.4f", sample.time)),\(String(format: "%.3f", sample.deflection)),mm"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Building

    private func requestRebuild() {
        if batchInFlight {
            // The GPU still owns the solver's buffers; rebuild when the batch lands.
            rebuildPending = true
        } else {
            rebuild()
        }
    }

    private func rebuild() {
        isRunning = false
        rebuildPending = false
        guard let device, let commandQueue, let renderer else { return }

        let scenario = settings.scenario
        let grid = scenario.grid(cellSize: settings.resolution.cellSize)
        do {
            if let solver, solver.grid == grid {
                try solver.load(scenario)
            } else {
                solver = nil
                // State (two copies), peak, impulse, mask and the visualisation volume; the
                // structure's mesh is small by comparison.
                let required = grid.cellCount * 57
                guard UInt64(required) < device.recommendedMaxWorkingSetSize / 10 * 7 else {
                    throw BlastError.allocationFailed(
                        "\(grid.cellCount / 1_000_000) million cells; try a coarser resolution")
                }
                solver = try BlastSolver(
                    device: device, commandQueue: commandQueue, scenario: scenario,
                    cellSize: settings.resolution.cellSize)
            }
            errorMessage = nil
        } catch {
            solver = nil
            errorMessage = "\(error)"
        }

        self.scenario = scenario
        self.grid = solver?.grid
        memoryFootprint = solver?.memoryFootprint ?? 0
        structureSummary = solver?.structure?.summary()
        structureSubsteps = solver?.structureSubsteps ?? 0
        structureHistory = []
        chargeIsBlocked = scenario.chargeIsBlocked
        time = 0
        stepCount = 0
        stats = SimulationStats()
        batchSize = 4
        traces = scenario.gauges.enumerated().map { GaugeTrace(id: $0.offset, name: $0.element.name) }
        if let solver {
            renderer.setScene(scenario, solver: solver)
        }
    }

    // MARK: - Stepping

    private func restartPacing() {
        paceOriginWall = .now
        paceOriginTime = time
        lastBatchCompletion = .now
    }

    /// Commits the next batch of steps if the run is active and the GPU is free.
    private func pump() {
        guard isRunning, !batchInFlight, let solver else { return }

        var limit = duration
        if speed != .unlimited {
            let wall = (ContinuousClock.now - paceOriginWall).seconds
            limit = min(duration, paceOriginTime + wall / speed.rawValue)
        }
        let remaining = limit - solver.time
        guard remaining > 1e-9 else {
            if solver.time >= duration - 1e-9 {
                finish()
            } else if !waitingForPace {
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

        // Steps past the limit would be wasted work, so only encode as many as are needed.
        let needed = stats.timeStep > 0 ? Int((remaining / stats.timeStep).rounded(.up)) + 1 : 2
        let steps = max(1, min(batchSize, needed))
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
        time = solver.time
        stepCount = solver.stepCount

        let now = ContinuousClock.now
        let wall = (now - lastBatchCompletion).seconds
        lastBatchCompletion = now
        if result.steps > 0, gpuSeconds > 0 {
            let stepRate = Double(result.steps) / gpuSeconds
            let blend = stats.stepsPerSecond == 0 ? 1 : 0.1
            stats.stepsPerSecond += blend * (stepRate - stats.stepsPerSecond)
            stats.cellUpdatesPerSecond = stats.stepsPerSecond * Double(solver.grid.cellCount)
            stats.timeStep = result.lastTimeStep
            if result.elapsed > 0, wall > 0 {
                let ratio = wall / result.elapsed
                stats.slowMotion += (stats.slowMotion == 0 ? 1 : 0.1) * (ratio - stats.slowMotion)
            }
            // Aim for roughly 10 ms of GPU work per batch so the display stays fluid.
            let ideal = 0.010 * stepRate
            batchSize = min(max(Int(ideal.rounded()), 1), 64)
        }

        if failed || !result.isStable {
            errorMessage = "The solution became unstable. Reset, or try a smaller charge or a finer grid."
            isRunning = false
        }
        if (now - lastTracePublication).seconds > 0.1 || !isRunning {
            publishTraces()
        }
        if rebuildPending {
            rebuild()
            return
        }
        if time >= duration - 1e-9 {
            finish()
        }
        pump()
    }

    private func finish() {
        isRunning = false
        publishTraces()
    }

    /// Copies the gauge histories into chart-sized traces, keeping the extremes of each bucket.
    private func publishTraces() {
        guard let solver else { return }
        lastTracePublication = .now
        structureSummary = solver.structure?.summary()
        if let summary = structureSummary, !summary.hasBlownUp,
            structureHistory.last?.time != solver.time * 1000
        {
            structureHistory.append(
                StructureSample(
                    id: structureHistory.count, time: solver.time * 1000,
                    deflection: Double(summary.maxDisplacement) * 1000))
        }
        if structureSummary?.hasBlownUp == true {
            errorMessage = "The structure became numerically unstable. Reset and try a smaller charge."
            isRunning = false
        }
        let ambient = scenario.atmosphere.pressure
        let maxPoints = 500
        for (index, history) in solver.gaugeHistories.enumerated() where index < traces.count {
            let bucket = max(1, history.count / maxPoints)
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
