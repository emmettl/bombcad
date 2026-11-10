import AppKit
import Foundation
import Metal
import MetalKit
import simd

// The play window: orbit, scrub, change the firing order and spacing, refire. Experimental, and
// illustrative like the rest of `hillsideblast`: the firings are a stylised ripple for the eye.

/// The event's poses, packed: position as three floats and the orientation as smallest-three in
/// 10:10:10:2, so 16 bytes a block a frame. A block's release frame is kept apart.
final class PoseCache {
    let bodies: Int
    let capacity: Int
    let storage: UnsafeMutablePointer<UInt32>
    var release: [UInt16]
    private(set) var filled = 0
    var bytes: Int { capacity * bodies * 16 + bodies * 2 }

    init(bodies: Int, frames: Int) {
        self.bodies = bodies
        capacity = frames
        storage = UnsafeMutablePointer<UInt32>.allocate(capacity: frames * bodies * 4)
        release = Array(repeating: UInt16.max, count: bodies)
    }
    deinit { storage.deallocate() }

    private static func pack(_ q: SIMD4<Float>) -> UInt32 {
        var largest = 0
        for i in 1..<4 where abs(q[i]) > abs(q[largest]) { largest = i }
        let sign: Float = q[largest] < 0 ? -1 : 1
        var word = UInt32(largest) << 30
        var shift: UInt32 = 20
        for i in 0..<4 where i != largest {
            let v = (q[i] * sign * 0.7072 + 0.5)
            word |= UInt32(max(0, min(1023, v * 1023 + 0.5))) << shift
            shift = shift &- 10
        }
        return word
    }

    private static func unpack(_ word: UInt32) -> SIMD4<Float> {
        let largest = Int(word >> 30)
        var q = SIMD4<Float>(repeating: 0)
        var sum: Float = 0
        var shift: UInt32 = 20
        for i in 0..<4 where i != largest {
            let v = (Float((word >> shift) & 1023) / 1023 - 0.5) / 0.7072
            q[i] = v
            sum += v * v
            shift = shift &- 10
        }
        q[largest] = sqrt(max(0, 1 - sum))
        return q
    }

    /// Stores frame `f` from `pose` (pairs of float4, w the block's state).
    func store(frame f: Int, pose: UnsafePointer<SIMD4<Float>>) {
        nonisolated(unsafe) let out = storage + f * bodies * 4
        nonisolated(unsafe) let input = pose
        let chunk = 8192
        let count = bodies
        DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { c in
            for n in (c * chunk)..<min(count, (c + 1) * chunk) {
                let p = input[2 * n]
                out[4 * n] = p.x.bitPattern
                out[4 * n + 1] = p.y.bitPattern
                out[4 * n + 2] = p.z.bitPattern
                out[4 * n + 3] = Self.pack(input[2 * n + 1])
            }
        }
        for n in 0..<count where release[n] == UInt16.max && pose[2 * n].w >= 0.5 { release[n] = UInt16(f) }
        filled = max(filled, f + 1)
    }

    /// Unpacks frame `f` into `pose`.
    func decode(frame f: Int, into pose: UnsafeMutablePointer<SIMD4<Float>>) {
        let input = UnsafePointer(storage + f * bodies * 4)
        let count = bodies
        let released = release
        nonisolated(unsafe) let target = pose
        let chunk = 8192
        DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { c in
            for n in (c * chunk)..<min(count, (c + 1) * chunk) {
                let w: Float = released[n] != UInt16.max && Int(released[n]) <= f ? 1 : 0
                target[2 * n] = SIMD4(
                    Float(bitPattern: input[4 * n]), Float(bitPattern: input[4 * n + 1]),
                    Float(bitPattern: input[4 * n + 2]), w)
                target[2 * n + 1] = Self.unpack(input[4 * n + 3])
            }
        }
    }
}

struct FiringSettings: Equatable {
    var order: FiringOrder = .leftToRight
    /// Time between one firing and the next in the order (s).
    var stagger: Float = 0.1
    /// Firings along the row; fewer means further apart.
    var count = 16
}

/// Everything the window shows, and the same object the self-test drives.
final class PlaySession {
    static let frameRate: Float = 30
    static let substeps = 8
    static let dustGrid: Float = 1.5
    /// Frames between stored dust fields.
    static let keyEvery = 30
    static let firingDrawRate = 15
    let eventFrames = 601
    let width = 1600
    let height = 900

