import Foundation
import simd

/// The old joints of the rock's weathered surface: three sets, two near-vertical and a sparse
/// inclined one, each joint a long irregular trace that wanders along its strike and down its dip,
/// runs through several beds (now and then jogging a little at a bedding plane, or stopping at
/// one) and dies out over some metres; the spacing varies, joints come in clusters and gaps. They
/// are drawn on the old surface only, as weathered grooves (`QuarryFace.weatheredRelief`) with a
/// dark crack along them (`jointField` in `QuarryRender.metal`, which keeps a copy of this: change
/// them together), so that unbroken rock reads as one mass with joints in it rather than as smooth
/// slabs. Until 13 November 2026 each bed had its own short cracks, evenly spaced, so a face read
/// as coursed masonry (emmettl/bombcad-work#142). They are not where the rock breaks: illustrative,
/// for the eye.
public enum QuarryJoints {
    struct JointSet {
        var normal: SIMD2<Float>
        var along: SIMD2<Float>
        var spacing: Float
        var lean: Float
        /// The share of the places a joint could be that hold one.
        var keep: Float
        var salt: UInt32
    }
    static let sets = [
        JointSet(
            normal: [0.9394, 0.3429], along: [-0.3429, 0.9394], spacing: 3.4, lean: 0.08, keep: 0.6, salt: 17),
        JointSet(
            normal: [-0.3090, 0.9511], along: [-0.9511, -0.3090], spacing: 5.2, lean: -0.05, keep: 0.5,
            salt: 29),
        JointSet(
            normal: [0.8090, -0.5878], along: [0.5878, 0.8090], spacing: 9, lean: 0.55, keep: 0.4, salt: 43),
    ]

    /// A value in 0..<1 from an integer and a salt, the same in the shader.
    public static func hash(_ k: Int32, _ salt: UInt32) -> Float {
        var h = (UInt32(bitPattern: k) &* 0x8DA6_B343) ^ (salt &* 0xCB1A_B31F)
        h ^= h >> 13
        h = h &* 0x4F37_F8A5
        h ^= h >> 16
        return Float(h & 0xFF_FFFF) / 16_777_216
    }

    /// Smooth value noise along a line, in 0..<1.
    static func noise1(_ x: Float, _ salt: UInt32) -> Float {
        let i = floor(x)
        let f = x - i
        let s = f * f * (3 - 2 * f)
        let k = Int32(i)
        let a = hash(k, salt)
        return a + (hash(k &+ 1, salt) - a) * s
    }

