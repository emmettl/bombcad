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
        let opened = Date()
        func open() throws -> QuarrySession {
            let session = try QuarrySession.prepare(
                device: device, site: .builtIn(playScene), options: settings,
                settings: QuarryFiringSettings(),
                width: 1600, height: 900,
                keyDirectory: dataRoot.appendingPathComponent(
                    "play-dust-\(ProcessInfo.processInfo.processIdentifier)"),
                timings: { print($0) }, progress: { _, _ in })
            session.follow()
            return session
        }
        let selfTest = option(arguments, "--self-test")
        if let selfTest, arguments.contains("--offscreen") {
            // The test alone holds the session, so a moved strip's scene replaces it in memory too.
            let test = PlayTest(
                session: try open(), output: dataRoot.appendingPathComponent(selfTest), present: nil)
            test.fired = opened
            test.shotTimes = (option(arguments, "--shots-at") ?? "").split(separator: ",").compactMap {
                Float($0)
            }.sorted()
            test.chipTrace = arguments.contains("--chip-trace")
            test.options = settings
            test.dataRoot = dataRoot
            try test.runOffscreen()
            return
        }
        let session = try open()
        let app = NSApplication.shared
        app.setActivationPolicy(selfTest == nil ? .regular : .accessory)
        let controller = PlayController(session: session)
        Self.controller = controller
        controller.show(activate: selfTest == nil)
        if let selfTest {
            controller.test = PlayTest(
                session: session, output: dataRoot.appendingPathComponent(selfTest),
                present: controller.metalView)
            controller.test?.fired = opened
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
        // Over what is simulated so far; the slider spans the whole event.
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
        // While the physics runs, the window draws no faster than the event and shares the GPU.
        view.preferredFramesPerSecond = session.preferredDrawRate
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
        progress.doubleValue = Double(session.availableFrames) / Double(session.eventFrames)
        let seconds = Float(session.frame) / QuarrySession.frameRate
        status.stringValue = String(
            format: "%.1f s  %.0f fps  %@", seconds, fps,
            session.refireProgress != nil ? "starting…" : session.playbackStatus)
        let work = Date().timeIntervalSince(now) * 1000
        interval = interval == 0 ? elapsed * 1000 : interval * 0.9 + elapsed * 100
        workTime = workTime == 0 ? work : workTime * 0.9 + work * 0.1
        readout.stringValue = String(
            format: " %5.1f ms  %3.0f fps   work %4.1f ms ", interval, 1000 / max(interval, 1e-3), workTime)
        test?.work(work)
        test?.tick(elapsed: elapsed)
    }
}

/// Scripted use of the session, measuring the loop the window really runs: the first firing and
/// a refire watched as they are simulated, scrubbing, and (offscreen) a new strip.
final class PlayTest {
    var session: QuarrySession
    let output: URL
    weak var present: MTKView?
    enum Phase { case waiting, follow, scrub, refire, refollow, strip, stripFollow, done }
    var phase = Phase.waiting
    var phaseName: String { "\(phase)" }
    /// Intervals between drawn frames (ms), by phase.
    var frames: [Phase: [Double]] = [:]
    /// Each drawn frame's own work on the main thread (ms), apart from the wait for the next one.
    var works: [Phase: [Double]] = [:]
    func work(_ ms: Double) {
        works[phase, default: []].append(ms)
        lastWork = ms
    }
    var ticks = 0
    var random = QuarryRandom(seed: 9)
    var memory: [String] = []
    var lines: [String] = []
    /// When the firing (or strip) being waited on was asked for, and the rest poses it starts from.
    var fired = Date()
    var rest: [SIMD3<Float>] = []
    var motionSeen = true
    var startedEvent: ObjectIdentifier?
    var lastFrame = 0
    var lastAdvance = Date()
    var stalls = 0
    var backward = 0
    var rates: [Double] = []
    var footprintPeak = 0
    var options = QuarryFace.Options()
    var dataRoot = URL(fileURLWithPath: "/tmp")
    var incoming: QuarrySession?
    var stripError: String?
    /// Each tick while following: when, the phase, the frame shown, frames stored, work, rate.
    var series = "seconds,phase,frame,available,work_ms,rate,update_ms,draw_ms\n"
    var lastWork = 0.0
    var lastParts = (update: 0.0, draw: 0.0)
    /// Event times (s) at which each followed event is captured, with its dust and without
    /// (`--shots-at`), for when the dust shows against the rock; and those not yet taken.
    var shotTimes: [Float] = []
    var shotsLeft: [Float] = []
    /// `--chip-trace`: the chips as they stood at the last frame traced, where each one last
    /// landed, and the counts by second of the event.
    var chipTrace = false
    var chipLast: [QuarryDecor.Chip] = []
    var chipLanded: [SIMD3<Float>] = []
    /// Whether each chip's fall began from rest: left lying where it was while what held it went.
    var chipFromRest: [Bool] = []
    var chipFrame = -1
    var chipLines: [String] = []
    var chipCounts:
        [Int: (
            drops: Int, relands: Int, dropHeight: Float, dropAcross: Float, vanished: Int, straight: Int,
            flying: Int
        )] =
            [:]

