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
    /// A face: how far behind the old face the new one stands. A ridge cut: how far below the
    /// crest on its line the cut's floor lies (m).
    public var depth: Float
    /// Which scene the site lays out: a quarry face's strip, or a cut across a ridge whose line
    /// runs from `start` to `end` across the crest (emmettl/bombcad-work#131).
    public var scene: QuarryScene
    /// A ridge cut's width at its floor (m); not used by a face.
    public var width: Float

    public init(
        terrain: Terrain, start: SIMD2<Float>, end: SIMD2<Float>, depth: Float = 26,
        scene: QuarryScene = .face,
        width: Float = QuarryRidge.defaultWidth
    ) {
        self.terrain = terrain
        self.start = start
        self.end = end
        self.depth = depth
        self.scene = scene
        self.width = width
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
        public var siteShare: Float = 0.17
        /// 0 for the film's full mesh, 1 for the live window's (fewer triangles).
        public var meshDetail = 0
        public var spheres = 5
        /// How much the bedding and joints cut the coarse cells, times the rock's own intensity: 1
        /// as the scenes are; less for fewer, larger pieces (for trying, emmettl/bombcad-work#139).
        public var fractureScale: Float = 1
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
        /// The strip lies on ground with no face to break: nothing between old and new surfaces. For a
        /// ridge cut, the line does not cross a ridge: the ground does not fall away on both sides.
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
    /// A ridge cut's outcrops (`QuarryFace.outcrop`), render-only, shaded on their own
    /// (`ledgeFragment`); empty for a face.
    public var ledgeVertices: [Vertex] = []
    public var ledgeIndices: [UInt32] = []
    /// The held skin over the blocks' outer faces (`heldSkin`): render-only, in the world's frame,
    /// each triangle tagged with the block under it and gone once that block moves.
    public var skinVertices: [Vertex] = []
    public var skinIndices: [UInt32] = []
    /// What the generator made, line by line (counts and times).
    public var report: [String] = []
    /// Which generated rock this is, the same in every copy of it: a renderer of a face kept
    /// without its meshes (`withoutMesh()`) finds them on the GPU by it, where another renderer of
    /// the same rock put them. 0 before `generate()`.
    public var meshID: UInt64 = 0
    /// The domain of the hash grid (m).
    public let low: SIMD3<Float>
    public let high: SIMD3<Float>
    /// The lowest floor and the highest old ground near the strip (m).
    public let floorLevel: Float
    public let topLevel: Float
    /// A ridge cut's layout (its floor, crest and walls); nil for a face.
    public let ridge: QuarryRidge?
    /// The old face's line (its y at each x, a metre apart from the grid's first column) and the
    /// floor and top heights in front of and behind it. For a ridge cut, the cut's centre line
    /// (y = 0), and the ground after and before the blast along it.
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
        if site.scene == .ridgeCut {
            let layout = QuarryRidge.layout(site: site, origin: origin, along: along)
            inward = layout.inward
            terrain = layout.terrain
            original = layout.original
            faceTable = layout.centre
            floorTable = layout.floor
            topTable = layout.top
            floorLevel = layout.floorLevel
            topLevel = layout.topLevel
            low = layout.low
            high = layout.high
            ridge = layout.ridge
            guard layout.crossesRidge, layout.cutVolume > 2000 else { throw Failure.noFace }
            return
        }
        ridge = nil
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
        meshID = UInt64.random(in: 1...UInt64.max)
        let options = self.options
        let length = self.length
        let depth = self.depth
        let start = Date()
        // Bounds of the broken strip.
        let faceLow = faceTable.min() ?? 0
        let faceHigh = faceTable.max() ?? 0
        var boxLow = SIMD3<Float>(-1, faceLow - 15, floorLevel - 1)
        var boxHigh = SIMD3<Float>(length + 1, faceHigh + depth + 30, topLevel + 1)
        let ridge = self.ridge
        if let ridge {
            // The cut across the ridge: its line's length, as wide as its walls reach at the crest.
            (boxLow, boxHigh) = ridge.box(topLevel: topLevel)
        }
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
            // Finer near the firings: a face's row, a ridge cut's rows either side of its middle.
            let across =
                ridge == nil ? abs(p.y - hillside.faceLine(p.x) - depth * 0.4) / 18 : abs(p.y) / 18
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
        // A ridge cut has no held skin past its ends, which is about a third of a face's blocks:
        // more coarse cells, so that `blocks` asks for about as many blocks in either scene.
        var siteTarget = Int(
            Float(options.blocks) * options.siteShare * (ridge == nil ? 1 : QuarryRidge.siteBoost))
        if let ridge { siteTarget = ridge.coarseCells(siteTarget) }
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
        // A ridge cut has no face running on past it, so no skin: the ground past its walls is the
        // ridge itself.
        for _ in 0..<(ridge == nil ? 400_000 : 0) {
            skinSamples += 1
            if skin(skinSample()) { skinHits += 1 }
        }
        let skinBox = (skinHigh - skinLow).x * (skinHigh - skinLow).y * (skinHigh - skinLow).z
        let skinVolume = skinBox * Float(skinHits) / Float(max(skinSamples, 1))
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
        // How far every cell's outer face stands back besides its bed's own recess: the mean of
        // the share of its size each cell took until 12 November 2026.
        let cellRecess = cell * 0.06
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
                    let middle = (q + site) * 0.5
                    // Each pair of cells meets in the metric of the bed between them, so neighbours
                    // share their face and cells never overlap: massive limestone breaks blockier,
                    // shale flatter.
                    let normal = Self.beddedNormal(
                        q - site, stretch: QuarryRock.stretch(QuarryRock.kind(at: middle)))
                    if simd_dot(normal, middle - site) > extent { continue }
                    polyhedron.clip(normal: normal, offset: simd_dot(normal, middle), kind: 0)
                }
                // Clip to the old surface and the new one, by tangent planes around the cell.
                let extent = min(polyhedron.maxDistance(from: site), cell)
                for offset: SIMD2<Float> in [.zero, [0.7, 0], [-0.7, 0], [0, 0.7], [0, -0.7]] where !isSkin {
                    let p = SIMD2(site.x, site.y) + offset * extent
                    let bottom = hillside.tangentPlane(hNew, p)
                    polyhedron.clip(normal: -bottom.0, offset: -bottom.1, kind: 2)
                }
                // The old surface by its tangent planes at the point of it the site lies under (along
                // its normal) and at points around that one along the surface. Taken at points around
                // the site in plan, as until 12 November 2026, a steep face's planes came from the
                // floor in front or the brow above and cut its outer cells away, leaving pits. A
                // plane the site stands well outside of is across a hollow, and left out.
                // Each cell's outer face stands back by its bed's own weathering (shale under ledges
                // of the harder beds), so the face is banded in relief. Until 12 November 2026 each
                // cell also stood back a random amount of its own, which drew every cell's outline
                // on the unbroken face as a crack: the rock looked broken before the blast
                // (emmettl/bombcad-work#136). Now the recess is the bed's alone, eased across beds'
                // boundaries, the same surface for every cell.
                let foot = hillside.onSurface(hOld, site)
                let side = simd_normalize(
                    abs(foot.normal.z) < 0.9
                        ? simd_cross(foot.normal, SIMD3(0, 0, 1)) : simd_cross(foot.normal, SIMD3(1, 0, 0)))
                let slope = simd_cross(foot.normal, side)
                for (k, along) in [SIMD3<Float>.zero, side, -side, slope, -slope].enumerated() {
                    // The held skin keeps its cells as before, at points around the site in plan:
                    // taken along the surface it kept a fifth more of them, all bodies to simulate.
                    let inPlan: [SIMD2<Float>] = [.zero, [0.7, 0], [-0.7, 0], [0, 0.7], [0, -0.7]]
                    let q = SIMD2(site.x, site.y) + inPlan[k] * extent
                    let (point, normal) =
                        isSkin
                        ? (SIMD3(q, hillside.height(hOld, q.x, q.y)), hillside.tangentPlane(hOld, q).0)
                        : along == .zero
                            ? foot : hillside.onSurface(hOld, foot.point + along * (0.7 * extent))
                    if along != .zero, simd_dot(normal, site - point) > 0.6 { continue }
                    let recess = QuarryRock.blendedRecess(at: point) + cellRecess
                    polyhedron.clip(normal: normal, offset: simd_dot(normal, point) - recess, kind: 1)
                }
                if isSkin {
                    // Behind the skin: the old surface's plane under the site itself, moved in by the
                    // thickness. (Planes from the other samples, up on the brow, cut away the whole of
                    // a steep face's skin.)
                    let under = hillside.tangentPlane(hOld, SIMD2(site.x, site.y))
                    polyhedron.clip(normal: -under.0, offset: -(under.1 - skinThickness), kind: 2)
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
                let intensity = min(1, density(centre) / 2.6) * options.fractureScale
                let pieces = QuarryFracture.fracture(
                    cells[n].polyhedron, intensity: intensity, minimumVolume: 0.012 * referenceVolume,
                    beds: !cells[n].skin)
                var chips = QuarryRandom(seed: options.seed &+ UInt64(n) &* 7919)
                output[n] = pieces.compactMap { original -> Built? in
                    var piece = original
                    // Some corners knocked off as fresh breaks, more on the harder rock.
                    let size = cbrt(max(piece.volumeAndCentroid.volume, 1e-6))
                    let hard = QuarryRock.kind(at: piece.volumeAndCentroid.centroid) != .shale
                    if !cells[n].skin, size > 0.35, chips.float() < (hard ? 0.6 : 0.25) {
                        QuarryFracture.chipCorners(
                            &piece, count: 1 + Int(chips.float() * 2.5), size: size, random: &chips)
                    }
                    let (volume, centroid) = piece.volumeAndCentroid
                    guard piece.faces.count >= 4, volume > 0, piece.faces.count < 48 else { return nil }
                    return Built(polyhedron: piece, volume: volume, centroid: centroid, skin: cells[n].skin)
                }
            }
        }
        let built = cutOut.flatMap { $0 }
        progress?(0.6)
        let meanVolume = built.reduce(0) { $0 + $1.volume } / Float(max(built.count, 1))
        // A piece under the excavated ground or out in front of the old face is no part of the cut:
        // where the surfaces bend, their tangent planes clip a coarse cell only roughly, and with
        // the larger cells of massive beds (12 November 2026) a few pieces hung metres below the
        // floor (to be pushed up through it when fired) or stood out of the face.
        var stray = 0
        let keep = built.filter { piece in
            guard piece.volume > 0.02 * meanVolume else { return false }
            guard !piece.skin else { return true }
            let c = piece.centroid
            let margin = 0.25 * cbrt(piece.volume)
            let out = height(hNew, c.x, c.y) - c.z > margin || c.z - height(hOld, c.x, c.y) > margin
            if out { stray += 1 }
            return !out
        }
        report.append("left out \(stray) pieces under the floor or out of the face")
        var shapes: [QuarryRock.Shape: Int] = [:]
        var elongations: [Float] = []
        var flatnesses: [Float] = []
        var byKind: [QuarryRock.Kind: [QuarryRock.Shape: Int]] = [:]
        for piece in keep where !piece.skin {
            let (shape, ratios) = QuarryRock.shapeAndRatios(piece.polyhedron)
            shapes[shape, default: 0] += 1
            byKind[QuarryRock.kind(at: piece.centroid), default: [:]][shape, default: 0] += 1
            elongations.append(ratios.x)
            flatnesses.append(ratios.y)
        }
        elongations.sort()
        flatnesses.sort()
        let shapeCount = max(1, shapes.values.reduce(0, +))
        let sizes = keep.filter { !$0.skin }.map { cbrt($0.volume) }.sorted()
        if !sizes.isEmpty {
            func at(_ p: Float) -> String {
                String(format: "%.2f", sizes[min(sizes.count - 1, Int(Float(sizes.count) * p))])
            }
            report.append(
                "sizes (cube root of volume, m): 10% \(at(0.1)), median \(at(0.5)), 90% \(at(0.9)), 99% \(at(0.99)), largest \(at(1))"
            )
        }
        report.append(
            "shapes (Zingg) of the broken rock: "
                + QuarryRock.Shape.allCases.map {
                    "\($0.rawValue) \(Int((Float(shapes[$0] ?? 0) / Float(shapeCount) * 100).rounded()))%"
                }.joined(separator: ", "))
        for kind in QuarryRock.Kind.allCases {
            let counts = byKind[kind] ?? [:]
            let total = max(1, counts.values.reduce(0, +))
            report.append(
                "shapes, \(kind) (\(total) pieces): "
                    + QuarryRock.Shape.allCases.map {
                        "\($0.rawValue) \(Int((Float(counts[$0] ?? 0) / Float(total) * 100).rounded()))%"
                    }.joined(separator: ", "))
        }
        if !elongations.isEmpty {
            func spread(_ v: [Float]) -> String {
                [0.1, 0.5, 0.9].map { String(format: "%.2f", v[min(v.count - 1, Int(Float(v.count) * $0))]) }
                    .joined(separator: " / ")
            }
            report.append(
                "spread (10% / median / 90%): b/a \(spread(elongations)), c/b \(spread(flatnesses))")
        }
        report.append(
            "built \(built.count) cells, kept \(keep.count) (dropped slivers); mean volume \(String(format: "%.2f", meanVolume)) m3, took \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
        )
        let finalEdge = cbrt(meanVolume)
        let radiusCap = finalEdge * 0.55
        let meanVolumeKept = keep.reduce(0) { $0 + $1.volume } / Float(max(keep.count, 1))
        precondition(keep.count <= Int(QuarryRock.bodyMask), "too many blocks for a vertex's body index")
        // How deep each block lies below the old surface, and which way that surface is: rock near
        // it is weathered, deeper rock fresh (`QuarryRock.weathering`).
        let rings: [SIMD2<Float>] = (0..<8).map { SIMD2(cos(Float($0) * .pi / 4), sin(Float($0) * .pi / 4)) }
        @Sendable func surfaceDepth(_ p: SIMD3<Float>) -> (depth: Float, outward: SIMD3<Float>) {
            let top = hillside.height(hOld, p.x, p.y)
            guard p.z < top else { return (0, SIMD3(0, 0, 1)) }
            let e: Float = 0.5
            let dx = (hillside.height(hOld, p.x + e, p.y) - hillside.height(hOld, p.x - e, p.y)) / (2 * e)
            let dy = (hillside.height(hOld, p.x, p.y + e) - hillside.height(hOld, p.x, p.y - e)) / (2 * e)
            let up = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
            var best = (top - p.z) * up.z
            var outward = up
            var r: Float = 0.5
            while r < min(best, 9) {
                for d in rings where hillside.height(hOld, p.x + d.x * r, p.y + d.y * r) < p.z {
                    best = r
                    outward = SIMD3(d.x, d.y, 0)
                    break
                }
                r += 0.5
            }
            return (best, outward)
        }
        // The old surface, stood back by each bed's own weathering and `cellRecess`, as the cells
        // were clipped: their outer faces are laid on it, so the unbroken face is one surface,
        // banded by its beds, rather than a cell-by-cell crack network (emmettl/bombcad-work#136).
        let outer: OuterSurface = { p in
            let e: Float = 0.5
            let top = hillside.height(hOld, p.x, p.y)
            let dx = (hillside.height(hOld, p.x + e, p.y) - hillside.height(hOld, p.x - e, p.y)) / (2 * e)
            let dy = (hillside.height(hOld, p.x, p.y + e) - hillside.height(hOld, p.x, p.y - e)) / (2 * e)
            let normal = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
            let depth = (top - p.z) * normal.z
            return (depth - QuarryRock.blendedRecess(at: p + normal * depth) - cellRecess, normal)
        }
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
                // Each face's weathering, by its own depth: deeper along open joints, and with an
                // irregular front.
                let c = keep[n].centroid
                let (depth, outward) = surfaceDepth(c)
                let polyhedron = keep[n].polyhedron
                let tags = polyhedron.faces.enumerated().map { f, polygon -> UInt32 in
                    let centre = polygon.reduce(SIMD3<Float>.zero, +) / Float(polygon.count)
                    var d =
                        depth - simd_dot(centre - c, outward) + 2.5 * QuarryNoise.value(centre * 0.12 + 3.3)
                    if polyhedron.kinds[f] == 3 { d *= 0.55 }
                    if polyhedron.kinds[f] == 1 { d = min(d, 0) }
                    return QuarryRock.faceTag(
                        weathering: QuarryRock.weathering(depth: d), random: localRandom.float())
                }
                let weathered = QuarryRock.weathering(depth: depth)
                // How thick the piece is across the old surface: its outer face is not laid on the
                // surface further in than a share of that, so a thin piece is never turned inside out.
                let across = polyhedron.extent(along: outer(c).normal)
                let thickness = across.1 - across.0
                Self.tessellate(
                    polyhedron, centre: c, body: UInt32(n), level: level,
                    warp: size * 0.07, seed: Float(n) * 0.137, relief: Self.blockRelief,
                    rounding: level >= 2 ? size * (0.03 + 0.04 * weathered) : 0, tags: tags,
                    outer: outer, inward: 0.4 * thickness, vertices: &vertices, indices: &indices)
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
        // The held skin over the blocks' outer faces, on the same surface, finer than the blocks'
        // own meshes (emmettl/bombcad-work#139).
        let skin = Self.heldSkin(
            pieces: keep.map(\.polyhedron), centres: keep.map(\.centroid), held: keep.map(\.skin),
            face: hillside,
            oldHeights: hOld, outer: outer, relief: Self.blockRelief,
            spacing: options.meshDetail > 0 ? 0.25 : 0.15)
        skinVertices = skin.vertices
        skinIndices = skin.indices
        report.append(skin.report)
        maxRadius = spheres.reduce(0) { max($0, $1.radius) }
        report.append(
            "blocks \(blocks.count), spheres \(spheres.count) (\(String(format: "%.2f", Float(spheres.count) / Float(max(blocks.count, 1)))) per block), max radius \(String(format: "%.2f", maxRadius)) m, vertices \(vertices.count), triangles \(indices.count / 3), \(String(format: "%.1f", Date().timeIntervalSince(start))) s in all"
        )
    }

    /// The weathering grade (of 31) that marks the dressing under a face's held skin past the
    /// strip's ends: drawn behind the skin (`dressingVertex`), as held blocks are, so a thin cell
    /// whose outer face could not reach the shale's recess does not show through it.
    public static let underSkinGrade: UInt32 = 30

    /// The relief of the blocks' surfaces (`shaped`), the held skin's too.
    static let blockRelief: Float = 0.16

    /// The bedding: the rock splits flatter along these planes, tilted a little.
    public static let beddingNormal = simd_normalize(SIMD3<Float>(0.06, 0.05, 1))
    public static let beddingStretch: Float = 1.7

    /// Squared distance from `site` to site `n` in the bedded metric.
    public static func bedded(_ n: Int, of site: SIMD3<Float>, in sites: [SIMD3<Float>]) -> Float {
        let d = sites[n] - site
        let along = simd_dot(d, beddingNormal)
        return simd_length_squared(d) + (beddingStretch * beddingStretch - 1) * along * along
    }

    /// The plane normal between sites `d` apart, in the bedded metric (`stretch` along the
    /// bedding's normal).
    public static func beddedNormal(_ d: SIMD3<Float>, stretch: Float = beddingStretch) -> SIMD3<Float> {
        let along = simd_dot(d, beddingNormal)
        return simd_normalize(d + (stretch * stretch - 1) * along * beddingNormal)
    }

    /// The tangent plane of heights `h` at `p` in plan: its normal, and its offset along it.
    func tangentPlane(_ h: [Float], _ p: SIMD2<Float>) -> (SIMD3<Float>, Float) {
        let e: Float = 0.5
        let z = height(h, p.x, p.y)
        let dx = (height(h, p.x + e, p.y) - height(h, p.x - e, p.y)) / (2 * e)
        let dy = (height(h, p.x, p.y + e) - height(h, p.x, p.y - e)) / (2 * e)
        let n = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
        return (n, simd_dot(n, SIMD3<Float>(p.x, p.y, z)))
    }

    /// The point of the surface of heights `h` that `q` lies under or over along the surface's
    /// normal, and the normal there.
    func onSurface(_ h: [Float], _ q: SIMD3<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>) {
        var x = q
        var normal = SIMD3<Float>(0, 0, 1)
        for _ in 0..<6 {
            let (n, offset) = tangentPlane(h, SIMD2(x.x, x.y))
            normal = n
            x += n * max(-3, min(3, offset - simd_dot(n, x)))
        }
        return (SIMD3(x.x, x.y, height(h, x.x, x.y)), normal)
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
        // The fine part is kept small: under the low sun its bumps shadowed every face in spots.
        return large * 0.22 + fine * 0.015
    }

    /// The old surface the rock was cut from, for a block's outer faces: how deep a point lies
    /// inside it (m, negative outside) and the surface's outward normal there.
    public typealias OuterSurface = @Sendable (SIMD3<Float>) -> (depth: Float, normal: SIMD3<Float>)

    /// Where a point of a cell's outer face (`kind` 1) lies on the continuous `outer` surface:
    /// moved along the surface's normal. Inward moves are held to `inward` (m), so a thin piece
    /// keeps its thickness. (Moved within the side faces it lies on instead, the corners that
    /// neighbouring cells share would land in exactly the same place, but a corner's line can
    /// lean far from the normal, and a small difference in depth then carried it across its
    /// own face: one outer triangle in fourteen was turned inside out.)
    static func ontoOuter(_ p: SIMD3<Float>, outer: OuterSurface, inward: Float) -> SIMD3<Float> {
        var t: Float = 0
        let (_, direction) = outer(p)
        for _ in 0..<3 {
            let (depth, normal) = outer(p + direction * t)
            t = max(-inward, min(0.9, t + depth / max(simd_dot(direction, normal), 0.6)))
        }
        return p + direction * t
    }

    /// A polygon's tessellated, displaced surface: each fan triangle subdivided `level` times,
    /// with vertex normals from its own grid. Kind comes from the polygon. With `outer`, the
    /// polyhedron's outer faces (kind 1, clipped by tangent planes cell by cell, so each a
    /// slightly different plane) and the edges of its other faces along them are laid on that
    /// continuous surface instead, with its normals, and not rounded or warped there: neighbouring
    /// cells then meet in one surface, so rock that has not broken reads as whole, with no crack
    /// network before the blast.
    public static func tessellate(
        _ poly: QuarryPolyhedron, centre c: SIMD3<Float>, origin: SIMD3<Float>? = nil, body: UInt32,
        level n: Int,
        warp: Float, seed: Float, relief: Float = 0, rounding: Float = 0, tags: [UInt32]? = nil,
        outer: OuterSurface? = nil, inward: Float = 0,
        vertices: inout [Vertex], indices: inout [UInt32]
    ) {
        // Each face's plane, outward.
        let planes: [(SIMD3<Float>, Float)] = poly.faces.map { polygon in
            var newell = SIMD3<Float>.zero
            for k in polygon.indices {
                let a = polygon[k]
                let b = polygon[(k + 1) % polygon.count]
                newell += SIMD3(
                    (a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
            }
            guard simd_length_squared(newell) > 1e-20, !polygon.isEmpty else {
                return (SIMD3(0, 0, 1), .infinity)
            }
            var normal = simd_normalize(newell)
            if simd_dot(normal, polygon[0] - c) < 0 { normal = -normal }
            return (normal, simd_dot(normal, polygon[0]))
        }
        let outerPlanes =
            outer == nil ? [] : poly.kinds.indices.filter { poly.kinds[$0] == 1 }.map { planes[$0] }
        func onOuter(_ p: SIMD3<Float>) -> Bool {
            outerPlanes.contains { abs(simd_dot($0.0, p) - $0.1) < 2e-3 }
        }
        for (f, polygon) in poly.faces.enumerated() where polygon.count >= 3 {
            let tagged = body | (tags?[f] ?? 0)
            let outerFace = outer != nil && poly.kinds[f] == 1
            // Edges on the outer surface are not rounded: rounded, they made a groove along every
            // seam between unbroken cells.
            let edgeOnOuter: [Bool] = polygon.indices.map { k in
                outer != nil
                    && (outerFace || (onOuter(polygon[k]) && onOuter(polygon[(k + 1) % polygon.count])))
            }
            // In-plane distance to the polygon's edge, for rounding: the same on both faces along an
            // edge, so the pull toward the centre keeps the block closed.
            func edgeDistance(_ p: SIMD3<Float>) -> Float {
                var best = Float.infinity
                for k in polygon.indices where !edgeOnOuter[k] {
                    let a = polygon[k]
                    let b = polygon[(k + 1) % polygon.count]
                    let ab = b - a
                    let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-12)))
                    best = min(best, simd_distance(p, a + ab * t))
                }
                return best
            }
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
                var surfaceNormals = [SIMD3<Float>?](repeating: nil, count: positions.count)
                for j in 0...n {
                    for i in 0...(n - j) {
                        let (u, v) = (Float(i) / Float(n), Float(j) / Float(n))
                        let planar = corners.0 + (corners.1 - corners.0) * u + (corners.2 - corners.0) * v
                        if let outer, outerFace || onOuter(planar) {
                            // On the outer surface: its place there, and its normal, also for a side
                            // face's edge along it, so that what shows of a side face through a seam
                            // is lit as the surface is.
                            let base = ontoOuter(planar, outer: outer, inward: inward)
                            let here = outerPoint(base, outer: outer, relief: relief)
                            positions[at(i, j)] = here
                            surfaceNormals[at(i, j)] = outerNormal(
                                base, here: here, outer: outer, relief: relief)
                            continue
                        }
                        var p = planar + displacement(planar)
                        if rounding > 0 {
                            let e = edgeDistance(planar)
                            if e < rounding {
                                let t = 1 - e / rounding
                                p += simd_normalize(c - planar) * (rounding * 0.5 * t * t)
                            }
                        }
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
                    var normal = surfaceNormals[m] ?? simd_normalize(normals[m] + 1e-9 * outward)
                    if normal.x.isNaN { normal = SIMD3(0, 0, 1) }
                    let packed = pack(normal: normal, kind: poly.kinds[f])
                    let local = position - (origin ?? c)
                    vertices.append(Vertex(x: local.x, y: local.y, z: local.z, normal: packed, body: tagged))
                }
            }
        }
    }

    /// Render-only rock over every steep part of the ground that the broken strip does not cover:
    /// bedded cells a little proud of the terrain, so the strip's ends do not show.
    public mutating func buildDressing(edge: Float = 1.15, level: Int = 3) {
        let t = terrain
        let hillside = self
        let acrossToo = ridge != nil
        // A ridge cut's flanks: dense rock only round the cut, ledges, scree and grass elsewhere.
        let flank = QuarryFlank(face: self)
        @Sendable func surface(_ x: Float, _ y: Float) -> Float {
            // A face's dressing reaches past the grid only along the strip; a ridge's past it across
            // the cut's line too, along the ridge.
            var inside = x > t.origin.x + 1 && x < t.origin.x + Float(t.columns - 2) * t.spacing
            if acrossToo {
                inside = inside && y > t.origin.y + 1 && y < t.origin.y + Float(t.rows - 2) * t.spacing
            }
            return inside ? hillside.height(t.heights, x, y) : hillside.oldHeight(x, y)
        }
        func slope(_ x: Float, _ y: Float) -> Float {
            let e: Float = 1
            let dx = (surface(x + e, y) - surface(x - e, y)) / (2 * e)
            let dy = (surface(x, y + e) - surface(x, y - e)) / (2 * e)
            return sqrt(dx * dx + dy * dy)
        }
        var r = QuarryRandom(seed: 5150)
        var lowXY = SIMD2<Float>(low.x - 60, low.y + 3)
        var highXY = SIMD2<Float>(620, high.y - 3)
        if let ridge {
            // Along the ridge both ways from the cut, as far as the view reaches it.
            (lowXY, highXY) = ridge.dressingArea(low: low, high: high)
        }
        // Sites at the wanted density per unit volume of a 2.7 m band under the steep ground.
        let trials = 300_000
        var weightSum: Float = 0
        var steepCount = 0
        func surfaceWeight(_ x: Float, _ y: Float) -> Float {
            let s = slope(x, y)
            // A ridge cut's dense rock is the cut's and a ragged margin round it, so its broken rock
            // is of a piece with rock round it; the flanks are ledges, scree and grass
            // (`QuarryFlank`; the crest down to about the floor and the steepest ground were
            // paved, which read as flat cut-outs from close, until 12 November 2026).
            if let flank { return flank.paves(x, y) ? sqrt(1 + s * s) : 0 }
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
        // The point on the surface each site was put under, for its clipping.
        var footings: [SIMD2<Float>] = []
        footings.reserveCapacity(wanted)
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
            // The dressing runs over the held skin past the strip's ends too: on the steep face the
            // skin's cells are mostly clipped away by the planes of the floor in front of them, and
            // the terrain's own smooth wall showed there (12 November 2026).
            sites.append(SIMD3(x, y, surface(x, y)) + n * (0.3 - 2.7 * r.float()))
            footings.append(SIMD2(x, y))
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
        let frozenFootings = footings
        let frozenGrid = grid
        // A ridge cut's dense rock's outer surface: the ground stood 0.35 m proud, then back by each
        // bed's weathering and by the sink toward the rock's edge, as its cells are clipped.
        var ridgeSurface: OuterSurface?
        if let flank {
            ridgeSurface = { p in
                let e: Float = 0.5
                let top = surface(p.x, p.y)
                let dx = (surface(p.x + e, p.y) - surface(p.x - e, p.y)) / (2 * e)
                let dy = (surface(p.x, p.y + e) - surface(p.x, p.y - e)) / (2 * e)
                let normal = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                let depth = (top - p.z) * normal.z
                let on = p + normal * depth
                return (depth + 0.35 - QuarryRock.blendedRecess(at: on) - flank.sink(on.x, on.y), normal)
            }
        }
        let ridgeOuter = ridgeSurface
        // A face's rock past the strip's ends, which the held skin's blocks share: laid on their own
        // outer surface (the old ground stood back by its bed's weathering and about the blocks'
        // `cellRecess`), so it reads whole beside the strip rather than as a mosaic of cells each
        // standing proud by its own amount (until 13 November 2026, emmettl/bombcad-work#139). The
        // dressing of the strip's new face, behind the broken rock, keeps its broken look.
        let faceRecess: Float = 0.08
        var faceSurface: OuterSurface?
        if flank == nil {
            faceSurface = { p in
                let e: Float = 0.5
                let top = surface(p.x, p.y)
                let dx = (surface(p.x + e, p.y) - surface(p.x - e, p.y)) / (2 * e)
                let dy = (surface(p.x, p.y + e) - surface(p.x, p.y - e)) / (2 * e)
                let normal = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                let depth = (top - p.z) * normal.z
                return (depth - QuarryRock.blendedRecess(at: p + normal * depth) - faceRecess, normal)
            }
        }
        let faceOuter = faceSurface
        let original = self.original
        /// How deep `p` lies under the old surface, along its normal (m).
        @Sendable func oldDepth(_ p: SIMD3<Float>) -> Float {
            let e: Float = 0.5
            let top = hillside.height(original, p.x, p.y)
            let dx =
                (hillside.height(original, p.x + e, p.y) - hillside.height(original, p.x - e, p.y)) / (2 * e)
            let dy =
                (hillside.height(original, p.x, p.y + e) - hillside.height(original, p.x, p.y - e)) / (2 * e)
            return (top - p.z) / sqrt(1 + dx * dx + dy * dy)
        }
        @Sendable func inCut(_ p: SIMD3<Float>) -> Bool {
            hillside.height(original, p.x, p.y) - hillside.height(t.heights, p.x, p.y) > 0.2
        }
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
                // Clipped to the surface by its tangent planes at the point the site was put under
                // and at points around it along the surface itself (not across the ground in plan,
                // which on a steep face reached the floor in front and the brow behind, and cut the
                // lower face's cells away: it was bare terrain past the strip's ends until 12
                // November 2026). A neighbour's plane the site stands well outside of is across a
                // hollow and is left out (applying it cut the cell away; never applying it left
                // spikes standing on the brow).
                @Sendable func tangentPlane(_ q: SIMD2<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
                    let e: Float = 0.5
                    let dx = (surface(q.x + e, q.y) - surface(q.x - e, q.y)) / (2 * e)
                    let dy = (surface(q.x, q.y + e) - surface(q.x, q.y - e)) / (2 * e)
                    return (SIMD3(q.x, q.y, surface(q.x, q.y)), simd_normalize(SIMD3<Float>(-dx, -dy, 1)))
                }
                let foot = tangentPlane(frozenFootings[n])
                let side = simd_normalize(
                    abs(foot.1.z) < 0.9
                        ? simd_cross(foot.1, SIMD3(0, 0, 1)) : simd_cross(foot.1, SIMD3(1, 0, 0)))
                let slope = simd_cross(foot.1, side)
                let extent = min(polyhedron.maxDistance(from: site), cell)
                // A ridge cut's dense rock dips under the ground toward its edge, rather than ending
                // in slabs standing proud of it.
                let sink = flank.map { 0.9 * max(0, 1 - $0.edgeDepth(site.x, site.y) / 3) } ?? 0
                let recess =
                    QuarryRock.recess(QuarryRock.kind(at: site))
                    * (0.6 + 0.8 * QuarryNoise.hash(Int32(n), 3, 5).magnitude) + sink
                let faceWhole = faceOuter != nil && !inCut(site)
                for along: SIMD3<Float> in [.zero, side, -side, slope, -slope] {
                    let reach = foot.0 + along * (0.7 * extent)
                    let (point, normal) = along == .zero ? foot : tangentPlane(SIMD2(reach.x, reach.y))
                    if along != .zero, simd_dot(normal, site - point) > 0.6 { continue }
                    // A ridge cut's dense rock stands back by its bed's weathering alone, the same
                    // surface for every cell (`ridgeOuter`), as the cut's held rock does.
                    let standBack =
                        flank.map { QuarryRock.blendedRecess(at: point) + $0.sink(point.x, point.y) }
                        ?? (faceWhole ? QuarryRock.blendedRecess(at: point) + faceRecess + 0.35 : recess)
                    polyhedron.clip(
                        normal: normal, offset: simd_dot(normal, point) + 0.35 - standBack, kind: 1)
                }
                if faceWhole, abs(site.y - hillside.faceLine(site.x)) < 30 {
                    // Along the face, its foot ends just under the floor in front, rather than in points standing
                    // out of it.
                    let floor = hillside.floorHeight(site.x) - 0.3
                    polyhedron.clip(normal: SIMD3(0, 0, -1), offset: -floor, kind: 2)
                }
                let (volume, centroid) = polyhedron.volumeAndCentroid
                guard polyhedron.faces.count >= 4, polyhedron.faces.count < 40, volume > 0.02 else { return }
                var vertices: [Vertex] = []
                var indices: [UInt32] = []
                var faceRandom = QuarryRandom(seed: UInt64(n) &+ 4441)
                // The rock under a face's held skin, past the strip and where its new face is too
                // near the old one to stay hidden behind the skin, is weathered a grade
                // less (`underSkinGrade`), which the shader reads as "behind the skin".
                let underSkin = faceWhole || (faceOuter != nil && oldDepth(centroid) < 2.5)
                let grade: Float = underSkin ? Float(Self.underSkinGrade) / 31 : 1
                let tags = polyhedron.faces.map { _ in
                    QuarryRock.faceTag(weathering: grade, random: faceRandom.float())
                }
                if let ridgeOuter {
                    // Laid on one continuous weathered surface, so the rock round the cut reads as
                    // whole, like the cut's own held rock, rather than as a mosaic of cells with
                    // grass between them (until 13 November 2026, emmettl/bombcad-work#138).
                    let across = polyhedron.extent(along: ridgeOuter(centroid).normal)
                    Self.tessellate(
                        polyhedron, centre: centroid, origin: .zero, body: 0, level: level, warp: 0, seed: 0,
                        relief: 0.3, tags: tags, outer: ridgeOuter, inward: 0.4 * (across.1 - across.0),
                        vertices: &vertices, indices: &indices)
                } else if faceWhole, let faceOuter {
                    let across = polyhedron.extent(along: faceOuter(centroid).normal)
                    Self.tessellate(
                        polyhedron, centre: centroid, origin: .zero, body: 0, level: level, warp: 0, seed: 0,
                        relief: Self.blockRelief, tags: tags, outer: faceOuter,
                        inward: 0.4 * (across.1 - across.0),
                        vertices: &vertices, indices: &indices)
                } else {
                    Self.tessellate(
                        polyhedron, centre: centroid, origin: .zero, body: 0, level: level, warp: 0, seed: 0,
                        relief: 0.75, tags: tags, vertices: &vertices,
                        indices: &indices)
                }
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
        if let flank {
            let made = appendLedges(flank)
            report.append(
                "ledges: \(flank.ledges.count) in \(made) outcrops, \(ledgeIndices.count / 3) triangles")
        }
    }

    /// This face without its meshes (the blocks' and the dressing's), for keeping once they are
    /// on the GPU: the solver, the dust and the session read only the layout, the blocks and their
    /// spheres, and another renderer of it finds the meshes by `meshID`. Kept whole, the meshes
    /// were held twice over, on the CPU and the GPU: 0.63 GB of the window's footprint until 12
    /// November 2026.
    public func withoutMesh() -> QuarryFace {
        var face = self
        face.vertices = []
        face.indices = []
        face.dressingVertices = []
        face.dressingIndices = []
        face.ledgeVertices = []
        face.ledgeIndices = []
        face.skinVertices = []
        face.skinIndices = []
        return face
    }

    /// Packs a unit normal in 10:10:10 and the face kind in the top two bits.
    public static func pack(normal n: SIMD3<Float>, kind: UInt8) -> UInt32 {
        func s10(_ v: Float) -> UInt32 {
            UInt32(max(0, min(1023, (v * 0.5 + 0.5) * 1023 + 0.5)))
        }
        return s10(n.x) | (s10(n.y) << 10) | (s10(n.z) << 20) | (UInt32(kind) << 30)
    }
}
