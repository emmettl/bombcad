import AVFoundation
import AppKit
import Metal
import SwiftUI
import Testing
import simd

@testable import BlastModel
@testable import BlastRender
@testable import BombCAD

/// File ▸ New Quarry Face's handling (emmettl/bombcad-work#128): the strip dragged on the face in
/// the 3-D view, an opened terrain's area chosen, the open project's terrain offered, and a clip
/// recorded. Offscreen: the window is never shown. Illustrative scene.
@MainActor
@Suite("Quarry face handling", .serialized)
struct QuarryFaceHandlingTests {
    /// The window's view, laid out offscreen, and its 3-D view.
    static func host(_ model: QuarryFaceModel) throws -> (
        NSWindow, NSHostingView<QuarryFaceView>, QuarryMetalView
    ) {
        let host = NSHostingView(rootView: QuarryFaceView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 860)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> QuarryMetalView? {
            if let metal = view as? QuarryMetalView { return metal }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return (window, host, try #require(find(host)))
    }

    /// The renderer's frame as luma (0...1), row 0 at the top, and its size.
    static func luma(_ renderer: QuarryRenderer) -> (values: [Float], width: Int, height: Int) {
        let (w, h) = (renderer.width, renderer.height)
        var bytes = [UInt8](repeating: 0, count: 4 * w * h)
        renderer.output.getBytes(
            &bytes, bytesPerRow: 4 * w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA.
        let values = (0..<(w * h)).map {
            (0.0722 * Float(bytes[4 * $0]) + 0.7152 * Float(bytes[4 * $0 + 1]) + 0.2126
                * Float(bytes[4 * $0 + 2]))
                / 255
        }
        return (values, w, h)
    }

    /// How much wider the scene is drawn in `frame`, shown over a view of width over height `aspect`
    /// with vertical field `fovY`, than it should be, judged against `reference` drawn from the same
    /// eye at `referenceAspect` and `referenceFovY` unstretched: the horizontal scale (0.5 to 1.8)
    /// that best matches the two (normalised correlation of their luma, each averaged over 4 by 4
    /// pixels). 1 when the frame is true to the view's shape; the view's shape over the frame's
    /// projection's when it is stretched.
    static func horizontalScale(
        _ frame: (values: [Float], width: Int, height: Int), aspect: Float, fovY: Float,
        reference: (values: [Float], width: Int, height: Int), referenceAspect: Float, referenceFovY: Float
    ) -> (scale: Float, correlation: Float) {
        func reduced(_ f: (values: [Float], width: Int, height: Int)) -> (v: [Float], w: Int, h: Int) {
            let (w, h) = (f.width / 4, f.height / 4)
            var v = [Float](repeating: 0, count: w * h)
            for j in 0..<h {
                for i in 0..<w {
                    var sum: Float = 0
                    for b in 0..<4 { for a in 0..<4 { sum += f.values[(4 * j + b) * f.width + 4 * i + a] } }
                    v[j * w + i] = sum / 16
                }
            }
            return (v, w, h)
        }
        func sample(_ f: (v: [Float], w: Int, h: Int), _ u: Float, _ t: Float) -> Float {
            let x = max(0, min(Float(f.w - 1), u * Float(f.w) - 0.5))
            let y = max(0, min(Float(f.h - 1), t * Float(f.h) - 0.5))
            let (i, j) = (min(f.w - 2, Int(x)), min(f.h - 2, Int(y)))
            let (fx, fy) = (x - Float(i), y - Float(j))
            let top = f.v[j * f.w + i] * (1 - fx) + f.v[j * f.w + i + 1] * fx
            let bottom = f.v[(j + 1) * f.w + i] * (1 - fx) + f.v[(j + 1) * f.w + i + 1] * fx
            return top * (1 - fy) + bottom * fy
        }
        let a = reduced(frame)
        let r = reduced(reference)
        // Half the field's tangents across and up, the view's and the reference's.
        let ty = tan(fovY / 2)
        let ry = tan(referenceFovY / 2)
        let (tx, rx) = (ty * aspect, ry * referenceAspect)
        // The view's samples, the same for every scale tried: those inside the reference at the least.
        let reach = 0.9 * min(1, rx * 0.5 / tx)
        let up = 0.9 * min(1, ry / ty)
        var points: [(x: Float, y: Float)] = []
        for j in 0..<90 {
            for i in 0..<160 {
                points.append((reach * (Float(i) / 79.5 - 1), up * (Float(j) / 44.5 - 1)))
            }
        }
        let shown = points.map { sample(a, ($0.x + 1) / 2, (1 - $0.y) / 2) }
        func correlation(_ x: [Float], _ y: [Float]) -> Float {
            let mx = x.reduce(0, +) / Float(x.count)
            let my = y.reduce(0, +) / Float(y.count)
            var (sxy, sxx, syy): (Float, Float, Float) = (0, 0, 0)
            for (p, q) in zip(x, y) {
                sxy += (p - mx) * (q - my)
                sxx += (p - mx) * (p - mx)
                syy += (q - my) * (q - my)
            }
            return sxy / max(1e-12, (sxx * syy).squareRoot())
        }
        var best: (scale: Float, correlation: Float) = (0, -2)
        for k in 0...260 {
            let scale = 0.5 + Float(k) * 0.005
            let seen = points.map {
                sample(r, ($0.x * tx / (rx * scale) + 1) / 2, (1 - $0.y * ty / ry) / 2)
            }
            let c = correlation(shown, seen)
            if c > best.correlation { best = (scale, c) }
        }
        return best
    }

    static func waitForEvent(_ model: QuarryFaceModel, seconds: Double = 240) async throws {
        var waited = 0.0
        while model.session?.canPlay != true || model.preparing != nil, waited < seconds {
            try await Task.sleep(for: .milliseconds(20))
            model.session?.update(elapsed: 0.02)
            waited += 0.02
        }
        #expect(model.session?.canPlay == true)
    }

    static func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("A strip dragged along the face in the 3-D view lies on the face and is broken on release")
    func dragsTheStripInTheView() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 12000)
        let (window, _, view) = try Self.host(model)
        defer { window.close() }
        #expect(!window.isVisible)
        model.prepare()
        try await Self.waitForEvent(model)
        model.stripMode = true
        #expect(model.session?.frame == 0)
        view.refreshOverlay()
        #expect(view.overlay.isShowing)
        // From the face at x = 40 to the face at x = 150 on the built-in hill, as the view shows them.
        let hill = model.site.terrain
        func onFace(_ x: Float) throws -> CGPoint {
            let y = BuiltInHill.faceLine(x) + 1.5
            let p = try #require(view.onView(SIMD3(x, y, hill.height(at: SIMD2(x, y)))))
            #expect(view.bounds.contains(p), "\(p) in \(view.bounds)")
            return p
        }
        let a = try onFace(40)
        let b = try onFace(150)
        view.mouseDown(with: Self.mouse(.leftMouseDown, at: a, in: view))
        for k in 1...30 {
            let t = CGFloat(k) / 30
            view.mouseDragged(
                with: Self.mouse(
                    .leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                    in: view))
        }
        #expect(model.draftStart != nil && model.draftEnd != nil)
        view.mouseUp(with: Self.mouse(.leftMouseUp, at: b, in: view))
        // Snapped to the face line at both ends; regenerated as from the map.
        #expect(
            abs(model.site.start.x - 40) < 6 && abs(model.site.start.y - (BuiltInHill.faceLine(40) + 1.5)) < 4
        )
        #expect(
            abs(model.site.end.x - 150) < 6 && abs(model.site.end.y - (BuiltInHill.faceLine(150) + 1.5)) < 4)
        #expect(model.preparing != nil)
        let latencies = view.dragLatencies.sorted()
        #expect(latencies.count == 30)
        // Each drag event drawn well within a frame (a debug build; release is faster).
        #expect(latencies[latencies.count / 2] < 50, "\(latencies)")
        print(
            "strip drag, ms from event to overlay: median \(latencies[latencies.count / 2]), worst \(latencies.last!)"
        )
        // An end dragged along the face: the other end stays.
        try await Self.waitForEvent(model)
        let session = try #require(model.session)
        session.seek(to: 0)
        let start = model.site.start
        let lines = QuarryStripGuide.lines(terrain: hill, start: model.site.start, end: model.site.end)
        let last = try #require(lines.face.last)
        let handle = try #require(view.onView(last))
        let further = try onFace(170)
        view.mouseDown(with: Self.mouse(.leftMouseDown, at: handle, in: view))
        view.mouseDragged(with: Self.mouse(.leftMouseDragged, at: further, in: view))
        view.mouseUp(with: Self.mouse(.leftMouseUp, at: further, in: view))
        #expect(simd_distance(model.site.start, start) < 1e-3)
        #expect(abs(model.site.end.x - 170) < 6)
        // Out of strip mode the strip is not drawn, and a drag orbits again.
        model.stripMode = false
        view.refreshOverlay()
        #expect(!view.overlay.isShowing)
        let orbited = try #require(view.session)
        let yaw = orbited.yaw
        let site = model.site.start
        view.mouseDown(with: Self.mouse(.leftMouseDown, at: a, in: view))
        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: view.convert(b, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDragged(with: drag)
        view.mouseUp(with: Self.mouse(.leftMouseUp, at: b, in: view))
        #expect(model.site.start == site)
        _ = yaw
    }

