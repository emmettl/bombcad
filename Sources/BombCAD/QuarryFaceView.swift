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
        /// Bumped whenever the ground changes, for the strip's lines drawn over the 3-D view.
        private(set) var terrainGeneration = 0
        /// Placing the strip in the 3-D view: dragging there lays it along the face.
        var stripMode = false {
            didSet {
                // The strip is laid on the ground as it stands before the blast: show that.
                guard stripMode, !oldValue, let session else { return }
                session.playing = false
                session.seek(to: 0)
            }
        }
        /// An opened terrain file, while its area is chosen; the last one, to choose again.
        var cropChoice: QuarryCropChoice?
        private(set) var lastCropChoice: QuarryCropChoice?
        /// The clip to record: how the camera moves, from where, how much of the event, how slowly.
        var clipMotion = QuarryClipCamera.Motion.still
        var clipFromShown = false
        var clipSeconds = 10.0
        var clipSpeed: Float = 1
        /// The movie's size in pixels.
        var clipSize = SIMD2<Int>(1920, 1080)
        private(set) var recorder: QuarryClipRecorder?
        private(set) var clipShare: Float = 0
        private(set) var clipStatus = ""
        private(set) var lastClip: QuarryClipRecorder.Report?
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
            terrainGeneration += 1
            makeMap(around: (site.start + site.end) / 2, radius: 260)
            draftStart = nil
            draftEnd = nil
            prepare()
        }

        /// Reads a terrain file and offers an overview of the whole of it to choose the area from.
        func openTerrain(_ url: URL) {
            do {
                let grid = try ElevationGrid(contentsOf: url)
                cropChoice = QuarryCropChoice(grid: grid, name: url.lastPathComponent)
            } catch {
                problem = "Couldn't read that terrain: \(error.localizedDescription)"
            }
        }

        /// The last terrain file's overview again, to choose another area of it.
        func chooseAreaAgain() {
            cropChoice = lastCropChoice
        }

        /// Takes the area chosen on the overview: a 2 m crop of it becomes the ground.
        func useCrop(_ choice: QuarryCropChoice) {
            cropChoice = nil
            lastCropChoice = choice
            do {
                let terrain = try choice.crop.terrain(from: choice.grid, name: choice.name)
                useTerrain(terrain, name: choice.name)
            } catch {
                problem = "Couldn't crop that terrain: \(error)"
            }
        }

        /// A project's own terrain, as its window has it.
        func useProjectTerrain(_ entry: QuarryProjectTerrains.Entry) {
            useTerrain(entry.terrain, name: entry.name)
        }

        /// Makes `terrain` the ground, with a first strip along its steepest face if it has one,
        /// and breaks it; else asks for a strip to be dragged.
        func useTerrain(_ terrain: Terrain, name: String) {
            terrainName = name
            terrainGeneration += 1
            draftStart = nil
            draftEnd = nil
            let extent = SIMD2(Float(terrain.columns - 1), Float(terrain.rows - 1)) * terrain.spacing
            let whole = extent.max() <= 1300
            if let strip = QuarryStripGuide.suggest(terrain: terrain) {
                site = QuarrySite(terrain: terrain, start: strip.start, end: strip.end)
                if whole {
                    makeMap(around: terrain.origin + extent / 2, radius: extent.max() / 2)
                } else {
                    makeMap(around: (strip.start + strip.end) / 2, radius: 400)
                }
                prepare()
                problem = nil
                return
            }
            site = QuarrySite(
                terrain: terrain, start: terrain.origin + extent * SIMD2(0.35, 0.5),
                end: terrain.origin + extent * SIMD2(0.65, 0.5))
            makeMap(around: terrain.origin + extent / 2, radius: min(extent.max(), 1200) / 2)
            prepareCount += 1
            incoming = nil
            preparing = nil
            session = nil
            problem = "Nothing steep enough for a face was found. Drag along a slope on the map."
            version += 1
        }

        /// A shaded relief of the ground round `centre`, for dragging the strip on.
        private func makeMap(around centre: SIMD2<Float>, radius: Float) {
            let terrain = site.terrain
            let size = 360
            let low = centre - radius
            let pixels = QuarryRelief.rgba(
                width: size, height: size, metresPerPixel: 2 * radius / Float(size)
            ) { terrain.height(at: low + $0) }
            map = QuarryCropChoice.image(pixels, width: size, height: size)
            mapOrigin = low
            mapSize = SIMD2(repeating: 2 * radius)
        }

        /// Records a clip of the event on view to `url`, with the clip settings: the window keeps
        /// playing, drawing less often, while it is made.
        func recordClip(to url: URL) {
            guard let session, let cache = session.cache, let device else { return }
            var camera = QuarryClipCamera(
                focus: session.focus, yaw: session.yaw, pitch: session.pitch, distance: session.distance,
                fovDegrees: session.fovDegrees)
            camera.motion = clipMotion
            var request = QuarryClipRequest(url: url, camera: camera)
            request.start = clipFromShown ? Float(session.frame) / QuarrySession.frameRate : 0
            request.seconds = max(
                1 / QuarrySession.frameRate, min(Float(clipSeconds), session.eventSeconds - request.start))
            request.speed = clipSpeed
            request.width = clipSize.x
            request.height = clipSize.y
            let run = session.run
            let recorder = QuarryClipRecorder(
                device: device, face: session.face, cache: cache, firings: run?.firings ?? session.firings,
                request: request, stillComing: { [weak run] in run?.isSimulating == true })
            self.recorder = recorder
            clipShare = 0
            clipStatus = "Starting…"
            lastClip = nil
            recorder.start { [weak self] share, status in
                MainActor.assumeIsolated {
                    guard let self, self.recorder === recorder else { return }
                    self.clipShare = share
                    self.clipStatus = status
                }
            } done: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, self.recorder === recorder else { return }
                    self.recorder = nil
                    switch result {
                    case .success(let report):
                        self.lastClip = report
                        self.clipStatus = String(
                            format: "Saved %@: %.1f s, %d frames, made in %.0f s%@",
                            report.url.lastPathComponent, report.videoSeconds, report.frames,
                            report.wallSeconds,
                            report.cutShort ? " (the event stopped before the end asked for)" : "")
                    case .failure(let error):
                        self.clipStatus = "\(error)"
                    }
                }
            }
        }

        func cancelClip() {
            recorder?.cancel()
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

    /// The 3-D view: the session's frame; drag to orbit, shift-drag to pan, scroll to zoom. In
    /// strip mode a drag lays the strip along the face under the cursor, or moves an end of it, with
    /// the strip drawn over the view; option-drag orbits then.
    final class QuarryMetalView: MTKView {
        var session: QuarrySession?
        weak var model: QuarryFaceModel?
        let overlay = QuarryStripOverlay(frame: .zero)
        private enum Drag {
            case orbit, pan
            case start, end
            case draw
        }
        private var drag: Drag?
        /// The snapped ground point under the cursor in strip mode, and whether it is on a face.
        private var hover: (point: SIMD2<Float>, onFace: Bool)?
        /// The strip's lines in the ground's metres, kept while the strip and ground are unchanged.
        private var lines: (key: [Float], lines: QuarryStripGuide.Lines)?
        /// Milliseconds from each strip drag's event to the overlay drawn with it, for the record.
        private(set) var dragLatencies: [Double] = []

        override init(frame: CGRect, device: MTLDevice?) {
            super.init(frame: frame, device: device)
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = bounds
            addSubview(overlay)
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                    owner: self))
        }

        private var stripMode: Bool { model?.stripMode == true }

        /// The view's projection, as the renderer draws it (its frame is stretched over the view).
        private func viewProjection(_ session: QuarrySession) -> simd_float4x4 {
            let v = session.view()
            return QuarryMatrix.perspective(fovY: v.fovY, aspect: session.renderer.aspect, near: 3, far: 1600)
                * QuarryMatrix.lookAt(eye: v.eye, target: v.target, up: SIMD3(0, 0, 1))
        }

        /// A point of the ground (its own metres and height) on the view, or nil behind the eye.
        private func screen(_ g: SIMD3<Float>, _ session: QuarrySession, _ vp: simd_float4x4) -> CGPoint? {
            let l = session.face.local(SIMD2(g.x, g.y))
            let c = vp * SIMD4(l.x, l.y, g.z + 0.3, 1)
            guard c.w > 0.5 else { return nil }
            return CGPoint(
                x: CGFloat(c.x / c.w + 1) / 2 * bounds.width, y: CGFloat(c.y / c.w + 1) / 2 * bounds.height)
        }

        /// A point of the ground (its own metres and height) on the view now, for checks.
        func onView(_ g: SIMD3<Float>) -> CGPoint? {
            guard let session else { return nil }
            return screen(g, session, viewProjection(session))
        }

        /// The old ground under a point of the view, in the ground's own metres.
        func ground(at point: CGPoint) -> SIMD2<Float>? {
            guard let session, bounds.width > 0, bounds.height > 0 else { return nil }
            let ndc = SIMD2(Float(2 * point.x / bounds.width - 1), Float(2 * point.y / bounds.height - 1))
            guard let p = session.groundPoint(ndc: ndc, aspect: session.renderer.aspect) else { return nil }
            return session.face.world(SIMD2(p.x, p.y))
        }

        /// The face line nearest the ground under `point`, or the ground itself where there is none.
        private func snapped(at point: CGPoint) -> (point: SIMD2<Float>, onFace: Bool)? {
            guard let model, let g = ground(at: point) else { return nil }
            if let s = QuarryStripGuide.snap(g, terrain: model.site.terrain) { return (s, true) }
            return (g, false)
        }

        private func stripLines(_ model: QuarryFaceModel) -> QuarryStripGuide.Lines {
            let (a, b) = model.stripOnMap
            let key = [a.x, a.y, b.x, b.y, model.site.depth, Float(model.terrainGeneration)]
            if let lines, lines.key == key { return lines.lines }
            let made = QuarryStripGuide.lines(
                terrain: model.site.terrain, start: a, end: b, depth: model.site.depth)
            lines = (key, made)
            return made
        }

        /// The strip's ends on the view: where its handles are drawn and picked.
        private func handles(_ model: QuarryFaceModel, _ session: QuarrySession, _ vp: simd_float4x4)
            -> [CGPoint?]
        {
            let l = stripLines(model)
            guard let first = l.face.first, let last = l.face.last else { return [nil, nil] }
            return [screen(first, session, vp), screen(last, session, vp)]
        }

        /// Draws the strip over the view, as it is now and with the camera as it is now.
        func refreshOverlay() {
            guard stripMode, let model, let session else {
                overlay.clear()
                return
            }
            let vp = viewProjection(session)
            let l = stripLines(model)
            let ends = handles(model, session, vp)
            let hoverPoint =
                drag == nil
                ? hover.flatMap { h in
                    screen(SIMD3(h.point, model.site.terrain.height(at: h.point)), session, vp).map {
                        ($0, h.onFace)
                    }
                } : nil
            overlay.show(
                face: l.face.map { screen($0, session, vp) }, back: l.back.map { screen($0, session, vp) },
                handles: ends, hover: hoverPoint)
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseMoved(with event: NSEvent) {
            guard stripMode else { return }
            hover = snapped(at: point(event))
            refreshOverlay()
        }

        override func mouseExited(with event: NSEvent) {
            hover = nil
            refreshOverlay()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let p = point(event)
            if event.modifierFlags.contains(.shift) {
                drag = .pan
            } else if !stripMode || event.modifierFlags.contains(.option) {
                drag = .orbit
            } else if let model, let session {
                let vp = viewProjection(session)
                let ends = handles(model, session, vp)
                func near(_ q: CGPoint?) -> Bool { q.map { hypot($0.x - p.x, $0.y - p.y) < 14 } ?? false }
                let (a, b) = model.stripOnMap
                if near(ends[0]) {
                    drag = .start
                    (model.draftStart, model.draftEnd) = (a, b)
                } else if near(ends[1]) {
                    drag = .end
                    (model.draftStart, model.draftEnd) = (a, b)
                } else if let s = snapped(at: p) {
                    drag = .draw
                    (model.draftStart, model.draftEnd) = (s.point, s.point)
                } else {
                    drag = .orbit
                }
                hover = nil
                refreshOverlay()
            } else {
                drag = .orbit
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let session else { return }
            switch drag ?? .orbit {
            case .pan:
                let right = SIMD3<Float>(cos(session.yaw), sin(session.yaw), 0)
                let scale = session.distance * 0.0016
                session.focus +=
                    right * Float(-event.deltaX) * scale + SIMD3(0, 0, Float(event.deltaY) * scale)
            case .orbit:
                session.yaw += Float(event.deltaX) * 0.005
                session.pitch = max(-0.2, min(1.3, session.pitch + Float(event.deltaY) * 0.004))
            case .start, .end, .draw:
                guard let model, let s = snapped(at: point(event)) else { return }
                if drag == .start { model.draftStart = s.point } else { model.draftEnd = s.point }
                refreshOverlay()
                CATransaction.flush()
                // From the event (system uptime) to the overlay committed with it.
                let ms = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
                if dragLatencies.count < 4096 { dragLatencies.append(ms) }
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer { drag = nil }
            switch drag {
            case .start, .end, .draw:
                guard let model else { return }
                if let a = model.draftStart, let b = model.draftEnd, simd_distance(a, b) < 4 {
                    // A click, not a drag: leave the strip as it was.
                    model.draftStart = nil
                    model.draftEnd = nil
                } else {
                    model.commitDraft()
                }
                drag = nil
                refreshOverlay()
            default: break
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard let session else { return }
            session.distance = max(25, min(800, session.distance * (1 - Float(event.scrollingDeltaY) * 0.01)))
        }
    }

    /// The strip drawn over the 3-D view: the old face's line along it, the new face's line its depth
    /// into the hill, handles at its ends, and the face point under the cursor. Layers only, so it
    /// is drawn at once, between the view's frames; events pass through to the view.
    final class QuarryStripOverlay: NSView {
        private let faceLine = CAShapeLayer()
        private let backLine = CAShapeLayer()
        private let handleDots = CAShapeLayer()
        private let hoverMark = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            let orange = NSColor.systemOrange.cgColor
            faceLine.strokeColor = orange
            faceLine.lineWidth = 3
            faceLine.lineJoin = .round
            backLine.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
            backLine.lineWidth = 2
            backLine.lineDashPattern = [6, 4]
            handleDots.fillColor = NSColor.white.cgColor
            handleDots.strokeColor = orange
            handleDots.lineWidth = 2.5
            hoverMark.lineWidth = 2
            for shape in [backLine, faceLine, handleDots, hoverMark] {
                if shape !== handleDots { shape.fillColor = nil }
                shape.shadowOpacity = 0.6
                shape.shadowRadius = 1.5
                shape.shadowOffset = .zero
                layer?.addSublayer(shape)
            }
            hoverMark.fillColor = nil
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private static func path(_ points: [CGPoint?]) -> CGPath {
            let path = CGMutablePath()
            var open = false
            for p in points {
                guard let p else {
                    open = false
                    continue
                }
                if open { path.addLine(to: p) } else { path.move(to: p) }
                open = true
            }
            return path
        }

        func clear() {
            guard faceLine.path != nil || hoverMark.path != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for shape in [faceLine, backLine, handleDots, hoverMark] { shape.path = nil }
            CATransaction.commit()
        }

        func show(face: [CGPoint?], back: [CGPoint?], handles: [CGPoint?], hover: (CGPoint, Bool)?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            faceLine.path = Self.path(face)
            // The new face's line, and the strip's ends joining the two.
            var backPoints = back
            if let a = face.first, let b = back.first { backPoints = [a, b, nil] + backPoints }
            if let a = face.last, let b = back.last { backPoints += [nil, b, a] }
            backLine.path = Self.path(backPoints)
            let dots = CGMutablePath()
            for p in handles.compactMap({ $0 }) {
                dots.addEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            }
            handleDots.path = dots
            if let (p, onFace) = hover {
                let mark = CGMutablePath()
                mark.addEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                if !onFace {
                    mark.move(to: CGPoint(x: p.x - 4, y: p.y - 4))
                    mark.addLine(to: CGPoint(x: p.x + 4, y: p.y + 4))
                }
                hoverMark.path = mark
                hoverMark.strokeColor = (onFace ? NSColor.systemYellow : NSColor.systemGray).cgColor
            } else {
                hoverMark.path = nil
            }
            CATransaction.commit()
        }

        /// Whether anything is drawn, for checks.
        var isShowing: Bool { faceLine.path.map { !$0.isEmpty } ?? false }
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
        /// Another scene is being built and fired, or a clip made: draw slowly and leave the
        /// machine to it.
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
            // The camera may have moved: the strip follows it.
            view.refreshOverlay()
            let spent = Date().timeIntervalSince(now) * 1000
            interval = interval == 0 ? elapsed * 1000 : interval * 0.9 + elapsed * 100
            work = work == 0 ? spent : work * 0.9 + spent * 0.1
            onFrame?(session.frame)
        }
    }

    struct QuarrySceneView: NSViewRepresentable {
        let session: QuarrySession?
        let model: QuarryFaceModel
        let coordinator: QuarryViewCoordinator
        var throttled = false
        var stripMode = false

        func makeCoordinator() -> QuarryViewCoordinator { coordinator }

        func makeNSView(context: Context) -> QuarryMetalView {
            let view = QuarryMetalView(frame: .zero, device: session?.device ?? model.device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 60
            view.session = session
            view.model = model
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
            view.model = model
            // Strip mode switched, or the strip changed: draw it now, not at the next frame.
            _ = stripMode
            view.refreshOverlay()
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
        @State private var projectTerrains = QuarryProjectTerrains.shared
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
                            session: model.session, model: model, coordinator: coordinator,
                            throttled: model.preparing != nil || model.recorder != nil,
                            stripMode: model.stripMode
                        )
                        stripControls
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
            .sheet(item: $model.cropChoice) { choice in
                QuarryCropSheet(choice: choice) {
                    model.useCrop($0)
                } cancel: {
                    model.cropChoice = nil
                }
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

        /// The strip mode's switch at the view's top right, and what a drag does in it.
        private var stripControls: some View {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle(isOn: $model.stripMode) {
                    Label("Place strip", systemImage: "line.diagonal")
                }
                .toggleStyle(.button)
                .help("Drag along a face in the view to lay the strip there, or drag one of its ends")
                .disabled(model.session == nil)
                if model.stripMode {
                    Text(
                        "Drag along a face to lay the strip, or drag an end.\nOption-drag to orbit, shift-drag to pan."
                    )
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
                            .help("A GeoTIFF or ESRI ASCII grid; you choose the area of it on an overview")
                    }
                    HStack {
                        let projects = projectTerrains.entries
                        if projects.count == 1, let entry = projects.first {
                            Button("Project's terrain") { model.useProjectTerrain(entry) }
                                .help("The terrain of \(entry.name), the project open in BombCAD")
                        } else if projects.count > 1 {
                            Menu("Project's terrain") {
                                ForEach(projects) { entry in
                                    Button(entry.name) { model.useProjectTerrain(entry) }
                                }
                            }
                            .fixedSize()
                        }
                        if model.lastCropChoice != nil {
                            Button("Choose area…") { model.chooseAreaAgain() }
                                .help("Choose another area of \(model.lastCropChoice?.name ?? "the file")")
                        }
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
                Section("Clip") {
                    QuarryClipControls(model: model)
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

    /// The clip's settings and its recording, with progress and Cancel.
    struct QuarryClipControls: View {
        @Bindable var model: QuarryFaceModel

        var body: some View {
            Picker("Camera", selection: $model.clipMotion) {
                ForEach(QuarryClipCamera.Motion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .help("The view as it is now, held still or turned slowly round what it looks at")
            Picker("From", selection: $model.clipFromShown) {
                Text("The event's start").tag(false)
                Text("The time shown").tag(true)
            }
            LabeledContent("Length") {
                HStack {
                    Slider(value: $model.clipSeconds, in: 2...20, step: 1)
                        .accessibilityLabel("Seconds of the event in the clip")
                    Text("\(Int(model.clipSeconds)) s").monospacedDigit().frame(
                        width: 36, alignment: .trailing)
                }
            }
            Picker("Speed", selection: $model.clipSpeed) {
                Text("Real time").tag(Float(1))
                Text("Half speed").tag(Float(0.5))
                Text("Quarter speed").tag(Float(0.25))
            }
            Text(
                String(
                    format: "A %d × %d movie of %.0f s of the event, %.0f s long.", model.clipSize.x,
                    model.clipSize.y, model.clipSeconds,
                    model.clipSeconds / Double(model.clipSpeed))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.recorder != nil {
                HStack {
                    ProgressView(model.clipStatus, value: Double(model.clipShare))
                        .font(.caption)
                    Button("Cancel") { model.cancelClip() }
                }
            } else {
                HStack {
                    Button("Record Clip…") { choose() }
                        .disabled(model.session?.canPlay != true)
                    if let clip = model.lastClip {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([clip.url])
                        }
                    }
                }
                if !model.clipStatus.isEmpty {
                    Text(model.clipStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }

        private func choose() {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "Quarry face.mp4"
            panel.message = "Rendering can be slower than real time; the window keeps playing meanwhile."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.recordClip(to: url)
        }
    }

    /// An opened terrain file and the area of it chosen: an overview of the whole file to choose on.
    struct QuarryCropChoice: Identifiable {
        let id = UUID()
        let grid: ElevationGrid
        let name: String
        var crop: QuarryTerrainCrop
        let overview: CGImage?
        /// Metres a pixel of the overview, and its size in pixels.
        let metresPerPixel: Float
        let pixels: SIMD2<Int>

        init(grid: ElevationGrid, name: String, longest: Int = 560) {
            self.grid = grid
            self.name = name
            crop = QuarryTerrainCrop(grid: grid)
            let extent = crop.extent
            metresPerPixel = max(extent.max(), 1) / Float(longest)
            pixels = SIMD2(
                max(1, Int((extent.x / metresPerPixel).rounded())),
                max(1, Int((extent.y / metresPerPixel).rounded())))
            let rgba = QuarryRelief.rgba(width: pixels.x, height: pixels.y, metresPerPixel: metresPerPixel) {
                [grid] p in
                grid.elevation(at: grid.coordinates(of: SIMD2<Double>(p), origin: grid.southWest))
            }
            overview = Self.image(rgba, width: pixels.x, height: pixels.y)
        }

        static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// The overview of a terrain file: drag the square to the area to break, and size it.
    struct QuarryCropSheet: View {
        @State var choice: QuarryCropChoice
        let use: (QuarryCropChoice) -> Void
        let cancel: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose the area of \(choice.name)").font(.headline)
                Text(
                    String(
                        format:
                            "The file covers %.1f × %.1f km. Drag the square to the slope or face to break; the area is taken at 2 m.",
                        choice.crop.extent.x / 1000, choice.crop.extent.y / 1000)
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                GeometryReader { geometry in
                    let scale = min(
                        geometry.size.width / CGFloat(choice.pixels.x),
                        geometry.size.height / CGFloat(choice.pixels.y))
                    let size = CGSize(
                        width: CGFloat(choice.pixels.x) * scale, height: CGFloat(choice.pixels.y) * scale)
                    let metres = CGFloat(choice.metresPerPixel) / scale
                    ZStack(alignment: .topLeading) {
                        if let overview = choice.overview {
                            Image(decorative: overview, scale: 1).resizable().interpolation(.medium)
                                .frame(width: size.width, height: size.height)
                        }
                        let side = CGFloat(choice.crop.side) / metres
                        Rectangle()
                            .strokeBorder(Color.orange, lineWidth: 2)
                            .background(Color.orange.opacity(0.12))
                            .frame(width: side, height: side)
                            .offset(
                                x: CGFloat(choice.crop.corner.x) / metres,
                                y: size.height - CGFloat(choice.crop.corner.y) / metres - side
                            )
                            .allowsHitTesting(false)
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            let p = value.location
                            choice.crop.move(
                                centre: SIMD2(Float(p.x * metres), Float((size.height - p.y) * metres)))
                        }
                    )
                    .accessibilityLabel("Overview of the terrain file: drag to choose the area")
                }
                .frame(width: 560, height: 420)
                LabeledContent("Size") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(choice.crop.side) }, set: { choice.crop.resize(Float($0)) }),
                            in: Double(
                                QuarryTerrainCrop.smallest)...Double(
                                    max(
                                        QuarryTerrainCrop.smallest + 1,
                                        min(QuarryTerrainCrop.largest, choice.crop.extent.min())))
                        )
                        .accessibilityLabel("Size of the area, metres across")
                        Text(String(format: "%.0f m", choice.crop.side)).monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Use This Area") { use(choice) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 600)
        }
    }

    /// The terrains of the projects open in BombCAD, for the quarry face to break: each project
    /// window says what its terrain is while it is open (none when its ground is flat).
    @MainActor
    @Observable
    final class QuarryProjectTerrains {
        static let shared = QuarryProjectTerrains()
        struct Entry: Identifiable {
            let id: UUID
            var name: String
            var terrain: Terrain
        }
        private(set) var entries: [Entry] = []

        func set(_ id: UUID, name: String, terrain: Terrain?) {
            guard let terrain, !terrain.isFlat, terrain.columns >= 2, terrain.rows >= 2 else {
                remove(id)
                return
            }
            if let k = entries.firstIndex(where: { $0.id == id }) {
                entries[k].name = name
                entries[k].terrain = terrain
            } else {
                entries.append(Entry(id: id, name: name, terrain: terrain))
            }
        }

        func remove(_ id: UUID) {
            entries.removeAll { $0.id == id }
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