    let device: MTLDevice
    let hillside: Hillside
    let library: MTLLibrary
    let dustLibrary: MTLLibrary
    let renderer: Renderer
    let restSizes: [Float]
    let launch = Launch()
    let pose: MTLBuffer
    let previous: MTLBuffer
    let dustPose: MTLBuffer
    let dustPrevious: MTLBuffer
    let present: MTLRenderPipelineState
    let presentSampler: MTLSamplerState

    var cache: PoseCache?
    var dust: DustField?
    var keys: [DustField.Keyframe?] = []
    var settings = FiringSettings()
    private(set) var frame = 0
    private(set) var dustFrame = 0
    private var decoded = -1
    /// The frame `previous` holds.
    private var previousFrame = -1
    var playing = false
    /// Dust steps a drawn frame may spend catching up after a scrub.
    var catchUpSteps = 4
    private var clock = 0.0

    var yaw: Float = -0.81
    var pitch: Float = -0.086
    var distance: Float = 143
    var focus = SIMD3<Float>(68, 15, 21)
    var fovDegrees: Float = 32

    var refireProgress: Float?
    var refireStatus = ""
    private(set) var lastRefireSeconds: Double?
    var onRefireDone: (() -> Void)?

    init(device: MTLDevice, hillside: Hillside) throws {
        self.device = device
        self.hillside = hillside
        func compile(_ file: String) throws -> MTLLibrary {
            let options = MTLCompileOptions()
            options.languageVersion = .version3_1
            let url = Bundle.module.url(forResource: file, withExtension: "metal")!
            return try device.makeLibrary(
                source: try String(contentsOf: url, encoding: .utf8), options: options)
        }
        library = try compile("Hillside")
        dustLibrary = try compile("HillsideDust")
        let path = CameraPath(
            eyes: (.zero, SIMD3(0, 1, 0)), targets: (SIMD3(0, 1, 0), .zero), fovY: (36, 36), duration: 20)
        renderer = try Renderer(
            device: device, library: library, hillside: hillside, width: 1600, height: 900, supersample: 1,
            path: path,
            frameRate: Self.frameRate, quality: .live)
        restSizes = hillside.blocks.map(\.size)
        let bodies = hillside.blocks.count
        pose = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        previous = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        dustPose = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        dustPrevious = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        let rest = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        for (n, block) in hillside.blocks.enumerated() {
            rest[2 * n] = SIMD4(block.centre, 0)
            rest[2 * n + 1] = SIMD4(0, 0, 0, 1)
        }
        previous.contents().copyMemory(from: pose.contents(), byteCount: 32 * bodies)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen")!
        d.fragmentFunction = library.makeFunction(name: "presentFragment")!
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        present = try device.makeRenderPipelineState(descriptor: d)
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        presentSampler = device.makeSamplerState(descriptor: sampler)!
    }

    var firings: [Firing] {
        FiringPattern.row(
            hillside: hillside, count: settings.count, first: 1.8, stagger: settings.stagger,
            order: settings.order)
    }

    var eventSeconds: Float { Float(eventFrames - 1) / Self.frameRate }

