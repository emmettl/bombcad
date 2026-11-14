import BlastCore
import BlastModel
import Foundation
import Metal
import simd

/// The stylised firing settings a user can change. Illustrative: for the look of the ripple only.
public struct QuarryFiringSettings: Equatable, Sendable {
    public var order: QuarryFiringOrder = .leftToRight
    /// Time between one firing and the next in the order (s).
    public var stagger: Float = 0.1
    /// Firings along the row; fewer means further apart.
    public var count = 16
    public init() {}
    public init(order: QuarryFiringOrder, stagger: Float, count: Int) {
        self.order = order
        self.stagger = stagger
        self.count = count
    }
}

/// A quarry face to play with: fired in the background and watched while it is simulated, from a
/// packed pose cache that fills as the solver goes and is scrubbed over what is done; its dust run
/// forward from fields kept on disk, drawn by `QuarryRenderer`. Used from the main thread; each
/// firing is a `QuarryRun` on its own thread, shown once its first frames are stored (the old event
/// stays on view until then). Illustrative.
public final class QuarrySession: @unchecked Sendable {
    public static let frameRate: Float = 30
    public static let substeps = 8
    /// The window's dust cells (m); the film's are 1 m.
    public static let dustGrid: Float = 1.5
    /// Frames between dust fields kept on disk.
    public static let keyEvery = 30
    /// While the physics runs and nothing new can be shown, the view draws at this rate and leaves
    /// the GPU to it.
    public static let firingDrawRate = 15
    /// While an event is shown as it is simulated, the view draws at the event's own rate: no frame
    /// is new faster than that, and the GPU is shared with the solver.
    public static let streamingDrawRate = 30
    /// How far playback likes to stay behind the solver while following it (s).
    public static let followLead = 0.4
    /// Command buffers a solver frame is split into, so the window's drawing can go between them.
    public static let solverBuffers = 8
    /// The most pixels the window's frame is drawn with, whatever the view's shape: as many as the
    /// 1600 by 900 it was drawn at before following the view, so a frame costs the same.
    public static let framePixels = 1600 * 900
    /// How long the view's size must hold before the frame is made again at it (s). Meanwhile the
    /// projection follows the view at once and the frame is stretched back to the view's shape.
    public static let resizeSettle = 0.25
    /// The shape whose field of view the camera's sets: a view narrower than this keeps its width of
    /// field and shows more above and below, so it holds all that a 16:9 clip from the same camera
    /// shows; a wider view keeps the vertical field and shows more to the sides.
    public static let fieldAspect: Float = 16 / 9
    public let eventFrames: Int

    public let device: MTLDevice
    public let face: QuarryFace
    public let renderer: QuarryRenderer
    let restSizes: [Float]
    let launch = QuarryLaunch()
    let pose: MTLBuffer
    let previous: MTLBuffer
    let dustPose: MTLBuffer
    let dustPrevious: MTLBuffer
    let present: MTLRenderPipelineState
    let presentSampler: MTLSamplerState
    /// Where the dust fields are kept, one file a stored second.
    public let keyDirectory: URL
    private var generation = 0

    /// The event shown, and the run filling it.
    public private(set) var cache: QuarryPoseCache?
    public private(set) var run: QuarryRun?
    public private(set) var dust: QuarryDustField?
    /// A firing asked for and not yet shown, and its dust once made.
    private var pending: QuarryRun?
    private var pendingDust: QuarryDustField?
    private var keyStored: [Bool] = []
    public var settings = QuarryFiringSettings()
    public private(set) var frame = 0
    private(set) var dustFrame = 0
    private var decoded = -1
    /// The frame `previous` holds.
    private var previousFrame = -1
    public var playing = false
    /// Dust steps a drawn frame may spend catching up after a scrub.
    public var catchUpSteps = 4
    private var clock = 0.0
    /// The frame size the view asks for and since when, while it differs from the frame's own; and
    /// whether the frame has been fitted to a view yet.
    private var wantedSize: (size: SIMD2<Int>, since: Double)?
    private var fitted = false
    /// Playback's speed against real time while it follows the solver (1 once the event is done),
    /// measured over about half a second; the speed the solver allows; and the solver's own.
    public private(set) var playbackRate = 1.0
    private var followRate = 1.0
    public private(set) var solverRate = 1.0
    private var solverSample: (time: Date, frames: Int)?

