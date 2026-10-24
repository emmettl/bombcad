import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation

/// The blast run on a paired Mac nearby and watched here (emmettl/bombcad-work#73): that Mac's GPU
/// runs it, as `BombCAD watch` does, and sends the scene as this Mac's renderer draws it, the field
/// every few cells and every structure's mesh, a frame a millisecond of simulated time while the
/// link keeps up; the viewport draws each as it arrives, and keeps them as the run's recording, so
/// that the run comes back with its result and a timeline to replay and compare as a run here does.
/// Should the connection drop, the run carries on there and can be watched again, or its result
/// fetched, later (`SessionRelay`).
@MainActor @Observable
final class RemoteRun {
    enum Phase: Equatable {
        case connecting
        case running
        /// The connection dropped; the run carries on there.
        case lost(String)
        /// Its result to be fetched later, the view back to this Mac's.
        case waiting
        case finished
        case failed(String)
        case stopped
    }

    /// The Mac it runs on, as `nearby:<name>`, and its name as shown.
    let host: String
    var macName: String { NearbyWorkers.isNearby(host) ? NearbyWorkers.name(of: host) : host }
    /// The job's identifier, which a session resuming it names.
    let id: UUID
    /// The run's name once kept.
    let name: String
    let scenario: Scenario
    let inputs: SimulationInputs
    let job: WatchJob
    var phase = Phase.connecting
    /// The link it is watched over, as the connection names it ("Studio over Wi-Fi").
    var link = ""
    var device = ""
    var fraction = 0.0
    var time = 0.0
    var framesShown = 0
    var bytesReceived = 0
    /// What it came to, for the overlay once finished: what crossing the link cost.
    var summary: String?
    /// Held there between batches (emmettl/bombcad-work#73 stage 3); the scene here can be edited
    /// meanwhile, and the run started again with the edits (`rerunRemoteWithEdits`).
    var paused = false
    /// The project's bytes sent for it, and those of its files named as sent before.
    var projectBytes = (sent: 0, reused: 0)

    /// The settings, the scene among them, it was sent with, to tell whether they have been edited
    /// here since.
    @ObservationIgnored var sentSettings: SimulationSettings?
    /// Whether its connection goes on to the next run (a rerun with edits) rather than closing.
    @ObservationIgnored var handingOver = false

    var isActive: Bool { phase == .connecting || phase == .running }
    var canResume: Bool {
        switch phase {
        case .lost, .waiting: true
        default: false
        }
    }

    @ObservationIgnored var client: SweepWorkerClient?
    @ObservationIgnored var upload: ViewUpload?
    /// What the view draws over the scene as of the last frame, every part resolved to its value
    /// or none (`SceneOverlay`), and what resolves them.
    @ObservationIgnored var overlay = SceneOverlay()
    @ObservationIgnored var overlayResolver = SceneOverlayResolver()
    /// The overlay's bytes received, before compression.
    @ObservationIgnored var overlayBytes = 0
    /// Whether the viewport shows this run's view, not this Mac's scene or a replay.
    @ObservationIgnored var isShown = false
    /// The fragments' launch speed, which their dots' colours are scaled by.
    @ObservationIgnored var fragmentLaunchSpeed: Float?
    /// The vents and envelope colours drawn last, and the thermal paint as last worked out.
    @ObservationIgnored var layersShown: TimelineLayers?
    @ObservationIgnored var paintCache: (frames: Int?, quantity: ThermalQuantity, paint: SurfacePaint?)?
    @ObservationIgnored var timeline: StreamedTimeline?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var lastHeard = ContinuousClock.now
    @ObservationIgnored var arrivals: [ContinuousClock.Instant] = []
    @ObservationIgnored var drawSeconds = 0.0
    @ObservationIgnored var stopping = false
    /// Why this Mac gave the run up (a frame it could not read), once it has.
    @ObservationIgnored var failure: String?

    init(host: String, name: String, scenario: Scenario, inputs: SimulationInputs, job: WatchJob) {
        self.host = host
        self.name = name
        self.scenario = scenario
        self.inputs = inputs
        self.job = job
        id = job.id
    }

