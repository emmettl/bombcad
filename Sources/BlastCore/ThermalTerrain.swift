import Foundation
import simd

/// The terrain as the fireball's sight lines meet it: the bilinear surface `Terrain.height`
/// describes, cell by cell, each cell the patch between four nodes, and a ring of cells round the
/// nodes `reach` wide where the edge is carried outward. A segment is blocked where it passes
/// below the surface. Along a segment the surface over one cell is a quadratic in the distance
/// (bilinear in x and y, each linear in it), so the lowest the segment comes beneath it is found
/// exactly, at the cell's two edges and the quadratic's turning point.
///
/// The CPU walks a segment's cells row by row; the GPU (Thermal.metal) is offered each cell as a
/// bounding box from the floor to its highest node and runs the same test, operation for
/// operation, every product that is added written as a fused multiply-add so that neither
/// compiler can fuse differently.
public struct TerrainSight: Sendable {
    public let terrain: Terrain
    /// Each cell's highest node, (columns + 1) × (rows + 1) cells, x fastest; cell (a, b) lies
    /// between nodes a − 1 and a along x, the first and last beyond the nodes.
    let tops: [Float]
    /// Each row of cells' highest node.
    let rowTops: [Float]
    /// How far beyond the nodes the outer ring of cells runs, in metres.
    static let reach: Float = 1e5

    /// Nil for no terrain or a flat one: the floor's own test is then the same.
    public init?(_ terrain: Terrain?) {
        guard let terrain, !terrain.isFlat else { return nil }
        self.terrain = terrain
        let (cx, cy) = (terrain.columns + 1, terrain.rows + 1)
        var tops = [Float](repeating: 0, count: cx * cy)
        for b in 0..<cy {
            for a in 0..<cx {
                let (i0, i1) = Self.nodes(a, terrain.columns)
                let (j0, j1) = Self.nodes(b, terrain.rows)
                tops[a + cx * b] = max(
                    max(terrain.height(column: i0, row: j0), terrain.height(column: i1, row: j0)),
                    max(terrain.height(column: i0, row: j1), terrain.height(column: i1, row: j1)))
            }
        }
        self.tops = tops
        rowTops = (0..<cy).map { b in tops[cx * b..<cx * (b + 1)].max()! }
    }

    var cellColumns: Int { terrain.columns + 1 }
    var cellRows: Int { terrain.rows + 1 }
    var cellCount: Int { cellColumns * cellRows }

    /// The nodes either side of cell `a` along an axis of `count` nodes: the same node twice
    /// beyond the edge.
    static func nodes(_ a: Int, _ count: Int) -> (Int, Int) {
        (min(max(a - 1, 0), count - 1), min(max(a, 0), count - 1))
    }

    /// The span of cell `a` along an axis whose nodes start at `origin`.
    static func span(_ a: Int, _ count: Int, origin: Float, spacing: Float) -> (Float, Float) {
        let low = a == 0 ? origin - reach : origin + Float(a - 1) * spacing
        let high = a == count ? origin + Float(count - 1) * spacing + reach : origin + Float(a) * spacing
        return (low, high)
    }

    /// A margin above a cell's top within which rounding could still put a point under it.
    static func margin(_ top: Float) -> Float { Float(0.001).addingProduct(1e-5, abs(top)) }

    /// Each cell's box, from the floor to its highest node, for the GPU's acceleration structure.
    var cellBounds: [Box] {
        var boxes: [Box] = []
        boxes.reserveCapacity(cellCount)
        for b in 0..<cellRows {
            let (y0, y1) = Self.span(b, terrain.rows, origin: terrain.origin.y, spacing: terrain.spacing)
            for a in 0..<cellColumns {
                let (x0, x1) = Self.span(
                    a, terrain.columns, origin: terrain.origin.x, spacing: terrain.spacing)
                boxes.append(Box(min: SIMD3(x0, y0, 0), max: SIMD3(x1, y1, tops[a + cellColumns * b])))
            }
        }
        return boxes
    }

    /// One cell's patch as the test reads it.
    struct Patch {
        var x0, y0, x1, y1: Float
        var h00, h10, h01, h11: Float
        /// The highest of the four.
        var top: Float
        /// The reciprocal of the spacing along x and y, zero beyond the nodes, where the surface
        /// does not change along that axis.
        var sx, sy: Float
    }