    /// Runs the physics and the dust again with the current settings, on a background queue. The
    /// window goes on drawing the old event until the new one is ready, and then takes it whole.
    func refire() {
        guard refireProgress == nil else { return }
        refireProgress = 0
        refireStatus = "Firing…"
        let firings = self.firings
        let started = Date()
        let hillside = self.hillside
        let launch = self.launch
        let device = self.device
        let library = self.library
        let dustLibrary = self.dustLibrary
        let eventFrames = self.eventFrames
        let sun = SIMD3(renderer.camera.sun.x, renderer.camera.sun.y, renderer.camera.sun.z)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let simulation = try BlockSimulation(
                    device: device, library: library, hillside: hillside, launch: launch, firings: firings,
                    dt: 1 / (Self.frameRate * Float(Self.substeps)))
                let cache = PoseCache(bodies: simulation.bodyCount, frames: eventFrames)
                let dust = try DustField(
                    device: device, library: dustLibrary, hillside: hillside, firings: firings, width: 1600,
                    height: 900,
                    sun: sun, gridSize: Self.dustGrid)
                let pointer = simulation.pose.contents().bindMemory(
                    to: SIMD4<Float>.self, capacity: 2 * simulation.bodyCount)
                cache.store(frame: 0, pose: pointer)
                var keys = [DustField.Keyframe?](repeating: nil, count: (eventFrames - 1) / Self.keyEvery + 1)
                let key = DustField.Keyframe(device: device, like: dust)
                dust.store(into: key)
                keys[0] = key
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
                    self.cache = cache
                    self.dust = dust
                    self.keys = keys
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
                    self?.refireStatus = "Refire failed: \(error)"
                }
            }
        }
    }

    func seek(to target: Int) {
        let target = max(0, min(eventFrames - 1, target))
        if target < frame { renderer.resetDecor() }
        frame = target
        clock = Double(target) / Double(Self.frameRate)
    }

    /// Advances playback by `elapsed` wall seconds, brings the dust toward the shown frame, and
    /// updates the poses for it.
    func update(elapsed: Double) {
        guard let cache, cache.filled == eventFrames else { return }
        if playing {
            clock += elapsed
            let next = min(eventFrames - 1, Int(clock * Double(Self.frameRate)))
            if next >= eventFrames - 1 { playing = false }
            if next != frame { frame = next }
        }
        if decoded != frame {
            previousFrame = decoded
            let bodies = cache.bodies
            previous.contents().copyMemory(from: pose.contents(), byteCount: 32 * bodies)
            cache.decode(
                frame: frame, into: pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies))
            if frame == decoded + 1 {
                renderer.stepDecor(pose: pose, previous: previous, time: Float(frame) / Self.frameRate)
            }
            decoded = frame
        }
        // The dust runs forward only: from the nearest stored field before the frame.
        if let dust {
            if dustFrame > frame
                || (frame - dustFrame > Self.keyEvery * 2 && hasKey(after: dustFrame, upTo: frame))
            {
                // The dust runs forward: the nearest stored field at or before the frame.
                var k = min(keys.count - 1, frame / Self.keyEvery)
                while k > 0, keys[k] == nil { k -= 1 }
                if let key = keys[k] {
                    dust.restore(from: key)
                    dustFrame = k * Self.keyEvery
                }
            }
            var budget = catchUpSteps
            while dustFrame < frame, budget > 0 {
                dustFrame += 1
                let bodies = cache.bodies
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
                    time: Float(dustFrame) / Self.frameRate,
                    restSize: restSizes, frameRate: Self.frameRate)
                budget -= 1
                let k = dustFrame / Self.keyEvery
                if dustFrame % Self.keyEvery == 0, k < keys.count, keys[k] == nil {
                    let key = DustField.Keyframe(device: device, like: dust)
                    dust.store(into: key)
                    keys[k] = key
                }
            }
        }
    }

    /// Whether a stored field lies past `start` and at or before `end`: a jump forward worth taking.
    private func hasKey(after start: Int, upTo end: Int) -> Bool {
        let last = min(keys.count - 1, end / Self.keyEvery)
        guard start / Self.keyEvery + 1 <= last else { return false }
        return (start / Self.keyEvery + 1...last).contains { keys[$0] != nil }
    }

    func view() -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float) {
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
        var eye = focus + direction * distance
        eye.z = max(eye.z, hillside.height(hillside.terrain.heights, eye.x, eye.y) + 2)
        return (eye, focus, fovDegrees * .pi / 180)
    }

    /// Draws the current frame to the offscreen target; returns the GPU time (s).
    @discardableResult
    func draw() -> Double {
        renderer.viewOverride = view()
        return renderer.render(pose: pose, previous: previous, time: Float(frame) / Self.frameRate)
    }

    /// Scales the offscreen frame into a drawable.
    func blit(to drawable: MTLTexture, buffer: MTLCommandBuffer) {
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

    var memoryReport: String {
        let poses = cache?.bytes ?? 0
        let keyBytes = keys.compactMap { $0 }.reduce(0) { $0 + $1.bytes }
        let fields = dust?.bytes ?? 0
        return String(
            format: "poses %d MB, dust keyframes %d MB (%d), dust fields %d MB, Metal allocated %d MB",
            poses >> 20, keyBytes >> 20, keys.compactMap { $0 }.count, fields >> 20,
            device.currentAllocatedSize >> 20)
    }
}

