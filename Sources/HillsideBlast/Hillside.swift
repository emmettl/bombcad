import BlastModel
import Foundation
import simd

// The hillside: a quarry face as a heightfield, the rock in front of a new, excavated face broken
// up into jittered Voronoi blocks. Illustrative: the fracture pattern is for the eye.

/// splitmix64.
struct Random {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func float(_ low: Float, _ high: Float) -> Float { low + (high - low) * float() }
    mutating func unit() -> SIMD3<Float> {
        while true {
            let v = SIMD3(float(-1, 1), float(-1, 1), float(-1, 1))
            let l = simd_length_squared(v)
            if l > 1e-4 && l <= 1 { return v / sqrt(l) }
        }
    }
}

/// Smooth value noise, roughly in [-1, 1].
enum Noise {
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343
        h ^= UInt32(bitPattern: y) &* 0xD816_3841
        h ^= UInt32(bitPattern: z) &* 0xCB1A_B31F
        h ^= h >> 13
        h = h &* 0x4F37_F8A5
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1
    }
    static func value(_ p: SIMD3<Float>) -> Float {
        let floored = floor(p)
        let f = p - floored
        let t = f * f * (3 - 2 * f)
        let (ix, iy, iz) = (Int32(floored.x), Int32(floored.y), Int32(floored.z))
        func at(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float { hash(ix + dx, iy + dy, iz + dz) }
        let a = at(0, 0, 0) + (at(1, 0, 0) - at(0, 0, 0)) * t.x
        let b = at(0, 1, 0) + (at(1, 1, 0) - at(0, 1, 0)) * t.x
        let c = at(0, 0, 1) + (at(1, 0, 1) - at(0, 0, 1)) * t.x
        let d = at(0, 1, 1) + (at(1, 1, 1) - at(0, 1, 1)) * t.x
        let e = a + (b - a) * t.y
        let g = c + (d - c) * t.y
        return e + (g - e) * t.z
    }
    static func fbm(_ p: SIMD3<Float>, octaves: Int = 4) -> Float {
        var sum: Float = 0
        var amplitude: Float = 0.5
        var q = p
        for _ in 0..<octaves {
            sum += amplitude * value(q)
            q = q * 2.03 + 17.3
            amplitude *= 0.5
        }
        return sum
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

/// One block's polyhedron: planar polygons, their kind (0 a fresh fracture, 1 the weathered surface,
/// 2 the excavated surface beneath).
struct Polyhedron {
    var faces: [[SIMD3<Float>]]
    var kinds: [UInt8]

    static func box(low: SIMD3<Float>, high: SIMD3<Float>) -> Polyhedron {
        let (a, b) = (low, high)
        let v = [
            SIMD3(a.x, a.y, a.z), SIMD3(b.x, a.y, a.z), SIMD3(b.x, b.y, a.z), SIMD3(a.x, b.y, a.z),
            SIMD3(a.x, a.y, b.z), SIMD3(b.x, a.y, b.z), SIMD3(b.x, b.y, b.z), SIMD3(a.x, b.y, b.z),
        ]
        let f: [[Int]] = [
            [3, 2, 1, 0], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [3, 0, 4, 7],
        ]
        return Polyhedron(faces: f.map { $0.map { v[$0] } }, kinds: Array(repeating: 0, count: 6))
    }

    /// Keeps the side where dot(n, x) <= d; the new face gets `kind`.
    mutating func clip(normal n: SIMD3<Float>, offset d: Float, kind: UInt8) {
        var newFaces: [[SIMD3<Float>]] = []
        var newKinds: [UInt8] = []
        var cut: [SIMD3<Float>] = []
        var cutAny = false
        for (f, polygon) in faces.enumerated() {
            var out: [SIMD3<Float>] = []
            out.reserveCapacity(polygon.count + 2)
            var previous = polygon[polygon.count - 1]
            var previousDistance = simd_dot(n, previous) - d
            for point in polygon {
                let distance = simd_dot(n, point) - d
                if (distance > 0) != (previousDistance > 0) {
                    let crossing =
                        previous + (point - previous) * (previousDistance / (previousDistance - distance))
                    out.append(crossing)
                    cut.append(crossing)
                    cutAny = true
                }
                if distance <= 0 { out.append(point) } else { cutAny = true }
                previous = point
                previousDistance = distance
            }
            if out.count >= 3 {
                newFaces.append(out)
                newKinds.append(kinds[f])
            }
        }
        guard cutAny else { return }
        if cut.count >= 3 {
            // Order the new face around its centre.
            let centre = cut.reduce(SIMD3<Float>.zero, +) / Float(cut.count)
            let u = simd_normalize(cut[0] - centre + (cut[0] == centre ? SIMD3(1, 0, 0) : .zero))
            let v = simd_normalize(simd_cross(n, u))
            var ordered = cut.map { p -> (Float, SIMD3<Float>) in
                let q = p - centre
                return (atan2(simd_dot(q, v), simd_dot(q, u)), p)
            }
            ordered.sort { $0.0 < $1.0 }
            var loop: [SIMD3<Float>] = []
            for (_, p) in ordered where loop.last.map({ simd_distance_squared($0, p) > 1e-6 }) ?? true {
                loop.append(p)
            }
            if loop.count > 2, simd_distance_squared(loop[0], loop[loop.count - 1]) < 1e-6 {
                loop.removeLast()
            }
            if loop.count >= 3 {
                newFaces.append(loop)
                newKinds.append(kind)
            }
        }
        faces = newFaces
        kinds = newKinds
    }

    /// Volume and centroid, by tetrahedra from the first vertex.
    var volumeAndCentroid: (volume: Float, centroid: SIMD3<Float>) {
        guard let origin = faces.first?.first else { return (0, .zero) }
        var volume: Float = 0
        var moment = SIMD3<Float>.zero
        for polygon in faces where polygon.count >= 3 {
            for k in 1..<(polygon.count - 1) {
                let (a, b, c) = (polygon[0] - origin, polygon[k] - origin, polygon[k + 1] - origin)
                let v = simd_dot(a, simd_cross(b, c)) / 6
                volume += v
                moment += v * (a + b + c) / 4
            }
        }
        return (abs(volume), abs(volume) > 0 ? moment / volume + origin : origin)
    }

    func maxDistance(from p: SIMD3<Float>) -> Float {
        var largest: Float = 0
        for polygon in faces { for v in polygon { largest = max(largest, simd_distance_squared(v, p)) } }
        return sqrt(largest)
    }
}

/// The hillside and its blocks, ready for the GPU.
struct Hillside {
    struct Options {
        var blocks = 100_000
        var spheres = 5
        var seed: UInt64 = 2026
        /// Length of the broken strip along the face (m).
        var length: Float = 180
        /// How far back from the old face the new one stands (m).
        var depth: Float = 26
    }

    /// A contact sphere: local offset from the centroid, its radius.
    struct Sphere {
        var offset: SIMD3<Float>
        var radius: Float
    }
    struct Block {
        var centre: SIMD3<Float>
        var volume: Float
        var inertiaDiagonalPerMass: SIMD3<Float>
        var firstVertex: Int
        var vertexCount: Int
        var firstIndex: Int
        var indexCount: Int
        var firstSphere: Int
        var sphereCount: Int
        var size: Float
    }
    /// Layout matches `HillsideBlockVertex` in `Hillside.metal`.
    struct Vertex {
        var x: Float, y: Float, z: Float
        var normal: UInt32
        var body: UInt32
    }

    var options: Options
    /// The excavated ground the blocks rest on and land on.
    var terrain: Terrain
    /// The old surface, before the blast, on the same grid.
    var original: [Float]
    var blocks: [Block] = []
    var spheres: [Sphere] = []
    var vertices: [Vertex] = []
    var indices: [UInt32] = []
    var meanEdge: Float = 0
    var maxRadius: Float = 0
    /// The domain of the hash grid (m).
    let low = SIMD3<Float>(-90, -190, -6)
    let high = SIMD3<Float>(290, 110, 110)

    static func faceLine(_ x: Float) -> Float {
        6 * sin(x / 37) + 3.5 * sin(x / 13 + 1) + 1.2 * sin(x / 5.3 + 2)
    }
    static func profile(_ y: Float, _ x: Float, shift: Float) -> Float {
        // Up the old (or new) face: 4 m wide for a steep drop, then the top of the hill.
        let across = y - faceLine(x) - shift
        let rise = smoothstep(-1, 4, across)
        // The top of the hill does not depend on the shift, so behind the new face nothing is taken.
        let top = 26 + 0.14 * max(0, y - faceLine(x)) + 3 * sin(x / 41 + 0.7) + 1.5 * sin(x / 17)
        return rise * top
    }
    static func relief(_ x: Float, _ y: Float) -> Float {
        let q = SIMD3<Float>(x / 22, y / 22, 3.1)
        return 1.6 * Noise.fbm(q, octaves: 5)
    }
    /// Pulls the new face back only along the strip, with rounded ends.
    static func mask(_ x: Float, length: Float) -> Float {
        smoothstep(0, 18, x) * (1 - smoothstep(length - 18, length, x))
    }
    func oldHeight(_ x: Float, _ y: Float) -> Float {
        Self.profile(y, x, shift: 0) + Self.relief(x, y)
    }
    func newHeight(_ x: Float, _ y: Float) -> Float {
        let m = Self.mask(x, length: options.length)
        return Self.profile(y, x, shift: options.depth * m) + Self.relief(x, y) * (0.4 + 0.6 * m)
    }

    /// Height at (x, y) on a heightfield given as the old or excavated surface (bilinear on the grid).
    func height(_ h: [Float], _ x: Float, _ y: Float) -> Float {
        let gx = max(0, min(Float(terrain.columns - 2), (x - terrain.origin.x) / terrain.spacing))
        let gy = max(0, min(Float(terrain.rows - 2), (y - terrain.origin.y) / terrain.spacing))
        let i = Int(gx)
        let j = Int(gy)
        let (fx, fy) = (gx - Float(i), gy - Float(j))
        let n = terrain.columns
        let a = h[i + n * j] + (h[i + 1 + n * j] - h[i + n * j]) * fx
        let b = h[i + n * (j + 1)] + (h[i + 1 + n * (j + 1)] - h[i + n * (j + 1)]) * fx
        return a + (b - a) * fy
    }

    init(options: Options) {
        self.options = options
        let spacing: Float = 1
        let originXY = SIMD2<Float>(-90, -190)
        let columns = 381
        let rows = 301
        terrain = Terrain(origin: originXY, spacing: spacing, columns: columns, rows: rows, heights: [])
        original = []
        var exc = [Float](repeating: 0, count: columns * rows)
        var old = exc
        for j in 0..<rows {
            for i in 0..<columns {
                let x = originXY.x + Float(i) * spacing
                let y = originXY.y + Float(j) * spacing
                old[i + columns * j] = oldHeight(x, y)
                exc[i + columns * j] = min(old[i + columns * j], newHeight(x, y))
            }
        }
        terrain.heights = exc
        original = old
    }

    /// Generate the blocks.
    mutating func generate(timing: Bool = true) {
        let options = self.options
        let start = Date()
        // Bounds of the broken strip.
        let boxLow = SIMD3<Float>(-1, -15, -1)
        let boxHigh = SIMD3<Float>(options.length + 1, options.depth + 30, 55)
        var random = Random(seed: options.seed)
        let hOld = original
        let hNew = terrain.heights
        func inside(_ p: SIMD3<Float>) -> Bool {
            let a = height(hNew, p.x, p.y)
            let b = height(hOld, p.x, p.y)
            return b - a > 0.2 && p.z > a && p.z < b
        }
        // Rock, not rubble: a spread of sizes through a smooth density field, with finer breakage
        // near the row of firings.
        var sites: [SIMD3<Float>] = []
        sites.reserveCapacity(options.blocks)
        var volumeSamples = 0
        var insideSamples = 0
        func density(_ p: SIMD3<Float>) -> Float {
            let q = p / SIMD3<Float>(25, 18, 12)
            let broad = exp(1.8 * Noise.fbm(q, octaves: 3))
            let across = abs(p.y - Self.faceLine(p.x) - options.depth * 0.4) / 18
            let near = 0.6 + 1.4 * exp(-across * across)
            return broad * near
        }
        let densityPeak: Float = 12
        // A spread with real big blocks: a few boulder centres that nothing else may come near.
        var boulders: [(SIMD3<Float>, Float)] = []
        let boulderCount = options.blocks / 180
        var boulderRandom = Random(seed: options.seed &+ 11)
        while boulders.count < boulderCount {
            let p = SIMD3<Float>(
                boulderRandom.float(boxLow.x, boxHigh.x), boulderRandom.float(boxLow.y, boxHigh.y),
                boulderRandom.float(boxLow.z, boxHigh.z))
            if inside(p) { boulders.append((p, boulderRandom.float(1.1, 2.6))) }
        }
        var boulderGrid: [Int64: [Int32]] = [:]
        func boulderKey(_ p: SIMD3<Float>) -> Int64 {
            let g = floor(p / 3)
            return Int64(g.x) &+ Int64(g.y) &* 100_003 &+ Int64(g.z) &* 100_000_007
        }
        for (n, b) in boulders.enumerated() { boulderGrid[boulderKey(b.0), default: []].append(Int32(n)) }
        func rejected(_ p: SIMD3<Float>) -> Bool {
            for dk: Float in [-3, 0, 3] {
                for dj: Float in [-3, 0, 3] {
                    for di: Float in [-3, 0, 3] {
                        for n in boulderGrid[boulderKey(p + SIMD3(di, dj, dk))] ?? [] {
                            let b = boulders[Int(n)]
                            if simd_distance_squared(b.0, p) < b.1 * b.1 { return true }
                        }
                    }
                }
            }
            return false
        }
        sites.append(contentsOf: boulders.map(\.0))
        while sites.count < options.blocks {
            let p = SIMD3<Float>(
                random.float(boxLow.x, boxHigh.x), random.float(boxLow.y, boxHigh.y),
                random.float(boxLow.z, boxHigh.z))
            volumeSamples += 1
            guard inside(p) else { continue }
            insideSamples += 1
            if random.float() * densityPeak < density(p), !rejected(p) { sites.append(p) }
        }
        let boxVolume = (boxHigh - boxLow).x * (boxHigh - boxLow).y * (boxHigh - boxLow).z
        let rockVolume = boxVolume * Float(insideSamples) / Float(volumeSamples)
        meanEdge = cbrt(rockVolume / Float(options.blocks))
        print(
            "rock volume \(Int(rockVolume)) m3, \(sites.count) sites, mean edge \(String(format: "%.2f", meanEdge)) m (density rejection took \(String(format: "%.1f", Date().timeIntervalSince(start))) s)"
        )
        // A hash of the sites for neighbours.
        let cell = meanEdge * 2.2
        let dims = SIMD3<Int>(
            Int(ceil((boxHigh.x - boxLow.x) / cell)) + 1, Int(ceil((boxHigh.y - boxLow.y) / cell)) + 1,
            Int(ceil((boxHigh.z - boxLow.z) / cell)) + 1)
        var buckets = [[Int32]](repeating: [], count: dims.x * dims.y * dims.z)
        func bucket(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let g = (p - boxLow) / cell
            return simd_clamp(SIMD3<Int>(Int(g.x), Int(g.y), Int(g.z)), .zero, dims &- 1)
        }
        for (n, p) in sites.enumerated() {
            let b = bucket(p)
            buckets[b.x + dims.x * (b.y + dims.y * b.z)].append(Int32(n))
        }
        let frozenSites = sites
        let frozenBuckets = buckets
        // Clip each cell.
        struct Built {
            var polyhedron: Polyhedron
            var volume: Float
            var centroid: SIMD3<Float>
        }
        var builtRaw = [Built?](repeating: nil, count: sites.count)
        let hillside = self
        builtRaw.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: frozenSites.count) { n in
                let site = frozenSites[n]
                let b = bucket(site)
                var near: [(Float, Int)] = []
                near.reserveCapacity(200)
                for dk in -2...2 {
                    for dj in -2...2 {
                        for di in -2...2 {
                            let c = b &+ SIMD3(di, dj, dk)
                            guard c.x >= 0, c.y >= 0, c.z >= 0, c.x < dims.x, c.y < dims.y, c.z < dims.z
                            else { continue }
                            for other in frozenBuckets[c.x + dims.x * (c.y + dims.y * c.z)]
                            where Int(other) != n {
                                near.append(
                                    (simd_distance_squared(site, frozenSites[Int(other)]), Int(other)))
                            }
                        }
                    }
                }
                near.sort { $0.0 < $1.0 }
                let reach = cell * 2.2
                var polyhedron = Polyhedron.box(
                    low: site - reach, high: site + reach)
                for (distanceSquared, other) in near {
                    let extent = polyhedron.maxDistance(from: site)
                    if distanceSquared > 4 * extent * extent { break }
                    let q = frozenSites[other]
                    let normal = simd_normalize(q - site)
                    let middle = (q + site) * 0.5
                    polyhedron.clip(normal: normal, offset: simd_dot(normal, middle), kind: 0)
                }
                // Clip to the old surface and the new one, by tangent planes around the cell.
                let extent = min(polyhedron.maxDistance(from: site), cell)
                for offset: SIMD2<Float> in [.zero, [0.7, 0], [-0.7, 0], [0, 0.7], [0, -0.7]] {
                    let p = SIMD2(site.x, site.y) + offset * extent
                    func normal(_ h: [Float]) -> (SIMD3<Float>, Float) {
                        let e: Float = 0.5
                        let z = hillside.height(h, p.x, p.y)
                        let dx =
                            (hillside.height(h, p.x + e, p.y) - hillside.height(h, p.x - e, p.y)) / (2 * e)
                        let dy =
                            (hillside.height(h, p.x, p.y + e) - hillside.height(h, p.x, p.y - e)) / (2 * e)
                        let n = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                        return (n, simd_dot(n, SIMD3<Float>(p.x, p.y, z)))
                    }
                    let top = normal(hOld)
                    polyhedron.clip(normal: top.0, offset: top.1, kind: 1)
                    let bottom = normal(hNew)
                    polyhedron.clip(normal: -bottom.0, offset: -bottom.1, kind: 2)
                }
                let (volume, centroid) = polyhedron.volumeAndCentroid
                if polyhedron.faces.count >= 4, volume > 0, polyhedron.faces.count < 40 {
                    output[n] = Built(polyhedron: polyhedron, volume: volume, centroid: centroid)
                }
            }
        }
        let built = builtRaw.compactMap { $0 }
        let meanVolume = built.reduce(0) { $0 + $1.volume } / Float(max(built.count, 1))
        let keep = built.filter { $0.volume > 0.08 * meanVolume }
        print(
            "built \(built.count) cells, kept \(keep.count) (dropped slivers); mean volume \(String(format: "%.2f", meanVolume)) m3, took \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
        )
        let radiusCap = meanEdge * 0.55
        let meanVolumeKept = keep.reduce(0) { $0 + $1.volume } / Float(max(keep.count, 1))
        var blocks: [Block] = []
        blocks.reserveCapacity(keep.count)
        for (body, cell) in keep.enumerated() {
            let c = cell.centroid
            var localBounds = (SIMD3<Float>(repeating: .infinity), SIMD3<Float>(repeating: -.infinity))
            for polygon in cell.polyhedron.faces {
                for v in polygon {
                    localBounds.0 = simd_min(localBounds.0, v - c)
                    localBounds.1 = simd_max(localBounds.1, v - c)
                }
            }
            // Mesh: flat-shaded polygons as fans, each face its own vertices.
            let firstVertex = vertices.count
            let firstIndex = indices.count
            var planes: [(SIMD3<Float>, Float)] = []
            planes.reserveCapacity(cell.polyhedron.faces.count)
            var corners: [SIMD3<Float>] = []
            corners.reserveCapacity(40)
            for (f, polygon) in cell.polyhedron.faces.enumerated() {
                var newell = SIMD3<Float>.zero
                for k in polygon.indices {
                    let a = polygon[k]
                    let b = polygon[(k + 1) % polygon.count]
                    newell += SIMD3(
                        (a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
                }
                var normal = simd_normalize(newell)
                if simd_dot(normal, polygon[0] - c) < 0 { normal = -normal }
                planes.append((normal, simd_dot(normal, polygon[0] - c)))
                let packed = Self.pack(normal: normal, kind: cell.polyhedron.kinds[f])
                let first = UInt32(vertices.count)
                for v in polygon {
                    let local = v - c
                    vertices.append(
                        Vertex(x: local.x, y: local.y, z: local.z, normal: packed, body: UInt32(body)))
                    corners.append(local)
                }
                for k in 1..<UInt32(polygon.count - 1) {
                    indices.append(first)
                    indices.append(first + k)
                    indices.append(first + k + 1)
                }
            }
            func inscribed(_ p: SIMD3<Float>) -> Float {
                planes.reduce(Float.infinity) { min($0, $1.1 - simd_dot($1.0, p)) }
            }
            // Contact: the inscribed sphere at the centre, and spheres toward the far corners.
            let firstSphere = spheres.count
            let central = max(0.05, min(inscribed(.zero), radiusCap))
            spheres.append(Sphere(offset: .zero, radius: central))
            var chosen: [SIMD3<Float>] = [.zero]
            var added = 1
            let target = max(
                3, min(24, Int((Float(options.spheres) * pow(cell.volume / meanVolumeKept, 0.7)).rounded())))
            while added < target {
                let farthest = corners.max { a, b in
                    chosen.reduce(Float.infinity) { min($0, simd_distance_squared(a, $1)) }
                        < chosen.reduce(Float.infinity) { min($0, simd_distance_squared(b, $1)) }
                }
                guard let farthest else { break }
                chosen.append(farthest)
                // Inward of the corner far enough for a useful sphere.
                var p = farthest * 0.55
                var r = inscribed(p)
                if r < radiusCap * 0.4 {
                    p = farthest * 0.35
                    r = inscribed(p)
                }
                if r > 0.3 * central {
                    spheres.append(Sphere(offset: p, radius: min(r, radiusCap)))
                }
                added += 1
            }
            let extent = localBounds.1 - localBounds.0
            let dx2 = extent * extent
            blocks.append(
                Block(
                    centre: c, volume: cell.volume,
                    inertiaDiagonalPerMass: SIMD3(dx2.y + dx2.z, dx2.x + dx2.z, dx2.x + dx2.y) / 12,
                    firstVertex: firstVertex, vertexCount: vertices.count - firstVertex,
                    firstIndex: firstIndex, indexCount: indices.count - firstIndex,
                    firstSphere: firstSphere, sphereCount: spheres.count - firstSphere,
                    size: cbrt(cell.volume)))
        }
        self.blocks = blocks
        maxRadius = spheres.reduce(0) { max($0, $1.radius) }
        print(
            "blocks \(blocks.count), spheres \(spheres.count) (\(String(format: "%.2f", Float(spheres.count) / Float(max(blocks.count, 1)))) per block), max radius \(String(format: "%.2f", maxRadius)) m, vertices \(vertices.count), triangles \(indices.count / 3), \(String(format: "%.1f", Date().timeIntervalSince(start))) s in all"
        )
    }

    /// Packs a unit normal in 10:10:10 and the face kind in the top two bits.
    static func pack(normal n: SIMD3<Float>, kind: UInt8) -> UInt32 {
        func s10(_ v: Float) -> UInt32 {
            UInt32(max(0, min(1023, (v * 0.5 + 0.5) * 1023 + 0.5)))
        }
        return s10(n.x) | (s10(n.y) << 10) | (s10(n.z) << 20) | (UInt32(kind) << 30)
    }
}

/// A row of firings, stylised for the eye: even along the face, staggered in time so a ripple runs
/// along it. No charge masses or designs of any kind; each firing only imparts a velocity by the
/// scaled law in `Launch`. This is a picture, not a blast-design aid: it says nothing about real
/// fragmentation, flyrock reach or safe distances.
struct Firing {
    var position: SIMD3<Float>
    var time: Float
}

enum FiringPattern {
    static func row(hillside: Hillside, count: Int = 16, first: Float = 1.0, stagger: Float = 0.1) -> [Firing]
    {
        let length = hillside.options.length
        return (0..<count).map { n in
            let x = 12 + (length - 24) * Float(n) / Float(max(count - 1, 1))
            let y = Hillside.faceLine(x) + hillside.options.depth * 0.45
            let z = hillside.height(hillside.original, x, y) * 0.55
            return Firing(position: SIMD3(x, y, z), time: first + stagger * Float(n))
        }
    }
}

/// Per-block launch state from the firings: when it lets go and how fast.
struct Launch {
    /// Scaled law, stated: the speed at distance r from the nearest firing is
    /// `speed0 (r0 / max(r, r0))^exponent`; illustrative, chosen by eye.
    var speed0: Float = 15
    var r0: Float = 3
    var exponent: Float = 1.0
    /// The face swells before it lets go: blocks drift at a share of the launch for `rise` seconds.
    var rise: Float = 0.22
    var swellShare: Float = 0.1
    /// Share of a block's launch that is up.
    var lift: Float = 0.55
    /// Speed of the break through the rock, for each block's release (m/s). Visual only.
    var front: Float = 200

    func apply(to blocks: inout [Hillside.Block], firings: [Firing], hillside: Hillside) -> (
        fire: [Float], velocity: [SIMD3<Float>], spin: [SIMD3<Float>]
    ) {
        var random = Random(seed: 77)
        var fire = [Float](repeating: 0, count: blocks.count)
        var velocity = [SIMD3<Float>](repeating: .zero, count: blocks.count)
        var spin = velocity
        for (n, block) in blocks.enumerated() {
            let c = block.centre
            var best: Float = .infinity
            var nearest = firings[0]
            for firing in firings {
                let d = simd_distance_squared(c, firing.position)
                if d < best {
                    best = d
                    nearest = firing
                }
            }
            let r = sqrt(best)
            // The last skin of blocks against the new face stays put, so the face is left rough.
            let across =
                c.y - Hillside.faceLine(c.x) - hillside.options.depth
                * Hillside.mask(c.x, length: hillside.options.length)
            if across > -2.6 {
                fire[n] = .greatestFiniteMagnitude
                velocity[n] = .zero
                spin[n] = .zero
                continue
            }
            let speed = speed0 * pow(r0 / max(r, r0), exponent)
            let radial = simd_normalize(c - nearest.position + SIMD3<Float>(0, 0, 0.5))
            let outward = SIMD3<Float>(0, -1, 0)
            var direction = simd_normalize(0.55 * radial + 0.45 * outward)
            direction.z += lift * (0.6 + 0.4 * random.float())
            direction = simd_normalize(direction + 0.18 * random.unit())
            fire[n] = nearest.time + r / front
            velocity[n] = direction * max(0.25, speed * random.float(0.7, 1.2))
            spin[n] =
                random.unit()
                * min(9, simd_length(velocity[n]) * random.float(0.3, 1.5) / max(block.size, 0.3))
        }
        return (fire, velocity, spin)
    }
}