    /// One line on what crossing the link cost, here and on the other Mac.
    func describe(_ stats: ViewStats?) -> String {
        let intervals = zip(arrivals.dropFirst(), arrivals).map { ($0.0 - $0.1).seconds * 1000 }
        var line = String(
            format: "The project out %.0f kB%@; ", Double(projectBytes.sent) / 1e3,
            projectBytes.reused > 0
                ? String(format: " (%.0f kB more named as sent before)", Double(projectBytes.reused) / 1e3)
                : "")
        line += String(
            format:
                "%d frames shown, %.0f kB each on average (%.1f kB of it, before compression, drawn over the scene), %.1f MB in all; an update every %@; drawing here %.1f ms a frame",
            framesShown, Double(bytesReceived) / 1e3 / Double(max(framesShown, 1)),
            Double(overlayBytes) / 1e3 / Double(max(framesShown, 1)), Double(bytesReceived) / 1e6,
            HeadlessWatch.median(intervals).map { String(format: "%.0f ms", $0) } ?? "–",
            1000 * drawSeconds / Double(max(framesShown, 1)))
        if let stats {
            line += String(
                format:
                    ". On %@: the run took %.1f s, frames held it %.1f ms each (%.2f ms of it what is drawn over the scene); lag %@",
                macName, stats.runSeconds, 1000 * stats.readSeconds / Double(max(stats.sent, 1)),
                1000 * stats.overlaySeconds / Double(max(stats.sent, 1)),
                HeadlessWatch.median(stats.lags.map { $0 * 1000 }).map { String(format: "%.0f ms", $0) }
                    ?? "–")
        }
        return line
    }
}

/// A watched run's frames kept as a run's recording (`RunTimelineRecorder`'s folder: the setup,
/// a file a frame, `run.json`), so that it replays as a run here does; at most one frame each
/// `interval` of simulated time, and the last.
@MainActor
final class StreamedTimeline {
    let folder: URL
    private var manifest: RunTimelineManifest
    private let writer = TimelineWriter()
    private let interval: Double
    private var nextTime = -Double.infinity
    private var frames = 0
    private var pending: [(path: String, time: Double)] = []
    /// The latest frame not recorded, to record as the last.
    private var latest: TimelineFrame?
    /// Each layer stored only when it has changed, as a recording here stores them.
    private var keeper = TimelineLayerKeeper()

    init(setup raw: Data, fingerprint: String, duration: Double) throws {
        folder = RunTimelineRecorder.stagingRoot.appending(
            path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        manifest = RunTimelineManifest(
            sceneFingerprint: fingerprint, settingsFingerprint: fingerprint,
            budgetBytes: RunTimelineRecorder.defaultBudgetBytes)
        manifest.encodingVersion = TimelineCodec.version
        let setup = try TimelineCodec.compress(raw)
        try setup.write(to: folder.appending(path: "frames/setup.lzfse"))
        manifest.add(.init(kind: .setup, time: 0, step: 0, path: "frames/setup.lzfse", bytes: setup.count))
        interval = max(duration / Double(RunTimelineRecorder.defaultFrames), 1e-6)
    }

    /// Takes a frame as it arrives, its layers each resolved to a value or none.
    func add(_ frame: TimelineFrame) {
        guard frame.time >= nextTime - 1e-12 else {
            latest = frame
            return
        }
        record(frame)
    }

    private func record(_ frame: TimelineFrame) {
        latest = nil
        if let last = pending.last, last.time >= frame.time { return }
        let path = String(format: "frames/f-%06d.lzfse", frames)
        var stored = frame
        stored.layers = keeper.store(frame.layers, frame: frames)
        writer.write(stored, to: folder.appending(path: path))
        pending.append((path, frame.time))
        frames += 1
        nextTime = frame.time + interval
    }

    /// Waits for every frame to be written and writes the manifest; the folder, or nil if no frame
    /// could be.
    func finish() async -> URL? {
        if let latest { record(latest) }
        let sizes = await writer.drain()
        for frame in pending {
            guard let bytes = sizes[frame.path] else { continue }
            manifest.add(
                .init(
                    kind: .frames, time: frame.time, step: 0, path: frame.path, bytes: bytes,
                    endTime: frame.time, count: 1))
        }
        guard !manifest.entries(.frames).isEmpty, let data = try? manifest.encoded(),
            (try? data.write(to: folder.appending(path: RunTimelineManifest.fileName))) != nil
        else {
            discard()
            return nil
        }
        return folder
    }

    func discard() { try? FileManager.default.removeItem(at: folder) }
}

extension SimulationModel {
    /// The run elsewhere whose view the viewport shows now, if it shows one rather than this Mac's
    /// scene or a replay.
    var shownRemoteRun: RemoteRun? {
        guard playback == nil, let remote = remoteRun, remote.isShown, remote.upload != nil else {
            return nil
        }
        return remote
    }