/// The app's view: the session's frame, orbit by dragging, zoom by scrolling.
final class PlayMetalView: MTKView {
    weak var session: PlaySession?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDragged(with event: NSEvent) {
        guard let session else { return }
        if event.modifierFlags.contains(.shift) {
            let right = SIMD3<Float>(cos(session.yaw), sin(session.yaw), 0)
            let scale = session.distance * 0.0016
            session.focus += right * Float(-event.deltaX) * scale + SIMD3(0, 0, Float(event.deltaY) * scale)
        } else {
            session.yaw += Float(event.deltaX) * 0.005
            session.pitch = max(-0.2, min(1.3, session.pitch + Float(event.deltaY) * 0.004))
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        session.distance = max(25, min(600, session.distance * (1 - Float(event.scrollingDeltaY) * 0.01)))
    }
}

enum PlayApp {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }

    @MainActor static var controller: PlayController?

    @MainActor
    static func run(arguments: [String], hillside: inout Hillside, device: MTLDevice, dataRoot: URL) throws {
        print("Illustrative only: a stylised ripple for the eye, not a blast-design aid.")
        var live = Hillside(options: hillside.options)
        live.options.meshDetail = 1
        live.generate()
        live.buildDressing(level: 1)
        let session = try PlaySession(device: device, hillside: live)
        let selfTest = option(arguments, "--self-test")
        if let selfTest, arguments.contains("--offscreen") {
            let test = PlayTest(
                session: session, output: dataRoot.appendingPathComponent(selfTest), present: nil)
            try test.runOffscreen()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(selfTest == nil ? .regular : .accessory)
        let controller = PlayController(session: session)
        Self.controller = controller
        controller.show(activate: selfTest == nil)
        if let selfTest {
            controller.test = PlayTest(
                session: session, output: dataRoot.appendingPathComponent(selfTest),
                present: controller.metalView)
            // Behind other windows the view's own display link stops: drive its draw from a timer.
            controller.metalView.isPaused = true
            controller.metalView.enableSetNeedsDisplay = false
            let view = controller.metalView
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in view.draw() }
            // If nothing draws (a locked or sleeping display), give up rather than hang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                print("self-test watchdog: \(controller.test?.phaseName ?? "?") after 300 s, stopping")
                NSApp.terminate(nil)
            }
        }
        session.refire()
        app.run()
    }
}

/// The window and its controls.
final class PlayController: NSObject, MTKViewDelegate, NSWindowDelegate {
    let session: PlaySession
    let metalView: PlayMetalView
    let queue: MTLCommandQueue
    var window: NSWindow!
    let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let playButton = NSButton(title: "Play", target: nil, action: nil)
    let orderPopup = NSPopUpButton()
    let staggerSlider = NSSlider(value: 100, minValue: 20, maxValue: 400, target: nil, action: nil)
    let countSlider = NSSlider(value: 16, minValue: 6, maxValue: 30, target: nil, action: nil)
    let fireButton = NSButton(title: "Fire again", target: nil, action: nil)
    let progress = NSProgressIndicator()
    let status = NSTextField(labelWithString: "")
    /// The live frame time, over the view: the interval between frames and the work in each.
    let readout = NSTextField(labelWithString: "")
    var interval = 0.0
    var workTime = 0.0
    let staggerLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    var last = Date()
    var fps = 0.0
    var scrubbing = false
    var test: PlayTest?