    init(session: QuarrySession, output: URL, present: MTKView?) {
        self.session = session
        self.output = output
        self.present = present
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        session.renderer.savePNG(output.appendingPathComponent(name + ".png"))
    }

    /// Reads the chips back each new frame: a chip that was lying (state 2) and falls again (state
    /// 1) is a drop; when it lands again, how far it fell and how far it went across meanwhile.
    private func traceChips(_ label: String) {
        guard chipTrace, session.frame != chipFrame else { return }
        let renderer = session.renderer
        let count = renderer.chipCount
        let chips = Array(
            UnsafeBufferPointer(
                start: renderer.chips.contents().bindMemory(to: QuarryDecor.Chip.self, capacity: count),
                count: count))
        if session.frame < chipFrame || chipLast.count != count {
            chipLast = chips
            chipLanded = Array(repeating: SIMD3(repeating: .nan), count: count)
            chipFromRest = Array(repeating: false, count: count)
            chipFrame = session.frame
            return
        }
        let second = Int(Float(session.frame) / QuarrySession.frameRate)
        var c = chipCounts[second] ?? (0, 0, 0, 0, 0, 0, 0)
        for i in 0..<count {
            let was = chipLast[i].state
            let now = chips[i].state
            let p = SIMD3(chips[i].posSize.x, chips[i].posSize.y, chips[i].posSize.z)
            if was == 2, now == 1 {
                c.drops += 1
                let v = chips[i].velAge
                chipFromRest[i] = simd_length(SIMD2(v.x, v.y)) < 0.5 && v.z > -1
                chipLanded[i] = SIMD3(chipLast[i].posSize.x, chipLast[i].posSize.y, chipLast[i].posSize.z)
            } else if was == 1, now == 2, !chipLanded[i].x.isNaN {
                c.relands += 1
                let from = chipLanded[i]
                c.dropHeight += from.z - p.z
                c.dropAcross += simd_length(SIMD2(p.x - from.x, p.y - from.y))
                chipLanded[i] = SIMD3(repeating: .nan)
            } else if was != 0, now == 0 {
                c.vanished += 1
            }
            if now == 1 {
                // Falling straight down: faster than 3 m/s down, slower than 0.5 m/s across.
                let v = chips[i].velAge
                c.flying += 1
                if chipFromRest[i], v.z < -3, simd_length(SIMD2(v.x, v.y)) < 0.5 { c.straight += 1 }
            }
        }
        chipCounts[second] = c
        chipLast = chips
        chipFrame = session.frame
        chipLabel = label
        if !session.isSimulating, !session.playing || session.frame >= session.eventFrames - 1 {
            flushChips()
        }
    }

