import Foundation
import simd

/// Placing a quarry face's strip by hand: the face line under a point, the strip's line along the
/// face drawn over the 3-D view, and a first strip on a terrain that has none yet. Everything is in
/// the ground's own metres (a `Terrain`'s scene coordinates). Illustrative: for choosing where the
/// stylised scene breaks, not a survey of a face (emmettl/bombcad-work#128).
public enum QuarryStripGuide {
    /// The steepest rise, over 2 m, that counts as a face: about 22°.
    public static let faceRise: Float = 0.8

    /// The rise over 2 m across `p` along `direction` (a unit vector).
    static func rise(_ terrain: Terrain, _ p: SIMD2<Float>, _ direction: SIMD2<Float>) -> Float {
        terrain.height(at: p + direction) - terrain.height(at: p - direction)
    }

    /// The uphill direction at `p`, from the slope over `span` metres either way; nil on the flat.
    public static func uphill(_ terrain: Terrain, at p: SIMD2<Float>, span: Float = 4) -> SIMD2<Float>? {
        let g = SIMD2(
            terrain.height(at: p + SIMD2(span, 0)) - terrain.height(at: p - SIMD2(span, 0)),
            terrain.height(at: p + SIMD2(0, span)) - terrain.height(at: p - SIMD2(0, span)))
        let length = simd_length(g)
        return length > 1e-4 ? g / length : nil
    }

    /// The steepness at `q`: the rise over 2 m up its own slope.
    static func steepness(_ terrain: Terrain, _ q: SIMD2<Float>) -> Float {
        let g = SIMD2(
            terrain.height(at: q + SIMD2(1, 0)) - terrain.height(at: q - SIMD2(1, 0)),
            terrain.height(at: q + SIMD2(0, 1)) - terrain.height(at: q - SIMD2(0, 1)))
        return simd_length(g)
    }

    /// The face line nearest `p`: of the ground within `reach` metres steep enough to be a face,
    /// the nearest part, then the steepest point across the face there. Nil where nothing near is
    /// steep enough.
    public static func snap(_ p: SIMD2<Float>, terrain: Terrain, reach: Float = 25) -> SIMD2<Float>? {
        var nearest: SIMD2<Float>?
        var distance = Float.infinity
        let cell: Float = 1
        var y = -reach
        while y <= reach {
            var x = -reach
            while x <= reach {
                let d = (x * x + y * y).squareRoot()
                if d <= reach, d < distance {
                    let q = p + SIMD2(x, y)
                    if steepness(terrain, q) >= faceRise {
                        nearest = q
                        distance = d
                    }
                }
                x += cell
            }
            y += cell
        }
        guard let edge = nearest, let up = uphill(terrain, at: edge, span: 2) else { return nearest }
        // Across the face from its nearest edge, to its steepest line.
        var best = -Float.infinity
        var at = edge
        var t: Float = -8
        while t <= 8 {
            let q = edge + up * t
            let r = rise(terrain, q, up)
            if r > best {
                best = r
                at = q
            }
            t += 0.5
        }
        return at
    }

    /// Into the hill from the strip `start`–`end`: the side whose ground is higher, as
    /// `QuarryFace` decides it.
    public static func inward(terrain: Terrain, start: SIMD2<Float>, end: SIMD2<Float>) -> SIMD2<Float> {
        let length = max(simd_distance(start, end), 1e-3)
        let along = (end - start) / length
        var into = SIMD2<Float>(-along.y, along.x)
        let middle = (start + end) / 2
        var higher: Float = 0
        for t: Float in [-0.3, 0, 0.3] {
            let p = middle + along * (t * length)
            higher += terrain.height(at: p + into * 15) - terrain.height(at: p - into * 15)
        }
        if higher < 0 { into = -into }
        return into
    }

    /// The strip drawn on the ground: the old face's line along it (at each step the steepest rise
    /// within 40 m across it, smoothed, as `QuarryFace` finds it), at half the face's height, and
    /// the line `depth` behind it on the ground where the new face will stand, as points (x, y,
    /// height) in the ground's metres.
    public struct Lines: Sendable, Equatable {
        public var face: [SIMD3<Float>]
        public var back: [SIMD3<Float>]
    }

