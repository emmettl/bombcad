import Foundation
import Testing
import simd

@testable import BlastModel

/// Placing the quarry face's strip by hand, choosing a crop of a terrain file, and the poses
/// between frames for a slow-motion clip (emmettl/bombcad-work#128). Illustrative scene; these are
/// consistency checks.
@Suite("Quarry strip guide")
struct QuarryStripGuideTests {
    static let hill = QuarrySite.builtIn().terrain

    /// Where the built-in face is steepest across: its smoothstep's middle.
    static func faceY(_ x: Float) -> Float { BuiltInHill.faceLine(x) + 1.5 }

    @Test("A point near the face snaps to it from the floor or the top; flat ground has no face")
    func snapsToTheFace() throws {
        for x: Float in [30, 90, 150] {
            for offset: Float in [-14, -4, 6, 15] {
                let p = SIMD2(x, Self.faceY(x) + offset)
                let snapped = try #require(QuarryStripGuide.snap(p, terrain: Self.hill), "\(p)")
                #expect(abs(snapped.y - Self.faceY(x)) < 3, "\(p) → \(snapped)")
                #expect(abs(snapped.x - x) < 6, "\(p) → \(snapped)")
            }
        }
        let flat = Terrain(spacing: 2, columns: 200, rows: 200, heights: [Float](repeating: 3, count: 40_000))
        #expect(QuarryStripGuide.snap(SIMD2(200, 200), terrain: flat) == nil)
        // Out on the floor, far from the face: nothing within reach.
        #expect(QuarryStripGuide.snap(SIMD2(90, -120), terrain: Self.hill) == nil)
    }

    @Test("The strip's lines follow the face, with the new face's line its depth into the hill")
    func linesFollowTheFace() {
        let lines = QuarryStripGuide.lines(terrain: Self.hill, start: SIMD2(0, 0), end: SIMD2(180, 0))
        #expect(lines.face.count == 61)
        #expect(lines.back.count == lines.face.count)
        for (p, q) in zip(lines.face, lines.back) {
            // Smoothed over 12 m, so within a few metres of the face's wiggles.
            #expect(abs(p.y - Self.faceY(p.x)) < 4, "\(p)")
            #expect(abs((q.y - p.y) - 26) < 1e-3)
            // Half way up the face: well above the floor and below the top.
            let floor = Self.hill.height(at: SIMD2(p.x, p.y - 8))
            let top = Self.hill.height(at: SIMD2(p.x, p.y + 8))
            #expect(p.z > floor + 0.25 * (top - floor) && p.z < floor + 0.75 * (top - floor), "\(p)")
            #expect(q.z > p.z)
        }
        // Into the hill whichever way the strip was dragged.
        let into = QuarryStripGuide.inward(terrain: Self.hill, start: SIMD2(0, 0), end: SIMD2(180, 0))
        let back = QuarryStripGuide.inward(terrain: Self.hill, start: SIMD2(180, 0), end: SIMD2(0, 0))
        #expect(simd_distance(into, SIMD2(0, 1)) < 1e-5)
        #expect(simd_distance(back, SIMD2(0, 1)) < 1e-5)
    }

    @Test("A first strip lies along the steepest face, and none is offered on flat ground")
    func suggestsAStrip() throws {
        let strip = try #require(QuarryStripGuide.suggest(terrain: Self.hill))
        #expect(abs(simd_distance(strip.start, strip.end) - 180) < 0.5)
        let middle = (strip.start + strip.end) / 2
        #expect(abs(middle.y - Self.faceY(middle.x)) < 5, "\(middle)")
        let along = simd_normalize(strip.end - strip.start)
        #expect(abs(along.x) > 0.85, "\(along) \(strip)")
        // It breaks: the layout finds a face under it.
        _ = try QuarryFace(site: QuarrySite(terrain: Self.hill, start: strip.start, end: strip.end))
        let flat = Terrain(spacing: 2, columns: 300, rows: 300, heights: [Float](repeating: 0, count: 90_000))
        #expect(QuarryStripGuide.suggest(terrain: flat) == nil)
    }

    @Test("A crop stays inside the file, between its smallest and largest, where it was put")
    func cropStaysInside() {
        var crop = QuarryTerrainCrop(extent: SIMD2(3000, 2000))
        #expect(crop.side == 1200)
        #expect(crop.corner == SIMD2(900, 400))
        crop.move(centre: SIMD2(100, 100))
        #expect(crop.corner == .zero)
        crop.move(centre: SIMD2(2990, 1990))
        #expect(crop.corner == SIMD2(1800, 800))
        crop.resize(100)
        #expect(crop.side == QuarryTerrainCrop.smallest)
        #expect(abs(crop.centre.x - 2400) < 1e-3 && abs(crop.centre.y - 1400) < 1e-3)
        crop.resize(5000)
        #expect(crop.side == 1200)
        #expect(crop.corner == SIMD2(1800, 800))
        // A small file: the whole of it.
        let small = QuarryTerrainCrop(extent: SIMD2(500, 800))
        #expect(small.side == 500)
        #expect(small.corner == SIMD2(0, 150))
    }