    /// Draws the remote run's vent panels and envelope colours as its last frame had them, if they
    /// changed (or `again`).
    func showRemoteLayers(_ remote: RemoteRun, again: Bool = false) {
        let layers = remote.overlay.layers
        if !again, let shown = remote.layersShown, shown.vents == layers.vents,
            shown.envelopeCodes == layers.envelopeCodes
        {
            return
        }
        remote.layersShown = layers
        showLayers(layers, scenario: remote.scenario, recordsLayers: true)
        applyFarFieldColours()
    }

    /// The remote run's thermal paint of `quantity` as its last frame had it.
    func remoteThermalPaint(_ remote: RemoteRun, _ quantity: ThermalQuantity) -> SurfacePaint? {
        let thermal = remote.overlay.layers.thermal.value
        if let cache = remote.paintCache, cache.frames == thermal?.frames, cache.quantity == quantity {
            return cache.paint
        }
        let paint = thermalPaint(thermal, quantity)
        remote.paintCache = (thermal?.frames, quantity, paint)
        return paint
    }

    /// The remote run's fragments, their strikes and its ground points as its last frame had them,
    /// as the view draws them.
    func remoteDots(_ remote: RemoteRun, _ settings: RenderSettings) -> [SIMD4<Float>] {
        let overlay = remote.overlay
        let ground =
            settings.showGroundPoints
            ? overlay.groundDots.value ?? groundShockSpec?.dots(on: remote.scenario.terrain) ?? [] : []
        return fragmentDots(
            overlay.fragments, strikes: overlay.strikes.value ?? [], launchSpeed: remote.fragmentLaunchSpeed,
            showFragments: settings.showFragments, showTracers: settings.showTracers) + ground
    }

    /// The Macs paired with this one that a run can be sent to, as `nearby:<name>`.
    var pairedMacs: [String] {
        NearbyWorkers.store.pairings().map { NearbyWorkers.host($0.peer.name) }.sorted()
    }

    /// Connects to a worker on `host`, resuming the held run `resume` if given: a paired Mac nearby
    /// by default; tests reach a server in their own process.
    static func connectRemote(_ host: String, resume: UUID?) async throws -> SweepWorkerClient {
        guard NearbyWorkers.isNearby(host) else {
            throw ProjectFileError.invalid("Only a paired Mac nearby can run the blast for this one.")
        }
        return try await NearbyWorkers.connect(host: host, resume: resume)
    }

    /// Why a run cannot be sent to another Mac now, or nil if it can.
    var remoteRunUnavailable: String? {
        if sweep.isActive { return "A sweep is running." }
        if isLoadingInputs || rebuildPending || isPreparingImports || importsNeedResampling {
            return "The scene is still being prepared."
        }
        if remoteRun?.isActive == true { return "A run is already under way on \(remoteRun!.macName)." }
        if savedRuns.count >= SavedSimulationRun.maximumRuns {
            return "The project keeps \(SavedSimulationRun.maximumRuns) runs already; remove one first."
        }
        return nil
    }