    public static func lines(
        terrain: Terrain, start: SIMD2<Float>, end: SIMD2<Float>, depth: Float = 26, step: Float = 3
    ) -> Lines {
        let length = simd_distance(start, end)
        guard length > 1e-3 else { return Lines(face: [], back: []) }
        let along = (end - start) / length
        let into = inward(terrain: terrain, start: start, end: end)
        let count = max(2, Int((length / step).rounded(.up)) + 1)
        var offsets = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let p = start + along * (length * Float(i) / Float(count - 1))
            var best = -Float.infinity
            var y: Float = -40
            while y <= 40 {
                let r = rise(terrain, p + into * y, into)
                if r > best {
                    best = r
                    offsets[i] = y
                }
                y += 0.5
            }
        }
        // Smoothed over about 12 m, as the layout smooths its own over 9 m.
        let half = max(1, Int(6 / step))
        var smoothed = offsets
        for i in 0..<count {
            let range = max(0, i - half)...min(count - 1, i + half)
            smoothed[i] = range.reduce(0) { $0 + offsets[$1] } / Float(range.count)
        }
        // The face's line at half its height, between the floor 8 m out and the top 8 m in (as
        // the layout measures them), smoothed too: on a steep face the height at the steepest
        // point jumps with every metre the line wanders.
        let points = (0..<count).map {
            start + along * (length * Float($0) / Float(count - 1)) + into * smoothed[$0]
        }
        let middles = points.map {
            (terrain.height(at: $0 - into * 8) + terrain.height(at: $0 + into * 8)) / 2
        }
        var face: [SIMD3<Float>] = []
        var back: [SIMD3<Float>] = []
        for i in 0..<count {
            let range = max(0, i - half)...min(count - 1, i + half)
            let z = range.reduce(0) { $0 + middles[$1] } / Float(range.count)
            face.append(SIMD3(points[i], z))
            let q = points[i] + into * depth
            back.append(SIMD3(q, terrain.height(at: q)))
        }
        return Lines(face: face, back: back)
    }

    /// A first strip on `terrain`: `length` metres along the contour through the steepest ground
    /// at least `margin` in from its edges, centred there. Nil when nothing is steep enough to be
    /// a face.
    public static func suggest(terrain: Terrain, length: Float = 180, margin: Float = 60) -> (
        start: SIMD2<Float>, end: SIMD2<Float>
    )? {
        let extent = SIMD2(Float(terrain.columns - 1), Float(terrain.rows - 1)) * terrain.spacing
        let low = terrain.origin + min(margin, extent.min() / 4)
        let high = terrain.origin + extent - min(margin, extent.min() / 4)
        guard all(high .> low) else { return nil }
        // Steepness over 8 m on a grid of about 160 x 160, so a lone spike in a survey does not win.
        let cell = max(terrain.spacing, (high - low).max() / 160)
        var best: Float = 0
        var at: SIMD2<Float>?
        var y = low.y
        while y <= high.y {
            var x = low.x
            while x <= high.x {
                let p = SIMD2(x, y)
                let g = SIMD2(
                    terrain.height(at: p + SIMD2(4, 0)) - terrain.height(at: p - SIMD2(4, 0)),
                    terrain.height(at: p + SIMD2(0, 4)) - terrain.height(at: p - SIMD2(0, 4)))
                let s = simd_length(g)
                if s > best {
                    best = s
                    at = p
                }
                x += cell
            }
            y += cell
        }
        // 8 m across: a rise of four times a face's 2 m rise.
        guard let centre = at, best >= 4 * faceRise else { return nil }
        let middle = snap(centre, terrain: terrain) ?? centre
        // Along the face as it runs over tens of metres, not its local wiggle.
        guard let up = uphill(terrain, at: middle, span: 15) else { return nil }
        var along = SIMD2(up.y, -up.x)
        let half = min(length, extent.min() * 0.6) / 2
        // Then along the face as it runs the strip's whole length: through its line at both ends.
        // Out from the middle in steps, so the line is followed round its bends.
        for reach in [min(30, half), min(60, half), half] {
            guard let a = snap(middle - along * reach, terrain: terrain),
                let b = snap(middle + along * reach, terrain: terrain), simd_distance(a, b) > reach
            else { continue }
            along = simd_normalize(b - a)
        }
        return (middle - along * half, middle + along * half)
    }
}

/// A crop of an elevation file for the quarry face: a square up to 1.2 km across, chosen on an
/// overview of the whole file, in metres from the file's south-west corner (emmettl/bombcad-work#128).
public struct QuarryTerrainCrop: Sendable, Equatable {
    /// The largest crop, and the smallest the face's own grid fits in (m).
    public static let largest: Float = 1200
    public static let smallest: Float = 300
    /// The crop's spacing (m).
    public static let spacing: Float = 2