    @Test("The crop's terrain comes from where it was chosen in a file far from the origin")
    func cropReadsTheChosenPlace() throws {
        // A projected file 4 km by 3 km at 10 m whose ground rises 1 m every 100 m east.
        let (columns, rows) = (401, 301)
        let southWest = SIMD2<Double>(512_000, 4_180_000)
        var elevations = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns { elevations[i + columns * j] = 100 + Float(i) * 0.1 + Float(j) * 0.02 }
        }
        let grid = ElevationGrid(
            columns: columns, rows: rows, southWest: southWest, step: SIMD2(10, 10), units: .metres,
            elevations: elevations)
        var crop = QuarryTerrainCrop(grid: grid)
        #expect(crop.extent == SIMD2(4000, 3000))
        crop.move(centre: SIMD2(3000, 1000))
        #expect(crop.origin(in: grid) == southWest + SIMD2(2400, 400))
        let terrain = try crop.terrain(from: grid, name: "test")
        #expect(terrain.spacing == 2)
        #expect(terrain.columns == 601)
        // Heights from the crop's own lowest point: 1 m per 100 m east, 0.2 m per 100 m north.
        #expect(abs(terrain.height(at: SIMD2(0, 0))) < 1e-3)
        #expect(abs(terrain.height(at: SIMD2(1000, 0)) - 10) < 1e-2)
        #expect(abs(terrain.height(at: SIMD2(0, 1000)) - 2) < 1e-2)
    }

    @Test("A shaded relief is the size asked for, with the files' gaps shown apart")
    func reliefHasItsSize() {
        let pixels = QuarryRelief.rgba(width: 40, height: 30, metresPerPixel: 5) { p in
            p.x < 100 ? p.y * 0.5 : nil
        }
        #expect(pixels.count == 40 * 30 * 4)
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
        // The gap (east half) is a flat grey; the slope (west half) is lit.
        let gap = 4 * (35 + 40 * 10)
        #expect(pixels[gap] == 60)
        let lit = 4 * (5 + 40 * 10)
        #expect(pixels[lit] > 60)
    }

    @Test("Poses between frames lie between them; at whole frames they are the frames")
    func posesBetweenFrames() {
        let bodies = 50
        let frames = 8
        let low = SIMD3<Float>(-90, -190, -6)
        let high = SIMD3<Float>(290, 110, 110)
        func pose(_ f: Int) -> [SIMD4<Float>] {
            (0..<bodies).flatMap { n -> [SIMD4<Float>] in
                let angle = Float(f) * 0.1 + Float(n) * 0.01
                return [
                    SIMD4(Float(f * f), Float(n), 5, f >= 3 ? 1 : 0),
                    SIMD4(0, 0, sin(angle / 2), cos(angle / 2)),
                ]
            }
        }
        let cache = QuarryPoseCache(
            rest: pose(0), still: [Bool](repeating: false, count: bodies), frames: frames, low: low,
            high: high, stride: 2)
        for f in 0..<frames {
            pose(f).withUnsafeBufferPointer { cache.store(frame: f, pose: $0.baseAddress!) }
        }
        var whole = [SIMD4<Float>](repeating: .zero, count: 2 * bodies)
        var between = whole
        for f in 0..<frames {
            whole.withUnsafeMutableBufferPointer { cache.decode(frame: f, into: $0.baseAddress!) }
            between.withUnsafeMutableBufferPointer { cache.decode(at: Double(f), into: $0.baseAddress!) }
            for k in 0..<2 * bodies { #expect(simd_distance(whole[k], between[k]) < 1e-6, "frame \(f)") }
        }
        // A quarter of the way from stored frame 2 to stored frame 4: x from 4 to 16.
        between.withUnsafeMutableBufferPointer { cache.decode(at: 2.5, into: $0.baseAddress!) }
        #expect(abs(between[0].x - 7) < 0.02)
        #expect(between[0].w == 0)
        between.withUnsafeMutableBufferPointer { cache.decode(at: 3.25, into: $0.baseAddress!) }
        #expect(abs(between[0].x - 11.5) < 0.02)
        #expect(between[0].w == 1)
        // The last stretch, from stored frame 6 to the last, frame 7.
        between.withUnsafeMutableBufferPointer { cache.decode(at: 6.5, into: $0.baseAddress!) }
        #expect(abs(between[0].x - 42.5) < 0.02)
        #expect(abs(simd_length(between[1]) - 1) < 1e-5)
        // Past the end, held at the last frame.
        between.withUnsafeMutableBufferPointer { cache.decode(at: 99, into: $0.baseAddress!) }
        #expect(abs(between[0].x - 49) < 0.02)
    }
}
