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

/// A quarry face to play with: fired in the background, replayed and scrubbed from a packed pose
/// cache, its dust run forward from fields kept on disk, drawn by `QuarryRenderer`. Used from the
/// main thread; firing runs on its own queue and hands the new event back whole. Illustrative.
public final class QuarrySession: @unchecked Sendable {
    public static let frameRate: Float = 30
    public static let substeps = 8
    /// The window's dust cells (m); the film's are 1 m.
    public static let dustGrid: Float = 1.5
    /// Frames between dust fields kept on disk.
    public static let keyEvery = 30
    /// While the physics runs, the view draws at this rate and leaves the GPU to it.
    public static let firingDrawRate = 15
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

    public private(set) var cache: QuarryPoseCache?
    public private(set) var dust: QuarryDustField?
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

    /// The orbit: about `focus`, at `distance`, `yaw` round and `pitch` up (radians).
    public var yaw: Float = -0.81
    public var pitch: Float = -0.086
    public var distance: Float = 143
    public var focus: SIMD3<Float>
    public var fovDegrees: Float = 32

    public private(set) var refireProgress: Float?
    public private(set) var refireStatus = ""
    public private(set) var lastRefireSeconds: Double?
    public var onRefireDone: (() -> Void)?

    /// `face` generated (with `meshDetail` 1 for a window); `keyDirectory` for the dust fields.
    public init(
        device: MTLDevice, face: QuarryFace, width: Int, height: Int, keyDirectory: URL, seconds: Float = 20
    ) throws {
        self.device = device
        self.face = face
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
        // The default view: from the floor in front of the strip's near end, toward its middle.
        let scale = face.length / 180
        focus = SIMD3(68 * scale, 15, face.floorLevel + 21)
        distance = 143 * max(1, scale * 0.85)
    }

    deinit { try? FileManager.default.removeItem(at: keyDirectory) }

    public var firings: [QuarryFiring] {
        QuarryFiringPattern.row(
            face: face, count: settings.count, first: 1.8, stagger: settings.stagger,
            order: settings.order)
    }

    public var eventSeconds: Float { Float(eventFrames - 1) / Self.frameRate }
    public var isReady: Bool { cache?.filled == eventFrames }

    private func keyURL(_ k: Int, generation g: Int) -> URL {
        keyDirectory.appendingPathComponent("dust-\(g)-\(k).bin")
    }

    /// Runs the physics again with the current settings on a background queue. The view goes on
    /// drawing the old event until the new one is ready, and then takes it whole. The dust is made
    /// as playback first passes each second.
    public func refire() {
        guard refireProgress == nil else { return }
        refireProgress = 0
        refireStatus = "Firing…"
        let firings = self.firings
        let started = Date()
        let face = self.face
        let launch = self.launch
        let device = self.device
        let eventFrames = self.eventFrames
        let sun = SIMD3(renderer.camera.sun.x, renderer.camera.sun.y, renderer.camera.sun.z)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let simulation = try QuarrySimulation(
                    device: device, face: face, launch: launch, firings: firings,
                    dt: 1 / (Self.frameRate * Float(Self.substeps)))
                let pointer = simulation.pose.contents().bindMemory(
                    to: SIMD4<Float>.self, capacity: 2 * simulation.bodyCount)
                let rest = Array(UnsafeBufferPointer(start: pointer, count: 2 * simulation.bodyCount))
                let cache = QuarryPoseCache(
                    rest: rest, still: face.blocks.map(\.skin), frames: eventFrames, low: face.low,
                    high: face.high)
                let dust = try QuarryDustField(
                    device: device, face: face, firings: firings, sun: sun, gridSize: Self.dustGrid)
                cache.store(frame: 0, pose: pointer)
                for f in 1..<eventFrames {
                    simulation.advance(substeps: Self.substeps)
                    cache.store(frame: f, pose: pointer)
                    if f % 10 == 0 {
                        let share = Float(f) / Float(eventFrames)
                        DispatchQueue.main.async { self?.refireProgress = share }
                    }
                }
                let seconds = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let old = self.generation
                    for k in self.keyStored.indices where self.keyStored[k] {
                        try? FileManager.default.removeItem(at: self.keyURL(k, generation: old))
                    }
                    self.generation += 1
                    self.cache = cache
                    self.dust = dust
                    self.keyStored = Array(repeating: false, count: (eventFrames - 1) / Self.keyEvery + 1)
                    if (try? dust.save(to: self.keyURL(0, generation: self.generation))) != nil {
                        self.keyStored[0] = true
                    }
                    self.renderer.dust = dust
                    self.dustFrame = 0
                    self.lastRefireSeconds = seconds
                    self.refireProgress = nil
                    self.refireStatus = String(format: "Fired in %.1f s", seconds)
                    self.renderer.resetDecor()
                    self.decoded = -1
                    self.seek(to: 0)
                    self.playing = true
                    self.clock = 0
                    self.onRefireDone?()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.refireProgress = nil
                    self?.refireStatus = "Firing failed: \(error)"
                }
            }
        }
    }

    public func seek(to target: Int) {
        let target = max(0, min(eventFrames - 1, target))
        if target < frame { renderer.resetDecor() }
        frame = target
        clock = Double(target) / Double(Self.frameRate)
    }

    /// Advances playback by `elapsed` wall seconds, updates the poses for the shown frame, and
    /// brings the dust toward it.
    public func update(elapsed: Double) {
        guard let cache, cache.filled == eventFrames else { return }
        if playing {
            clock += elapsed
            let next = min(eventFrames - 1, Int(clock * Double(Self.frameRate)))
            if next >= eventFrames - 1 { playing = false }
            if next != frame { frame = next }
        }
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

    /// Whether a stored field lies past `start` and at or before `end`: a jump forward worth taking.
    private func hasKey(after start: Int, upTo end: Int) -> Bool {
        let last = min(keyStored.count - 1, end / Self.keyEvery)
        guard start / Self.keyEvery + 1 <= last else { return false }
        return (start / Self.keyEvery + 1...last).contains { keyStored[$0] }
    }

    /// The orbit's eye, kept above the ground.
    public func view() -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float) {
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
        var eye = focus + direction * distance
        eye.z = max(eye.z, face.height(face.terrain.heights, eye.x, eye.y) + 2)
        return (eye, focus, fovDegrees * .pi / 180)
    }

    /// The point on the ground under a view ray through `ndc` (x and y in -1...1, y up), in the
    /// strip's frame; nil when the ray misses the ground.
    public func groundPoint(ndc: SIMD2<Float>, aspect: Float) -> SIMD3<Float>? {
        let v = view()
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
        renderer.viewOverride = view()
        return renderer.render(pose: pose, previous: previous, time: Float(frame) / Self.frameRate)
    }

    /// Scales the frame into a drawable.
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
            cache?.bytes ?? 0, dust?.bytes ?? 0, stored * (dust?.storedBytes ?? 0),
            device.currentAllocatedSize
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