    /// The orbit: about `focus`, at `distance`, `yaw` round and `pitch` up (radians).
    public var yaw: Float = -0.81
    public var pitch: Float = -0.086
    public var distance: Float = 143
    public var focus: SIMD3<Float>
    public var fovDegrees: Float = 32

    /// Set while a firing is asked for and nothing of it can be shown yet: the share of its lead
    /// stored.
    public private(set) var refireProgress: Float?
    public private(set) var refireStatus = ""
    /// Seconds from asking for the last firing to its first frame shown.
    public private(set) var lastRefireSeconds: Double?
    /// Called on the main thread when a new event is first shown, and when its run ends.
    public var onEventStarted: (() -> Void)?
    public var onRefireDone: (() -> Void)?

    /// `face` generated (with `meshDetail` 1 for a window); `keyDirectory` for the dust fields.
    /// `run`, if given, is a firing of this face already under way, adopted by `follow()`.
    public init(
        device: MTLDevice, face: QuarryFace, width: Int, height: Int, keyDirectory: URL, seconds: Float = 20,
        run: QuarryRun? = nil, settings: QuarryFiringSettings = QuarryFiringSettings()
    ) throws {
        self.device = device
        // The meshes are the renderer's, on the GPU; held here as well they were 0.6 GB.
        self.face = face.withoutMesh()
        self.settings = settings
        eventFrames = Int(seconds * Self.frameRate) + 1
        self.keyDirectory = keyDirectory
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let path = QuarryCameraPath(
            eyes: (.zero, SIMD3(0, 1, 0)), targets: (SIMD3(0, 1, 0), .zero), fovY: (36, 36), duration: seconds
        )
        renderer = try QuarryRenderer(
            device: device, face: face, width: width, height: height, supersample: 1, path: path,
            frameRate: Self.frameRate, quality: .live)
        restSizes = face.blocks.map(\.size)
        let bodies = face.blocks.count
        pose = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        previous = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        dustPose = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        dustPrevious = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        let rest = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        for (n, block) in face.blocks.enumerated() {
            rest[2 * n] = SIMD4(block.centre, 0)
            rest[2 * n + 1] = SIMD4(0, 0, 0, 1)
        }
        previous.contents().copyMemory(from: pose.contents(), byteCount: 32 * bodies)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = renderer.library.makeFunction(name: "fullscreen")!
        d.fragmentFunction = renderer.library.makeFunction(name: "presentFragment")!
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        present = try device.makeRenderPipelineState(descriptor: d)
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        presentSampler = device.makeSamplerState(descriptor: sampler)!
        let orbit = Self.defaultOrbit(face)
        (yaw, pitch, distance, focus) = (orbit.yaw, orbit.pitch, orbit.distance, orbit.focus)
        if let run {
            // Made here, off the main thread, so the new event can be shown as soon as it is ready.
            pending = run
            pendingDust = try QuarryDustField(
                device: device, face: self.face, firings: run.firings, sun: sunDirection,
                gridSize: Self.dustGrid)
            refireProgress = 0
            refireStatus = "Firing…"
        }
    }

    deinit {
        pending?.cancel()
        run?.cancel()
        try? FileManager.default.removeItem(at: keyDirectory)
    }

    public var firings: [QuarryFiring] {
        Self.firings(face: face, settings: settings)
    }

    public static func firings(face: QuarryFace, settings: QuarryFiringSettings) -> [QuarryFiring] {
        QuarryFiringPattern.pattern(
            face: face, count: settings.count, first: 1.8, stagger: settings.stagger, order: settings.order)
    }

