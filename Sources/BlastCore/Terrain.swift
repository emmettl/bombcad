import Foundation
import simd

/// The ground's shape: a regular grid of elevations over the scene's floor, joined bilinearly
/// between its nodes. The air sees it as rigid solid: a cell is solid where its centre lies below
/// the surface, on the coarse grid and on every level of refinement, as a cell is solid where its
/// centre lies inside a block. Heights are metres above the domain's floor, z = 0, which stays the
/// reflecting face beneath it; with no terrain (the default) the floor is the ground.
public struct Terrain: Sendable, Hashable, Codable {
    /// The scene position (x, y) of the first node, in metres.
    public var origin: SIMD2<Float>
    /// The distance between neighbouring nodes, in metres, the same along x and y.
    public var spacing: Float
    /// Nodes along x and along y.
    public var columns: Int
    public var rows: Int
    /// Elevation of each node above z = 0, in metres, x fastest.
    public var heights: [Float]
    /// Where the heights came from (a DEM's name and crop, or the shape that made them).
    public var source: String?

    public init(
        origin: SIMD2<Float> = .zero, spacing: Float, columns: Int, rows: Int, heights: [Float],
        source: String? = nil
    ) {
        self.origin = origin
        self.spacing = spacing
        self.columns = columns
        self.rows = rows
        self.heights = heights
        self.source = source
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidGrid
        case invalidHeight
        case tooHigh(Float)

        public var description: String {
            switch self {
            case .invalidGrid:
                "The terrain needs at least 2 × 2 nodes, a positive spacing and one height a node."
            case .invalidHeight: "Every terrain height must be finite and at or above the domain's floor."
            case .tooHigh(let top):
                "The terrain rises to \(top) m, to the domain's top or above it; raise the domain."
            }
        }
    }

    public func validate(domain: SIMD3<Float>? = nil) throws {
        guard columns >= 2, rows >= 2, spacing.isFinite, spacing > 0, heights.count == columns * rows,
            origin.x.isFinite, origin.y.isFinite
        else { throw Failure.invalidGrid }
        guard heights.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw Failure.invalidHeight }
        if let domain, let top = heights.max(), top >= domain.z { throw Failure.tooHigh(top) }
    }

    /// True when every node is on the floor: the air then sees exactly the flat ground.
    public var isFlat: Bool { heights.allSatisfy { $0 <= 0 } }

    public var highest: Float { heights.max() ?? 0 }

    /// The far corner of the nodes, in scene metres.
    public var extent: SIMD2<Float> { origin + spacing * SIMD2(Float(columns - 1), Float(rows - 1)) }

    public func height(column i: Int, row j: Int) -> Float { heights[i + columns * j] }

    /// The surface's elevation at scene position `p`: bilinear between the four nodes round it,
    /// the edge nodes' value carried outward beyond the grid. The GPU's `terrainHeight` in
    /// Refine.metal does the same arithmetic.
    public func height(at p: SIMD2<Float>) -> Float {
        let last = SIMD2(Float(columns - 1), Float(rows - 1))
        let position = simd_clamp((p - origin) / spacing, .zero, last)
        let low = simd_min(SIMD2<Int>(position.rounded(.down)), SIMD2(columns - 2, rows - 2))
        let f = position - SIMD2<Float>(low)
        let base = low.x + columns * low.y
        let h00 = heights[base]
        let h10 = heights[base + 1]
        let h01 = heights[base + columns]
        let h11 = heights[base + columns + 1]
        let bottom = h00 + f.x * (h10 - h00)
        let top = h01 + f.x * (h11 - h01)
        return bottom + f.y * (top - bottom)
    }

    public func height(at p: SIMD3<Float>) -> Float { height(at: SIMD2(p.x, p.y)) }

    /// The upward unit normal of the surface at `p`, from the bilinear patch's slope there (flat
    /// beyond the grid, where the edge is carried outward).
    public func normal(at p: SIMD2<Float>) -> SIMD3<Float> {
        let last = SIMD2(Float(columns - 1), Float(rows - 1))
        let raw = (p - origin) / spacing
        let position = simd_clamp(raw, .zero, last)
        let low = simd_min(SIMD2<Int>(position.rounded(.down)), SIMD2(columns - 2, rows - 2))
        let f = position - SIMD2<Float>(low)
        let base = low.x + columns * low.y
        let h00 = heights[base]
        let h10 = heights[base + 1]
        let h01 = heights[base + columns]
        let h11 = heights[base + columns + 1]
        var dx = ((h10 - h00) * (1 - f.y) + (h11 - h01) * f.y) / spacing
        var dy = ((h01 - h00) * (1 - f.x) + (h11 - h10) * f.x) / spacing
        if raw.x < 0 || raw.x > last.x { dx = 0 }
        if raw.y < 0 || raw.y > last.y { dy = 0 }
        return simd_normalize(SIMD3(-dx, -dy, 1))
    }

    /// True when `point` is below the surface.
    public func contains(_ point: SIMD3<Float>) -> Bool { point.z < height(at: point) }

    /// How many cells of `grid`'s column (i, j) lie below the surface: those whose centre is
    /// below the surface at the column's centre. Its first cell of air is at this height index.
    public func buriedCells(i: Int, j: Int, grid: Grid) -> Int {
        let dx = grid.cellSize
        let h = height(at: SIMD2((Float(i) + 0.5) * dx, (Float(j) + 0.5) * dx))
        // Cell k is solid when (k + 0.5) dx < h.
        let count = Int((h / dx - 0.5).rounded(.up))
        return min(max(count, 0), grid.nz)
    }

    /// The first cell of air above the surface in every column of `grid`, x fastest.
    public func surfaceCells(grid: Grid) -> [Int32] {
        var cells = [Int32](repeating: 0, count: grid.nx * grid.ny)
        for j in 0..<grid.ny {
            for i in 0..<grid.nx { cells[i + grid.nx * j] = Int32(buriedCells(i: i, j: j, grid: grid)) }
        }
        return cells
    }
}