    func patch(_ a: Int, _ b: Int) -> Patch {
        let t = terrain
        let (i0, i1) = Self.nodes(a, t.columns)
        let (j0, j1) = Self.nodes(b, t.rows)
        let (x0, x1) = Self.span(a, t.columns, origin: t.origin.x, spacing: t.spacing)
        let (y0, y1) = Self.span(b, t.rows, origin: t.origin.y, spacing: t.spacing)
        let inverse = 1 / t.spacing
        return Patch(
            x0: x0, y0: y0, x1: x1, y1: y1, h00: t.height(column: i0, row: j0),
            h10: t.height(column: i1, row: j0),
            h01: t.height(column: i0, row: j1), h11: t.height(column: i1, row: j1),
            top: tops[a + cellColumns * b], sx: i0 == i1 ? 0 : inverse,
            sy: j0 == j1 ? 0 : inverse)
    }

    /// The height of `point` above the patch: negative below it.
    static func clearance(_ p: Patch, _ point: SIMD3<Float>) -> Float {
        let fx = (point.x - p.x0) * p.sx
        let fy = (point.y - p.y0) * p.sy
        let bottom = p.h00.addingProduct(fx, p.h10 - p.h00)
        let top = p.h01.addingProduct(fx, p.h11 - p.h01)
        return point.z - bottom.addingProduct(fy, top - bottom)
    }

    /// Where `start` + t `delta` is within the patch's footprint, for t in [`low`, `high`].
    static func clip(
        _ p: Patch, _ start: SIMD3<Float>, _ delta: SIMD3<Float>, _ low: inout Float, _ high: inout Float
    )
        -> Bool
    {
        clip(p.x0, p.x1, start.x, delta.x, &low, &high) && clip(p.y0, p.y1, start.y, delta.y, &low, &high)
    }

    /// The slab test along one axis, as `CPUThermalVisibility.blocks` does it.
    static func clip(
        _ lower: Float, _ upper: Float, _ s: Float, _ d: Float, _ low: inout Float, _ high: inout Float
    )
        -> Bool
    {
        if abs(d) < 1e-12 { return s >= lower && s <= upper }
        var a = (lower - s) / d
        var b = (upper - s) / d
        if a > b { swap(&a, &b) }
        low = max(low, a)
        high = min(high, b)
        return low <= high
    }

    /// The point `start` + t `delta`.
    static func point(_ start: SIMD3<Float>, _ delta: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        SIMD3(
            start.x.addingProduct(t, delta.x), start.y.addingProduct(t, delta.y),
            start.z.addingProduct(t, delta.z))
    }

    /// The clearance's rate of change with t at `point`, and half its second derivative (constant).
    static func slope(_ p: Patch, _ point: SIMD3<Float>, _ delta: SIMD3<Float>) -> (Float, Float) {
        let fx = (point.x - p.x0) * p.sx
        let fy = (point.y - p.y0) * p.sy
        let bx = delta.x * p.sx
        let by = delta.y * p.sy
        let twist = (p.h11 - p.h01) - (p.h10 - p.h00)
        let alongX = (p.h10 - p.h00).addingProduct(fy, twist)
        let alongY = (p.h01 - p.h00).addingProduct(fx, twist)
        let rate = delta.z - (by * alongY).addingProduct(bx, alongX)
        return (rate, -(bx * by) * twist)
    }

    /// Whether the segment from `start` by `delta` passes below the patch: its clearance at the
    /// ends of its run over the cell, and at the turning point between if the clearance curves up.
    static func blocks(_ p: Patch, _ start: SIMD3<Float>, _ delta: SIMD3<Float>) -> Bool {
        var low: Float = 0
        var high: Float = 1
        guard clip(p, start, delta, &low, &high) else { return false }
        let first = point(start, delta, low)
        let last = point(start, delta, high)
        // Above the patch's highest node throughout: nothing to find.
        if min(first.z, last.z) > p.top + margin(p.top) { return false }
        if clearance(p, first) < 0 || clearance(p, last) < 0 { return true }
        let (rate, curve) = slope(p, first, delta)
        guard curve > 0 else { return false }
        let turn = low + -rate / (2 * curve)
        return turn > low && turn < high && clearance(p, point(start, delta, turn)) < 0
    }

