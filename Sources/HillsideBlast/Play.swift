import AppKit
import BlastModel
import BlastRender
import Foundation
import Metal
import MetalKit
import simd

// The play window: orbit, scrub, change the firing order and spacing, refire. Experimental, and
// illustrative like the rest of `hillsideblast`: the firings are a stylised ripple for the eye.

/// The app's view: the session's frame, orbit by dragging, zoom by scrolling.
final class PlayMetalView: MTKView {
    weak var session: QuarrySession?
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
    static func run(arguments: [String], options: QuarryFace.Options, device: MTLDevice, dataRoot: URL) throws
    {
        print("Illustrative only: a stylised ripple for the eye, not a blast-design aid.")
        var settings = options
        settings.meshDetail = 1
        var live = try QuarryFace(site: .builtIn(), options: settings)
        live.generate()
        live.buildDressing(level: 1)
        let session = try QuarrySession(
            device: device, face: live, width: 1600, height: 900,
            keyDirectory: dataRoot.appendingPathComponent(
                "play-dust-\(ProcessInfo.processInfo.processIdentifier)"))
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
    let session: QuarrySession
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

    init(session: QuarrySession) {
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
        window.title = "QuarryFace (illustrative: not a blast-design aid)"
        window.delegate = self

        timeline.target = self
        timeline.action = #selector(timelineMoved)
        timeline.isContinuous = true
        playButton.target = self
        playButton.action = #selector(togglePlay)
        for order in QuarryFiringOrder.allCases { orderPopup.addItem(withTitle: order.rawValue) }
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
        session.settings.order = QuarryFiringOrder.allCases[max(0, orderPopup.indexOfSelectedItem)]
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
        view.preferredFramesPerSecond = session.refireProgress == nil ? 60 : QuarrySession.firingDrawRate
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
        let seconds = Float(session.frame) / QuarrySession.frameRate
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
    let session: QuarrySession
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
    var random = QuarryRandom(seed: 9)
    var shots: Set<Int> = []
    var memory: [String] = []

    init(session: QuarrySession, output: URL, present: MTKView?) {
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
                session.settings = QuarryFiringSettings(order: .centreOut, stagger: 0.06, count: 22)
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
        try? FileManager.default.removeItem(at: session.keyDirectory)
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
                Thread.sleep(forTimeInterval: 1.0 / Double(QuarrySession.firingDrawRate))
            }
        }
    }
}
