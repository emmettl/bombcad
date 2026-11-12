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
