#if !os(macOS)
    import BlastCore
    import BlastRender
    import DocumentKit
    import MetalKit
    import Network
    import SwiftUI
    import os
    import UIKit
    import simd

    /// BombCAD on an iPad: the viewer of runs kept on a Mac nearby (emmettl/bombcad-work#43). It
    /// pairs with a Mac sharing its GPU, as another Mac would, lists the kept runs with recordings
    /// in the projects that Mac shares, fetches one whole into a copy laid out as the run's own
    /// folder, and replays it with the app's renderer as the Mac's Replay does, scrubbed with a
    /// slider; it can be scrubbed as soon as its first frame is in, the frames it has not got yet
    /// asked for ahead of the rest.
    struct ViewerApp: App {
        @State private var model = ViewerModel()

        var body: some Scene {
            WindowGroup { ViewerRootView(model: model) }
        }
    }

    /// The Macs nearby and paired, and the runs the one connected shares.
    @MainActor @Observable
    final class ViewerModel {
        private(set) var nearby: [NearbyBrowser.Found] = []
        private(set) var paired: [NearbyPairing.Pairing] = []
        private(set) var connected: String?
        private(set) var timelines: [SharedTimeline] = []
        private(set) var busy: String?
        var problem: String?
        /// A pairing waiting for this iPad's user to say whether the Mac shows the same code.
        var pairingCode: PairingCode?
        var viewer: TimelineViewer?
        @ObservationIgnored private var browser: NearbyBrowser?
        @ObservationIgnored private var client: SweepWorkerClient?

        struct PairingCode: Identifiable {
            var peer: String
            var code: String
            var answer: CheckedContinuation<Bool, Never>
            var id: String { code }
        }

        /// `BOMBCAD_VIEWER_AUTO=1`: connects to the first paired Mac, opens its first shared run
        /// (or the first whose project is named `BOMBCAD_VIEWER_PROJECT`), and once it is all in,
        /// scrubs through every frame and writes what it measured to `Documents/viewer-report.txt`;
        /// for measuring, in the Simulator (`SIMCTL_CHILD_`) or on an iPad (`devicectl device
        /// process launch -e`).
        let auto = ProcessInfo.processInfo.environment["BOMBCAD_VIEWER_AUTO"] == "1"
        let autoProject = ProcessInfo.processInfo.environment["BOMBCAD_VIEWER_PROJECT"]

        /// Where the iPad keeps its pairings: the Keychain, as the Mac does, when the app is signed
        /// by a team (`Scripts/build-ipad-viewer.sh --device`, which embeds the provisioning
        /// profile that grants its keychain group); else a file in the app's own container,
        /// readable by it alone, since the Simulator's ad hoc build kept a Keychain item only
        /// until it quit.
        static func pairingStore() -> PairingStore? {
            guard ProcessInfo.processInfo.environment["BOMBCAD_NEARBY_STORE"] == nil else { return nil }
            if signedByTeam { return KeychainPairingStore() }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return try? FilePairingStore(url: support.appending(path: "BombCAD/pairings.json"))
        }

        /// Whether the app carries a team's provisioning profile, and with it the entitlements the
        /// Keychain needs; an ad hoc build has none.
        static var signedByTeam: Bool {
            Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        }

        func start() {
            guard browser == nil else { return }
            if let store = Self.pairingStore() { NearbyWorkers.store = store }
            if let given = ProcessInfo.processInfo.environment["BOMBCAD_VIEWER_ADDRESS"] { address = given }
            let browser = NearbyBrowser()
            browser.changed = { [weak self] found in self?.nearby = found }
            browser.start()
            self.browser = browser
            refreshPaired()
            if auto, let first = paired.first {
                Task {
                    await connect(first)
                    let chosen = timelines.first { autoProject == nil || $0.projectName == autoProject }
                    if let chosen { open(chosen) }
                }
            }
        }

        func refreshPaired() { paired = NearbyWorkers.store.pairings() }

        /// A Mac named by its address and the ports `BombCAD serve` prints, "host pairing-port
        /// session-port", for when Bonjour cannot see it: in the Simulator, whose browsing found
        /// the Mac but handed the app no results (23 October 2026), as a test process's never do.
        var address = UserDefaults.standard.string(forKey: "viewer.address") ?? "" {
            didSet { UserDefaults.standard.set(address, forKey: "viewer.address") }
        }

        private var manual: (host: String, pairing: UInt16, session: UInt16)? {
            let parts = address.split(separator: " ").map(String.init)
            guard parts.count == 3, let pairing = UInt16(parts[1]), let session = UInt16(parts[2]) else {
                return nil
            }
            return (parts[0], pairing, session)
        }

        /// Finds a Mac at the address given, if one is, else by Bonjour.
        private var resolve: NearbyWorkers.Resolve {
            let manual = self.manual
            return { id, service, within in
                guard let manual,
                    let port = NWEndpoint.Port(
                        rawValue: service == NearbyWorkers.pairingService ? manual.pairing : manual.session)
                else { return try await NearbyBrowser.find(id, service, within) }
                let advert = NearbyWorkers.Advert(
                    id: id, version: "?", protocolVersion: SweepWorkerHello.protocolVersion,
                    solverVersion: SavedSimulationRun.solverVersion, device: "?")
                return NearbyBrowser.Found(
                    name: manual.host, advert: advert,
                    endpoint: .hostPort(host: .init(manual.host), port: port),
                    interfaces: [])
            }
        }

        func pairByAddress() async {
            guard manual != nil else {
                problem =
                    "Give the Mac's address and the two ports BombCAD serve prints, as: host 49817 49818."
                return
            }
            await pair(id: UUID(), name: address)
        }

        func pair(_ found: NearbyBrowser.Found) async { await pair(id: found.advert.id, name: found.name) }

        private func pair(id: UUID, name: String) async {
            busy = "Pairing with \(name)…"
            defer { busy = nil }
            do {
                _ = try await NearbyWorkers.pair(with: id, resolve: resolve) { peer, code in
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            self.pairingCode = PairingCode(peer: peer.name, code: code, answer: continuation)
                        }
                    }
                }
                refreshPaired()
            } catch {
                problem = error.localizedDescription
            }
        }

        func answerPairing(_ same: Bool) {
            pairingCode?.answer.resume(returning: same)
            pairingCode = nil
        }

        func forget(_ pairing: NearbyPairing.Pairing) {
            try? NearbyWorkers.store.forget(pairing.peer.id)
            refreshPaired()
        }

        func connect(_ pairing: NearbyPairing.Pairing) async {
            disconnect()
            busy = "Connecting to \(pairing.peer.name)…"
            defer { busy = nil }
            do {
                let client = try await NearbyWorkers.connect(
                    host: NearbyWorkers.host(pairing.peer.name), resolve: resolve)
                self.client = client
                connected = client.name
                timelines = try await client.timelines()
            } catch {
                problem = error.localizedDescription
                disconnect()
            }
        }

        func refreshTimelines() async {
            guard let client else { return }
            do { timelines = try await client.timelines() } catch { problem = error.localizedDescription }
        }

        func disconnect() {
            viewer?.stop()
            viewer = nil
            client?.close()
            client = nil
            connected = nil
            timelines = []
        }

        func open(_ shared: SharedTimeline) {
            guard let client else { return }
            viewer?.stop()
            do {
                let viewer = try TimelineViewer(shared, client: client)
                viewer.auto = auto
                self.viewer = viewer
                viewer.start()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// A shared recording being fetched and replayed: frames shown as they arrive, scrubbed among
    /// those in, the vent panels, envelope colours, thermal paint and cloud drawn as recorded.
    @MainActor @Observable
    final class TimelineViewer {
        let shared: SharedTimeline
        let download: TimelineDownload
        private(set) var index = 0
        private(set) var arrivedCount = 0
        private(set) var player: RunTimelinePlayer?
        private(set) var problem: String?
        private(set) var sent: TimelineSentStats?
        var settings = RenderSettings()
        var camera = OrbitCamera(target: .zero, distance: 100, azimuth: 0.8, elevation: 0.5)
        var showsEnvelopeDamage = true
        var showsThermal = true
        var isPlaying = false
        /// Bumped whenever the frame or its layers change, for the view to draw again.
        private(set) var version = 0
        /// The seconds each frame shown took to read, decode and upload.
        private(set) var showSeconds: [Double] = []
        @ObservationIgnored var auto = false
        @ObservationIgnored let device: MTLDevice
        @ObservationIgnored let commandQueue: MTLCommandQueue
        @ObservationIgnored let renderer: SceneRenderer
        @ObservationIgnored private let client: SweepWorkerClient
        @ObservationIgnored private let fetch: TimelineFetch
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var playing: Task<Void, Never>?
        /// The frame scrubbed to, shown once it arrives if it has not yet, and since when.
        @ObservationIgnored private var wanted: Int?
        @ObservationIgnored private var wantedSince = ContinuousClock.now
        /// The seconds from scrubbing to a frame not yet in to its being shown.
        private(set) var waitSeconds: [Double] = []
        /// The GPU's seconds drawing each view of the frame, the last few thousand.
        @ObservationIgnored private(set) var drawSeconds: [Double] = []
        /// The most memory the app has had in use, by the system's count (its footprint).
        @ObservationIgnored private(set) var peakFootprint: UInt64 = 0
        /// The drawable's size, in pixels.
        @ObservationIgnored var drawnSize = CGSize.zero
        @ObservationIgnored private var thermalGrids: [ThermalSurfaceGrid] = []
        @ObservationIgnored private var thermalReceivers = 0
        @ObservationIgnored private(set) var paint: SurfacePaint?

        init(_ shared: SharedTimeline, client: SweepWorkerClient) throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw ProjectFileError.invalid("This iPad has no Metal device.")
            }
            self.shared = shared
            self.client = client
            self.device = device
            commandQueue = queue
            renderer = try SceneRenderer(device: device)
            download = try TimelineDownload(shared)
            fetch = TimelineFetch(id: UUID(), project: shared.project, run: shared.run)
        }

        var count: Int { download.frameCount }
        var scenario: Scenario? { download.run?.scenario }
        var time: Double { player.map { $0.entries[min(index, $0.entries.count - 1)].time } ?? 0 }
        var frame: TimelineFrame? { player?.frame }
        var layers: TimelineLayers { player?.frame?.layers ?? TimelineLayers() }

        func start() {
            task = Task { [weak self, client, fetch] in
                do {
                    let stats = try await client.fetchTimeline(fetch) { part, payload in
                        self?.arrived(part, payload)
                    }
                    self?.finished(stats)
                } catch {
                    self?.problem = error.localizedDescription
                }
            }
        }

        func stop() {
            task?.cancel()
            pause()
        }

        private func arrived(_ part: TimelinePart, _ payload: Data) {
            do {
                try download.receive(part, payload)
            } catch {
                problem = error.localizedDescription
                return
            }
            arrivedCount = download.arrived.count
            guard part.kind == .frame else { return }
            if player == nil, download.isPlayable {
                openPlayer(showing: part.index)
            } else if let wanted, part.index == wanted {
                self.wanted = nil
                show(wanted)
                waitSeconds.append(wantedSince.duration(to: .now).timelineSeconds)
            }
        }

        private func openPlayer(showing first: Int) {
            guard let run = download.run else { return }
            do {
                let player = try RunTimelinePlayer(folder: download.folder, device: device)
                self.player = player
                renderer.setScene(run.scenario, view: player.upload.view)
                camera = .framing(run.scenario)
                if let thermal = run.thermal {
                    thermalGrids = ThermalExposure.surfaceGrids(
                        scene: FragmentScene(run.scenario), spec: thermal.spec)
                    thermalReceivers = thermalGrids.reduce(0) { $0 + $1.receivers.count }
                }
                show(first)
                if auto { Task { await scrubWhileFetching() } }
            } catch {
                problem = error.localizedDescription
            }
        }

        /// For measuring: while the frames come, scrubs every 0.2 s to a frame not yet in.
        private func scrubWhileFetching() async {
            while !download.isComplete {
                let missing = (0..<count).filter { !download.arrived.contains($0) }
                if wanted == nil, let n = missing.randomElement() { scrub(to: n) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        private func finished(_ stats: TimelineSentStats) {
            download.finish()
            sent = stats
            version += 1
            if auto { Task { await measureScrubbing() } }
        }

        /// The slider dragged: playing stops.
        func scrubbed(to n: Int) {
            pause()
            scrub(to: n)
        }

        /// Shows frame `n` if it is in; if not, asks for it next and shows the nearest in now.
        func scrub(to n: Int) {
            let n = min(max(n, 0), max(count - 1, 0))
            if !download.arrived.contains(n) {
                if wanted != n { wantedSince = .now }
                wanted = n
                client.preferTimelineFrame(fetch.id, n)
            }
            if let near = download.nearestArrived(to: n) { show(near) }
        }

        /// Uploads frame `n` once the GPU has finished the frames drawn from the last, and its layers.
        func show(_ n: Int) {
            guard let player, download.arrived.contains(n) else { return }
            let start = ContinuousClock.now
            if let fence = commandQueue.makeCommandBuffer() {
                fence.commit()
                fence.waitUntilCompleted()
            }
            do {
                try player.show(n)
            } catch {
                problem = error.localizedDescription
                return
            }
            index = player.index
            showSeconds.append(start.duration(to: .now).timelineSeconds)
            showLayers()
        }

        func showLayers() {
            guard let scenario else { return }
            let layers = self.layers
            let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
            if let opened = layers.vents.value?.panels, opened.count == panels.count {
                renderer.setVentPanels(zip(panels, opened).compactMap { $1 ? nil : $0.box })
            } else {
                renderer.setVentPanels(panels.map(\.box))
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
            if showsThermal, let thermal = layers.thermal.value, thermal.fluence.count == thermalReceivers {
                paint = SurfacePaint(
                    grids: thermalGrids, shades: thermal.fluence.map(ThermalQuantity.fluence.shade))
                settings.thermal = .fluence
            } else {
                paint = nil
                settings.thermal = nil
            }
            renderer.setSurfacePaint(paint)
            version += 1
        }

        /// The envelope building tapped in the view, shown with its damage as of the frame shown,
        /// its surface exposure and the run's standing, as the Mac's inspector shows them.
        var picked: UUID?

        /// A tap at a point in normalised device coordinates (x right, y up, -1 to 1): the envelope
        /// building it meets first, or none.
        func pick(ndc: SIMD2<Float>, aspectRatio: Float) {
            guard let scenario else { return }
            let ray = camera.ray(ndc: ndc, aspectRatio: aspectRatio)
            picked = ScenePicking.envelope(in: scenario, origin: ray.origin, direction: ray.direction)
        }

        /// The picked building's bounds, outlined in the view as the Mac outlines the one inspected.
        var pickedBounds: Box? {
            guard let picked, let blocks = scenario?.object(id: picked)?.envelope?.blocks,
                let first = blocks.first
            else { return nil }
            return blocks.dropFirst().reduce(first) {
                Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
            }
        }

        /// The picked building's name, its damage code as of the frame shown (1–6, 0 if not yet
        /// judged then), and its surface exposure over the run.
        var pickedBuilding: (name: String, code: Int, exposure: EnvelopeExposureSummary?)? {
            guard let picked, let objects = scenario?.envelopeObjects,
                let index = objects.firstIndex(where: { $0.id == picked })
            else { return nil }
            let codes = layers.envelopeCodes.value
            let code = codes.map { $0.count == objects.count ? Int($0[index]) : 0 } ?? 0
            return (
                objects[index].name, code, download.run?.envelopeExposure?.first { $0.id == picked }
            )
        }

        /// The cloud's outlines from the eye, from the frame it was handed over in.
        var cloudLines: [SIMD4<Float>] {
            guard settings.showCloud, layers.cloud.value != nil, let cloud = download.run?.cloud else {
                return []
            }
            return CloudOverlay.lines(cloud, eye: camera.eye)
        }

        var zoomLimits: ClosedRange<Float> {
            let size = scenario?.domainSize ?? SIMD3(200, 200, 200)
            return OrbitCamera.defaultZoomLimits.lowerBound...max(3 * max(size.x, size.y, size.z), 600)
        }

        func play() {
            guard !isPlaying, count > 0 else { return }
            if index >= count - 1 { scrub(to: 0) }
            isPlaying = true
            playing = Task { [weak self] in
                while let self, self.isPlaying, self.index < self.count - 1 {
                    try? await Task.sleep(for: .seconds(1 / TimelinePlayback.framesPerSecond))
                    guard self.isPlaying else { return }
                    // The next frame in, skipping those still to come.
                    guard let next = self.download.arrived.filter({ $0 > self.index }).min() else { break }
                    self.show(next)
                }
                self?.isPlaying = false
            }
        }

        func pause() {
            isPlaying = false
            playing?.cancel()
            playing = nil
        }

        /// What fetching and scrubbing came to, as text.
        var report: String {
            let total = download.started.duration(to: download.finished ?? .now).timelineSeconds
            let first = download.firstFrame.map { download.started.duration(to: $0).timelineSeconds }
            let shows = showSeconds.sorted()
            func ms(_ q: Double) -> Double {
                shows.isEmpty ? 0 : 1000 * shows[min(Int(q * Double(shows.count)), shows.count - 1)]
            }
            return String(
                format:
                    "%@ / %@: %d frames, %.1f MB in %.2f s (%.1f MB/s); first frame shown after %.2f s; a frame shown in %.1f ms median, %.1f ms at the 95th percentile, %.1f ms at most (%d shown)%@",
                shared.projectName, shared.name, count, Double(download.bytes) / 1e6, total,
                Double(download.bytes) / 1e6 / max(total, 1e-9), first ?? -1, ms(0.5), ms(0.95), ms(1),
                shows.count,
                sent.map {
                    String(
                        format: "; the Mac sent it in %.2f s, %d frames ahead of their turn", $0.seconds,
                        $0.preferred)
                } ?? "")
                + waitReport + drawReport
        }

        func drew(seconds: Double) {
            if drawSeconds.count >= 4096 { drawSeconds.removeFirst(1024) }
            drawSeconds.append(seconds)
            if drawSeconds.count % 30 == 0 { peakFootprint = max(peakFootprint, Self.footprint()) }
        }

        /// The memory the app has in use as the system counts it against its limit.
        static func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? info.phys_footprint : 0
        }

        /// The GPU's time per view drawn, and the memory in use.
        private var drawReport: String {
            let draws = drawSeconds.sorted()
            let now = Self.footprint()
            var text = String(
                format: "; memory in use %.0f MB, at most %.0f MB", Double(now) / 1e6,
                Double(max(peakFootprint, now)) / 1e6)
            // Zero where no limit applies, as in the Simulator.
            let available = os_proc_available_memory()
            if available > 0 {
                text += String(format: ", of the %.0f MB the app may use", Double(available + Int(now)) / 1e6)
            }
            if !draws.isEmpty {
                text += String(
                    format:
                        "; the GPU drew a view in %.1f ms median, %.1f ms at the 95th percentile (%d views, %.0f by %.0f pixels)",
                    1000 * draws[draws.count / 2], 1000 * draws[min(draws.count * 95 / 100, draws.count - 1)],
                    draws.count, drawnSize.width, drawnSize.height)
            }
            return text
        }

        /// How long frames scrubbed to before they were in took to come.
        private var waitReport: String {
            let waits = waitSeconds.sorted()
            guard !waits.isEmpty else { return "" }
            return String(
                format:
                    "; %d frames scrubbed to before they were in came after %.0f ms median, %.0f ms at most",
                waits.count, 1000 * waits[waits.count / 2], 1000 * (waits.last ?? 0))
        }

        /// Scrubs through every frame in a shuffled order, then writes the report.
        private func measureScrubbing() async {
            let order = Array(0..<count).shuffled()
            showSeconds = []
            for n in order {
                show(n)
                try? await Task.sleep(for: .milliseconds(5))
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? (report + "\n").write(
                to: documents.appending(path: "viewer-report.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Views

    struct ViewerRootView: View {
        @Bindable var model: ViewerModel
        @State private var columns = NavigationSplitViewVisibility.all

        var body: some View {
            NavigationSplitView(columnVisibility: $columns) {
                List {
                    Section("Macs paired") {
                        if model.paired.isEmpty {
                            Text("None yet: pair with a Mac below.").foregroundStyle(.secondary)
                        }
                        ForEach(model.paired, id: \.peer.id) { pairing in
                            Button {
                                Task { await model.connect(pairing) }
                            } label: {
                                Label(pairing.peer.name, systemImage: "desktopcomputer")
                            }
                            .swipeActions { Button("Forget", role: .destructive) { model.forget(pairing) } }
                        }
                    }
                    Section("Sharing nearby") {
                        if model.nearby.isEmpty {
                            Text("Looking for Macs sharing their GPU…").foregroundStyle(.secondary)
                        }
                        ForEach(model.nearby, id: \.advert.id) { found in
                            Button {
                                Task { await model.pair(found) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("Pair with \(found.name)")
                                    Text("BombCAD \(found.advert.version), \(found.advert.device)").font(
                                        .caption
                                    )
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!found.advert.compatible)
                        }
                    }
                    Section("By address") {
                        TextField("host pairing-port session-port", text: $model.address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Pair by Address") { Task { await model.pairByAddress() } }
                    }
                    if let connected = model.connected {
                        Section("Kept runs on \(connected)") {
                            if model.timelines.isEmpty {
                                Text("No kept runs with recordings in the projects it shares.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.timelines) { shared in
                                Button {
                                    model.open(shared)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text("\(shared.projectName): \(shared.name)")
                                        Text(
                                            String(
                                                format: "%d frames to %.0f ms, %.0f MB", shared.frames,
                                                1000 * shared.endTime, Double(shared.bytes) / 1e6)
                                        )
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("BombCAD")
                .refreshable { await model.refreshTimelines() }
                .overlay {
                    if let busy = model.busy { ProgressView(busy).padding().background(.regularMaterial) }
                }
            } detail: {
                if let viewer = model.viewer {
                    TimelineViewerView(viewer: viewer)
                } else {
                    ContentUnavailableView(
                        "No run open", systemImage: "cube.transparent",
                        description: Text(
                            "Pair with a Mac sharing its GPU, then choose one of its kept runs."))
                }
            }
            .task { model.start() }
            .alert(
                "Pair with \(model.pairingCode?.peer ?? "")?",
                isPresented: .constant(model.pairingCode != nil),
                presenting: model.pairingCode
            ) { _ in
                Button("It Matches") { model.answerPairing(true) }
                Button("Cancel", role: .cancel) { model.answerPairing(false) }
            } message: { code in
                Text("Check that the Mac shows the code \(code.code), and allow it there.")
            }
            .alert(
                "BombCAD", isPresented: .constant(model.problem != nil),
                actions: { Button("OK") { model.problem = nil } }, message: { Text(model.problem ?? "") })
        }
    }

    struct TimelineViewerView: View {
        @Bindable var viewer: TimelineViewer

        var body: some View {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ViewerMetalView(viewer: viewer).ignoresSafeArea(edges: .horizontal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewer.shared.projectName): \(viewer.shared.name)").font(.headline)
                        Text(
                            viewer.download.isComplete
                                ? String(
                                    format: "All %d frames in, %.0f MB", viewer.count,
                                    Double(viewer.download.bytes) / 1e6)
                                : "\(viewer.arrivedCount) of \(viewer.count) frames in…"
                        )
                        .font(.caption)
                        if let problem = viewer.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                    if let building = viewer.pickedBuilding {
                        PickedBuildingCard(viewer: viewer, building: building)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                VStack(spacing: 8) {
                    HStack {
                        Button {
                            viewer.isPlaying ? viewer.pause() : viewer.play()
                        } label: {
                            Image(systemName: viewer.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Slider(
                            value: Binding(
                                get: { Double(viewer.index) },
                                set: { viewer.scrubbed(to: Int($0.rounded())) }),
                            in: 0...Double(max(viewer.count - 1, 1)), step: 1)
                        Text(String(format: "%.1f ms", 1000 * viewer.time)).monospacedDigit().frame(
                            width: 100)
                    }
                    Picker("Show", selection: $viewer.settings.mode) {
                        ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 24) {
                        Toggle("Damage", isOn: $viewer.showsEnvelopeDamage).fixedSize()
                        Toggle("Heat", isOn: $viewer.showsThermal).fixedSize()
                        Toggle("Cloud", isOn: $viewer.settings.showCloud).fixedSize()
                    }
                    .onChange(of: viewer.showsEnvelopeDamage) { viewer.showLayers() }
                    .onChange(of: viewer.showsThermal) { viewer.showLayers() }
                }
                .padding()
            }
            .navigationTitle(viewer.shared.name)
        }
    }

    /// The envelope building tapped: its damage as of the frame shown, in the colours the view
    /// paints it, what its surfaces took over the run, and the run's standing for both, its
    /// evidence a tap away as on the Mac.
    struct PickedBuildingCard: View {
        let viewer: TimelineViewer
        let building: (name: String, code: Int, exposure: EnvelopeExposureSummary?)

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(building.name).font(.headline)
                    Spacer()
                    Button {
                        viewer.picked = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear the selected building")
                }
                HStack {
                    Circle().fill(EnvelopeDamageSection.colour(building.code))
                        .overlay(Circle().stroke(.secondary.opacity(0.5)))
                        .frame(width: 10, height: 10)
                    Text(
                        (1...6).contains(building.code)
                            ? "\(EnvelopeDamageColour.labels[building.code - 1]) at \(String(format: "%.1f ms", 1000 * viewer.time))"
                            : String(format: "Not judged by %.1f ms", 1000 * viewer.time))
                    Spacer()
                    StandingBadge(
                        standing: viewer.download.run?.standing, kinds: [.envelopeDamage], unrecorded: true)
                }
                .font(.caption)
                if let exposure = building.exposure {
                    HStack {
                        Text(
                            String(
                                format: "Surfaces: peak %.1f kPa, mean impulse %@ over %.0f m²",
                                exposure.peakPositivePa / 1000,
                                exposure.meanPositiveImpulsePaS.map { String(format: "%.0f kPa·ms", $0) }
                                    ?? "none",
                                exposure.validAreaM2))
                        Spacer()
                        StandingBadge(
                            standing: viewer.download.run?.standing, kinds: [.envelopeExposure],
                            unrecorded: true)
                    }
                    .font(.caption)
                }
                Text(
                    "The run keeps each building's damage colour, not its glass chances: the Mac's inspector has those."
                )
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .monospacedDigit()
            .padding(10)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
    }

    /// The viewport: an `MTKView` drawing the viewer's frame with the app's renderer; one finger
    /// orbits, two pan, a pinch zooms.
    struct ViewerMetalView: UIViewRepresentable {
        let viewer: TimelineViewer

        func makeCoordinator() -> Coordinator { Coordinator(viewer: viewer) }

        func makeUIView(context: Context) -> MTKView {
            let view = MTKView(frame: .zero, device: viewer.device)
            view.colorPixelFormat = SceneRenderer.pixelFormat
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 30
            view.delegate = context.coordinator
            let orbit = UIPanGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.orbit))
            orbit.maximumNumberOfTouches = 1
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan))
            pan.minimumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.pinch))
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
            for recogniser in [orbit, pan, pinch, tap] { view.addGestureRecognizer(recogniser) }
            return view
        }

        func updateUIView(_ view: MTKView, context: Context) { context.coordinator.viewer = viewer }

        @MainActor
        final class Coordinator: NSObject, MTKViewDelegate {
            var viewer: TimelineViewer
            private var drawnPaint: SurfacePaint?

            init(viewer: TimelineViewer) { self.viewer = viewer }

            @objc func orbit(_ gesture: UIPanGestureRecognizer) {
                let delta = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)
                viewer.camera.orbit(
                    deltaAzimuth: -Float(delta.x) * 0.008, deltaElevation: Float(delta.y) * 0.008)
            }

            @objc func pan(_ gesture: UIPanGestureRecognizer) {
                let delta = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)
                viewer.camera.pan(right: Float(delta.x) * 0.002, forward: Float(delta.y) * 0.002)
            }

            @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
                viewer.camera.zoom(by: 1 / Float(max(gesture.scale, 0.01)), within: viewer.zoomLimits)
                gesture.scale = 1
            }

            /// A tap picks the envelope building under it.
            @objc func tap(_ gesture: UITapGestureRecognizer) {
                guard let view = gesture.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
                let point = gesture.location(in: view)
                let ndc = SIMD2(
                    Float(2 * point.x / view.bounds.width - 1), Float(1 - 2 * point.y / view.bounds.height))
                viewer.pick(ndc: ndc, aspectRatio: Float(view.bounds.width / view.bounds.height))
            }

            nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

            nonisolated func draw(in view: MTKView) {
                MainActor.assumeIsolated { drawFrame(view) }
            }

            private func drawFrame(_ view: MTKView) {
                guard viewer.player != nil, let drawable = view.currentDrawable,
                    let descriptor = view.currentRenderPassDescriptor,
                    let commandBuffer = viewer.commandQueue.makeCommandBuffer()
                else { return }
                let renderer = viewer.renderer
                var settings = viewer.settings
                settings.showCharge = viewer.time == 0
                settings.highlight = viewer.pickedBounds
                renderer.settings = settings
                renderer.setFreestanding(viewer.frame?.freestanding ?? [])
                renderer.setLines(viewer.cloudLines)
                if viewer.paint != drawnPaint {
                    drawnPaint = viewer.paint
                    renderer.setSurfacePaint(drawnPaint)
                }
                renderer.pixelsPerPoint = Float(view.contentScaleFactor)
                renderer.encode(into: commandBuffer, descriptor: descriptor, camera: viewer.camera)
                viewer.drawnSize = view.drawableSize
                let viewer = self.viewer
                commandBuffer.addCompletedHandler { buffer in
                    let seconds = buffer.gpuEndTime - buffer.gpuStartTime
                    guard seconds > 0 else { return }
                    Task { @MainActor in viewer.drew(seconds: seconds) }
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
    }
#endif