// MARK: - Shapes

extension Terrain {
    /// Nodes `spacing` apart covering the domain's floor from (0, 0), elevations from `height`.
    public static func sampled(
        domain: SIMD3<Float>, spacing: Float, source: String? = nil, _ height: (SIMD2<Float>) -> Float
    ) -> Terrain {
        let columns = max(2, Int((domain.x / spacing).rounded(.up)) + 1)
        let rows = max(2, Int((domain.y / spacing).rounded(.up)) + 1)
        var heights = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                heights[i + columns * j] = max(0, height(SIMD2(Float(i), Float(j)) * spacing))
            }
        }
        return Terrain(spacing: spacing, columns: columns, rows: rows, heights: heights, source: source)
    }

    /// The floor itself, as a heightfield: the air sees exactly the flat ground.
    public static func flat(domain: SIMD3<Float>, spacing: Float) -> Terrain {
        sampled(domain: domain, spacing: spacing, source: "flat") { _ in 0 }
    }

    /// A plane rising along +x at `angle` degrees from the line x = `foot`, flat before it.
    public static func slope(domain: SIMD3<Float>, spacing: Float, foot: Float, angle: Float) -> Terrain {
        let rise = tan(angle * .pi / 180)
        return sampled(domain: domain, spacing: spacing, source: "slope of \(angle)° from x = \(foot) m") {
            max(0, ($0.x - foot) * rise)
        }
    }

    /// A round Gaussian hill, `height` at `centre`, falling to 1/e at `radius`.
    public static func hill(
        domain: SIMD3<Float>, spacing: Float, centre: SIMD2<Float>, height: Float, radius: Float
    ) -> Terrain {
        sampled(domain: domain, spacing: spacing, source: "hill \(height) m high, \(radius) m radius") {
            height * exp(-simd_length_squared($0 - centre) / (radius * radius))
        }
    }

    /// A long ridge across y, its crest at x = `crest`, `height` high, with straight flanks of
    /// `halfWidth` either side (a triangle in section).
    public static func ridge(
        domain: SIMD3<Float>, spacing: Float, crest: Float, height: Float, halfWidth: Float
    ) -> Terrain {
        sampled(domain: domain, spacing: spacing, source: "ridge \(height) m high, \(2 * halfWidth) m wide") {
            height * max(0, 1 - abs($0.x - crest) / halfWidth)
        }
    }
}

// MARK: - Persistence

extension Terrain {
    private enum CodingKeys: String, CodingKey { case origin, spacing, columns, rows, heights, source }

    /// Heights are stored as little-endian 32-bit floats, base64 in JSON: exact, and a quarter the
    /// size of decimal text for a DEM's worth of them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(SIMD2<Float>.self, forKey: .origin)
        spacing = try c.decode(Float.self, forKey: .spacing)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        let data = try c.decode(Data.self, forKey: .heights)
        guard data.count == 4 * columns * rows, columns >= 2, rows >= 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .heights, in: c, debugDescription: "terrain heights do not match its grid")
        }
        let count = columns * rows
        heights = data.withUnsafeBytes { raw in
            (0..<count).map {
                Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)))
            }
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin, forKey: .origin)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encodeIfPresent(source, forKey: .source)
        var data = Data(capacity: 4 * heights.count)
        for height in heights {
            withUnsafeBytes(of: height.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        try c.encode(data, forKey: .heights)
    }
}