    /// Sends the blast to `host` and watches it here (see `RemoteRun`), over `session` if given (a
    /// rerun's), else the session the last run there left open, else a new one.
    func startRemoteRun(on host: String, over session: SweepWorkerClient? = nil) {
        if let reason = remoteRunUnavailable {
            session?.close()
            errorMessage = reason
            return
        }
        // A session left open to another Mac goes.
        if let open = remoteSession, open.host != host || open.client.isClosed || session != nil {
            if open.client !== session { open.client.close() }
            remoteSession = nil
        }
        isRunning = false
        stopReplay()
        do {
            var document = ProjectDocument(model: self)
            document.savedRuns = []
            let inputs = try HeadlessRun.inputs(
                for: document, options: HeadlessRun.Options(project: URL(filePath: "/dev/null")))
            let cellSize =
                Resolution(rawValue: inputs.settings.resolution)?.cellSize ?? settings.resolution.cellSize
            let grid = inputs.scenario.grid(cellSize: cellSize)
            // The field as a run here records it: at most about half a million texels.
            let stride = RunTimelineRecorder.stride(for: SIMD3(grid.nx, grid.ny, grid.nz))
            let macName = NearbyWorkers.isNearby(host) ? NearbyWorkers.name(of: host) : host
            let taken = Set(savedRuns.map { $0.name.lowercased() })
            let name = (1...).lazy.map { $0 == 1 ? "On \(macName)" : "On \(macName) \($0)" }
                .first { !taken.contains($0.lowercased()) }!
            let job = WatchJob(
                id: UUID(), name: name, project: SweepWorkerArchive(try document.makeArchive()),
                frameInterval: 1, view: ViewSpec(sceneStride: stride), keepsRunning: true, asApp: true)
            let remote = RemoteRun(
                host: host, name: name, scenario: inputs.scenario, inputs: inputs, job: job)
            remote.sentSettings = settings
            remote.fragmentLaunchSpeed = fragmentSpec.map {
                $0.launchSpeed(chargeMass: inputs.scenario.charge.mass)
            }
            // The receivers its thermal paint is sent for, laid out here as there.
            if let spec = thermalSpec, (try? spec.validate()) != nil {
                stopThermal()
                layOutThermalPaint(spec, scene: FragmentScene(inputs.scenario))
            }
            remoteRun?.timeline?.discard()
            remoteRun = remote
            errorMessage = nil
            time = 0
            stepCount = 0
            let client = session ?? remoteSession?.client
            remoteSession = nil
            remote.task = Task { await drive(remote, resuming: false, over: client) }
        } catch {
            errorMessage = "The run could not be sent: \(error.localizedDescription)"
        }
    }

    /// Watches the remote run again after the connection dropped, or fetches its result.
    func resumeRemoteRun() {
        guard let remote = remoteRun, remote.canResume else { return }
        isRunning = false
        stopReplay()
        remote.phase = .connecting
        remote.stopping = false
        remote.task = Task { await drive(remote, resuming: true) }
    }

    /// Leaves a remote run whose connection dropped to run on, its result to be fetched later, and
    /// shows this Mac's scene again.
    func fetchRemoteResultLater() {
        guard let remote = remoteRun, case .lost = remote.phase else { return }
        remote.phase = .waiting
        restoreLiveView()
    }

    /// Holds the remote run there between its batches, or lets it go on; held, the scene here can
    /// be edited, and the run started again with the edits (`rerunRemoteWithEdits`).
    func toggleRemotePause() {
        guard let remote = remoteRun, remote.phase == .running, let client = remote.client else { return }
        remote.paused.toggle()
        client.pause(remote.id, remote.paused)
        if !remote.paused, let upload = remote.upload, let renderer {
            // Back to the run's view, should an edit here have shown this Mac's scene.
            fenceGPU()
            renderer.setScene(remote.scenario, view: upload.view)
            remote.isShown = true
            showRemoteLayers(remote, again: true)
            sceneVersion += 1
        }
    }

    /// Whether the scene or its settings have been edited here since the remote run was sent.
    var remoteRunEdited: Bool {
        guard let remote = remoteRun, let sent = remote.sentSettings else { return false }
        // The settings hold the scene as edited.
        return sent != settings
    }