    /// Smooth value noise over a plane, in 0..<1.
    static func noise2(_ x: Float, _ y: Float, _ salt: UInt32) -> Float {
        let (i, j) = (floor(x), floor(y))
        let (fx, fy) = (x - i, y - j)
        let (sx, sy) = (fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy))
        let (a, b) = (Int32(i), Int32(j) &* 7919)
        let h00 = hash(a &+ b, salt)
        let h10 = hash(a &+ 1 &+ b, salt)
        let h01 = hash(a &+ b &+ 7919, salt)
        let h11 = hash(a &+ 1 &+ b &+ 7919, salt)
        let low = h00 + (h10 - h00) * sx
        let high = h01 + (h11 - h01) * sx
        return low + (high - low) * sy
    }

    /// How deep in a joint's weathered groove `p` lies (1 on the joint's trace, falling to 0 at
    /// `halfWidth` from it), and how near it is to the open crack along the trace (1 within half
    /// of `line`, 0 from `line`, the crack's width varying along it); each times how open the joint
    /// is there.
    public static func field(_ p: SIMD3<Float>, halfWidth: Float, line: Float) -> (
        groove: Float, crack: Float
    ) {
        var groove: Float = 0
        var crack: Float = 0
        // The shale has none of its own (its partings are along the bedding).
        let bed = Int32(floor(QuarryFracture.bedCoordinate(simd_dot(p, QuarryFace.beddingNormal))))
        guard QuarryRock.kind(bed: Int(bed)) != .shale else { return (0, 0) }
        for set in sets {
            let v = simd_dot(SIMD2(p.x, p.y), set.along)
            let s = Float(set.salt)
            // Wandering along the strike, and down the dip (not ruled upright); a small jog at some
            // bedding planes.
            var u =
                simd_dot(SIMD2(p.x, p.y), set.normal) + set.lean * p.z + 1.1 * sin(0.11 * v + s)
                + 0.35 * sin(0.37 * v + 0.7 * s) + 0.12 * sin(1.3 * v + 1.9 * s)
                + 0.7 * (noise1(p.z * 0.33 + v * 0.05, set.salt &+ 3) - 0.5)
                + 0.06 * (noise1(p.z * 2.3 + v * 1.7, set.salt &+ 7) - 0.5)
                + (hash(bed, set.salt &+ 6) < 0.3 ? (hash(bed, set.salt &+ 5) - 0.5) * 0.8 : 0)
            // The spacing varies: closer here, wider there.
            u += 0.9 * set.spacing * (noise1(u / set.spacing * 0.45, set.salt &+ 4) - 0.5)
            let k0 = Int32(floor(u / set.spacing))
            for dk: Int32 in -1...1 {
                let k = k0 &+ dk
                guard hash(k, set.salt) < set.keep else { continue }
                let centre = (Float(k) + 0.5 + 0.8 * (hash(k, set.salt &+ 1) - 0.5)) * set.spacing
                let d = abs(u - centre)
                guard d < max(halfWidth, 1.55 * line) else { continue }
                // Open over stretches some metres long both ways, through several beds; stopping at
                // a bedding plane here and there.
                let n = noise2(v * 0.045 + Float(k) * 7.31, p.z * 0.07 + Float(k) * 3.7, set.salt &+ 2)
                let open = max(0, min(1, (n - 0.38) / 0.24))
                let confined: Float = hash(bed &* 131 &+ k, set.salt &+ 9) < 0.15 ? 0 : 1
                let openness = open * open * (3 - 2 * open) * confined
                if d < halfWidth {
                    let t = d / halfWidth
                    groove = max(groove, openness * (1 - t * t) * (1 - t * t))
                }
                let width = line * (0.45 + 1.1 * noise1(p.z * 1.4 + v * 0.6 + Float(k), set.salt &+ 8))
                if d < width {
                    let t = max(0, min(1, (d - 0.5 * width) / (0.5 * width)))
                    crack = max(crack, openness * (1 - t * t * (3 - 2 * t)))
                }
            }
        }
        return (groove, crack)
    }
}

extension QuarryFace {
    /// The weathered relief of the old surface, out along its normal `n` (m): grooves along the old
    /// joints, knobs and hollows a metre or two across, and on the harder beds, where the surface
    /// runs nearly along the bedding (a crest, a ledge's top), small steps where laminae have
    /// weathered off. A function of position (and the surface's normal) alone, so neighbouring
    /// blocks, the held skin over them and the render-only rock round a ridge cut all have it alike
    /// (emmettl/bombcad-work#139). Its features are a metre or so and larger, as coarse as the
    /// window's meshes can carry; the finer ones (the cracks, pits) are the shader's.
    public static func weatheredRelief(_ p: SIMD3<Float>, normal n: SIMD3<Float>) -> Float {
        let joint = QuarryJoints.field(p, halfWidth: 0.35, line: 0.05).groove
        var r = -0.07 * joint
        r += 0.05 * QuarryNoise.fbm(p * 0.75 + 41, octaves: 2)
        let c = QuarryFracture.bedCoordinate(simd_dot(p, beddingNormal))
        let amplitude: Float
        switch QuarryRock.kind(bed: Int(floor(c))) {
        case .limestone: amplitude = 0.06
        case .shale: amplitude = 0
        case .sandstone: amplitude = 0.045
        case .ironstone: amplitude = 0.035
        }
        if amplitude > 0 {
            let along = max(0, min(1, (abs(simd_dot(n, beddingNormal)) - 0.75) / 0.17))
            let f = (c * 2) - floor(c * 2)
            let rise = f < 0.8 ? f / 0.8 : (1 - f) / 0.2
            r += amplitude * along * along * (3 - 2 * along) * (0.5 - rise)
        }
        return r
    }

    /// A point of a block's outer surface, `base` lying on the continuous `outer` surface: shaped
    /// by the displacement and relief, then the weathered relief along the surface's normal.
    static func outerPoint(_ base: SIMD3<Float>, outer: OuterSurface, relief: Float) -> SIMD3<Float> {
        let shapedBase = shaped(base, relief: relief)
        let n = outer(base).normal
        return shapedBase + n * weatheredRelief(shapedBase, normal: n)
    }

