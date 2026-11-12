import AVFoundation
import AppKit
import Metal
import SwiftUI
import Testing

@testable import BlastModel
@testable import BlastRender
@testable import BombCAD

/// The Quarry Face window captured offscreen while its event is watched as it is simulated
/// (emmettl/bombcad-work#126): `BOMBCAD_INTERFACE_REVIEW=dir swift test --filter QuarryFaceReview`.
/// The 3-D view is a Metal layer, which a capture of the window leaves blank, so each step also
/// writes the session's own frame. For a person to look at; it checks only that each state is reached.
@MainActor
@Suite(
    "Quarry Face window review", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
struct QuarryFaceReviewTests {
    @Test("Preparing, following the solver, firing again, and done")
    func streamingStates() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        )
        .appendingPathComponent("quarry-stream")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = QuarryFaceModel(blocks: 12000)
        let host = NSHostingView(rootView: QuarryFaceView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 860)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        #expect(!window.isVisible)
        if model.session == nil, model.preparing == nil { model.prepare() }

        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            if let session = model.session {
                session.draw()
                session.renderer.savePNG(output.appendingPathComponent(name + "-view.png"))
            }
        }
        func wait(_ seconds: Double, until done: () -> Bool) async throws {
            var waited = 0.0
            while !done(), waited < seconds {
                try await Task.sleep(for: .milliseconds(20))
                model.session?.update(elapsed: 0.02)
                waited += 0.02
            }
        }

        try await wait(60) { model.preparing != nil }
        try capture("1-preparing")
        try await wait(240) { model.session?.isSimulating == true }
        try await Task.sleep(for: .milliseconds(400))
        try capture("2-following")
        try await wait(240) { model.session?.isReady == true }
        model.fire()
        try capture("3-fired-again")
        let session = try #require(model.session)
        #expect(session.isStarting || session.isSimulating)
        try await wait(240) { session.isReady && !session.isStarting }
        session.seek(to: session.eventFrames - 1)
        session.update(elapsed: 0)
        try capture("4-done")
        #expect(session.isReady)
    }
    /// The 3-D view at the default window's shape and a wide one, at the window's own 100,000
    /// blocks (emmettl/bombcad-work#130): the frame as the view draws it now, as it was (16:9
    /// stretched over the view), and the 16:9 frame a clip from the same camera has; how wide the
    /// rock is drawn against that clip's frame; and a frame's GPU time at the default shape, now and
    /// as it was. Each image is written at the view's size in points.
    @Test("The view at two window shapes, against the 16:9 frame, and a frame's cost")
    func viewShapes() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        )
        .appendingPathComponent("quarry-aspect")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = QuarryFaceModel()
        let (window, host, view) = try QuarryFaceHandlingTests.host(model)
        defer { window.close() }
        #expect(!window.isVisible)
        var log: [String] = []
        func note(_ line: String) {
            print(line)
            log.append(line)
        }
        model.prepare()
        var waited = 0.0
        while !(model.session?.isReady == true && model.preparing == nil), waited < 300 {
            try await Task.sleep(for: .milliseconds(20))
            model.session?.update(elapsed: 0.02)
            waited += 0.02
        }
        let session = try #require(model.session)
        #expect(session.isReady)
        let renderer = session.renderer
        note("blocks \(session.face.blocks.count)")

        /// The renderer's frame written at `size` (points), stretched to it as the view shows it.
        func write(_ name: String, size: CGSize) throws {
            let frameURL = output.appendingPathComponent(name + "-frame.png")
            renderer.savePNG(frameURL)
            let frame = try #require(
                NSImage(contentsOf: frameURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let context = try #require(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(frame, in: CGRect(origin: .zero, size: size))
            let image = try #require(context.makeImage())
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            try? FileManager.default.removeItem(at: frameURL)
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

        for (shape, width) in [("default", 1400.0), ("wide", 2400.0)] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 860)
            host.layoutSubtreeIfNeeded()
            let start = ProcessInfo.processInfo.systemUptime
            view.fitFrame(now: start)
            view.fitFrame(now: start + 1)
            let aspect = view.viewAspect
            let fitted = (renderer.width, renderer.height)
            note(
                String(
                    format:
                        "%@ window %.0f x 860: view %.0f x %.0f points (%.3f), %d x %d drawable pixels; frame %d x %d, vertical field %.1f° (the camera's %.0f°)",
                    shape, width, view.bounds.width, view.bounds.height, aspect, view.viewPixels.x,
                    view.viewPixels.y, fitted.0, fitted.1, session.view(aspect: aspect).fovY * 180 / .pi,
                    session.fovDegrees))
            for (moment, frame) in [("calm", 0), ("4s", 120), ("settled", session.eventFrames - 1)] {
                session.seek(to: frame)
                session.update(elapsed: 0)
                session.draw()
                let shown = QuarryFaceHandlingTests.luma(renderer)
                try write("\(shape)-\(moment)-now", size: view.bounds.size)
                // As it was: the 16:9 frame stretched over the view; and that frame itself, a clip's.
                renderer.resize(width: 1600, height: 900)
                session.draw()
                let clip = QuarryFaceHandlingTests.luma(renderer)
                try write("\(shape)-\(moment)-before", size: view.bounds.size)
                try write("\(shape)-\(moment)-16x9", size: CGSize(width: 1600, height: 900))
                renderer.resize(width: fitted.0, height: fitted.1)
                renderer.aspect = aspect
                let field = session.view().fovY
                let now = QuarryFaceHandlingTests.horizontalScale(
                    shown, aspect: aspect, fovY: session.view(aspect: aspect).fovY, reference: clip,
                    referenceAspect: 16 / 9, referenceFovY: field)
                let before = QuarryFaceHandlingTests.horizontalScale(
                    clip, aspect: aspect, fovY: field, reference: clip, referenceAspect: 16 / 9,
                    referenceFovY: field)
                note(
                    String(
                        format:
                            "  %@: rock drawn %.3f times as wide as it should be (correlation %.3f); before %.3f (%.3f)",
                        moment, now.scale, now.correlation, before.scale, before.correlation))
                #expect(abs(now.scale - 1) < 0.03)
            }
            guard shape == "default" else { continue }
            // A frame's GPU time at the default shape, now against 16:9 at 1600 x 900, taken in turn.
            for (moment, frame) in [("calm", 0), ("4s, dust rising", 120)] {
                session.seek(to: frame)
                session.update(elapsed: 0)
                var times: (now: [Double], before: [Double]) = ([], [])
                // In blocks of 10, after two draws each time the targets are made.
                for _ in 0..<4 {
                    for _ in 0..<2 { session.draw() }
                    for _ in 0..<10 { times.now.append(session.draw() * 1000) }
                    renderer.resize(width: 1600, height: 900)
                    for _ in 0..<2 { session.draw() }
                    for _ in 0..<10 { times.before.append(session.draw() * 1000) }
                    renderer.resize(width: fitted.0, height: fitted.1)
                    renderer.aspect = aspect
                }
                note(
                    String(
                        format:
                            "  GPU a frame, %@: %.2f ms now (%d x %d), %.2f ms before (1600 x 900), medians of 40",
                        moment, median(times.now), fitted.0, fitted.1, median(times.before)))
            }
        }
        try log.joined(separator: "\n").write(
            to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    /// The strip placed in the 3-D view, an opened file's overview, and clips recorded from the
    /// window, at the window's own 100,000 blocks (emmettl/bombcad-work#128). Writes composites of
    /// the view with the strip drawn over it, the window, and frames taken from the clips' files.
    @Test("Placing the strip in the view, choosing an area, and recording clips")
    func handling() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        )
        .appendingPathComponent("quarry-handling")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = QuarryFaceModel()
        let (window, host, view) = try QuarryFaceHandlingTests.host(model)
        defer { window.close() }
        #expect(!window.isVisible)
        let projectID = UUID()
        QuarryProjectTerrains.shared.set(projectID, name: "Hillside project", terrain: model.site.terrain)
        defer { QuarryProjectTerrains.shared.remove(projectID) }
        var log: [String] = []
        func note(_ line: String) {
            print(line)
            log.append(line)
        }

        /// The window, and the 3-D view's own frame with the strip's layers drawn over it.
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            guard let session = model.session else { return }
            session.update(elapsed: 0)
            session.draw()
            let frameURL = output.appendingPathComponent(name + "-frame.png")
            session.renderer.savePNG(frameURL)
            let frame = try #require(
                NSImage(contentsOf: frameURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let size = view.bounds.size
            let context = try #require(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(origin: .zero, size: size))
            view.overlay.layer?.render(in: context)
            let image = try #require(context.makeImage())
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + "-view.png"))
            try? FileManager.default.removeItem(at: frameURL)
        }
        func wait(_ seconds: Double, until done: () -> Bool) async throws {
            var waited = 0.0
            while !done(), waited < seconds {
                try await Task.sleep(for: .milliseconds(20))
                model.session?.update(elapsed: 0.02)
                waited += 0.02
            }
        }

        model.prepare()
        try await wait(300) { model.session?.isReady == true && model.preparing == nil }
        let session = try #require(model.session)
        note("blocks \(session.face.blocks.count)")

        // 1. Strip mode: the strip over the face before the blast, and the face point under the cursor.
        model.stripMode = true
        view.refreshOverlay()
        try capture("1-strip-mode")
        let hill = model.site.terrain
        func onFace(_ x: Float) throws -> CGPoint {
            let y = BuiltInHill.faceLine(x) + 1.5
            return try #require(view.onView(SIMD3(x, y, hill.height(at: SIMD2(x, y)))))
        }
        let hoverAt = try onFace(120)
        view.mouseMoved(
            with: QuarryFaceHandlingTests.mouse(
                .mouseMoved, at: CGPoint(x: hoverAt.x, y: hoverAt.y - 25), in: view))
        try capture("2-hover")

        // 2. A new strip dragged from x = 60 to x = 230 along the face, partly past the old one.
        let a = try onFace(60)
        let b = try onFace(230)
        view.mouseDown(with: QuarryFaceHandlingTests.mouse(.leftMouseDown, at: a, in: view))
        for k in 1...60 {
            let t = CGFloat(k) / 60
            view.mouseDragged(
                with: QuarryFaceHandlingTests.mouse(
                    .leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                    in: view))
            if k == 40 { try capture("3-dragging") }
        }
        let latencies = view.dragLatencies.sorted()
        note(
            String(
                format:
                    "strip drag, event to overlay committed: median %.2f ms, p90 %.2f ms, worst %.2f ms (%d events)",
                latencies[latencies.count / 2], latencies[latencies.count * 9 / 10], latencies.last!,
                latencies.count))
        let released = Date()
        view.mouseUp(with: QuarryFaceHandlingTests.mouse(.leftMouseUp, at: b, in: view))
        note("new strip \(model.site.start) → \(model.site.end)")
        try await wait(120) { model.preparing == nil && model.session !== session }
        note(String(format: "strip released → its event on view: %.1f s", Date().timeIntervalSince(released)))
        try await Task.sleep(for: .milliseconds(300))
        model.session?.update(elapsed: 0.3)
        try capture("4-new-strip")
        model.stripMode = false

        // 3. An opened file's overview, with the area to break chosen on it.
        let (columns, rows) = (751, 501)
        var elevations = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                elevations[i + columns * j] =
                    300 + hill.height(at: SIMD2(Float(i) * 4 - 2000, Float(j) * 4 - 1000))
            }
        }
        let grid = ElevationGrid(
            columns: columns, rows: rows, southWest: SIMD2(431_000, 5_200_000), step: SIMD2(4, 4),
            units: .metres,
            elevations: elevations)
        var choice = QuarryCropChoice(grid: grid, name: "hillside-4m.asc")
        choice.crop.move(centre: SIMD2(2090, 1000))
        choice.crop.resize(900)
        let sheet = NSHostingView(
            rootView: QuarryCropSheet(choice: choice) { _ in
            } cancel: {
            })
        sheet.frame = CGRect(x: 0, y: 0, width: 600, height: 620)
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sheet.layoutSubtreeIfNeeded()
        let sheetBitmap = try #require(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
        sheet.cacheDisplay(in: sheet.bounds, to: sheetBitmap)
        try #require(sheetBitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("5-crop-sheet.png"))

        // 4. Clips from the event on view: the whole of it at real time from this view, and the
        // busiest seconds at quarter speed on a slow orbit.
        try await wait(300) { model.session?.isReady == true }
        let event = try #require(model.session)
        func record(_ name: String, from: Int, seconds: Double, speed: Float, motion: QuarryClipCamera.Motion)
            async throws
            -> URL
        {
            event.seek(to: from)
            event.update(elapsed: 0)
            model.clipFromShown = from > 0
            model.clipSeconds = seconds
            model.clipSpeed = speed
            model.clipMotion = motion
            let url = output.appendingPathComponent(name + ".mp4")
            let footprintBefore = event.memory.metal
            model.recordClip(to: url)
            // Under way: drawing the movie's frames, not running up to them.
            try await wait(600) { model.recorder == nil || model.clipShare > 0.3 }
            try capture("6-recording-" + name)
            try await wait(3000) { model.recorder == nil }
            let report = try #require(model.lastClip, "\(model.clipStatus)")
            note(
                String(
                    format:
                        "%@: %d frames (%.1f s of movie) in %.1f s, lead-in %.1f s; a frame median %.1f ms (draw %.1f ms GPU, dust %.1f ms); Metal %d MB before, %d MB at most while recording",
                    name, report.frames, report.videoSeconds, report.wallSeconds, report.leadInSeconds,
                    report.frameMilliseconds, report.drawMilliseconds, report.dustMilliseconds,
                    footprintBefore >> 20,
                    report.metalPeak >> 20))
            // Frames from the file itself.
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            note(
                String(
                    format: "%@ file: %.2f s, %d KB", name, duration,
                    (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) >> 10))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for share in [0.02, 0.2, 0.4, 0.6, 0.98] {
                let t = duration * share
                let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(String(format: "%@-%05.2f.png", name, t)))
            }
            return url
        }
        _ = try await record("whole-real-time", from: 0, seconds: 20, speed: 1, motion: .still)
        _ = try await record("quarter-speed-orbit", from: 60, seconds: 4, speed: 0.25, motion: .orbit)
        try log.joined(separator: "\n").write(
            to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    /// File ▸ New Ridge Cut at the window's own 100,000 blocks (emmettl/bombcad-work#131): the window
    /// while the cut is simulated and once it has settled, the cut's line placed over the view,
    /// a new line dragged across the ridge, and a clip recorded from the window, with frames taken
    /// from its file.
    @Test("The ridge cut: following, settled, placing the cut, and a clip")
    func ridgeCut() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        )
        .appendingPathComponent("ridge-cut")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = QuarryFaceModel(scene: .ridgeCut)
        let (window, host, view) = try QuarryFaceHandlingTests.host(model)
        defer { window.close() }
        #expect(!window.isVisible)
        var log: [String] = []
        func note(_ line: String) {
            print(line)
            log.append(line)
        }
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            guard let session = model.session else { return }
            session.update(elapsed: 0)
            view.fitFrame(now: 1e9)
            session.draw()
            let frameURL = output.appendingPathComponent(name + "-frame.png")
            session.renderer.savePNG(frameURL)
            let frame = try #require(
                NSImage(contentsOf: frameURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let size = view.bounds.size
            let context = try #require(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(origin: .zero, size: size))
            view.overlay.layer?.render(in: context)
            let image = try #require(context.makeImage())
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + "-view.png"))
            try? FileManager.default.removeItem(at: frameURL)
        }
        func wait(_ seconds: Double, until done: () -> Bool) async throws {
            var waited = 0.0
            while !done(), waited < seconds {
                try await Task.sleep(for: .milliseconds(20))
                model.session?.update(elapsed: 0.02)
                waited += 0.02
            }
        }

        let opened = Date()
        model.prepare()
        try await wait(300) { model.session?.isSimulating == true && (model.session?.frame ?? 0) > 100 }
        note(
            String(
                format: "opened → %.1f s of the event on view in %.1f s",
                Float(model.session?.frame ?? 0) / 30, Date().timeIntervalSince(opened)))
        try capture("1-following")
        try await wait(300) { model.session?.isReady == true }
        let session = try #require(model.session)
        let ridge = try #require(session.face.ridge)
        note(
            "blocks \(session.face.blocks.count), cut \(Int(ridge.cutEnd - ridge.cutStart)) m along the line, floor \(ridge.floor) m, crest \(ridge.crest) m; \(session.memoryReport)"
        )
        session.seek(to: session.eventFrames - 1)
        session.update(elapsed: 0)
        try capture("2-settled")

        // Placing: the cut's line and outline over the ridge as it stood.
        model.stripMode = true
        view.refreshOverlay()
        try capture("3-place-cut")
        // From high above, as a user would turn the view to see both flanks (from beside the ridge
        // the far flank is behind the crest).
        session.focus = SIMD3(80, -20, 10)
        session.pitch = 1.1
        session.distance = 330
        let ground = model.site.terrain
        func onView(_ p: SIMD2<Float>) throws -> CGPoint {
            try #require(view.onView(SIMD3(p, ground.height(at: p))))
        }
        let a = try onView(SIMD2(-75, -35))
        let b = try onView(SIMD2(75, -35))
        view.mouseDown(with: QuarryFaceHandlingTests.mouse(.leftMouseDown, at: a, in: view))
        for k in 1...40 {
            let t = CGFloat(k) / 40
            view.mouseDragged(
                with: QuarryFaceHandlingTests.mouse(
                    .leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                    in: view))
            if k == 30 { try capture("4-dragging") }
        }
        let released = Date()
        view.mouseUp(with: QuarryFaceHandlingTests.mouse(.leftMouseUp, at: b, in: view))
        note("new cut \(model.site.start) → \(model.site.end)")
        try await wait(120) { model.preparing == nil && model.session !== session }
        note(String(format: "cut released → its event on view: %.1f s", Date().timeIntervalSince(released)))
        model.stripMode = false
        try await wait(300) { model.session?.isReady == true }
        model.session?.seek(to: 150)
        model.session?.update(elapsed: 0)
        try capture("5-new-cut-5s")

        // A clip from the window: the whole event at real time, from this view.
        let event = try #require(model.session)
        event.seek(to: 0)
        event.update(elapsed: 0)
        model.clipFromShown = false
        model.clipSeconds = 20
        model.clipSpeed = 1
        model.clipMotion = .orbit
        let url = output.appendingPathComponent("window-clip.mp4")
        model.recordClip(to: url)
        try await wait(3000) { model.recorder == nil }
        let report = try #require(model.lastClip, "\(model.clipStatus)")
        note(
            String(
                format: "clip: %d frames (%.1f s) in %.1f s, a frame median %.1f ms; Metal at most %d MB",
                report.frames, report.videoSeconds, report.wallSeconds, report.frameMilliseconds,
                report.metalPeak >> 20))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for t in [1.0, 2.5, 4.0, 6.0, 10.0, duration - 0.1] {
            let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(String(format: "window-clip-%05.2f.png", t)))
        }
        try log.joined(separator: "\n").write(
            to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