    /// Stops the remote run there and sends the scene as it is now, edits and all, over the same
    /// connection: the project's files sent already are named rather than sent again, so a moved
    /// charge sends only the scene.
    func rerunRemoteWithEdits() {
        guard let remote = remoteRun, remote.phase == .running, remote.client != nil else { return }
        if isLoadingInputs || rebuildPending || isPreparingImports || importsNeedResampling {
            errorMessage = "The scene is still being prepared; rerun once it is."
            return
        }
        remote.handingOver = true
        remote.stopping = true
        remote.client?.writer.enqueue(.cancel(remote.id))
    }

    /// Lets go of a session the last remote run left open for the next.
    func closeRemoteSession() {
        remoteSession?.client.close()
        remoteSession = nil
    }

    /// How long a session left open waits for the next run before it is let go: its worker there
    /// holds no GPU memory between jobs, but is a process all the same.
    static let remoteSessionIdle = Duration.seconds(300)

    /// Leaves `client` open for the next run on `host`, for a while.
    private func keepRemoteSession(host: String, _ client: SweepWorkerClient) {
        closeRemoteSession()
        remoteSession = (host, client)
        Task { [weak self, weak client] in
            try? await Task.sleep(for: Self.remoteSessionIdle)
            guard let self, let client, self.remoteSession?.client === client else { return }
            self.closeRemoteSession()
        }
    }

    /// Stops the remote run there, and shows this Mac's scene again.
    func stopRemoteRun() {
        guard let remote = remoteRun else { return }
        remote.stopping = true
        if remote.isActive, let client = remote.client {
            client.writer.enqueue(.cancel(remote.id))
        } else {
            if remote.canResume {
                // Held there for this Mac: connect again to stop it, if it can be reached.
                let (host, id, connect) = (remote.host, remote.id, remoteConnect)
                Task {
                    guard let client = try? await connect(host, id) else { return }
                    client.writer.enqueue(.cancel(id))
                    client.close()
                }
            }
            remote.task?.cancel()
            remote.client?.close()
            remote.timeline?.discard()
            remote.phase = .stopped
        }
        if remote.phase != .running { restoreLiveView() }
    }

    /// Puts away a finished, failed or stopped remote run's notice.
    func dismissRemoteRun() {
        guard let remote = remoteRun, !remote.isActive, !remote.canResume else { return }
        remoteRun = nil
    }

