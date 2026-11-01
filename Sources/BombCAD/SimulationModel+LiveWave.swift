import BlastCore
import BlastRender
import Foundation
import Observation
import simd

/// How fast the live blast wave plays back: a district's front takes seconds to cross it, a
/// street's a few hundredths of one.
enum LiveWaveSpeed: Double, CaseIterable, Identifiable {
    case realTime = 1
    case quarter = 0.25
    case tenth = 0.1
    case fiftieth = 0.02
    case twoHundredth = 0.005

    var id: Double { rawValue }

    var title: String { self == .realTime ? "Real time" : "1/\(Int((1 / rawValue).rounded())) speed" }
}

/// What a live wave is worked out for: the charge, its mass, the scene loaded and whether the
/// charge is being dragged (a large district then works on coarser cells).
struct LiveWaveRequest: Equatable {
    var charge: SIMD3<Float>
    var mass: Double
    var sceneVersion: Int
    var coarse: Bool
}

// The blast wave, live (emmettl/bombcad-work#112 item 2; docs/live-wave.md): an arrival time,
// peak and decay over the plan, worked out in tens of milliseconds whenever the charge moves, and
// drawn by the renderer at any time on its clock, so that the front can be dragged, scrubbed and
// played without a run.
extension SimulationModel {
    /// A plan of more cells than this is worked out on cells twice as large while the charge is
    /// dragged, and on its own once it is let go.
    static let liveWaveDragCells = 500_000

    /// The cells the wave over `scene` is worked out on: `LiveWave.Plan.cellSize`'s, twice as large
    /// while the charge is dragged where that plan has more than `liveWaveDragCells`.
    static func liveWaveCell(for scene: Scenario, dragging: Bool) -> Float {
        let fine = LiveWave.Plan.cellSize(for: scene)
        let cells = Double(scene.domainSize.x / fine) * Double(scene.domainSize.y / fine)
        return dragging && cells > Double(liveWaveDragCells) ? 2 * fine : fine
    }

    func liveWaveShownChanged() {
        if liveWaveShown {
            watchLiveWave()
            requestLiveWave()
        } else {
            pauseLiveWave()
            liveWave = nil
            liveWaveVersion += 1
            liveWaveStatus = ""
            liveWaveShownFor = nil
            liveWaveWaiting = nil
            liveWavePlans = [:]
        }
    }

    /// Whether the view draws the live wave now: shown, and no run's own wave on screen.
    var drawsLiveWave: Bool {
        liveWaveShown && liveWave != nil && !isRunning && time == 0 && playback == nil && remoteRun == nil
    }

    /// The last arrival on the plan and a little after, where playing stops.
    var liveWaveEnd: Double {
        guard let liveWave else { return 0 }
        return Double(liveWave.lastArrival) * 1.05
    }