    var chipLabel = ""
    private func flushChips() {
        for s in chipCounts.keys.sorted() {
            let v = chipCounts[s]!
            chipLines.append(
                String(
                    format:
                        "%@ chips, second %d: %d fall again from lying, %d land again (fell %.2f m, went %.2f m across, means), %d leave the box; in the air %d chip-frames, of which falling straight down from rest %d (%.1f%%)",
                    chipLabel, s, v.drops, v.relands, v.relands > 0 ? v.dropHeight / Float(v.relands) : 0,
                    v.relands > 0 ? v.dropAcross / Float(v.relands) : 0, v.vanished, v.flying, v.straight,
                    100 * Float(v.straight) / Float(max(1, v.flying))))
        }
        chipCounts = [:]
    }

    /// The frame as drawn, then again without its dust, at each of `shotTimes` the event passes.
    private func timedShots(_ label: String) {
        let shown = Float(session.frame) / QuarrySession.frameRate
        while let next = shotsLeft.first, shown >= next - 1e-4 {
            shotsLeft.removeFirst()
            let name = String(format: "%@-t%05.2f", label.replacingOccurrences(of: " ", with: "-"), shown)
            shot(name)
            let dust = session.renderer.dust
            session.renderer.dust = nil
            session.draw()
            shot(name + "-nodust")
            session.renderer.dust = dust
            session.draw()
            note(
                String(
                    format: "%@: shot at event %.2f s (asked %.2f), %.2f s after asking", label, shown, next,
                    Date().timeIntervalSince(fired)))
        }
    }

    private func note(_ line: String) {
        print(line)
        lines.append(line)
    }

    /// Waits for `session`'s new event: notes when it starts and when its rock first moves on view.
    private func watchStart(_ label: String) -> Bool {
        guard let cache = session.cache, ObjectIdentifier(cache) != startedEvent else { return false }
        startedEvent = ObjectIdentifier(cache)
        note(
            String(
                format: "%@: first frame shown %.2f s after asking", label, Date().timeIntervalSince(fired)))
        rest = session.face.blocks.map(\.centre)
        motionSeen = false
        lastFrame = 0
        lastAdvance = Date()
        shotsLeft = shotTimes
        return true
    }

    private func watchMotion(_ label: String) {
        guard !motionSeen else { return }
        let poses = session.shownPoses
        for n in rest.indices {
            let p = poses[2 * n]
            if simd_distance(SIMD3(p.x, p.y, p.z), rest[n]) > 0.02 {
                motionSeen = true
                note(
                    String(
                        format: "%@: rock first moves on view %.2f s after asking (event time %.2f s)", label,
                        Date().timeIntervalSince(fired), Float(session.frame) / QuarrySession.frameRate))
                shot(label.replacingOccurrences(of: " ", with: "-") + "-first-motion")
                return
            }
        }
    }

    /// Playback while the event is simulated: never backward, and how often it holds still.
    private func watchFollow() {
        if session.frame < lastFrame { backward += 1 }
        if session.frame != lastFrame {
            lastAdvance = Date()
        } else if session.playing, Date().timeIntervalSince(lastAdvance) > 0.1 {
            stalls += 1
            lastAdvance = Date()
        }
        lastFrame = session.frame
        if session.isSimulating, session.playing { rates.append(session.playbackRate) }
        series += String(
            format: "%.3f,%@,%d,%d,%.1f,%.3f,%.1f,%.1f\n", Date().timeIntervalSince(fired), "\(phase)",
            session.frame, session.availableFrames, lastWork, session.playbackRate, lastParts.update,
            lastParts.draw)
        footprintPeak = max(footprintPeak, PlayApp.footprintMB())
    }