    /// The window's default orbit for `face`, as a new session of it starts with: a ridge cut's
    /// opening view (`QuarryRidgeView`, in the cut's frame, so it follows the cut); a face's from
    /// the floor in front of the strip's near end, toward its middle.
    public static func defaultOrbit(_ face: QuarryFace) -> QuarryOrbit {
        QuarryRidgeView.opening(face)?.orbit ?? QuarryOrbit.faceOpening(face)
    }

    /// Starts a firing of `face` on its own thread, for a session made after it with `run:`.
    public static func startRun(
        device: MTLDevice, face: QuarryFace, settings: QuarryFiringSettings, seconds: Float = 20
    ) -> QuarryRun {
        QuarryRun(
            device: device, face: face, firings: firings(face: face, settings: settings),
            frames: Int(seconds * frameRate) + 1, frameRate: frameRate, substeps: substeps,
            buffers: solverBuffers)
    }

    /// The renderer's sun, which the dust is lit by.
    private var sunDirection: SIMD3<Float> {
        SIMD3(renderer.camera.sun.x, renderer.camera.sun.y, renderer.camera.sun.z)
    }

    /// Lays a face out along `site`, breaks its rock and fires it, on the calling thread (not the
    /// main one): the render-only dressing past the strip is built beside the rock, the solver
    /// starts as soon as the blocks exist, and the rest of the scene (the renderer, the dust) is
    /// built while it runs. `progress` is told each stage and the share done. The session returned
    /// shows the event once `follow()` finds it ready.
    public static func prepare(
        device: MTLDevice, site: QuarrySite, options: QuarryFace.Options, settings: QuarryFiringSettings,
        width: Int, height: Int, keyDirectory: URL, timings: ((String) -> Void)? = nil,
        progress: @escaping (String, Float) -> Void
    ) throws -> QuarrySession {
        try autoreleasepool {
            try prepareInPool(
                device: device, site: site, options: options, settings: settings, width: width,
                height: height,
                keyDirectory: keyDirectory, timings: timings, progress: progress)
        }
    }

    /// The dressing, built on its own thread from the layout alone.
    private final class Dressing: @unchecked Sendable {
        var face: QuarryFace
        init(_ face: QuarryFace) { self.face = face }
    }

