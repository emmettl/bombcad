import Foundation
import simd

// The face: a quarry face as a heightfield, the rock in front of a new, excavated face broken
// up into jittered Voronoi blocks. Illustrative: the fracture pattern is for the eye.

/// splitmix64.
public struct QuarryRandom: Sendable {
    public var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    public mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    public mutating func float(_ low: Float, _ high: Float) -> Float { low + (high - low) * float() }
    public mutating func unit() -> SIMD3<Float> {
        while true {
            let v = SIMD3(float(-1, 1), float(-1, 1), float(-1, 1))
            let l = simd_length_squared(v)
            if l > 1e-4 && l <= 1 { return v / sqrt(l) }
        }
    }
}

/// Smooth value noise, roughly in [-1, 1].
public enum QuarryNoise {
    public static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343
        h ^= UInt32(bitPattern: y) &* 0xD816_3841
        h ^= UInt32(bitPattern: z) &* 0xCB1A_B31F
        h ^= h >> 13
        h = h &* 0x4F37_F8A5
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1
    }
    public static func value(_ p: SIMD3<Float>) -> Float {
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
    public static func fbm(_ p: SIMD3<Float>, octaves: Int = 4) -> Float {
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
public struct QuarryPolyhedron: Sendable {
    public var faces: [[SIMD3<Float>]]
    public var kinds: [UInt8]

    public static func box(low: SIMD3<Float>, high: SIMD3<Float>) -> QuarryPolyhedron {
        let (a, b) = (low, high)
        let v = [
            SIMD3(a.x, a.y, a.z), SIMD3(b.x, a.y, a.z), SIMD3(b.x, b.y, a.z), SIMD3(a.x, b.y, a.z),
            SIMD3(a.x, a.y, b.z), SIMD3(b.x, a.y, b.z), SIMD3(b.x, b.y, b.z), SIMD3(a.x, b.y, b.z),
        ]
        let f: [[Int]] = [
            [3, 2, 1, 0], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [3, 0, 4, 7],
        ]
        return QuarryPolyhedron(faces: f.map { $0.map { v[$0] } }, kinds: Array(repeating: 0, count: 6))
    }

    /// Keeps the side where dot(n, x) <= d; the new face gets `kind`.
    public mutating func clip(normal n: SIMD3<Float>, offset d: Float, kind: UInt8) {
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
    public var volumeAndCentroid: (volume: Float, centroid: SIMD3<Float>) {
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

    public func maxDistance(from p: SIMD3<Float>) -> Float {
        var largest: Float = 0
        for polygon in faces { for v in polygon { largest = max(largest, simd_distance_squared(v, p)) } }
        return sqrt(largest)
    }
}

/// Where a quarry face lies: the ground, and a strip along the face from `start` to `end`, in the
/// ground's own metres. The broken rock is the face's material between the old face and a new one
/// `depth` behind it. Illustrative: for the look of a face being blasted, not a design of one.
public struct QuarrySite: Sendable {
    public var terrain: Terrain
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var depth: Float

    public init(terrain: Terrain, start: SIMD2<Float>, end: SIMD2<Float>, depth: Float = 26) {
        self.terrain = terrain
        self.start = start
        self.end = end
        self.depth = depth
    }

    public var length: Float { simd_distance(start, end) }

    /// The built-in face: a quarry floor, a steep face and a hill behind it, with the strip
    /// along the face from (0, 0) to (180, 0).
    public static func builtIn() -> QuarrySite {
        let origin = SIMD2<Float>(-420, -420)
        let (columns, rows) = (1101, 761)
        var heights = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let p = origin + SIMD2(Float(i), Float(j))
                heights[i + columns * j] = BuiltInHill.height(p.x, p.y)
            }
        }
        let terrain = Terrain(origin: origin, spacing: 1, columns: columns, rows: rows, heights: heights)
        return QuarrySite(terrain: terrain, start: .zero, end: SIMD2(180, 0))
    }
}

/// The built-in hill's shape (m).
enum BuiltInHill {
    static func faceLine(_ x: Float) -> Float {
        6 * sin(x / 37) + 3.5 * sin(x / 13 + 1) + 1.2 * sin(x / 5.3 + 2)
    }
    static func height(_ x: Float, _ y: Float) -> Float {
        let across = y - faceLine(x)
        let rise = smoothstep(-1, 4, across)
        let top = 26 + 0.14 * max(0, across) + 3 * sin(x / 41 + 0.7) + 1.5 * sin(x / 17)
        let q = SIMD3<Float>(x / 22, y / 22, 3.1)
        return rise * top + 1.6 * QuarryNoise.fbm(q, octaves: 5)
    }
}

/// The face and its blocks, ready for the GPU. Everything is in the strip's own frame: x along the
/// strip from its start, y into the hill (the uphill side), z up as in the ground.
public struct QuarryFace: Sendable {
    public struct Options: Sendable {
        public var blocks = 100_000
        /// Coarse Voronoi cells as a share of `blocks`: the bedding and joints cut them further.
        public var siteShare: Float = 0.33
        /// 0 for the film's full mesh, 1 for the live window's (fewer triangles).
        public var meshDetail = 0
        public var spheres = 5
        public var seed: UInt64 = 2026
        public init() {}
    }

    /// A contact sphere: local offset from the centroid, its radius.
    public struct Sphere: Sendable {
        public var offset: SIMD3<Float>
        public var radius: Float
    }
    public struct Block: Sendable {
        public var centre: SIMD3<Float>
        public var volume: Float
        public var inertiaDiagonalPerMass: SIMD3<Float>
        public var firstVertex: Int
        public var vertexCount: Int
        public var firstIndex: Int
        public var indexCount: Int
        public var firstSphere: Int
        public var sphereCount: Int
        public var size: Float
        /// Part of the held skin past the strip: never released.
        public var skin = false
    }
    /// Layout matches `QuarryBlockVertex` in `QuarryRender.metal`.
    public struct Vertex: Sendable {
        public var x: Float, y: Float, z: Float
        public var normal: UInt32
        public var body: UInt32
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The strip lies on ground with no face to break: nothing between old and new surfaces.
        case noFace
        case stripTooShort
    }

    public let site: QuarrySite
    public var options: Options
    /// Length of the broken strip along the face (m).
    public let length: Float
    /// How far back from the old face the new one stands (m).
    public var depth: Float { site.depth }
    /// The strip's frame in the ground: origin, along and into the hill.
    public let origin: SIMD2<Float>
    public let along: SIMD2<Float>
    public let inward: SIMD2<Float>
    /// The excavated ground the blocks rest on and land on, in the strip's frame.
    public var terrain: Terrain
    /// The old surface, before the blast, on the same grid.
    public var original: [Float]
    public var blocks: [Block] = []
    public var spheres: [Sphere] = []
    public var vertices: [Vertex] = []
    public var indices: [UInt32] = []
    public var meanEdge: Float = 0
    public var maxRadius: Float = 0
    /// Six local surface points per block, for the decorative chips.
    public var chipAnchors: [SIMD3<Float>] = []
    /// Render-only dressing of the rest of the face (one identity pose).
    public var dressingVertices: [Vertex] = []
    public var dressingIndices: [UInt32] = []
    /// What the generator made, line by line (counts and times).
    public var report: [String] = []
    /// The domain of the hash grid (m).
    public let low: SIMD3<Float>
    public let high: SIMD3<Float>
    /// The lowest floor and the highest old ground near the strip (m).
    public let floorLevel: Float
    public let topLevel: Float
    /// The old face's line (its y at each x, a metre apart from the grid's first column) and the
    /// floor and top heights in front of and behind it.
    private let faceTable: [Float]
    private let floorTable: [Float]
    private let topTable: [Float]

    /// The strip's frame to the ground's.
    public func world(_ p: SIMD2<Float>) -> SIMD2<Float> { origin + along * p.x + inward * p.y }
    /// The ground's frame to the strip's.
    public func local(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let d = p - origin
        return SIMD2(simd_dot(d, along), simd_dot(d, inward))
    }

    private func table(_ t: [Float], _ x: Float) -> Float {
        let g = max(0, min(Float(t.count - 2), x - terrain.origin.x))
        let i = Int(g)
        return t[i] + (t[i + 1] - t[i]) * (g - Float(i))
    }
    /// The old face's y at x.
    public func faceLine(_ x: Float) -> Float { table(faceTable, x) }
    public func floorHeight(_ x: Float) -> Float { table(floorTable, x) }

    /// Pulls the new face back only along the strip, with rounded ends.
    public static func mask(_ x: Float, length: Float) -> Float {
        smoothstep(0, 18, x) * (1 - smoothstep(length - 18, length, x))
    }
    /// The old ground anywhere, in the strip's frame.
    public func oldHeight(_ x: Float, _ y: Float) -> Float {
        site.terrain.height(at: world(SIMD2(x, y)))
    }

    /// Height at (x, y) on a heightfield given as the old or excavated surface (bilinear on the grid).
    public func height(_ h: [Float], _ x: Float, _ y: Float) -> Float {
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

    /// The site laid out in the strip's frame; `generate()` then breaks the rock.
    public init(site: QuarrySite, options: Options = Options()) throws {
        self.site = site
        self.options = options
        length = site.length
        guard length >= 40 else { throw Failure.stripTooShort }
        origin = site.start
        along = simd_normalize(site.end - site.start)
        var into = SIMD2<Float>(-along.y, along.x)
        // Into the hill: the side whose ground is higher.
        let middle = (site.start + site.end) / 2
        var higher: Float = 0
        for t: Float in [-0.3, 0, 0.3] {
            let p = middle + along * (t * length)
            higher += site.terrain.height(at: p + into * 15) - site.terrain.height(at: p - into * 15)
        }
        if higher < 0 { into = -into }
        inward = into
        let spacing: Float = 1
        let originXY = SIMD2<Float>(-170, -190)
        let columns = Int(length) + 341
        let rows = 301
        terrain = Terrain(origin: originXY, spacing: spacing, columns: columns, rows: rows, heights: [])
        original = []
        let site = self.site
        let (start, alongAxis, inwardAxis) = (origin, along, inward)
        func old(_ x: Float, _ y: Float) -> Float {
            site.terrain.height(at: start + alongAxis * x + inwardAxis * y)
        }
        // The old face's line: at each x the steepest rise into the hill near the strip, smoothed.
        var face = [Float](repeating: 0, count: columns)
        for i in 0..<columns {
            let x = originXY.x + Float(i)
            var best: Float = -.infinity
            var at: Float = 0
            var y: Float = -40
            while y <= 40 {
                let rise = old(x, y + 1) - old(x, y - 1)
                if rise > best {
                    best = rise
                    at = y
                }
                y += 0.5
            }
            face[i] = at
        }
        var smoothed = face
        for i in 0..<columns {
            let range = max(0, i - 4)...min(columns - 1, i + 4)
            smoothed[i] = range.reduce(0) { $0 + face[$1] } / Float(range.count)
        }
        faceTable = smoothed
        floorTable = (0..<columns).map { old(originXY.x + Float($0), smoothed[$0] - 8) }
        topTable = (0..<columns).map { old(originXY.x + Float($0), smoothed[$0] + 8) }
        var exc = [Float](repeating: 0, count: columns * rows)
        var oldGrid = exc
        for j in 0..<rows {
            for i in 0..<columns {
                let x = originXY.x + Float(i) * spacing
                let y = originXY.y + Float(j) * spacing
                let h0 = old(x, y)
                oldGrid[i + columns * j] = h0
                // The new face is the old one's shape, moved `depth` into the hill along the strip:
                // the ground keeps the old face's share of its rise, counted from the new face.
                let shift = site.depth * Self.mask(x, length: length)
                let floor = floorTable[i]
                let rise = topTable[i] - floor
                var h1 = h0
                if shift > 0, rise > 2 {
                    let u = y - smoothed[i] - shift
                    let share = max(0, min(1, (old(x, smoothed[i] + u) - floor) / rise))
                    h1 = min(h0, floor + share * (h0 - floor))
                }
                exc[i + columns * j] = h1
            }
        }
        terrain.heights = exc
        original = oldGrid
        // Levels near the strip, for the domains.
        var lowest = Float.infinity
        var highest = -Float.infinity
        for j in 0..<rows {
            let y = originXY.y + Float(j)
            guard y > -60, y < 80 else { continue }
            for i in 0..<columns {
                lowest = min(lowest, exc[i + columns * j])
                highest = max(highest, oldGrid[i + columns * j])
            }
        }
        floorLevel = lowest
        topLevel = highest
        low = SIMD3(-90, -190, lowest - 6)
        high = SIMD3(length + 110, 110, highest + 60)
        let cut = zip(oldGrid, exc).reduce(Float(0)) { $0 + ($1.0 - $1.1) }
        guard cut > 2000 else { throw Failure.noFace }
    }

    /// Generate the blocks. `progress`, if given, is told the share done after each stage.
    public mutating func generate(timing: Bool = true, progress: ((Float) -> Void)? = nil) {
        let options = self.options
        let length = self.length
        let depth = self.depth
        let start = Date()
        // Bounds of the broken strip.
        let faceLow = faceTable.min() ?? 0
        let faceHigh = faceTable.max() ?? 0
        let boxLow = SIMD3<Float>(-1, faceLow - 15, floorLevel - 1)
        let boxHigh = SIMD3<Float>(length + 1, faceHigh + depth + 30, topLevel + 1)
        var random = QuarryRandom(seed: options.seed)
        let hOld = original
        let hNew = terrain.heights
        func inside(_ p: SIMD3<Float>) -> Bool {
            let a = height(hNew, p.x, p.y)
            let b = height(hOld, p.x, p.y)
            return b - a > 0.2 && p.z > a && p.z < b
        }
        /// Within `skinThickness` behind the old face where nothing is broken.
        let skinThickness: Float = 2.4
        func skin(_ p: SIMD3<Float>) -> Bool {
            let b = height(hOld, p.x, p.y)
            // Anywhere in the band behind the old face that the strip's broken rock does not
            // fill, including where the strip tapers out at its ends.
            guard !inside(p), p.z < b, p.z > floorHeight(p.x) + 0.2 else { return false }
            // Not under the excavated floor in front of the new face.
            if b - height(hNew, p.x, p.y) > 0.2, p.z < height(hNew, p.x, p.y) { return false }
            return height(hOld, p.x, p.y - skinThickness) < p.z && abs(p.y - faceLine(p.x)) < 30
        }
        // Rock, not rubble: a spread of sizes through a smooth density field, with finer breakage
        // near the row of firings.
        var sites: [SIMD3<Float>] = []
        sites.reserveCapacity(options.blocks)
        var volumeSamples = 0
        var insideSamples = 0
        // A copy for the parallel loops below to read (the tables and terrain they read do not
        // change in this function).
        let hillside = self
        @Sendable func density(_ p: SIMD3<Float>) -> Float {
            let q = p / SIMD3<Float>(25, 18, 12)
            let broad = exp(1.8 * QuarryNoise.fbm(q, octaves: 3))
            let across = abs(p.y - hillside.faceLine(p.x) - depth * 0.4) / 18
            let near = 0.6 + 1.4 * exp(-across * across)
            return broad * near
        }
        let densityPeak: Float = 12
        // A spread with real big blocks: a few boulder centres that nothing else may come near.
        var boulders: [(SIMD3<Float>, Float)] = []
        let boulderCount = options.blocks / 180
        var boulderRandom = QuarryRandom(seed: options.seed &+ 11)
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
        let siteTarget = Int(Float(options.blocks) * options.siteShare)
        while sites.count < siteTarget {
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
        // A skin of the same rock along the old face past the strip's ends, held for ever, so the
        // face looks the same on both sides of where the blast stops.
        let skinLow = SIMD3<Float>(-165, faceLow - 25, floorLevel + 0.2)
        let skinHigh = SIMD3<Float>(length + 165, faceHigh + 45, topLevel)
        var skinSamples = 0
        var skinHits = 0
        var skinRandom = QuarryRandom(seed: options.seed &+ 23)
        func skinSample() -> SIMD3<Float> {
            SIMD3(
                skinRandom.float(skinLow.x, skinHigh.x), skinRandom.float(skinLow.y, skinHigh.y),
                skinRandom.float(skinLow.z, skinHigh.z))
        }
        for _ in 0..<400_000 {
            skinSamples += 1
            if skin(skinSample()) { skinHits += 1 }
        }
        let skinBox = (skinHigh - skinLow).x * (skinHigh - skinLow).y * (skinHigh - skinLow).z
        let skinVolume = skinBox * Float(skinHits) / Float(skinSamples)
        let skinTarget = Int(2.5 * Float(siteTarget) * skinVolume / max(rockVolume, 1))
        var skinSites = 0
        while skinSites < skinTarget {
            let p = skinSample()
            guard skin(p), skinRandom.float() * densityPeak < density(p) else { continue }
            sites.append(p)
            skinSites += 1
        }
        report.append("skin past the strip's ends: \(Int(skinVolume)) m3, \(skinSites) sites")
        meanEdge = cbrt(rockVolume / Float(options.blocks))
        report.append(
            "rock volume \(Int(rockVolume)) m3, \(sites.count) sites, mean edge \(String(format: "%.2f", meanEdge)) m (density rejection took \(String(format: "%.1f", Date().timeIntervalSince(start))) s)"
        )
        // A hash of the sites for neighbours.
        let cell = meanEdge * 2.2
        let hashLow = simd_min(boxLow, skinLow)
        let hashHigh = simd_max(boxHigh, skinHigh)
        let dims = SIMD3<Int>(
            Int(ceil((hashHigh.x - hashLow.x) / cell)) + 1, Int(ceil((hashHigh.y - hashLow.y) / cell)) + 1,
            Int(ceil((hashHigh.z - hashLow.z) / cell)) + 1)
        var buckets = [[Int32]](repeating: [], count: dims.x * dims.y * dims.z)
        @Sendable func bucket(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let g = (p - hashLow) / cell
            return simd_clamp(SIMD3<Int>(Int(g.x), Int(g.y), Int(g.z)), .zero, dims &- 1)
        }
        for (n, p) in sites.enumerated() {
            let b = bucket(p)
            buckets[b.x + dims.x * (b.y + dims.y * b.z)].append(Int32(n))
        }
        progress?(0.1)
        let frozenSites = sites
        let frozenStripCount = sites.count - skinSites
        let frozenBuckets = buckets
        // Clip each cell.
        struct Built {
            var polyhedron: QuarryPolyhedron
            var volume: Float
            var centroid: SIMD3<Float>
            var skin = false
        }
        var builtRaw = [Built?](repeating: nil, count: sites.count)
        builtRaw.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: frozenSites.count) { n in
                let site = frozenSites[n]
                let isSkin = n >= frozenStripCount
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
                near.sort {
                    Self.bedded($0.1, of: site, in: frozenSites)
                        < Self.bedded($1.1, of: site, in: frozenSites)
                }
                let reach = cell * 2.2
                var polyhedron = QuarryPolyhedron.box(
                    low: site - reach, high: site + reach)
                for (_, other) in near {
                    let extent = polyhedron.maxDistance(from: site)
                    let q = frozenSites[other]
                    let normal = Self.beddedNormal(q - site)
                    let middle = (q + site) * 0.5
                    if simd_dot(normal, middle - site) > extent { continue }
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
                    // Each cell's outer face sits a little in from the surface or not, so the face is
                    // stepped block by block rather than one smooth plane.
                    let recess = extent * 0.55 * QuarryNoise.hash(Int32(n), 7, 11).magnitude
                    polyhedron.clip(normal: top.0, offset: top.1 - recess, kind: 1)
                    if isSkin {
                        // Behind the skin: the old surface's plane under the site itself, moved in by
                        // the thickness. (Planes from the other samples, up on the brow, cut away
                        // the whole of a steep face's skin.)
                        if offset == .zero {
                            polyhedron.clip(normal: -top.0, offset: -(top.1 - skinThickness), kind: 2)
                        }
                    } else {
                        let bottom = normal(hNew)
                        polyhedron.clip(normal: -bottom.0, offset: -bottom.1, kind: 2)
                    }
                }
                let (volume, centroid) = polyhedron.volumeAndCentroid
                if polyhedron.faces.count >= 4, volume > 0, polyhedron.faces.count < 40 {
                    output[n] = Built(
                        polyhedron: polyhedron, volume: volume, centroid: centroid, skin: isSkin)
                }
            }
        }
        let cells = builtRaw.compactMap { $0 }
        progress?(0.4)
        // Bedding and joints cut each coarse cell into slabs and wedges, and more where the rock
        // is more broken, so large blocks stand among fines.
        let referenceVolume = cells.reduce(0) { $0 + $1.volume } / Float(max(cells.count, 1))
        var cutOut = [[Built]](repeating: [], count: cells.count)
        cutOut.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: cells.count) { n in
                let centre = cells[n].centroid
                let intensity = min(1, density(centre) / 2.6)
                let pieces = QuarryFracture.fracture(
                    cells[n].polyhedron, intensity: intensity, minimumVolume: 0.012 * referenceVolume)
                output[n] = pieces.compactMap { piece -> Built? in
                    let (volume, centroid) = piece.volumeAndCentroid
                    guard piece.faces.count >= 4, volume > 0, piece.faces.count < 48 else { return nil }
                    return Built(polyhedron: piece, volume: volume, centroid: centroid, skin: cells[n].skin)
                }
            }
        }
        let built = cutOut.flatMap { $0 }
        progress?(0.6)
        let meanVolume = built.reduce(0) { $0 + $1.volume } / Float(max(built.count, 1))
        let keep = built.filter { $0.volume > 0.02 * meanVolume }
        report.append(
            "built \(built.count) cells, kept \(keep.count) (dropped slivers); mean volume \(String(format: "%.2f", meanVolume)) m3, took \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
        )
        let finalEdge = cbrt(meanVolume)
        let radiusCap = finalEdge * 0.55
        let meanVolumeKept = keep.reduce(0) { $0 + $1.volume } / Float(max(keep.count, 1))
        // Each block's displaced mesh, built in parallel.
        var meshes = [(vertices: [Vertex], indices: [UInt32], anchors: [SIMD3<Float>])](
            repeating: ([], [], []), count: keep.count)
        meshes.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: keep.count) { n in
                var vertices: [Vertex] = []
                var indices: [UInt32] = []
                var anchors: [SIMD3<Float>] = []
                var localRandom = QuarryRandom(seed: UInt64(n) &+ 910)
                let size = cbrt(keep[n].volume)
                let level: Int
                if options.meshDetail > 0 {
                    level = size < 1.2 ? 1 : 2
                } else {
                    level = size < 0.55 ? 1 : size < 1.2 ? 2 : size < 2.2 ? 3 : 4
                }
                Self.tessellate(
                    keep[n].polyhedron, centre: keep[n].centroid, body: UInt32(n), level: level,
                    warp: size * 0.07, seed: Float(n) * 0.137, relief: 0.16, vertices: &vertices,
                    indices: &indices)
                for _ in 0..<6 {
                    let polygon = keep[n].polyhedron.faces[
                        Int(localRandom.float() * Float(keep[n].polyhedron.faces.count - 1))]
                    let a = polygon[0]
                    let b = polygon[1]
                    let c = polygon[2]
                    let u = sqrt(localRandom.float())
                    let v = localRandom.float()
                    let point = a + (b - a) * u * v + (c - a) * u * (1 - v)
                    anchors.append(point - keep[n].centroid)
                }
                output[n] = (vertices, indices, anchors)
            }
        }
        progress?(0.75)
        let meshed = Date()
        var blocks: [Block] = []
        blocks.reserveCapacity(keep.count)
        for (body, cell) in keep.enumerated() {
            if body % 20_000 == 19_999 { progress?(0.75 + 0.25 * Float(body) / Float(keep.count)) }
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
            for polygon in cell.polyhedron.faces {
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
                for v in polygon { corners.append(v - c) }
            }
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: meshes[body].vertices)
            indices.append(contentsOf: meshes[body].indices.map { $0 + base })
            chipAnchors.append(contentsOf: meshes[body].anchors)
            // Inscribed in the block, and clear of the ground it rests on: a sphere that starts in
            // the ground is pushed out of it as soon as its block wakes, and a large block was thrown
            // that way (emmettl/bombcad-work#125).
            let groundNow = terrain.heights
            func inscribed(_ p: SIMD3<Float>) -> Float {
                let inside = planes.reduce(Float.infinity) { min($0, $1.1 - simd_dot($1.0, p)) }
                let w = c + p
                let e: Float = 0.5
                let ground = height(groundNow, w.x, w.y)
                let dx = (height(groundNow, w.x + e, w.y) - height(groundNow, w.x - e, w.y)) / (2 * e)
                let dy = (height(groundNow, w.x, w.y + e) - height(groundNow, w.x, w.y - e)) / (2 * e)
                let up = 1 / sqrt(1 + dx * dx + dy * dy)
                return min(inside, (w.z - ground) * up - 0.02)
            }
            // Contact: the inscribed sphere at the centre, and spheres toward the far corners.
            let firstSphere = spheres.count
            let central = max(0.05, min(inscribed(.zero), radiusCap))
            spheres.append(Sphere(offset: .zero, radius: central))
            var chosen: [SIMD3<Float>] = [.zero]
            var added = 1
            let aspect =
                (localBounds.1 - localBounds.0).max() / max((localBounds.1 - localBounds.0).min(), 0.05)
            let target = max(
                3,
                min(
                    12,
                    Int(
                        (Float(options.spheres) * pow(cell.volume / meanVolumeKept, 0.7) + aspect * 0.5)
                            .rounded())))
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
                    size: cbrt(cell.volume), skin: cell.skin))
        }
        self.blocks = blocks
        report.append(String(format: "meshes and spheres: %.1f s", Date().timeIntervalSince(meshed)))
        maxRadius = spheres.reduce(0) { max($0, $1.radius) }
        report.append(
            "blocks \(blocks.count), spheres \(spheres.count) (\(String(format: "%.2f", Float(spheres.count) / Float(max(blocks.count, 1)))) per block), max radius \(String(format: "%.2f", maxRadius)) m, vertices \(vertices.count), triangles \(indices.count / 3), \(String(format: "%.1f", Date().timeIntervalSince(start))) s in all"
        )
    }

    /// The bedding: the rock splits flatter along these planes, tilted a little.
    public static let beddingNormal = simd_normalize(SIMD3<Float>(0.06, 0.05, 1))
    public static let beddingStretch: Float = 1.7

    /// Squared distance from `site` to site `n` in the bedded metric.
    public static func bedded(_ n: Int, of site: SIMD3<Float>, in sites: [SIMD3<Float>]) -> Float {
        let d = sites[n] - site
        let along = simd_dot(d, beddingNormal)
        return simd_length_squared(d) + (beddingStretch * beddingStretch - 1) * along * along
    }

    /// The plane normal between sites `d` apart, in the bedded metric.
    public static func beddedNormal(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let along = simd_dot(d, beddingNormal)
        return simd_normalize(d + (beddingStretch * beddingStretch - 1) * along * beddingNormal)
    }

    /// Surface displacement, a function of world position alone so that neighbouring blocks stay
    /// matched where they touch.
    public static func displacement(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = p * SIMD3<Float>(0.8, 0.8, 1.15) + 31
        let large = SIMD3<Float>(
            QuarryNoise.fbm(q, octaves: 2), QuarryNoise.fbm(q + 13.7, octaves: 2),
            QuarryNoise.fbm(q + 29.1, octaves: 2))
        let r = p * 3.4 + 7
        let fine = SIMD3<Float>(
            QuarryNoise.fbm(r, octaves: 2), QuarryNoise.fbm(r + 5.3, octaves: 2),
            QuarryNoise.fbm(r + 17.9, octaves: 2))
        return large * 0.22 + fine * 0.06
    }

    /// A polygon's tessellated, displaced surface: each fan triangle subdivided `level` times,
    /// with vertex normals from its own grid. Kind comes from the polygon.
    public static func tessellate(
        _ poly: QuarryPolyhedron, centre c: SIMD3<Float>, origin: SIMD3<Float>? = nil, body: UInt32,
        level n: Int,
        warp: Float, seed: Float, relief: Float = 0, vertices: inout [Vertex], indices: inout [UInt32]
    ) {
        for (f, polygon) in poly.faces.enumerated() where polygon.count >= 3 {
            for k in 1..<(polygon.count - 1) {
                let (a, b, cc) = (polygon[0], polygon[k], polygon[k + 1])
                var outward = simd_cross(b - a, cc - a)
                if simd_length_squared(outward) < 1e-12 { continue }
                let flip = simd_dot(outward, a - c) < 0
                if flip { outward = -outward }
                let corners = flip ? (a, cc, b) : (a, b, cc)
                let side = n + 1
                func at(_ i: Int, _ j: Int) -> Int { j * (2 * side - j + 1) / 2 + i }
                var positions = [SIMD3<Float>](repeating: .zero, count: side * (side + 1) / 2)
                for j in 0...n {
                    for i in 0...(n - j) {
                        let (u, v) = (Float(i) / Float(n), Float(j) / Float(n))
                        var p = corners.0 + (corners.1 - corners.0) * u + (corners.2 - corners.0) * v
                        p += displacement(p)
                        if relief > 0 {
                            let w = p * 0.42 + 13
                            p +=
                                relief
                                * SIMD3<Float>(
                                    QuarryNoise.fbm(w, octaves: 3), QuarryNoise.fbm(w + 4.7, octaves: 3),
                                    QuarryNoise.fbm(w + 11.3, octaves: 3)) * 1.4
                        }
                        if warp > 0 {
                            let t = p * 0.7 + seed
                            p +=
                                warp
                                * SIMD3<Float>(
                                    QuarryNoise.value(t), QuarryNoise.value(t + 9.1),
                                    QuarryNoise.value(t + 21.3)) * 1.5
                        }
                        positions[at(i, j)] = p
                    }
                }
                var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
                func triangle(_ x: Int, _ y: Int, _ z: Int) {
                    let normal = simd_cross(positions[y] - positions[x], positions[z] - positions[x])
                    normals[x] += normal
                    normals[y] += normal
                    normals[z] += normal
                }
                let first = UInt32(vertices.count)
                for j in 0..<n {
                    for i in 0..<(n - j) {
                        triangle(at(i, j), at(i + 1, j), at(i, j + 1))
                        indices += [
                            first + UInt32(at(i, j)), first + UInt32(at(i + 1, j)),
                            first + UInt32(at(i, j + 1)),
                        ]
                        if i + 1 < n - j {
                            triangle(at(i + 1, j), at(i + 1, j + 1), at(i, j + 1))
                            indices += [
                                first + UInt32(at(i + 1, j)), first + UInt32(at(i + 1, j + 1)),
                                first + UInt32(at(i, j + 1)),
                            ]
                        }
                    }
                }
                for (m, position) in positions.enumerated() {
                    var normal = simd_normalize(normals[m] + 1e-9 * outward)
                    if normal.x.isNaN { normal = SIMD3(0, 0, 1) }
                    let packed = pack(normal: normal, kind: poly.kinds[f])
                    let local = position - (origin ?? c)
                    vertices.append(Vertex(x: local.x, y: local.y, z: local.z, normal: packed, body: body))
                }
            }
        }
    }

    /// Render-only rock over every steep part of the ground that the broken strip does not cover:
    /// bedded cells a little proud of the terrain, so the strip's ends do not show.
    public mutating func buildDressing(edge: Float = 1.15, level: Int = 3) {
        let t = terrain
        let hillside = self
        @Sendable func surface(_ x: Float, _ y: Float) -> Float {
            let inside = x > t.origin.x + 1 && x < t.origin.x + Float(t.columns - 2) * t.spacing
            return inside ? hillside.height(t.heights, x, y) : hillside.oldHeight(x, y)
        }
        func slope(_ x: Float, _ y: Float) -> Float {
            let e: Float = 1
            let dx = (surface(x + e, y) - surface(x - e, y)) / (2 * e)
            let dy = (surface(x, y + e) - surface(x, y - e)) / (2 * e)
            return sqrt(dx * dx + dy * dy)
        }
        var r = QuarryRandom(seed: 5150)
        let lowXY = SIMD2<Float>(low.x - 60, low.y + 3)
        let highXY = SIMD2<Float>(620, high.y - 3)
        // Sites at the wanted density per unit volume of a 2.7 m band under the steep ground.
        let trials = 300_000
        var weightSum: Float = 0
        var steepCount = 0
        func surfaceWeight(_ x: Float, _ y: Float) -> Float {
            let s = slope(x, y)
            return s > 0.55 + 0.25 * r.float() ? sqrt(1 + s * s) : 0
        }
        for _ in 0..<trials {
            let w = surfaceWeight(r.float(lowXY.x, highXY.x), r.float(lowXY.y, highXY.y))
            if w > 0 {
                weightSum += w
                steepCount += 1
            }
        }
        let area = (highXY.x - lowXY.x) * (highXY.y - lowXY.y) * weightSum / Float(trials)
        let wanted = Int(area * 2.7 / (edge * edge * edge))
        var sites: [SIMD3<Float>] = []
        sites.reserveCapacity(wanted)
        let maxWeight = sqrt(1 + 8 * 8 as Float)
        var attemptsMade = 0
        while sites.count < wanted && attemptsMade < 40_000_000 {
            attemptsMade += 1
            let (x, y) = (r.float(lowXY.x, highXY.x), r.float(lowXY.y, highXY.y))
            let w = surfaceWeight(x, y)
            guard w > 0, r.float() < min(1, w / maxWeight * 3) else { continue }
            let e: Float = 0.8
            let dx = (surface(x + e, y) - surface(x - e, y)) / (2 * e)
            let dy = (surface(x, y + e) - surface(x, y - e)) / (2 * e)
            let n = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
            // The skin of blocks covers the old face near the strip; the dressing goes on past it.
            if x > -163, x < length + 163,
                hillside.height(original, x, y) - hillside.height(t.heights, x, y) < 0.3
            {
                continue
            }
            sites.append(SIMD3(x, y, surface(x, y)) + n * (0.3 - 2.7 * r.float()))
        }
        let accepted = sites.count
        let cell = edge * 2.1
        var grid: [Int64: [Int32]] = [:]
        @Sendable func key(_ p: SIMD3<Float>) -> Int64 {
            let g = floor(p / cell)
            return Int64(g.x) &+ Int64(g.y) &* 1_000_003 &+ Int64(g.z) &* 2_000_000_011
        }
        for (n, p) in sites.enumerated() { grid[key(p), default: []].append(Int32(n)) }
        let frozen = sites
        let frozenGrid = grid
        var meshes = [(vertices: [Vertex], indices: [UInt32])](repeating: ([], []), count: sites.count)
        meshes.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: frozen.count) { n in
                let site = frozen[n]
                var near: [Int] = []
                for dk: Float in [-1, 0, 1] {
                    for dj: Float in [-1, 0, 1] {
                        for di: Float in [-1, 0, 1] {
                            for other in frozenGrid[key(site + SIMD3(di, dj, dk) * cell)] ?? []
                            where Int(other) != n {
                                near.append(Int(other))
                            }
                        }
                    }
                }
                near.sort { Self.bedded($0, of: site, in: frozen) < Self.bedded($1, of: site, in: frozen) }
                var polyhedron = QuarryPolyhedron.box(low: site - cell * 1.8, high: site + cell * 1.8)
                for other in near {
                    let q = frozen[other]
                    let normal = Self.beddedNormal(q - site)
                    let middle = (q + site) * 0.5
                    if simd_dot(normal, middle - site) > polyhedron.maxDistance(from: site) { continue }
                    polyhedron.clip(normal: normal, offset: simd_dot(normal, middle), kind: 0)
                }
                let extent = min(polyhedron.maxDistance(from: site), cell)
                for offset: SIMD2<Float> in [.zero, [0.7, 0], [-0.7, 0], [0, 0.7], [0, -0.7]] {
                    let p = SIMD2(site.x, site.y) + offset * extent
                    let e: Float = 0.5
                    let z = surface(p.x, p.y)
                    let dx = (surface(p.x + e, p.y) - surface(p.x - e, p.y)) / (2 * e)
                    let dy = (surface(p.x, p.y + e) - surface(p.x, p.y - e)) / (2 * e)
                    let normal = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                    polyhedron.clip(
                        normal: normal, offset: simd_dot(normal, SIMD3<Float>(p.x, p.y, z)) + 0.35, kind: 1)
                }
                let (volume, centroid) = polyhedron.volumeAndCentroid
                guard polyhedron.faces.count >= 4, polyhedron.faces.count < 40, volume > 0.02 else { return }
                var vertices: [Vertex] = []
                var indices: [UInt32] = []
                Self.tessellate(
                    polyhedron, centre: centroid, origin: .zero, body: 0, level: level, warp: 0, seed: 0,
                    relief: 0.75, vertices: &vertices,
                    indices: &indices)
                output[n] = (vertices, indices)
            }
        }
        for mesh in meshes where !mesh.vertices.isEmpty {
            let base = UInt32(dressingVertices.count)
            dressingVertices.append(contentsOf: mesh.vertices)
            dressingIndices.append(contentsOf: mesh.indices.map { $0 + base })
        }
        report.append(
            "dressing: \(sites.count) sites, \(dressingIndices.count / 3) triangles (\(accepted) steep samples)"
        )
    }

    /// Packs a unit normal in 10:10:10 and the face kind in the top two bits.
    public static func pack(normal n: SIMD3<Float>, kind: UInt8) -> UInt32 {
        func s10(_ v: Float) -> UInt32 {
            UInt32(max(0, min(1023, (v * 0.5 + 0.5) * 1023 + 0.5)))
        }
        return s10(n.x) | (s10(n.y) << 10) | (s10(n.z) << 20) | (UInt32(kind) << 30)
    }
}