    init(session: PlaySession) {
        self.session = session
        metalView = PlayMetalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), device: session.device)
        queue = session.device.makeCommandQueue()!
        super.init()
        metalView.session = session
        metalView.delegate = self
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.preferredFramesPerSecond = 60
    }

    func show(activate: Bool) {
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1280, height: 790),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Hillside (illustrative: not a blast-design aid)"
        window.delegate = self

        timeline.target = self
        timeline.action = #selector(timelineMoved)
        timeline.isContinuous = true
        playButton.target = self
        playButton.action = #selector(togglePlay)
        for order in FiringOrder.allCases { orderPopup.addItem(withTitle: order.rawValue) }
        orderPopup.target = self
        orderPopup.action = #selector(settingChanged)
        staggerSlider.target = self
        staggerSlider.action = #selector(settingChanged)
        countSlider.target = self
        countSlider.action = #selector(settingChanged)
        countSlider.numberOfTickMarks = 25
        countSlider.allowsTickMarkValuesOnly = true
        fireButton.target = self
        fireButton.action = #selector(fire)
        fireButton.keyEquivalent = "\r"
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        status.lineBreakMode = .byTruncatingTail
        settingChanged()

        let top = NSStackView(views: [playButton, timeline])
        top.orientation = .horizontal
        top.spacing = 10
        func labelled(_ text: String, _ control: NSView, _ value: NSTextField? = nil) -> NSStackView {
            let views = [NSTextField(labelWithString: text), control] + (value.map { [$0] } ?? [])
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 6
            return stack
        }
        staggerSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        countSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        staggerLabel.widthAnchor.constraint(equalToConstant: 55).isActive = true
        countLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let bottom = NSStackView(views: [
            labelled("Order", orderPopup), labelled("Ripple", staggerSlider, staggerLabel),
            labelled("Firings", countSlider, countLabel), fireButton, progress, status,
        ])
        bottom.orientation = .horizontal
        bottom.spacing = 14
        let controls = NSStackView(views: [top, bottom])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        controls.translatesAutoresizingMaskIntoConstraints = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(metalView)
        readout.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        readout.textColor = .white
        readout.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        readout.drawsBackground = true
        readout.translatesAutoresizingMaskIntoConstraints = false
        metalView.addSubview(readout)
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: content.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -24),
            readout.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 8),
            readout.leadingAnchor.constraint(equalTo: metalView.leadingAnchor, constant: 8),
        ])
        window.contentView = content
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderBack(nil)
        }
    }

    @objc func timelineMoved() {
        session.playing = false
        session.seek(to: Int(timeline.doubleValue * Double(session.eventFrames - 1)))
        scrubbing = true
    }

    @objc func togglePlay() {
        session.playing.toggle()
        if session.playing, session.frame >= session.eventFrames - 1 { session.seek(to: 0) }
    }

    @objc func settingChanged() {
        session.settings.order = FiringOrder.allCases[max(0, orderPopup.indexOfSelectedItem)]
        session.settings.stagger = staggerSlider.floatValue / 1000
        session.settings.count = countSlider.integerValue
        staggerLabel.stringValue = "\(staggerSlider.integerValue) ms"
        countLabel.stringValue = "\(session.settings.count)"
    }

    @objc func fire() { session.refire() }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // While the physics runs, the window draws slowly and leaves the GPU to it.
        view.preferredFramesPerSecond = session.refireProgress == nil ? 60 : PlaySession.firingDrawRate
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        last = now
        fps = fps == 0 ? 1 / max(elapsed, 1e-3) : fps * 0.92 + 0.08 / max(elapsed, 1e-3)
        session.update(elapsed: elapsed)
        session.draw()
        if let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() {
            session.blit(to: drawable.texture, buffer: buffer)
            buffer.present(drawable)
            buffer.commit()
        }
        if !scrubbing, session.eventFrames > 1 {
            timeline.doubleValue = Double(session.frame) / Double(session.eventFrames - 1)
        }
        scrubbing = false
        playButton.title = session.playing ? "Pause" : "Play"
        progress.doubleValue = Double(session.refireProgress ?? 0)
        fireButton.isEnabled = session.refireProgress == nil
        let seconds = Float(session.frame) / PlaySession.frameRate
        status.stringValue = String(
            format: "%.1f s  %.0f fps  %@", seconds, fps,
            session.refireProgress != nil
                ? "firing \(Int((session.refireProgress ?? 0) * 100))%" : session.refireStatus)
        let work = Date().timeIntervalSince(now) * 1000
        interval = interval == 0 ? elapsed * 1000 : interval * 0.9 + elapsed * 100
        workTime = workTime == 0 ? work : workTime * 0.9 + work * 0.1
        readout.stringValue = String(
            format: " %5.1f ms  %3.0f fps   work %4.1f ms ", interval, 1000 / max(interval, 1e-3), workTime)
        test?.work(work)
        test?.tick(elapsed: elapsed)
    }
}

/// Scripted use of the session, measuring the loop the window really runs.
final class PlayTest {
    let session: PlaySession
    let output: URL
    weak var present: MTKView?
    enum Phase { case waiting, play, scrub, firing, after, done }
    var phase = Phase.waiting
    var phaseName: String { "\(phase)" }
    var frames: [Phase: [Double]] = [:]
    /// Each drawn frame's own work on the main thread (ms), apart from the wait for the next one.
    var works: [Phase: [Double]] = [:]
    func work(_ ms: Double) { works[phase, default: []].append(ms) }
    var ticks = 0
    var firstRefire: Double?
    var secondRefire: Double?
    let start = Date()
    var random = Random(seed: 9)
    var shots: Set<Int> = []
    var memory: [String] = []