    /// The continuous outer surface's own normal at a point of it, `here` being `outerPoint(base)`:
    /// forward differences 6 cm along the surface, each brought back onto it once, the same for
    /// every cell (and the skin) that has the point.
    static func outerNormal(
        _ base: SIMD3<Float>, here: SIMD3<Float>, outer: OuterSurface, relief: Float
    ) -> SIMD3<Float> {
        let (_, ns) = outer(base)
        let t1 = simd_normalize(
            abs(ns.z) < 0.9 ? simd_cross(ns, SIMD3(0, 0, 1)) : simd_cross(ns, SIMD3(1, 0, 0)))
        let t2 = simd_cross(ns, t1)
        let e: Float = 0.06
        func at(_ q: SIMD3<Float>) -> SIMD3<Float> {
            outerPoint(q + ns * outer(q).depth, outer: outer, relief: relief)
        }
        let normal = simd_cross(at(base + t1 * e) - here, at(base + t2 * e) - here)
        guard simd_length_squared(normal) > 1e-12 else { return ns }
        let unit = simd_normalize(normal)
        return simd_dot(unit, ns) < 0 ? -unit : unit
    }

    /// The displacement and relief of a block's surface, functions of world position alone.
    static func shaped(_ base: SIMD3<Float>, relief: Float) -> SIMD3<Float> {
        var p = base + displacement(base)
        if relief > 0 {
            let w = p * 0.42 + 13
            p +=
                relief
                * SIMD3<Float>(
                    QuarryNoise.fbm(w, octaves: 3), QuarryNoise.fbm(w + 4.7, octaves: 3),
                    QuarryNoise.fbm(w + 11.3, octaves: 3)) * 1.4
        }
        return p
    }

    /// How far the held skin stands out from the blocks' own outer faces (m): enough to cover them
    /// where both sample the same surface at different points, little enough not to show when it
    /// goes.
    static let skinLift: Float = 0.045