    /// Where the ray from `origin` along `direction` first goes below the patch, if before
    /// `limit`; `low` if it starts below it.
    static func entry(_ p: Patch, _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ limit: Float) -> Float?
    {
        var low: Float = 0
        var high = limit
        guard clip(p, origin, direction, &low, &high) else { return nil }
        let first = point(origin, direction, low)
        if min(first.z, point(origin, direction, high).z) > p.top + margin(p.top) { return nil }
        let c0 = clearance(p, first)
        if c0 <= 0 { return low < limit ? low : nil }
        let (c1, c2) = slope(p, first, direction)
        // The smallest positive root of c0 + c1 u + c2 u².
        var u = Float.infinity
        if c2 == 0 {
            if c1 < 0 { u = -c0 / c1 }
        } else {
            let disc = (-4 * c2 * c0).addingProduct(c1, c1)
            if disc >= 0 {
                let q = -0.5 * (c1 + (c1 < 0 ? -disc.squareRoot() : disc.squareRoot()))
                let (r1, r2) = (q / c2, c0 / q)
                if r1 > 0 { u = min(u, r1) }
                if r2 > 0 { u = min(u, r2) }
            }
        }
        let t = low + u
        return u.isFinite && t <= high && t < limit ? t : nil
    }

    /// Every cell the segment from `start` by `delta` may pass under (a few more besides, which
    /// the exact test turns away), passed to `visit` until it returns true.
    func cells(
        from start: SIMD3<Float>, by delta: SIMD3<Float>, _ visit: (Int, Int) -> Bool
    ) -> Bool {
        let t = terrain
        // A cell's index along an axis, nudged by `slack` so that a segment touching a cell's
        // edge visits it too; the exact test turns away those it does not cross.
        let slack = 1e-3 * t.spacing
        func index(_ v: Float, _ origin: Float, _ count: Int) -> Int {
            let raw = ((v - origin) / t.spacing).rounded(.down)
            return Int(min(max(raw, -1), Float(count - 1))) + 1
        }
        let end = start + delta
        let rowLow = index(min(start.y, end.y) - slack, t.origin.y, t.rows)
        let rowHigh = index(max(start.y, end.y) + slack, t.origin.y, t.rows)
        for b in rowLow...rowHigh {
            // The part of the segment over this row, then the columns under it.
            var low: Float = 0
            var high: Float = 1
            let (y0, y1) = Self.span(b, t.rows, origin: t.origin.y, spacing: t.spacing)
            if abs(delta.y) >= 1e-12 {
                var a = (y0 - slack - start.y) / delta.y
                var c = (y1 + slack - start.y) / delta.y
                if a > c { swap(&a, &c) }
                low = max(low, a)
                high = min(high, c)
                if low > high { continue }
            }
            let za = start.z + low * delta.z
            let zb = start.z + high * delta.z
            if min(za, zb) > rowTops[b] + Self.margin(rowTops[b]) { continue }
            let xa = start.x + low * delta.x
            let xb = start.x + high * delta.x
            let columnLow = index(min(xa, xb) - slack, t.origin.x, t.columns)
            let columnHigh = index(max(xa, xb) + slack, t.origin.x, t.columns)
            for a in columnLow...columnHigh {
                let top = tops[a + cellColumns * b]
                if min(za, zb) > top + Self.margin(top) { continue }
                if visit(a, b) { return true }
            }
        }
        return false
    }

    /// Whether the segment from `start` to `end` passes below the surface anywhere.
    public func blocks(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Bool {
        let highest = terrain.highest
        if min(start.z, end.z) > highest + Self.margin(highest) { return false }
        let delta = end - start
        return cells(from: start, by: delta) { a, b in Self.blocks(patch(a, b), start, delta) }
    }

    /// How far along the ray from `origin` the surface is first met, or `limit` if not before.
    public func nearest(from origin: SIMD3<Float>, along direction: SIMD3<Float>, within limit: Float)
        -> Float
    {
        let highest = terrain.highest
        let top = highest + Self.margin(highest)
        // Rising, the ray can meet the surface only below its highest point; nor need it be
        // followed beyond the outer ring.
        var reach = min(limit, 4 * Self.reach)
        if direction.z > 0 { reach = min(reach, max(0, (top - origin.z) / direction.z)) }
        if origin.z > top && direction.z >= 0 { return limit }
        guard reach > 0 else { return limit }
        var nearest = limit
        _ = cells(from: origin, by: reach * direction) { a, b in
            if let t = Self.entry(patch(a, b), origin, direction, nearest) { nearest = t }
            return false
        }
        return nearest
    }
}