    private static func prepareInPool(
        device: MTLDevice, site: QuarrySite, options: QuarryFace.Options, settings: QuarryFiringSettings,
        width: Int, height: Int, keyDirectory: URL, timings: ((String) -> Void)?,
        progress: @escaping (String, Float) -> Void
    ) throws -> QuarrySession {
        var times: [(String, Date)] = [("", Date())]
        progress(site.scene == .ridgeCut ? "Laying out the cut…" : "Laying out the face…", 0)
        var face = try QuarryFace(site: site, options: options)
        times.append(("layout", Date()))
        let dressing = Dressing(face)
        let dressed = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: dressed) {
            autoreleasepool { dressing.face.buildDressing(level: 1) }
        }
        progress("Breaking the rock…", 0.05)
        face.generate { progress("Breaking the rock…", 0.05 + 0.8 * $0) }
        times.append(("rock (dressing beside it)", Date()))
        let run = startRun(device: device, face: face.withoutMesh(), settings: settings)
        progress("Building the scene while it fires…", 0.85)
        dressed.wait()
        face.dressingVertices = dressing.face.dressingVertices
        face.dressingIndices = dressing.face.dressingIndices
        face.ledgeVertices = dressing.face.ledgeVertices
        face.ledgeIndices = dressing.face.ledgeIndices
        face.report += dressing.face.report
        times.append(("rest of the dressing", Date()))
        let session = try QuarrySession(
            device: device, face: face, width: width, height: height, keyDirectory: keyDirectory, run: run,
            settings: settings)
        times.append(("scene", Date()))
        progress("Firing…", 0.95)
        if let timings {
            let parts = (1..<times.count).map {
                String(format: "%@ %.2f s", times[$0].0, times[$0].1.timeIntervalSince(times[$0 - 1].1))
            }
            timings(parts.joined(separator: ", ") + "; \(face.blocks.count) blocks")
            for line in face.report { timings(line) }
        }
        return session
    }

    public var eventSeconds: Float { Float(eventFrames - 1) / Self.frameRate }
    /// The whole event is stored.
    public var isReady: Bool { cache?.isComplete == true }
    /// Something of an event is shown, and can be played and scrubbed over what is stored.
    public var canPlay: Bool { (cache?.available ?? 0) > 0 }
    /// The frames that can be shown now: all of them once the event is stored.
    public var availableFrames: Int { cache?.available ?? 0 }
    /// The shown event is still being simulated.
    public var isSimulating: Bool { run?.isSimulating == true }
    /// A firing is asked for and not yet shown.
    public var isStarting: Bool { pending != nil }
    /// The rate the view should draw at: the event's own while the solver needs the GPU.
    public var preferredDrawRate: Int {
        if isSimulating { return Self.streamingDrawRate }
        return pending != nil ? Self.firingDrawRate : 60
    }

    private func keyURL(_ k: Int, generation g: Int) -> URL {
        keyDirectory.appendingPathComponent("dust-\(g)-\(k).bin")
    }

    /// Fires the face again with the current settings. The solver runs on its own thread; the old
    /// event stays on view until the new one's first frames are stored, and then the new one plays
    /// as it is simulated. A firing asked for while another is under way replaces it.
    public func refire() {
        pending?.cancel()
        // The event on view keeps what it has stored; its solver gives the GPU to the new one.
        run?.cancel()
        let run = Self.startRun(device: device, face: face, settings: settings, seconds: eventSeconds)
        pending = run
        pendingDust = nil
        refireProgress = 0
        refireStatus = "Firing…"
        let face = self.face
        let device = self.device
        let sun = sunDirection
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // Pooled: making the field reads its buffers, which would otherwise stay alive.
                let dust = try autoreleasepool {
                    try QuarryDustField(
                        device: device, face: face, firings: run.firings, sun: sun, gridSize: Self.dustGrid)
                }
                DispatchQueue.main.async {
                    guard let self, self.pending === run else { return }
                    self.pendingDust = dust
                    self.adoptIfReady()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.pending === run else { return }
                    self.fail(run, "Firing failed: \(error)")
                }
            }
        }
        follow()
    }

    /// Shows the firing under way as soon as it can be: call once the callbacks are set.
    public func follow() {
        guard let run = pending else { return }
        run.whenStartable { [weak self] in
            DispatchQueue.main.async { self?.adoptIfReady() }
        }
    }

    private func fail(_ run: QuarryRun, _ message: String) {
        run.cancel()
        pending = nil
        pendingDust = nil
        refireProgress = nil
        refireStatus = message
    }

    /// Takes the pending firing as the event shown, once its lead and its dust are ready.
    private func adoptIfReady() {
        guard let run = pending else { return }
        if let failure = run.failure {
            fail(run, "Firing failed: \(failure)")
            return
        }
        guard !run.cancelled else { return }
        guard let dust = pendingDust, run.isStartable, let cache = run.cache else {
            if let cache = run.cache { refireProgress = Float(cache.available) / Float(run.lead) }
            return
        }
        let old = generation
        for k in keyStored.indices where keyStored[k] {
            try? FileManager.default.removeItem(at: keyURL(k, generation: old))
        }
        generation += 1
        self.run = run
        self.cache = cache
        self.dust = dust
        pending = nil
        pendingDust = nil
        keyStored = Array(repeating: false, count: (eventFrames - 1) / Self.keyEvery + 1)
        if (try? dust.save(to: keyURL(0, generation: generation))) != nil {
            keyStored[0] = true
        }
        renderer.dust = dust
        dustFrame = 0
        let seconds = Date().timeIntervalSince(run.requested)
        lastRefireSeconds = seconds
        refireProgress = nil
        refireStatus = String(format: "Started in %.1f s", seconds)
        renderer.resetDecor()
        decoded = -1
        frame = 0
        clock = 0
        playing = true
        playbackRate = 1
        followRate = 1
        solverRate = 1
        solverSample = nil
        onEventStarted?()
        // Told again when the solver is done.
        run.whenFinished { [weak self, weak run] in
            DispatchQueue.main.async {
                guard let self, let run, self.run === run else { return }
                if let total = run.secondsToFinish {
                    self.refireStatus = String(
                        format: "Started in %.1f s, simulated in %.1f s", self.lastRefireSeconds ?? 0, total)
                }
                self.onRefireDone?()
            }
        }
    }

    public func seek(to target: Int) {
        let head = max(0, availableFrames - 1)
        let target = max(0, min(eventFrames - 1, head, target))
        if target < frame { renderer.resetDecor() }
        frame = target
        clock = Double(target) / Double(Self.frameRate)
    }

    /// What the playback is doing, for a readout: following the solver, and how fast.
    public var playbackStatus: String {
        guard let cache else { return refireStatus }
        if run?.isSimulating == true {
            let share = Int(100 * Float(cache.filled) / Float(eventFrames))
            if playing, playbackRate < 0.97 {
                return String(
                    format: "Simulating %d%%, playing at %.2f× real time to keep up", share, playbackRate)
            }
            return "Simulating \(share)%, playing as it is computed"
        }
        return refireStatus
    }

    /// Advances playback by `elapsed` wall seconds, updates the poses for the shown frame, and
    /// brings the dust toward it. While the event is still being simulated, playback follows the
    /// solver: at real time while it keeps ahead, else at the solver's own rate a little behind it,
    /// never past the last frame stored and never backward.
    public func update(elapsed: Double) {
        if pending != nil { adoptIfReady() }
        guard let cache else { return }
        let available = cache.available
        guard available > 0 else { return }
        let head = available - 1
        let fps = Double(Self.frameRate)
        let simulating = run?.isSimulating == true
        if simulating { measureSolver(available) }
        if playing {
            var advance = elapsed
            if simulating {
                // Ahead of the solver by less than the lead: slow toward its own rate, and below it
                // while the gap is short, so the gap grows back rather than playback stuttering.
                let lead = Double(head) / fps - clock
                let wanted = max(0, min(1, solverRate + (lead - Self.followLead) * 0.8))
                followRate += (wanted - followRate) * min(1, elapsed * 4)
                advance = elapsed * followRate
                // And every frame shown, one a drawn frame at most, once drawing falls behind the
                // event: while the solver shares the GPU a drawn frame can take longer than a frame
                // of the event, and skipping frames to keep real time would stutter. Slower and
                // smooth instead. (A drawn frame a little late, by the display's pacing, still keeps
                // real time.)
                if elapsed > 1.25 / fps { advance = min(advance, 1 / fps) }
                playbackRate += (advance / max(elapsed, 1e-3) - playbackRate) * min(1, elapsed * 2)
            } else {
                followRate = 1
                playbackRate = 1
            }
            clock = min(clock + advance, Double(head) / fps)
            let next = min(eventFrames - 1, Int(clock * fps + 1e-6))
            if next >= eventFrames - 1 { playing = false }
            if next > frame { frame = next }
        }
        frame = min(frame, head)
        let bodies = cache.bodies
        if decoded != frame {
            previousFrame = decoded
            previous.contents().copyMemory(from: pose.contents(), byteCount: 32 * bodies)
            cache.decode(
                frame: frame, into: pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies))
            if frame == decoded + 1 {
                renderer.stepDecor(pose: pose, previous: previous, time: Float(frame) / Self.frameRate)
            }
            decoded = frame
        }
        guard let dust else { return }
        // The dust runs forward only: back, or far ahead past a stored field, it starts again from
        // the nearest field on disk at or before the frame.
        if dustFrame > frame
            || (frame - dustFrame > Self.keyEvery * 2 && hasKey(after: dustFrame, upTo: frame))
        {
            var k = min(keyStored.count - 1, frame / Self.keyEvery)
            while k > 0, !keyStored[k] { k -= 1 }
            if (try? dust.load(from: keyURL(k, generation: generation))) != nil {
                dustFrame = k * Self.keyEvery
            }
        }
        var budget = catchUpSteps
        while dustFrame < frame, budget > 0 {
            dustFrame += 1
            // Catching up to the shown frame from the one before: those poses are decoded already.
            let shown = dustFrame == frame && previousFrame == frame - 1
            if !shown {
                cache.decode(
                    frame: dustFrame - 1,
                    into: dustPrevious.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies))
                cache.decode(
                    frame: dustFrame,
                    into: dustPose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies))
            }
            _ = dust.step(
                pose: shown ? pose : dustPose, previous: shown ? previous : dustPrevious, bodies: bodies,
                time: Float(dustFrame) / Self.frameRate, restSize: restSizes, frameRate: Self.frameRate)
            budget -= 1
            let k = dustFrame / Self.keyEvery
            if dustFrame % Self.keyEvery == 0, k < keyStored.count, !keyStored[k] {
                keyStored[k] = (try? dust.save(to: keyURL(k, generation: generation))) != nil
            }
        }
    }

    /// The solver's rate against real time, from the frames it stores, smoothed over about a second.
    private func measureSolver(_ available: Int) {
        let now = Date()
        guard let sample = solverSample else {
            solverSample = (now, available)
            return
        }
        let span = now.timeIntervalSince(sample.time)
        guard span >= 0.25 else { return }
        let rate = Double(available - sample.frames) / Double(Self.frameRate) / span
        solverRate += (rate - solverRate) * min(1, span)
        solverSample = (now, available)
    }

    /// Whether a stored field lies past `start` and at or before `end`: a jump forward worth taking.
    private func hasKey(after start: Int, upTo end: Int) -> Bool {
        let last = min(keyStored.count - 1, end / Self.keyEvery)
        guard start / Self.keyEvery + 1 <= last else { return false }
        return (start / Self.keyEvery + 1...last).contains { keyStored[$0] }
    }

    /// The orbit's eye, kept above the ground, and the camera's field (as a 16:9 clip has it).
    public func view() -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float) {
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
        var eye = focus + direction * distance
        eye.z = max(eye.z, face.height(face.terrain.heights, eye.x, eye.y) + 2)
        return (eye, focus, fovDegrees * .pi / 180)
    }

    /// The frame's size for a view `pixels` across and up: the view's own shape, with no more pixels
    /// than `framePixels` nor than the view has; whole multiples of 8, so small changes in the view
    /// keep the frame.
    public static func frameSize(view pixels: SIMD2<Int>) -> SIMD2<Int> {
        let w = Double(max(1, pixels.x))
        let h = Double(max(1, pixels.y))
        let scale = min(1, (Double(framePixels) / (w * h)).squareRoot())
        func down8(_ v: Double) -> Int { max(8, Int(v / 8) * 8) }
        return SIMD2(down8(w * scale), down8(h * scale))
    }

    /// The vertical field (radians) of a view of `aspect` (width over height) for the camera's
    /// `fovY`: `fovY` itself for a view at least as wide as `fieldAspect`, else wider, keeping that
    /// shape's width of field.
    public static func fieldOfView(_ fovY: Float, aspect: Float) -> Float {
        guard aspect > 0, aspect < fieldAspect else { return fovY }
        return 2 * atan(tan(fovY / 2) * fieldAspect / aspect)
    }

    /// The orbit's view as a view of `aspect` shows it (see `fieldOfView`).
    public func view(aspect: Float) -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float) {
        let v = view()
        return (v.eye, v.target, Self.fieldOfView(v.fovY, aspect: aspect))
    }

    /// Fits the frame to a view of `aspect` (its width over height) and `pixels` (its drawable's
    /// size). The projection takes the view's shape at once. The frame is made again at the view's
    /// shape (`frameSize`) once the size it asks for has held for `resizeSettle`, or at once the first
    /// time: while a window is resized its frame is drawn at the size it has and stretched back to
    /// the view's shape, rather than its targets being made each frame. Returns whether it was made
    /// again.
    @discardableResult
    public func fit(
        aspect: Float, pixels: SIMD2<Int>, now: Double = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard aspect.isFinite, aspect > 0, pixels.x > 0, pixels.y > 0 else { return false }
        renderer.aspect = aspect
        let size = Self.frameSize(view: pixels)
        guard size != SIMD2(renderer.width, renderer.height) else {
            wantedSize = nil
            fitted = true
            return false
        }
        if wantedSize?.size != size { wantedSize = (size, now) }
        guard !fitted || now - (wantedSize?.since ?? now) >= Self.resizeSettle else { return false }
        renderer.resize(width: size.x, height: size.y)
        renderer.aspect = aspect
        wantedSize = nil
        fitted = true
        return true
    }

    /// The point on the ground under a view ray through `ndc` (x and y in -1...1, y up), in the
    /// strip's frame; nil when the ray misses the ground.
    public func groundPoint(ndc: SIMD2<Float>, aspect: Float) -> SIMD3<Float>? {
        let v = view(aspect: aspect)
        let forward = simd_normalize(v.target - v.eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let t = tan(v.fovY / 2)
        let ray = simd_normalize(forward + right * ndc.x * t * aspect + up * ndc.y * t)
        var p = v.eye
        let step: Float = 0.5
        for _ in 0..<4000 {
            p += ray * step
            let ground = face.height(face.original, p.x, p.y)
            if p.z <= ground { return SIMD3(p.x, p.y, ground) }
        }
        return nil
    }

    /// Draws the current frame to the renderer's target; returns the GPU time (s).
    @discardableResult
    public func draw() -> Double {
        renderer.viewOverride = view(aspect: renderer.aspect)
        return renderer.render(pose: pose, previous: previous, time: Float(frame) / Self.frameRate)
    }

    /// Scales the frame over a drawable: the frame has the view's shape, or the projection does while
    /// the view's size settles.
    public func blit(to drawable: MTLTexture, buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(present)
        encoder.setFragmentTexture(renderer.output, index: 0)
        encoder.setFragmentSamplerState(presentSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The poses of the frame shown, for checks: pairs of float4 per block.
    public var shownPoses: [SIMD4<Float>] {
        let count = 2 * face.blocks.count
        return Array(
            UnsafeBufferPointer(
                start: pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: count), count: count))
    }

    /// Memory held, by part (bytes): the pose cache, the dust fields, dust kept on disk, and
    /// everything Metal has allocated.
    public var memory: (poses: Int, dustFields: Int, dustOnDisk: Int, metal: Int) {
        let stored = keyStored.filter { $0 }.count
        return (
            (cache?.bytes ?? 0) + (pending?.cache?.bytes ?? 0),
            (dust?.bytes ?? 0) + (pendingDust?.bytes ?? 0),
            stored * (dust?.storedBytes ?? 0), device.currentAllocatedSize
        )
    }

    public var memoryReport: String {
        let m = memory
        return String(
            format: "poses %d MB, dust fields %d MB, dust on disk %d MB, Metal allocated %d MB",
            m.poses >> 20,
            m.dustFields >> 20, m.dustOnDisk >> 20, m.metal >> 20)
    }
}