    private func drive(_ remote: RemoteRun, resuming: Bool, over session: SweepWorkerClient? = nil) async {
        do {
            let client: SweepWorkerClient
            if let session, !session.isClosed {
                client = session
            } else {
                client = try await remoteConnect(remote.host, resuming ? remote.id : nil)
            }
            if remote.stopping {
                // Stopped while connecting: a new run goes no further; a held one is stopped there.
                if resuming { client.writer.enqueue(.cancel(remote.id)) }
                client.close()
                return
            }
            remote.client = client
            remote.link = client.name
            remote.device = client.hello?.device ?? ""
            remote.phase = .running
            remote.lastHeard = .now
            let watchdog = remoteSilenceLimit.map { limit in
                Task { [weak client, weak remote] in
                    while let remote, remote.isActive {
                        try? await Task.sleep(for: .seconds(1))
                        if remote.lastHeard.duration(to: .now) > limit { client?.drop() }
                    }
                }
            }
            defer { watchdog?.cancel() }
            let setup: (Data) -> Void = { [weak self] payload in
                if !resuming { remote.projectBytes = client.projectBytes }
                self?.remoteSetup(remote, payload)
            }
            let frame: (WatchFrame.Header, Data) -> Void = { [weak self] header, payload in
                self?.remoteFrame(remote, header, payload)
            }
            let progress: (Double) -> Void = { fraction in
                remote.fraction = fraction
                remote.lastHeard = .now
            }
            let result =
                resuming
                ? try await client.resumeWatch(remote.id, setup: setup, progress: progress, frame: frame)
                : try await client.watch(remote.job, setup: setup, progress: progress, frame: frame)
            if !resuming { remote.projectBytes = client.projectBytes }
            let run = try client.checkedRun(result.archive, name: remote.name, inputs: remote.inputs)
            remote.summary = remote.describe(result.stats)
            remote.client = nil
            // The sharing Mac need keep its result no longer.
            client.writer.enqueue(.release(remote.id))
            if remote.handingOver {
                // Finished before the stop reached it: kept, and the rerun goes on regardless.
                await finishRemoteRun(remote, run)
                startRemoteRun(on: remote.host, over: client)
                return
            }
            // Left open for the next run there, so that a rerun sends only what changed.
            keepRemoteSession(host: remote.host, client)
            await finishRemoteRun(remote, run)
        } catch {
            let connected = remote.client != nil
            let closed = remote.client?.isClosed ?? true
            if remote.handingOver, let client = remote.client, !client.isClosed {
                // Stopped to run again with the edits, over the same connection.
                remote.client = nil
                remote.timeline?.discard()
                remote.phase = .stopped
                startRemoteRun(on: remote.host, over: client)
                return
            }
            if let client = remote.client, !client.isClosed { client.close() }
            remote.client = nil
            guard remoteRun === remote else { return }
            if let failure = remote.failure {
                remote.timeline?.discard()
                remote.phase = .failed(failure)
                restoreLiveView()
            } else if remote.stopping || error is CancellationError {
                remote.timeline?.discard()
                remote.phase = .stopped
                restoreLiveView()
            } else if connected && closed {
                remote.phase = .lost(
                    "The connection to \(remote.macName) dropped (\(error.localizedDescription)). The run carries on there."
                )
            } else if resuming {
                remote.phase = .lost(
                    "\(remote.macName) could not be reached again: \(error.localizedDescription)")
            } else {
                remote.timeline?.discard()
                remote.phase = .failed(error.localizedDescription)
                restoreLiveView()
            }
        }
    }

    /// Gives up the remote run for `reason`: it is stopped there, and fails here once it has.
    private func failRemoteRun(_ remote: RemoteRun, _ reason: String) {
        guard remote.failure == nil else { return }
        remote.failure = reason
        remote.client?.writer.enqueue(.cancel(remote.id))
    }

    private func remoteSetup(_ remote: RemoteRun, _ payload: Data) {
        guard remoteRun === remote, let device, let renderer else { return }
        remote.lastHeard = .now
        do {
            let raw =
                try remote.job.view?.compression.algorithm.map {
                    try (payload as NSData).decompressed(using: $0) as Data
                } ?? payload
            let upload = try ViewUpload(device: device, setup: SceneViewCodec.decodeSetup(raw))
            fenceGPU()
            renderer.setScene(remote.scenario, view: upload.view)
            remote.upload = upload
            remote.isShown = true
            showRemoteLayers(remote, again: true)
            if remote.timeline == nil {
                remote.timeline = try StreamedTimeline(
                    setup: raw,
                    fingerprint: SavedSimulationRun.fingerprint(
                        remote.inputs.scenario, settings: remote.inputs.settings),
                    duration: remote.inputs.settings.duration)
            }
            sceneVersion += 1
        } catch {
            failRemoteRun(remote, "The other Mac's view could not be read: \(error.localizedDescription)")
        }
    }

    private func remoteFrame(_ remote: RemoteRun, _ header: WatchFrame.Header, _ payload: Data) {
        defer { remote.client?.writer.enqueue(.viewAck(remote.id, header.frame)) }
        remote.lastHeard = .now
        guard remoteRun === remote, let upload = remote.upload else { return }
        let start = ContinuousClock.now
        do {
            let decoded = try WatchFrame.decode(header, payload: payload)
            guard let bytes = decoded.scene else { return }
            let frame = try SceneViewCodec.decodeFrame(bytes)
            let sent = try decoded.overlay.map { try SceneOverlayCodec.decode($0, time: frame.time) }
            fenceGPU()
            try upload.apply(frame)
            if let sent {
                remote.overlay = remote.overlayResolver.resolve(sent, frame: header.frame)
                remote.overlayBytes += decoded.overlay?.count ?? 0
            }
            let overlay = remote.overlay
            remote.timeline?.add(
                TimelineFrame(
                    view: frame, fragments: overlay.fragments,
                    freestanding: overlay.freestanding.value ?? [], layers: overlay.layers))
            if remote.isShown { showRemoteLayers(remote) }
            remote.framesShown += 1
            remote.bytesReceived += payload.count
            remote.arrivals.append(start)
            remote.drawSeconds += start.duration(to: .now).seconds
            remote.time = header.time
            time = header.time
            sceneVersion += 1
            onRemoteFrame?(remote)
        } catch {
            failRemoteRun(
                remote, "A frame from \(remote.macName) could not be read: \(error.localizedDescription)")
        }
    }

