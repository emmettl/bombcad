#if os(macOS)
    import AppKit
    import BlastModel
    import BlastRender
    import MetalKit
    import Observation
    import SwiftUI
    import UniformTypeIdentifiers

    /// File ▸ New Quarry Face (Experimental)…: a hillside's face broken and thrown by a stylised
    /// ripple of firings, to play with. Illustrative: for the look of it. It is not a blast-design
    /// aid; it takes nothing from the blast solver and gives no loads, reach or safety outputs.
    @MainActor
    @Observable
    final class QuarryFaceModel {
        /// The ground and the strip (in the ground's metres).
        private(set) var site: QuarrySite
        private(set) var terrainName = "Built-in hillside"
        /// The strip as dragged on the map, before it is broken.
        var draftStart: SIMD2<Float>?
        var draftEnd: SIMD2<Float>?
        var blocks = 100_000
        /// The stylised firing pattern, kept across strips.
        var order = QuarryFiringOrder.leftToRight
        var staggerMilliseconds = 100.0
        var firingCount = 16.0
        /// The event on view.
        private(set) var session: QuarrySession?
        /// A new strip's scene, built and firing, until its first frames can be shown.
        private(set) var incoming: QuarrySession?
        private(set) var preparing: String?
        private(set) var preparingShare: Float = 0
        /// Seconds from the strip's release to its event first shown, for the record.
        private(set) var lastStripSeconds: Double?
        private var prepareCount = 0
        private(set) var problem: String?
        private(set) var map: CGImage?
        /// The map's extent in the ground's metres: low corner and size.
        private(set) var mapOrigin = SIMD2<Float>.zero
        private(set) var mapSize = SIMD2<Float>(1, 1)
        /// Bumped whenever the session changes or fires, for the view.
        private(set) var version = 0
        let device: MTLDevice?
        private var keyRoot: URL

        init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), blocks: Int = 100_000) {
            self.device = device
            self.blocks = blocks
            site = .builtIn()
            keyRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BombCAD/QuarryFace", isDirectory: true)
            // Dust kept by an earlier launch of the window is stale.
            try? FileManager.default.removeItem(at: keyRoot)
            // The built-in ground is large; show the part round its strip.
            makeMap(around: (site.start + site.end) / 2, radius: 260)
        }

        /// The built-in hillside, or a terrain file read the way New District reads one.
        func useBuiltIn() {
            site = .builtIn()
            terrainName = "Built-in hillside"
            makeMap(around: (site.start + site.end) / 2, radius: 260)
            draftStart = nil
            draftEnd = nil
            prepare()
        }

        func openTerrain(_ url: URL) {
            do {
                let grid = try ElevationGrid(contentsOf: url)
                // A crop at 2 m round the grid's middle, up to 1.2 km across.
                let spacingMetres = grid.spacingInMetres(near: grid.southWest)
                let extent = SIMD2<Float>(
                    Float(Double(grid.columns - 1) * spacingMetres.x),
                    Float(Double(grid.rows - 1) * spacingMetres.y))
                let size = simd_min(extent, SIMD2(repeating: 1200))
                let corner = (extent - size) / 2
                let origin = SIMD2(
                    Double(corner.x / Float(spacingMetres.x)), Double(corner.y / Float(spacingMetres.y)))
                let crop = try grid.terrain(
                    origin: origin * grid.step + grid.southWest - grid.southWest, size: size, spacing: 2,
                    name: url.lastPathComponent)
                site = QuarrySite(
                    terrain: crop.terrain, start: size * SIMD2(0.35, 0.5), end: size * SIMD2(0.65, 0.5))
                terrainName = url.lastPathComponent
                makeMap(around: size / 2, radius: max(size.x, size.y) / 2)
                prepareCount += 1
                incoming = nil
                preparing = nil
                session = nil
                problem = "Drag along a face on the map to choose the strip."
                version += 1
            } catch {
                problem = "Couldn't read that terrain: \(error.localizedDescription)"
            }
        }

        /// A shaded relief of the ground round `centre`, for dragging the strip on.
        private func makeMap(around centre: SIMD2<Float>, radius: Float) {
            let terrain = site.terrain
            let size = 360
            let low = centre - radius
            let step = 2 * radius / Float(size)
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            var lowest = Float.infinity
            var highest = -Float.infinity
            for j in 0..<size {
                for i in 0..<size {
                    let h = terrain.height(at: low + SIMD2(Float(i), Float(j)) * step)
                    lowest = min(lowest, h)
                    highest = max(highest, h)
                }
            }
            for j in 0..<size {
                for i in 0..<size {
                    let p = low + SIMD2(Float(i), Float(j)) * step
                    let h = terrain.height(at: p)
                    let n = terrain.normal(at: p)
                    let light = max(0, simd_dot(n, simd_normalize(SIMD3(-0.6, 0.5, 0.65))))
                    let tone = 0.35 + 0.45 * light + 0.2 * (h - lowest) / max(highest - lowest, 1)
                    // Rows from the top, so north is up.
                    let k = 4 * (i + size * (size - 1 - j))
                    pixels[k] = UInt8(max(0, min(255, tone * 200)))
                    pixels[k + 1] = UInt8(max(0, min(255, tone * 185)))
                    pixels[k + 2] = UInt8(max(0, min(255, tone * 160)))
                    pixels[k + 3] = 255
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            map = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            mapOrigin = low
            mapSize = SIMD2(repeating: 2 * radius)
        }

        var settings: QuarryFiringSettings {
            QuarryFiringSettings(
                order: order, stagger: Float(staggerMilliseconds) / 1000, count: Int(firingCount))
        }

        /// Fires the face on view again with the settings chosen.
        func fire() {
            guard let session else { return }
            session.settings = settings
            session.refire()
            version += 1
        }

        /// Takes a new strip's scene, already firing, and puts it on view once its event starts;
        /// the old event stays on view until then.
        private func install(_ session: QuarrySession, started: Date) {
            session.onRefireDone = { [weak self] in self?.version += 1 }
            session.onEventStarted = { [weak self, weak session] in
                guard let self, let session else { return }
                if self.incoming === session {
                    self.lastStripSeconds = Date().timeIntervalSince(started)
                    self.session = session
                    self.incoming = nil
                    self.preparing = nil
                }
                self.version += 1
            }
            incoming = session
            preparing = "Firing…"
            session.follow()
        }

        /// The strip shown on the map: the draft while dragging, else the site's.
        var stripOnMap: (SIMD2<Float>, SIMD2<Float>) {
            (draftStart ?? site.start, draftEnd ?? site.end)
        }

        /// Breaks the rock along the dragged strip and fires it.
        func commitDraft() {
            guard let start = draftStart, let end = draftEnd else { return }
            draftStart = nil
            draftEnd = nil
            guard simd_distance(start, end) >= 40 else {
                problem = "Drag a longer strip: at least 40 m along the face."
                return
            }
            site = QuarrySite(terrain: site.terrain, start: start, end: end, depth: site.depth)
            prepare()
        }

        /// Lays the face out and breaks its rock in the background, then fires it.
        func prepare() {
            guard let device else {
                problem = "This Mac has no Metal device."
                return
            }
            preparing = "Laying out the face…"
            preparingShare = 0
            problem = nil
            prepareCount += 1
            let count = prepareCount
            // A strip dragged while another is still being built replaces it.
            incoming = nil
            let site = self.site
            let settings = self.settings
            var options = QuarryFace.Options()
            options.blocks = blocks
            options.meshDetail = 1
            let keys = keyRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let started = Date()
            Task.detached(priority: .userInitiated) {
                do {
                    // The solver starts as soon as the blocks exist; the scene is drawn up meanwhile.
                    let session = try QuarrySession.prepare(
                        device: device, site: site, options: options, settings: settings, width: 1600,
                        height: 900, keyDirectory: keys
                    ) { stage, share in
                        Task { @MainActor in
                            guard self.prepareCount == count else { return }
                            self.preparing = stage
                            self.preparingShare = share
                        }
                    }
                    await MainActor.run {
                        guard self.prepareCount == count else { return }
                        self.install(session, started: started)
                    }
                } catch QuarryFace.Failure.noFace {
                    await MainActor.run {
                        guard self.prepareCount == count else { return }
                        self.preparing = nil
                        self.problem = "There's no face under that strip to break. Drag along a steep slope."
                    }
                } catch {
                    await MainActor.run {
                        guard self.prepareCount == count else { return }
                        self.preparing = nil
                        self.problem = "Couldn't lay the face out: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// The 3-D view: the session's frame; drag to orbit, shift-drag to pan, scroll to zoom.
    final class QuarryMetalView: MTKView {
        var session: QuarrySession?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDragged(with event: NSEvent) {
            guard let session else { return }
            if event.modifierFlags.contains(.shift) {
                let right = SIMD3<Float>(cos(session.yaw), sin(session.yaw), 0)
                let scale = session.distance * 0.0016
                session.focus +=
                    right * Float(-event.deltaX) * scale + SIMD3(0, 0, Float(event.deltaY) * scale)
            } else {
                session.yaw += Float(event.deltaX) * 0.005
                session.pitch = max(-0.2, min(1.3, session.pitch + Float(event.deltaY) * 0.004))
            }
        }
        override func scrollWheel(with event: NSEvent) {
            guard let session else { return }
            session.distance = max(25, min(800, session.distance * (1 - Float(event.scrollingDeltaY) * 0.01)))
        }
    }

    /// Draws the session each display refresh and keeps the readout.
    @MainActor
    final class QuarryViewCoordinator: NSObject, MTKViewDelegate {
        let queue: MTLCommandQueue?
        weak var view: QuarryMetalView?
        var last = Date()
        /// The interval between frames and the work in each, smoothed (ms).
        private(set) var interval = 0.0
        private(set) var work = 0.0
        /// Another scene is being built and fired: draw slowly and leave the machine to it.
        var throttled = false
        var onFrame: ((Int) -> Void)?

        init(device: MTLDevice?) {
            queue = device?.makeCommandQueue()
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let view = view as? QuarryMetalView, let session = view.session else { return }
            view.preferredFramesPerSecond =
                throttled ? QuarrySession.firingDrawRate : session.preferredDrawRate
            let now = Date()
            let elapsed = now.timeIntervalSince(last)
            last = now
            session.update(elapsed: elapsed)
            session.draw()
            if let drawable = view.currentDrawable, let buffer = queue?.makeCommandBuffer() {
                session.blit(to: drawable.texture, buffer: buffer)
                buffer.present(drawable)
                buffer.commit()
            }
            let spent = Date().timeIntervalSince(now) * 1000
            interval = interval == 0 ? elapsed * 1000 : interval * 0.9 + elapsed * 100
            work = work == 0 ? spent : work * 0.9 + spent * 0.1
            onFrame?(session.frame)
        }
    }

    struct QuarrySceneView: NSViewRepresentable {
        let session: QuarrySession?
        let coordinator: QuarryViewCoordinator
        var throttled = false

        func makeCoordinator() -> QuarryViewCoordinator { coordinator }

        func makeNSView(context: Context) -> QuarryMetalView {
            let view = QuarryMetalView(frame: .zero, device: session?.device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 60
            view.session = session
            view.delegate = context.coordinator
            context.coordinator.view = view
            return view
        }

        func updateNSView(_ view: QuarryMetalView, context: Context) {
            context.coordinator.throttled = throttled
            if view.session !== session {
                view.session = session
                if view.device == nil { view.device = session?.device }
            }
        }
    }

    /// The window.
    struct QuarryFaceView: View {
        @State private var model: QuarryFaceModel
        @State private var coordinator = QuarryViewCoordinator(device: MTLCreateSystemDefaultDevice())
        @State private var shownFrame = 0
        @State private var scrub = 0.0
        @State private var scrubbing = false
        @State private var readout = ""
        @State private var importing = false
        @State private var tick = 0
        /// Frames simulated so far of the event on view.
        @State private var simulated = 0.0

        /// `model`, for a review of the window offscreen; else one of its own.
        init(model: QuarryFaceModel? = nil) {
            _model = State(initialValue: model ?? QuarryFaceModel())
        }

        var body: some View {
            HSplitView {
                sidebar
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        QuarrySceneView(
                            session: model.session, coordinator: coordinator,
                            throttled: model.preparing != nil
                        )
                        if !readout.isEmpty {
                            Text(readout)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                                .padding(8)
                                .accessibilityLabel("Frame time")
                        }
                        if let preparing = model.preparing {
                            // Over the old event, which stays on view until the new one starts.
                            ProgressView(preparing, value: Double(model.preparingShare))
                                .frame(width: 260)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .frame(
                                    maxWidth: .infinity, maxHeight: .infinity,
                                    alignment: model.session == nil ? .center : .bottom
                                )
                                .padding(.bottom, 12)
                        }
                    }
                    timeline
                }
                .frame(minWidth: 640)
            }
            .frame(minWidth: 1000, minHeight: 640)
            .onAppear {
                coordinator.onFrame = { frame in
                    if !scrubbing { shownFrame = frame }
                    tick += 1
                    if tick % 10 == 0 {
                        readout = String(
                            format: "%5.1f ms  %3.0f fps   work %4.1f ms", coordinator.interval,
                            1000 / max(coordinator.interval, 1e-3), coordinator.work)
                        if let session = model.session, session.isSimulating {
                            readout += "\n" + session.playbackStatus
                        }
                        simulated = model.session.map { Double($0.availableFrames) } ?? 0
                    }
                }
                if model.session == nil, model.preparing == nil { model.prepare() }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.tiff, UTType(filenameExtension: "asc") ?? .plainText, .plainText]
            ) { result in
                if case .success(let url) = result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    model.openTerrain(url)
                }
            }
        }

        private var sidebar: some View {
            Form {
                Section {
                    Label("Experimental and illustrative", systemImage: "flask")
                        .font(.headline)
                    Text(
                        "A face broken and thrown by a stylised ripple of firings, for the look of it. It is not a blast-design aid: nothing here comes from the blast solver, and it gives no loads, reach or safety distances."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Section("Ground") {
                    LabeledContent("Terrain", value: model.terrainName)
                    HStack {
                        Button("Built-in hillside") { model.useBuiltIn() }
                        Button("Open terrain…") { importing = true }
                    }
                    QuarryMapView(model: model)
                        .frame(height: 260)
                        .accessibilityLabel("Map: drag along a face to choose the strip")
                    Text("Drag along a face on the map to choose the strip; the rock behind it breaks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Blocks", selection: $model.blocks) {
                        Text("30,000").tag(30_000)
                        Text("60,000").tag(60_000)
                        Text("100,000").tag(100_000)
                    }
                }
                Section("Firing (stylised)") {
                    if let session = model.session {
                        QuarryFiringControls(model: model, session: session, version: model.version)
                    } else {
                        Text("Breaking the rock first…").foregroundStyle(.secondary)
                    }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.orange) }
                }
                if let session = model.session {
                    Section("Memory") {
                        let m = session.memory
                        Text(
                            "Poses \(m.poses >> 20) MB, dust fields \(m.dustFields >> 20) MB, dust kept on disk \(m.dustOnDisk >> 20) MB; Metal \(m.metal >> 20) MB in all."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .id(tick / 60)
                    }
                }
            }
            .formStyle(.grouped)
        }

        private var timeline: some View {
            HStack(spacing: 10) {
                Button {
                    guard let session = model.session else { return }
                    session.playing.toggle()
                    if session.playing, session.frame >= session.eventFrames - 1 { session.seek(to: 0) }
                } label: {
                    Image(systemName: model.session?.playing == true ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(model.session?.playing == true ? "Pause" : "Play")
                .help("Play or pause")
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.session?.canPlay != true)
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { Double(shownFrame) },
                            set: { value in
                                scrubbing = true
                                shownFrame = Int(value)
                                model.session?.playing = false
                                model.session?.seek(to: Int(value))
                                scrubbing = false
                            }),
                        in: 0...Double(max(1, (model.session?.eventFrames ?? 2) - 1))
                    )
                    .disabled(model.session?.canPlay != true)
                    .accessibilityLabel("Timeline")
                    // How much of the event is simulated: the timeline scrubs over that much.
                    if let session = model.session, session.isSimulating {
                        ProgressView(value: simulated / Double(session.eventFrames))
                            .controlSize(.mini)
                            .tint(.secondary)
                            .accessibilityLabel("Simulated so far")
                    }
                }
                Text(String(format: "%.1f s", Float(shownFrame) / QuarrySession.frameRate))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Order, ripple and count, and Fire again with its progress.
    struct QuarryFiringControls: View {
        @Bindable var model: QuarryFaceModel
        let session: QuarrySession
        let version: Int
        @State private var progress: Float?
        @State private var status = ""

        var body: some View {
            Picker("Order", selection: $model.order) {
                ForEach(QuarryFiringOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            LabeledContent("Ripple") {
                HStack {
                    Slider(value: $model.staggerMilliseconds, in: 20...400)
                        .accessibilityLabel("Ripple, milliseconds between firings")
                    Text("\(Int(model.staggerMilliseconds)) ms").monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
            LabeledContent("Firings") {
                HStack {
                    Slider(value: $model.firingCount, in: 6...30, step: 1)
                        .accessibilityLabel("Number of firings")
                    Text("\(Int(model.firingCount))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
            HStack {
                // Firing again while an event is still simulated replaces it.
                Button("Fire again") { model.fire() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.incoming != nil)
                if progress != nil {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .task(id: version) {
                while !Task.isCancelled {
                    progress = session.refireProgress
                    status = session.playbackStatus
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    /// The map: the ground's relief with the strip drawn on it; drag to choose a new strip.
    struct QuarryMapView: View {
        let model: QuarryFaceModel

        var body: some View {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                ZStack {
                    if let map = model.map {
                        Image(decorative: map, scale: 1).resizable().interpolation(.medium)
                    }
                    Canvas { context, _ in
                        let (a, b) = model.stripOnMap
                        var path = Path()
                        path.move(to: point(a, side))
                        path.addLine(to: point(b, side))
                        context.stroke(path, with: .color(.orange), lineWidth: 3)
                        for p in [a, b] {
                            context.fill(
                                Path(
                                    ellipseIn: CGRect(origin: point(p, side), size: .zero).insetBy(
                                        dx: -4, dy: -4)),
                                with: .color(.orange))
                        }
                    }
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            model.draftStart = ground(value.startLocation, side)
                            model.draftEnd = ground(value.location, side)
                        }
                        .onEnded { _ in model.commitDraft() })
            }
        }

        private func point(_ p: SIMD2<Float>, _ side: CGFloat) -> CGPoint {
            let u = (p - model.mapOrigin) / model.mapSize
            return CGPoint(x: CGFloat(u.x) * side, y: CGFloat(1 - u.y) * side)
        }

        private func ground(_ p: CGPoint, _ side: CGFloat) -> SIMD2<Float> {
            model.mapOrigin + SIMD2(Float(p.x / side), Float(1 - p.y / side)) * model.mapSize
        }
    }

    /// File ▸ New Quarry Face (Experimental)…, after New District.
    struct QuarryFaceCommands: Commands {
        @Environment(\.openWindow) private var openWindow

        var body: some Commands {
            CommandGroup(after: .newItem) {
                Button("New Quarry Face (Experimental)…") { openWindow(id: "quarry-face") }
            }
        }
    }
#endif