    private func followReport(_ label: String) {
        let gpu = session.run?.frameGPUSeconds ?? []
        note(
            String(
                format:
                    "%@: simulated in %.1f s (solver built in %.2f s); solver %.1f ms a frame median, %.1f p90; playback rate while following median %.2f, lowest %.2f; held still >0.1 s %d times; backward %d",
                label, session.run?.secondsToFinish ?? -1, session.run?.secondsToBuild ?? -1,
                percentile(gpu, 0.5) * 1000, percentile(gpu, 0.9) * 1000, percentile(rates, 0.5),
                rates.min() ?? 1, stalls, backward))
        rates = []
        stalls = 0
        backward = 0
    }

    func tick(elapsed: Double) {
        frames[phase, default: []].append(elapsed * 1000)
        switch phase {
        case .waiting:
            if watchStart("first fire") {
                memory.append(
                    "first fire started: \(session.memoryReport); footprint \(PlayApp.footprintMB()) MB")
                phase = .follow
                ticks = 0
            }
        case .follow:
            watchMotion("first fire")
            timedShots("first fire")
            traceChips("first fire")
            watchFollow()
            ticks += 1
            if ticks == 90 { shot("follow-a") }
            if !session.isSimulating, !session.playing {
                followReport("first fire")
                memory.append(
                    "after first fire: \(session.memoryReport); footprint \(PlayApp.footprintMB()) MB, peak \(footprintPeak) MB"
                )
                shot("follow-end")
                phase = .scrub
                ticks = 0
            }
        case .scrub:
            ticks += 1
            session.yaw += 0.01
            session.seek(to: Int(random.float() * Float(session.eventFrames - 1)))
            if ticks > 150 {
                session.yaw = -0.81
                session.seek(to: 0)
                session.playing = true
                phase = .refire
                ticks = 0
            }
        case .refire:
            // Fire again a second and a half into watching the old event; it stays on view meanwhile.
            ticks += 1
            if ticks == 45 {
                session.settings = QuarryFiringSettings(order: .centreOut, stagger: 0.06, count: 22)
                fired = Date()
                session.refire()
            }
            if ticks > 45, watchStart("refire") {
                phase = .refollow
                ticks = 0
            }
        case .refollow:
            watchMotion("refire")
            timedShots("refire")
            traceChips("refire")
            watchFollow()
            ticks += 1
            if ticks == 100 { shot("after-refire") }
            if !session.isSimulating, !session.playing {
                followReport("refire")
                memory.append(
                    "after refire: \(session.memoryReport); footprint \(PlayApp.footprintMB()) MB, peak \(footprintPeak) MB"
                )
                if present == nil {
                    startStrip()
                    phase = .strip
                } else {
                    finish()
                }
                ticks = 0
            }
        case .strip:
            // The old event plays on while the new strip is broken and fired.
            if !session.playing { session.playing = true }
            if session.frame >= session.eventFrames - 1 { session.seek(to: 0) }
            if let stripError {
                note("strip failed: \(stripError)")
                finish()
            }
            if let incoming, incoming.canPlay {
                session = incoming
                self.incoming = nil
                _ = watchStart("moved strip")
                phase = .stripFollow
                ticks = 0
            }
        case .stripFollow:
            watchMotion("moved strip")
            timedShots("moved strip")
            traceChips("moved strip")
            watchFollow()
            ticks += 1
            if ticks == 100 { shot("after-strip") }
            if ticks > 180 {
                note("moved strip: played 180 frames while simulating")
                memory.append(
                    "after a moved strip: \(session.memoryReport); footprint \(PlayApp.footprintMB()) MB, peak \(footprintPeak) MB"
                )
                finish()
            }
        case .done:
            break
        }
    }