    init(session: PlaySession, output: URL, present: MTKView?) {
        self.session = session
        self.output = output
        self.present = present
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        session.renderer.savePNG(output.appendingPathComponent(name + ".png"))
    }

    func tick(elapsed: Double) {
        switch phase {
        case .waiting:
            if session.refireProgress == nil, session.cache != nil {
                firstRefire = session.lastRefireSeconds
                memory.append(
                    "after first fire: \(session.memoryReport); footprint \(PlayApp.footprintMB()) MB")
                session.seek(to: 0)
                session.playing = true
                phase = .play
                ticks = 0
                print("first fire \(firstRefire ?? -1) s")
            }
        case .play:
            frames[.play, default: []].append(elapsed * 1000)
            ticks += 1
            if ticks == 90 { shot("play-a") }
            if ticks > 240 {
                session.playing = false
                phase = .scrub
                ticks = 0
                shot("play-b")
            }
        case .scrub:
            frames[.scrub, default: []].append(elapsed * 1000)
            ticks += 1
            session.yaw += 0.01
            session.seek(to: Int(random.float() * Float(session.eventFrames - 1)))
            if ticks > 150 {
                phase = .firing
                ticks = 0
                session.settings = FiringSettings(order: .centreOut, stagger: 0.06, count: 22)
                session.yaw = -0.81
                session.refire()
                session.onRefireDone = { [weak self] in
                    guard let self else { return }
                    self.secondRefire = self.session.lastRefireSeconds
                    self.memory.append(
                        "after refire: \(self.session.memoryReport); footprint \(PlayApp.footprintMB()) MB")
                    self.phase = .after
                    self.ticks = 0
                }
            }
        case .firing:
            frames[.firing, default: []].append(elapsed * 1000)
        case .after:
            frames[.after, default: []].append(elapsed * 1000)
            ticks += 1
            if ticks == 100 { shot("after-refire") }
            if ticks > 180 { finish() }
        case .done:
            break
        }
    }

    private func finish() {
        phase = .done
        func line(_ name: String, _ v: [Double]) -> String {
            String(
                format: "%@: %d frames, median %.1f ms (%.0f fps), p90 %.1f ms (%.0f fps), worst %.0f ms",
                name, v.count,
                percentile(v, 0.5), 1000 / percentile(v, 0.5), percentile(v, 0.9), 1000 / percentile(v, 0.9),
                v.max() ?? 0)
        }
        var report =
            "mode: \(present == nil ? "offscreen, no vsync" : "real window and drawables, behind other windows, paced by a 60 Hz timer")\n"
        report += String(format: "first fire %.1f s; refire %.1f s\n", firstRefire ?? -1, secondRefire ?? -1)
        report += line("playing", frames[.play] ?? []) + "\n"
        report += line("scrubbing and orbiting every frame", frames[.scrub] ?? []) + "\n"
        report += line("while refiring", frames[.firing] ?? []) + "\n"
        report += line("playing after refire", frames[.after] ?? []) + "\n"
        for (name, phase) in [("playing", Phase.play), ("scrubbing", .scrub), ("while refiring", .firing)] {
            if let v = works[phase], !v.isEmpty {
                report += String(
                    format: "main-thread work a frame, %@: median %.1f ms (ceiling %.0f fps), p90 %.1f ms\n",
                    name,
                    percentile(v, 0.5), 1000 / percentile(v, 0.5), percentile(v, 0.9))
            }
        }
        report += memory.joined(separator: "\n") + "\n"
        print(report)
        try? report.write(to: output.appendingPathComponent("loop.txt"), atomically: true, encoding: .utf8)
        if present != nil { NSApp.terminate(nil) }
    }

    /// The same loop as the window's, with nothing on screen and no vsync.
    func runOffscreen() throws {
        session.refire()
        var last = Date()
        while phase != .done {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0))
            let now = Date()
            let elapsed = now.timeIntervalSince(last)
            last = now
            session.update(elapsed: elapsed)
            session.draw()
            tick(elapsed: elapsed)
            if session.refireProgress != nil {
                Thread.sleep(forTimeInterval: 1.0 / Double(PlaySession.firingDrawRate))
            }
        }
    }
}