    /// The held skin (emmettl/bombcad-work#139): one continuous render-only surface over the outer
    /// faces of the blocks, `skinLift` proud of them, so rock that has not broken reads as one
    /// mass, with its joints, rather than as cells with a shade line along every seam (the cells'
    /// outer faces are clipped cell by cell and meet the surface only at their corners). It is a
    /// grid over the old surface, its columns along the strip and its rows by distance along the
    /// surface from the face's line (so a steep face is sampled as finely as a flat top), laid on
    /// the blocks' own outer surface (`outer`, `outerPoint`); each triangle belongs to the block
    /// under it and goes when that block starts to move
    /// (`skinVertex`). Where no block of the cut lies under it, past a face's strip's ends, it
    /// belongs to the nearest block of the held skin there, which never moves.
    static func heldSkin(
        pieces: [QuarryPolyhedron], centres: [SIMD3<Float>], held: [Bool], face: QuarryFace,
        oldHeights: [Float],
        outer: @escaping OuterSurface, relief: Float, spacing: Float
    ) -> (vertices: [Vertex], indices: [UInt32], report: String) {
        let start = Date()
        // The blocks that have an outer face, their planes and bounds.
        let outerPieces = pieces.indices.filter { pieces[$0].kinds.contains(1) }
        guard !outerPieces.isEmpty else { return ([], [], "held skin: none") }
        var planes = [[SIMD4<Float>]](repeating: [], count: pieces.count)
        var lowest = SIMD3<Float>(repeating: .infinity)
        var highest = SIMD3<Float>(repeating: -.infinity)
        let bucketSize: Float = 1
        var boxes: [(Int, SIMD3<Float>, SIMD3<Float>)] = []
        for n in outerPieces {
            let poly = pieces[n]
            var lo = SIMD3<Float>(repeating: .infinity)
            var hi = SIMD3<Float>(repeating: -.infinity)
            var list: [SIMD4<Float>] = []
            for polygon in poly.faces where polygon.count >= 3 {
                var newell = SIMD3<Float>.zero
                for k in polygon.indices {
                    let a = polygon[k]
                    let b = polygon[(k + 1) % polygon.count]
                    newell += SIMD3(
                        (a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
                    lo = simd_min(lo, a)
                    hi = simd_max(hi, a)
                }
                guard simd_length_squared(newell) > 1e-20 else { continue }
                var normal = simd_normalize(newell)
                if simd_dot(normal, polygon[0] - centres[n]) < 0 { normal = -normal }
                list.append(SIMD4(normal, simd_dot(normal, polygon[0])))
            }
            planes[n] = list
            lowest = simd_min(lowest, lo)
            highest = simd_max(highest, hi)
            boxes.append((n, lo, hi))
        }
        let (low, high) = (lowest, highest)
        let span = ((high - low) / bucketSize).rounded(.up)
        let dims = SIMD3<Int>(Int(span.x) + 1, Int(span.y) + 1, Int(span.z) + 1)
        @Sendable func bucket(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let g = (p - low) / bucketSize
            return SIMD3(Int(floor(g.x)), Int(floor(g.y)), Int(floor(g.z)))
        }
        var buckets = [Int: [Int32]]()
        for (n, lo, hi) in boxes {
            let a = simd_clamp(bucket(lo), .zero, dims &- 1)
            let b = simd_clamp(bucket(hi), .zero, dims &- 1)
            for k in a.z...b.z {
                for j in a.y...b.y {
                    for i in a.x...b.x {
                        buckets[i + dims.x * (j + dims.y * k), default: []].append(Int32(n))
                    }
                }
            }
        }
        let frozenBuckets = buckets
        let frozenPlanes = planes
        /// How far `p` lies outside piece `n` (negative inside).
        @Sendable func outside(_ n: Int, _ p: SIMD3<Float>) -> Float {
            frozenPlanes[n].reduce(-Float.infinity) { max($0, simd_dot(SIMD3($1.x, $1.y, $1.z), p) - $1.w) }
        }
        @Sendable func candidates(_ p: SIMD3<Float>) -> [Int32] {
            let b = bucket(p)
            guard b.x >= 0, b.y >= 0, b.z >= 0, b.x < dims.x, b.y < dims.y, b.z < dims.z else { return [] }
            return frozenBuckets[b.x + dims.x * (b.y + dims.y * b.z)] ?? []
        }
        /// The block under a point of the outer surface: the one holding a point a little inside it,
        /// or the nearest within a few centimetres.
        @Sendable func owner(_ base: SIMD3<Float>, _ normal: SIMD3<Float>) -> Int? {
            var best: (Int, Float)?
            for depth: Float in [0.12, 0.35, 0.7, 1.2] {
                let q = base - normal * depth
                for n in candidates(q) {
                    let o = outside(Int(n), q)
                    if o <= 0 { return Int(n) }
                    if depth == 0.12, o < (best?.1 ?? 0.5) { best = (Int(n), o) }
                }
            }
            return best?.0
        }
        /// The block nearest `p` (by how far outside it `p` lies), within 2 m.
        @Sendable func nearest(_ p: SIMD3<Float>) -> Int? {
            var best: (Int, Float)?
            let b = bucket(p)
            for dk in -2...2 {
                for dj in -2...2 {
                    for di in -2...2 {
                        let c = b &+ SIMD3(di, dj, dk)
                        guard c.x >= 0, c.y >= 0, c.z >= 0, c.x < dims.x, c.y < dims.y, c.z < dims.z else {
                            continue
                        }
                        for n in frozenBuckets[c.x + dims.x * (c.y + dims.y * c.z)] ?? [] {
                            let o = outside(Int(n), p)
                            if o < (best?.1 ?? 2) { best = (Int(n), o) }
                        }
                    }
                }
            }
            return best?.0
        }
        // Rows by distance along the old surface from the face's line, column by column.
        let columns = Int(((high.x - low.x) / spacing).rounded(.up)) + 1
        let profileStep: Float = 0.05
        let yLow = low.y - 1
        let profileCount = Int(((high.y + 1 - yLow) / profileStep).rounded(.up)) + 1
        var arcs = [[Float]](repeating: [], count: columns)
        arcs.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: columns) { i in
                let x = low.x + Float(i) * spacing
                var s = [Float](repeating: 0, count: profileCount)
                var previous = SIMD2<Float>(yLow, face.height(oldHeights, x, yLow))
                for j in 1..<profileCount {
                    let y = yLow + Float(j) * profileStep
                    let here = SIMD2<Float>(y, face.height(oldHeights, x, y))
                    s[j] = s[j - 1] + simd_distance(here, previous)
                    previous = here
                }
                // From the face's line, so rows keep to the same part of the face along it.
                let g = max(0, min(Float(profileCount - 1), (face.faceLine(x) - yLow) / profileStep))
                let j = min(profileCount - 2, Int(g))
                let reference = s[j] + (s[j + 1] - s[j]) * (g - Float(j))
                output[i] = s.map { $0 - reference }
            }
        }
        let frozenArcs = arcs
        let sLow = arcs.map { $0.first ?? 0 }.min() ?? 0
        let sHigh = arcs.map { $0.last ?? 0 }.max() ?? 0
        let rowLow = Int(floor(sLow / spacing))
        let rows = Int(ceil(sHigh / spacing)) - rowLow + 1
        // Each grid point's place on the outer surface (before its shape), or none off the profile.
        let count = columns * rows
        var bases = [SIMD3<Float>?](repeating: nil, count: count)
        bases.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: columns) { i in
                let x = low.x + Float(i) * spacing
                let s = frozenArcs[i]
                var j = 0
                for r in 0..<rows {
                    let target = Float(r + rowLow) * spacing
                    guard target >= s[0], target <= s[s.count - 1] else { continue }
                    while j < s.count - 2, s[j + 1] < target { j += 1 }
                    let t = s[j + 1] > s[j] ? (target - s[j]) / (s[j + 1] - s[j]) : 0
                    let y = yLow + (Float(j) + max(0, min(1, t))) * profileStep
                    let old = SIMD3<Float>(x, y, face.height(oldHeights, x, y))
                    output[i + columns * r] = ontoOuter(old, outer: outer, inward: 4)
                }
            }
        }
        let frozenBases = bases
        // Two triangles a cell, each the block's under its middle.
        struct Triangle {
            var corners: (Int32, Int32, Int32)
            var owner: Int32
        }
        var perColumn = [[Triangle]](repeating: [], count: max(columns - 1, 0))
        let heldPieces = outerPieces.filter { held[$0] }
        var heldBuckets = [Int64: [Int32]]()
        let heldCell: Float = 6
        @Sendable func heldKey(_ p: SIMD3<Float>) -> Int64 {
            Int64(floor(p.x / heldCell)) &* 1_000_003 &+ Int64(floor(p.y / heldCell)) &* 1009
                &+ Int64(floor(p.z / heldCell))
        }
        var allBuckets = [Int64: [Int32]]()
        for n in heldPieces { heldBuckets[heldKey(centres[n]), default: []].append(Int32(n)) }
        for n in outerPieces { allBuckets[heldKey(centres[n]), default: []].append(Int32(n)) }
        let frozenHeld = heldBuckets
        let frozenAll = allBuckets
        /// The block of `table` whose centre is nearest `p`, within 12 m.
        @Sendable func nearestCentre(_ p: SIMD3<Float>, _ table: [Int64: [Int32]]) -> Int? {
            var nearest: (Int32, Float)?
            for dz: Float in [-1, 0, 1] {
                for dy: Float in [-1, 0, 1] {
                    for dx: Float in [-1, 0, 1] {
                        for n in table[heldKey(p + SIMD3(dx, dy, dz) * heldCell)] ?? [] {
                            let dist = simd_distance_squared(centres[Int(n)], p)
                            if dist < (nearest?.1 ?? 144) { nearest = (n, dist) }
                        }
                    }
                }
            }
            return nearest.map { Int($0.0) }
        }
        let isFace = face.ridge == nil
        perColumn.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: max(columns - 1, 0)) { i in
                var list: [Triangle] = []
                for r in 0..<(rows - 1) {
                    let a = i + columns * r
                    let b = a + 1
                    let c = a + columns
                    let d = c + 1
                    guard frozenBases[a] != nil, frozenBases[b] != nil, frozenBases[c] != nil,
                        frozenBases[d] != nil
                    else { continue }
                    let split = (i + r) & 1 == 0
                    for corners in split ? [(a, b, d), (a, d, c)] : [(a, b, c), (b, d, c)] {
                        let (p, q, w) = (
                            frozenBases[corners.0]!, frozenBases[corners.1]!, frozenBases[corners.2]!
                        )
                        let middle = (p + q + w) / 3
                        let normal = outer(middle).normal
                        var found = owner(middle, normal)
                        let inCut =
                            face.height(oldHeights, middle.x, middle.y)
                            - face.height(face.terrain.heights, middle.x, middle.y) > 0.2
                        if found == nil, inCut {
                            // A hole in the cut's rock (pieces too small to keep, left out as
                            // standing out of the face, or where the strip tapers out): the nearest
                            // block's, within a couple of metres, else the one whose centre is
                            // nearest. Left open, the blocks drawn behind the skin showed through.
                            found = nearest(middle - normal * 0.3) ?? nearestCentre(middle, frozenAll)
                        }
                        if found == nil, isFace, !inCut, middle.z > face.floorHeight(middle.x) - 1 {
                            // Past the strip's ends, where only the dressing lies under it: the
                            // nearest block of the held skin, which never moves.
                            found = nearestCentre(middle, frozenHeld) ?? nearestCentre(middle, frozenAll)
                        }
                        guard let found else { continue }
                        var tri = (Int32(corners.0), Int32(corners.1), Int32(corners.2))
                        if simd_dot(simd_cross(q - p, w - p), normal) < 0 { tri = (tri.0, tri.2, tri.1) }
                        list.append(Triangle(corners: tri, owner: Int32(found)))
                    }
                }
                output[i] = list
            }
        }
        // The shaped points and normals of the grid points used.
        var used = [Bool](repeating: false, count: count)
        for list in perColumn {
            for t in list {
                used[Int(t.corners.0)] = true
                used[Int(t.corners.1)] = true
                used[Int(t.corners.2)] = true
            }
        }
        var points = [SIMD4<Float>](repeating: .zero, count: count)
        var normals = [UInt32](repeating: 0, count: count)
        let frozenUsed = used
        points.withUnsafeMutableBufferPointer { pointsOut in
            normals.withUnsafeMutableBufferPointer { normalsOut in
                nonisolated(unsafe) let pointsOutput = pointsOut
                nonisolated(unsafe) let normalsOutput = normalsOut
                DispatchQueue.concurrentPerform(iterations: rows) { r in
                    for i in 0..<columns where frozenUsed[i + columns * r] {
                        let base = frozenBases[i + columns * r]!
                        let here = outerPoint(base, outer: outer, relief: relief)
                        var normal = outerNormal(base, here: here, outer: outer, relief: relief)
                        // Where the displacement folds the surface over the shale's recess, its
                        // normal turns far from the surface's and the patch shaded dark in blots:
                        // held to within about 50 degrees of it.
                        let ns = outer(base).normal
                        let d = simd_dot(normal, ns)
                        if d < 0.65 { normal = simd_normalize(normal + ns * (0.65 - d) * 2) }
                        if normal.x.isNaN { normal = ns }
                        pointsOutput[i + columns * r] = SIMD4(here + normal * skinLift, 0)
                        normalsOutput[i + columns * r] = pack(normal: normal, kind: 1)
                    }
                }
            }
        }
        // Each block's triangles with their own vertices, in the world's frame: the skin goes before
        // its block has moved 3 cm, so it need not ride on the pose, and corners that blocks share
        // are then the same numbers, so the skin is watertight (in each block's frame they differed
        // in the last bit and left pinholes).
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        var made = [Int64: UInt32]()
        let tag = QuarryRock.faceTag(weathering: 1, random: 0.5)
        var triangles = 0
        for list in perColumn {
            for t in list {
                let owner = Int(t.owner)
                for corner in [t.corners.0, t.corners.1, t.corners.2] {
                    let key = Int64(corner) << 21 | Int64(owner)
                    if let index = made[key] {
                        indices.append(index)
                        continue
                    }
                    let point = points[Int(corner)]
                    let index = UInt32(vertices.count)
                    vertices.append(
                        Vertex(
                            x: point.x, y: point.y, z: point.z, normal: normals[Int(corner)],
                            body: UInt32(owner) | tag))
                    made[key] = index
                    indices.append(index)
                }
                triangles += 1
            }
        }
        let report = String(
            format: "held skin: %d triangles, %d vertices over %d blocks (%d x %d grid at %.2f m), %.1f s",
            triangles, vertices.count, Set(perColumn.flatMap { $0.map(\.owner) }).count, columns, rows,
            spacing,
            Date().timeIntervalSince(start))
        return (vertices, indices, report)
    }
}