    /// A strip 40 m along and 10 m in from the first, built and fired off the main thread.
    private func startStrip() {
        var site = QuarrySite.builtIn(playScene)
        let along = simd_normalize(site.end - site.start)
        // Along the face, or along the ridge (across the cut's line).
        let move = playScene == .ridgeCut ? SIMD2(-along.y, along.x) : along
        site.start += move * 40
        site.end += move * 40
        let options = self.options
        let device = session.device
        let keys = dataRoot.appendingPathComponent(
            "play-dust-strip-\(ProcessInfo.processInfo.processIdentifier)")
        fired = Date()
        nonisolated(unsafe) let test = self
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let made = try QuarrySession.prepare(
                    device: device, site: site, options: options, settings: QuarryFiringSettings(),
                    width: 1600,
                    height: 900, keyDirectory: keys, timings: { print("strip: \($0)") },
                    progress: { stage, share in print(String(format: "strip: %@ %.0f%%", stage, share * 100))
                    })
                made.follow()
                DispatchQueue.main.async { test.incoming = made }
            } catch {
                DispatchQueue.main.async { test.stripError = "\(error)" }
            }
        }
    }

    private func finish() {
        flushChips()
        phase = .done
        func line(_ name: String, _ v: [Double]) -> String {
            guard !v.isEmpty else { return "\(name): no frames" }
            return String(
                format: "%@: %d frames, median %.1f ms (%.0f fps), p90 %.1f ms (%.0f fps), worst %.0f ms",
                name, v.count,
                percentile(v, 0.5), 1000 / percentile(v, 0.5), percentile(v, 0.9), 1000 / percentile(v, 0.9),
                v.max() ?? 0)
        }
        var report =
            "mode: \(present == nil ? "offscreen, no vsync, paced to the session's draw rate" : "real window and drawables, behind other windows, paced by a 60 Hz timer")\n"
        report += lines.joined(separator: "\n") + "\n"
        let named: [(String, Phase)] = [
            ("waiting for the first fire", .waiting), ("following the first fire", .follow),
            ("scrubbing and orbiting every frame", .scrub),
            ("playing the old event, then waiting for the refire", .refire),
            ("following the refire", .refollow), ("old event while a strip is built", .strip),
            ("following the moved strip", .stripFollow),
        ]
        for (name, phase) in named {
            report += line("interval, " + name, frames[phase] ?? []) + "\n"
            if let v = works[phase], !v.isEmpty {
                report += String(
                    format: "work a frame, %@: median %.1f ms (ceiling %.0f fps), p90 %.1f ms\n", name,
                    percentile(v, 0.5), 1000 / percentile(v, 0.5), percentile(v, 0.9))
            }
        }
        report += memory.joined(separator: "\n") + "\n"
        report += chipLines.joined(separator: "\n") + "\n"
        print(report)
        try? report.write(to: output.appendingPathComponent("loop.txt"), atomically: true, encoding: .utf8)
        try? series.write(to: output.appendingPathComponent("series.csv"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: session.keyDirectory)
        if present != nil { NSApp.terminate(nil) }
    }

    /// The same loop as the window's, with nothing on screen and no vsync, paced to the rate the
    /// window would draw at.
    func runOffscreen() throws {
        var last = Date()
        while phase != .done {
            autoreleasepool { offscreenFrame(&last) }
        }
    }

    private func offscreenFrame(_ last: inout Date) {
        do {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0))
            let now = Date()
            let elapsed = now.timeIntervalSince(last)
            last = now
            session.update(elapsed: elapsed)
            let updated = Date()
            session.draw()
            let spent = Date().timeIntervalSince(now)
            lastParts = (updated.timeIntervalSince(now) * 1000, Date().timeIntervalSince(updated) * 1000)
            work(spent * 1000)
            tick(elapsed: elapsed)
            let rate =
                incoming == nil && phase != .strip ? session.preferredDrawRate : QuarrySession.firingDrawRate
            let wait = 1 / Double(rate) - Date().timeIntervalSince(now)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }
}

/// The scene `play` opens: the quarry face, or with `--ridge` the ridge cut.
let playScene: QuarryScene = CommandLine.arguments.contains("--ridge") ? .ridgeCut : .face