    /// Asks again on any change to the settings (the charge, its mass), the scene loaded, or the
    /// drag starting or ending, for as long as the wave is shown.
    private func watchLiveWave() {
        withObservationTracking {
            _ = settings
            _ = sceneVersion
            _ = isDraggingCharge
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.liveWaveShown else { return }
                self.requestLiveWave()
                self.watchLiveWave()
            }
        }
    }

    /// Works the wave out for the charge where it is now, unless it already is; one at a time, away
    /// from the main thread, with only the latest place waiting.
    func requestLiveWave() {
        guard liveWaveShown else { return }
        let request = LiveWaveRequest(
            charge: settings.chargePosition, mass: Double(settings.chargeMass), sceneVersion: sceneVersion,
            coarse: isDraggingCharge)
        guard request != liveWaveShownFor || liveWave == nil else { return }
        liveWaveWaiting = request
        startLiveWave()
    }

    private func startLiveWave() {
        guard !liveWaveInFlight, let request = liveWaveWaiting else { return }
        liveWaveWaiting = nil
        // The scene as loaded: while the charge is dragged it is not loaded again until let go.
        let layout = scenario
        let cell = Self.liveWaveCell(for: layout, dragging: request.coarse)
        let known = liveWavePlans[cell].flatMap { $0.version == request.sceneVersion ? $0.plan : nil }
        liveWaveInFlight = true
        Task { [weak self] in
            let (plan, field, planSeconds) = await Task.detached(priority: .userInitiated) {
                let start = ContinuousClock.now
                let plan = known ?? LiveWave.Plan(scene: layout, cell: cell)
                let planSeconds = known == nil ? (ContinuousClock.now - start) / .seconds(1) : 0
                let field = LiveWave.field(plan: plan, charge: request.charge, mass: request.mass)
                return (plan, field, planSeconds)
            }.value
            guard let self else { return }
            self.liveWaveInFlight = false
            if self.liveWaveShown {
                // Plans for scenes no longer loaded are let go.
                self.liveWavePlans = self.liveWavePlans.filter { $0.value.version == request.sceneVersion }
                self.liveWavePlans[cell] = (request.sceneVersion, plan)
                let first = self.liveWave == nil
                self.liveWave = field
                self.liveWaveVersion += 1
                self.liveWaveShownFor = request
                // First shown: the whole wave, every peak and shadow; then the time kept as it moves.
                if first { self.liveWaveTime = Double(field.lastArrival) }
                self.liveWaveTime = min(self.liveWaveTime, self.liveWaveEnd)
                self.liveWaveStatus =
                    String(
                        format:
                            "Estimate on %.0f m cells in %.0f ms%@: the front along the shortest paths round and over buildings, Kingery–Bulmash fitted to BombCAD's 4 m district runs (illustrative). Not a run.",
                        cell, 1000 * field.seconds,
                        planSeconds > 0
                            ? String(format: ", the plan laid out in %.0f ms", 1000 * planSeconds) : "")
            }
            self.startLiveWave()
        }
    }

    func playLiveWave() {
        guard liveWave != nil else { return }
        if liveWaveTime >= liveWaveEnd * 0.999 { liveWaveTime = 0 }
        liveWavePlaying = true
        let origin = (wall: ContinuousClock.now, time: liveWaveTime)
        let speed = liveWaveSpeed.rawValue
        liveWavePlayTask?.cancel()
        liveWavePlayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.liveWavePlaying, self.liveWave != nil else { return }
                let t = origin.time + (ContinuousClock.now - origin.wall) / .seconds(1) * speed
                if t >= self.liveWaveEnd {
                    self.liveWaveTime = self.liveWaveEnd
                    self.liveWavePlaying = false
                    return
                }
                self.liveWaveTime = t
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
    }

    func pauseLiveWave() {
        liveWavePlaying = false
        liveWavePlayTask?.cancel()
        liveWavePlayTask = nil
    }

    /// Plays on at `speed` from where it is.
    func setLiveWaveSpeed(_ speed: LiveWaveSpeed) {
        liveWaveSpeed = speed
        if liveWavePlaying { playLiveWave() }
    }

    /// Moves the wave to time `t` and holds it there.
    func scrubLiveWave(to t: Double) {
        pauseLiveWave()
        liveWaveTime = min(max(t, 0), liveWaveEnd)
    }

    /// What the wave shows at its time, for VoiceOver and the bar: how far the front has gone and
    /// how strong it is there, and the cells it has reached.
    var liveWaveSummary: String? {
        guard drawsLiveWave, let field = liveWave else { return nil }
        let t = Float(liveWaveTime)
        var reached = 0
        var front: Float = 0
        var frontPeak: Float = 0
        var fronts = 0
        // Every fourth cell each way is plenty to say it.
        let stride = 4
        for j in Swift.stride(from: 0, to: field.rows, by: stride) {
            for i in Swift.stride(from: 0, to: field.columns, by: stride) {
                let n = i + field.columns * j
                guard field.arrival[n] <= t else { continue }
                reached += 1
                // The cells the front reached in the last tenth of its time.
                if field.arrival[n] >= 0.9 * t {
                    front += field.straight[n]
                    frontPeak += field.peak[n]
                    fronts += 1
                }
            }
        }
        let samples = ((field.rows + stride - 1) / stride) * ((field.columns + stride - 1) / stride)
        let share = Double(reached) / Double(max(samples, 1))
        let at = Self.liveWaveTimeText(liveWaveTime)
        guard reached > 0 else { return "blast wave estimate at \(at): the front has not left the charge" }
        guard fronts > 0, t <= field.lastArrival else {
            return String(
                format:
                    "blast wave estimate at %@: the front has crossed the plan, %.0f%% of the plan reached",
                at,
                100 * share)
        }
        return String(
            format:
                "blast wave estimate at %@: the front about %.0f m from the charge at %.1f kPa, %.0f%% of the plan reached",
            at, Double(front) / Double(fronts), Double(frontPeak) / Double(fronts) / 1000, 100 * share)
    }

    /// A time in milliseconds below a second, else seconds.
    static func liveWaveTimeText(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}