    @Test("The view draws at its own shape, not 16:9 stretched; the strip and picking follow it")
    func drawsAtTheViewsShape() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 8000)
        let (window, host, view) = try Self.host(model)
        defer { window.close() }
        model.prepare()
        try await Self.waitForEvent(model)
        let session = try #require(model.session)
        session.seek(to: 0)
        session.update(elapsed: 0)
        let hill = model.site.terrain
        var clock = ProcessInfo.processInfo.systemUptime
        // The default window's view (about 4:3), then a wide one.
        for width in [1400.0, 2200.0] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 860)
            host.layoutSubtreeIfNeeded()
            let aspect = view.viewAspect
            #expect(abs(aspect - 16 / 9) > 0.2, "\(view.bounds)")
            // A new size is taken only once it has held: until then the projection follows the view
            // and the frame keeps its targets.
            let target = session.renderer.output
            let first = view.fitFrame(now: clock)
            #expect(session.renderer.aspect == aspect)
            if width > 1400 {
                #expect(!first)
                #expect(!view.fitFrame(now: clock + QuarrySession.resizeSettle / 2))
                #expect(session.renderer.output === target)
                #expect(view.fitFrame(now: clock + QuarrySession.resizeSettle * 1.1))
                #expect(session.renderer.output !== target)
            }
            clock += 10
            let renderer = session.renderer
            let frameAspect = Float(renderer.width) / Float(renderer.height)
            #expect(
                abs(frameAspect / aspect - 1) < 0.02, "\(renderer.width) x \(renderer.height), view \(aspect)"
            )
            #expect(renderer.width * renderer.height <= QuarrySession.framePixels)
            #expect(renderer.aspect == aspect)
            session.draw()
            // The overlay and picking use the projection the frame was drawn with: a point of the
            // face lands where it is drawn, and the ground under that point is the point itself.
            let drawn = renderer.lastViewProjection
            #expect(drawn == view.viewProjection(session))
            for x: Float in [40, 95, 150] {
                let y = BuiltInHill.faceLine(x) + 1.5
                let g = SIMD3(x, y, hill.height(at: SIMD2(x, y)))
                let p = try #require(view.onView(g))
                #expect(view.bounds.contains(p), "\(p) in \(view.bounds)")
                let l = session.face.local(SIMD2(g.x, g.y))
                let c = drawn * SIMD4(l.x, l.y, g.z + 0.3, 1)
                let q = CGPoint(
                    x: CGFloat(c.x / c.w + 1) / 2 * view.bounds.width,
                    y: CGFloat(c.y / c.w + 1) / 2 * view.bounds.height)
                #expect(hypot(p.x - q.x, p.y - q.y) < 0.5, "\(p) against \(q)")
                let back = try #require(view.ground(at: p))
                #expect(simd_distance(back, SIMD2(x, y)) < 1.5, "\(back) against \(SIMD2(x, y))")
            }
            // The rock is not stretched: the frame matches a 16:9 frame (a clip's) from the same
            // camera at a horizontal scale of 1; the old frame (16:9 stretched over the view) matched
            // at the view's shape over 16:9. A view narrower than 16:9 shows all the clip's width.
            let shown = Self.luma(renderer)
            let size = (renderer.width, renderer.height)
            renderer.resize(width: 1600, height: 900)
            session.draw()
            let wide = Self.luma(renderer)
            renderer.resize(width: size.0, height: size.1)
            renderer.aspect = aspect
            let fovY = session.view(aspect: aspect).fovY
            let clipFovY = session.view().fovY
            #expect(fovY > clipFovY + 0.01 || aspect >= 16 / 9)
            let now = Self.horizontalScale(
                shown, aspect: aspect, fovY: fovY, reference: wide, referenceAspect: 16 / 9,
                referenceFovY: clipFovY)
            let before = Self.horizontalScale(
                wide, aspect: aspect, fovY: clipFovY, reference: wide, referenceAspect: 16 / 9,
                referenceFovY: clipFovY)
            print(
                "view \(view.bounds.size), frame \(size.0) x \(size.1): horizontal scale \(now.scale) "
                    + "(correlation \(now.correlation)); 16:9 stretched over it \(before.scale)")
            #expect(abs(now.scale - 1) < 0.03, "\(now)")
            #expect(now.correlation > 0.9, "\(now)")
            #expect(abs(before.scale - aspect / (16 / 9)) < 0.03, "\(before)")
        }
    }

    @Test("An opened file's area is chosen on its overview; the project's own terrain is offered")
    func choosesTheGround() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        // A projected file 3 km by 2 km at 4 m, far from the origin: the built-in hill in its east.
        let hill = QuarrySite.builtIn().terrain
        let (columns, rows) = (751, 501)
        let southWest = SIMD2<Double>(431_000, 5_200_000)
        var elevations = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                // The hill's (x, y) at the file's (2000 + x, 1000 + y).
                let p = SIMD2(Float(i) * 4 - 2000, Float(j) * 4 - 1000)
                elevations[i + columns * j] = 300 + hill.height(at: p)
            }
        }
        let grid = ElevationGrid(
            columns: columns, rows: rows, southWest: southWest, step: SIMD2(4, 4), units: .metres,
            elevations: elevations)
        let model = QuarryFaceModel(blocks: 8000)
        var choice = QuarryCropChoice(grid: grid, name: "test.asc")
        #expect(choice.pixels == SIMD2(560, 373))
        #expect(choice.overview != nil)
        // The default is the middle; choose round the hill's strip instead.
        choice.crop.move(centre: SIMD2(2090, 1000))
        choice.crop.resize(800)
        model.useCrop(choice)
        #expect(model.terrainName == "test.asc")
        #expect(model.lastCropChoice != nil)
        // A first strip along the face found in the crop, broken at once.
        let crop = choice.crop
        let middle = (model.site.start + model.site.end) / 2 + crop.corner - SIMD2(2000, 1000)
        #expect(abs(middle.y - (BuiltInHill.faceLine(middle.x) + 1.5)) < 5, "\(middle)")
        #expect(model.preparing != nil)
        try await Self.waitForEvent(model)
        #expect(model.problem == nil)
        // The project's terrain: offered while its window is open, gone when it closes.
        let terrains = QuarryProjectTerrains.shared
        let id = UUID()
        terrains.set(id, name: "Hill project", terrain: hill)
        let entry = try #require(terrains.entries.first { $0.id == id })
        model.useProjectTerrain(entry)
        #expect(model.terrainName == "Hill project")
        #expect(model.preparing != nil)
        terrains.set(
            id, name: "Hill project",
            terrain: Terrain(spacing: 1, columns: 2, rows: 2, heights: [0, 0, 0, 0]))
        #expect(!terrains.entries.contains { $0.id == id })
        terrains.set(id, name: "Hill project", terrain: hill)
        terrains.remove(id)
        #expect(terrains.entries.isEmpty)
        try await Self.waitForEvent(model)
    }

    @Test("A slow-motion clip is written, and its frames move")
    func recordsAClip() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let model = QuarryFaceModel(blocks: 8000)
        model.prepare()
        try await Self.waitForEvent(model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quarry-clip-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        model.clipSize = SIMD2(480, 270)
        model.clipSeconds = 1
        model.clipSpeed = 0.5
        model.clipFromShown = false
        // From 2.5 s, as the rock lets go: the dust and chips run up to it first.
        model.session?.seek(to: 75)
        model.clipFromShown = true
        model.recordClip(to: url)
        #expect(model.recorder != nil)
        var waited = 0.0
        while model.recorder != nil, waited < 240 {
            try await Task.sleep(for: .milliseconds(50))
            model.session?.update(elapsed: 0.05)
            waited += 0.05
        }
        let report = try #require(model.lastClip, "\(model.clipStatus)")
        #expect(report.frames == 60)
        #expect(abs(report.videoSeconds - 2) < 0.01)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [[UInt8]] = []
        for t in [0.1, 1.0, 1.9] {
            let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            #expect(image.width == 480 && image.height == 270)
            let bitmap = NSBitmapImageRep(cgImage: image)
            frames.append(
                Array(
                    UnsafeBufferPointer(
                        start: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)))
        }
        // Not blank, and moving.
        for frame in frames { #expect(Set(frame.prefix(200_000)).count > 40) }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        }
        #expect(difference(frames[0], frames[1]) > 0.5)
        #expect(difference(frames[1], frames[2]) > 0.5)
        // Cancelled: no movie left.
        let cancelled = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quarry-clip-\(UUID()).mp4")
        model.clipSeconds = 5
        model.recordClip(to: cancelled)
        try await Task.sleep(for: .milliseconds(300))
        model.cancelClip()
        waited = 0
        while model.recorder != nil, waited < 60 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(model.recorder == nil)
        #expect(model.clipStatus == "Cancelled.")
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
    }
}