    /// Waits for the GPU to finish what it drew from the view's buffers before they are written:
    /// the queue runs in order, so an empty buffer's completion says it has.
    private func fenceGPU() {
        if let fence = commandQueue?.makeCommandBuffer() {
            fence.commit()
            fence.waitUntilCompleted()
        }
    }

    /// The run come back: kept with its recording, its histories shown, and its last frame on
    /// screen to replay from.
    private func finishRemoteRun(_ remote: RemoteRun, _ run: SavedSimulationRun) async {
        let folder = await remote.timeline?.finish()
        remote.timeline = nil
        guard remoteRun === remote else { return }
        do {
            try addRun(run)
        } catch {
            remote.phase = .failed("The run came back but could not be kept: \(error.localizedDescription)")
            return
        }
        if let folder {
            if let old = recentTimeline, old != folder, !runFolders.values.contains(old) {
                try? FileManager.default.removeItem(at: old)
            }
            recentTimeline = folder
            runFolders[run.id] = folder
        }
        showHistories(of: run)
        // The ground points as the run left them, as a run here leaves them for its replay.
        if let ground = run.groundShock {
            var result = ground.result
            result.place(on: run.scenario.terrain)
            groundShockLive = result
        }
        remote.phase = .finished
        time = run.elapsedTime
        stepCount = run.stepCount
        if folder != nil { replay(run) } else { restoreLiveView() }
    }

    /// The gauges' traces and the structure's deflection as `run` kept them.
    private func showHistories(of run: SavedSimulationRun) {
        traces = run.scenario.gauges.prefix(run.gauges.count).enumerated().map { index, gauge in
            let points = run.gauges[index].points
            let bucket = max(1, (points.count + 299) / 300)
            var trace = GaugeTrace(id: index, name: gauge.name)
            trace.points = Swift.stride(from: 0, to: points.count, by: bucket).map { start in
                let best = points[start..<min(start + bucket, points.count)].max {
                    abs($0.value) < abs($1.value)
                }!
                return GaugePoint(id: start / bucket, time: best.time * 1000, overpressure: best.value)
            }
            trace.peak = points.map(\.value).max() ?? 0
            return trace
        }
        structureRecord = (run.structure?.points ?? []).enumerated().map {
            StructureSample(id: $0.offset, time: $0.element.time * 1000, deflection: $0.element.value)
        }
        structureHistory = structureRecord
    }
}

extension SweepWorkerClient {
    /// The run `name` in a watched job's returned project, checked against its inputs, as a sweep
    /// case's is.
    func checkedRun(_ archive: SweepWorkerArchive, name runName: String, inputs: SimulationInputs) throws
        -> SavedSimulationRun
    {
        let returned = try ProjectDocument(archive: archive.archive())
        guard var run = returned.savedRuns.first(where: { $0.name == runName }) else {
            throw ProjectFileError.invalid("The worker on \(name) returned no result for \(runName).")
        }
        guard
            run.inputSHA256
                == (try SavedSimulationRun.fingerprint(inputs.scenario, settings: inputs.settings))
        else {
            throw ProjectFileError.invalid("The worker on \(name) ran different inputs for \(runName).")
        }
        if run.appVersion == "development",
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        {
            run.appVersion = version
        }
        try run.validate()
        return run
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