    /// The file's extent in metres (east, north) from its south-west cell centre.
    public let extent: SIMD2<Float>
    /// The crop's south-west corner, from the file's, and its side (m).
    public private(set) var corner: SIMD2<Float>
    public private(set) var side: Float

    /// The largest crop the file allows, round its middle.
    public init(grid: ElevationGrid) {
        let spacing = grid.spacingInMetres(near: grid.southWest)
        self.init(
            extent: SIMD2(
                Float(Double(grid.columns - 1) * spacing.x), Float(Double(grid.rows - 1) * spacing.y)))
    }

    public init(extent: SIMD2<Float>) {
        self.extent = extent
        side = min(Self.largest, extent.min())
        corner = simd_max((extent - side) / 2, .zero)
    }

    /// Moves the crop's centre to `centre` (m from the file's corner), kept inside the file.
    public mutating func move(centre: SIMD2<Float>) {
        corner = simd_clamp(centre - side / 2, .zero, simd_max(extent - side, .zero))
    }

    /// Changes the side, kept between the smallest and largest and inside the file, about the
    /// same centre.
    public mutating func resize(_ newSide: Float) {
        let middle = centre
        side = min(max(newSide, Self.smallest), Self.largest, extent.min())
        move(centre: middle)
    }

    public var centre: SIMD2<Float> { corner + side / 2 }

    /// The grid coordinates of the crop's (0, 0), for `ElevationGrid.terrain(origin:…)`.
    public func origin(in grid: ElevationGrid) -> SIMD2<Double> {
        grid.coordinates(of: SIMD2<Double>(corner), origin: grid.southWest)
    }

    /// The crop's terrain at 2 m, its (0, 0) at the crop's corner.
    public func terrain(from grid: ElevationGrid, name: String?) throws -> Terrain {
        try grid.terrain(
            origin: origin(in: grid), size: SIMD2(repeating: side), spacing: Self.spacing, name: name
        ).terrain
    }
}

/// A shaded relief for the quarry face's maps: RGBA bytes, rows from the north, lit from the
/// north-west, toned by height. `height` gives the ground (nil where there is no data) at a point
/// in the map's own metres from its south-west corner.
public enum QuarryRelief {
    public static func rgba(
        width: Int, height rows: Int, metresPerPixel: Float, height: (SIMD2<Float>) -> Float?
    ) -> [UInt8] {
        var values = [Float](repeating: .nan, count: width * rows)
        var lowest = Float.infinity
        var highest = -Float.infinity
        for j in 0..<rows {
            for i in 0..<width {
                if let h = height(SIMD2(Float(i) + 0.5, Float(j) + 0.5) * metresPerPixel), h.isFinite {
                    values[i + width * j] = h
                    lowest = min(lowest, h)
                    highest = max(highest, h)
                }
            }
        }
        let light = simd_normalize(SIMD3<Float>(-0.6, 0.5, 0.65))
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        func at(_ i: Int, _ j: Int) -> Float {
            values[max(0, min(width - 1, i)) + width * max(0, min(rows - 1, j))]
        }
        for j in 0..<rows {
            for i in 0..<width {
                let h = values[i + width * j]
                // Rows from the top, so north is up.
                let k = 4 * (i + width * (rows - 1 - j))
                guard !h.isNaN else {
                    pixels[k] = 60
                    pixels[k + 1] = 64
                    pixels[k + 2] = 72
                    pixels[k + 3] = 255
                    continue
                }
                func slope(_ a: Float, _ b: Float) -> Float { a.isNaN || b.isNaN ? 0 : a - b }
                let dx = slope(at(i + 1, j), at(i - 1, j)) / (2 * metresPerPixel)
                let dy = slope(at(i, j + 1), at(i, j - 1)) / (2 * metresPerPixel)
                let n = simd_normalize(SIMD3(-dx, -dy, 1))
                let lit = max(0, simd_dot(n, light))
                let tone = 0.35 + 0.45 * lit + 0.2 * (h - lowest) / max(highest - lowest, 1)
                pixels[k] = UInt8(max(0, min(255, tone * 200)))
                pixels[k + 1] = UInt8(max(0, min(255, tone * 185)))
                pixels[k + 2] = UInt8(max(0, min(255, tone * 160)))
                pixels[k + 3] = 255
            }
        }
        return pixels
    }
}
