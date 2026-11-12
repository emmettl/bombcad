import Testing
import simd

@testable import BlastModel

/// The quarry face's CPU parts: its layout on a terrain, its blocks, its stylised firing
/// patterns and its packed poses. Illustrative scene; these are consistency checks.
@Suite("Quarry face", .serialized)
struct QuarryFaceTests {
    static func small(_ site: QuarrySite = .builtIn(), seed: UInt64 = 2026) throws -> QuarryFace {
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.seed = seed
        options.meshDetail = 1
        var face = try QuarryFace(site: site, options: options)
        face.generate()
        return face
    }

    @Test("Blocks fill the cut between the old and new surfaces, and the generator repeats itself")
    func blocksFillTheCut() throws {
        let face = try Self.small()
        #expect(face.blocks.count > 1500)
        let broken = face.blocks.filter { !$0.skin }
        #expect(!broken.isEmpty && broken.count < face.blocks.count)
        for block in broken {
            let c = block.centre
            // Within a block's size of the cut, and two sideways: the faces are steep, and at this
            // count the coarse cells that bedding and joints cut are several metres across.
            let near = [-2 * block.size, -block.size, 0, block.size, 2 * block.size]
            let old = near.map { face.height(face.original, c.x, c.y + $0) }.max()!
            let new = near.map { face.height(face.terrain.heights, c.x, c.y + $0) }.min()!
            #expect(c.z > new - block.size && c.z < old + block.size, "\(c) between \(new) and \(old)")
            #expect(block.volume > 0 && block.sphereCount >= 1)
        }
        let again = try Self.small()
        #expect(again.blocks.count == face.blocks.count)
        #expect(again.blocks.map(\.centre) == face.blocks.map(\.centre))
        let other = try Self.small(seed: 7)
        #expect(other.blocks.map(\.centre) != face.blocks.map(\.centre))
    }

    @Test("A strip laid on any terrain finds its face; one on flat ground is refused")
    func layoutOnTerrain() throws {
        // The built-in hill turned a quarter round and moved: the same face, found again.
        let built = QuarrySite.builtIn().terrain
        let columns = built.rows
        let rows = built.columns
        var heights = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns { heights[i + columns * j] = built.height(column: j, row: columns - 1 - i) }
        }
        let origin = SIMD2<Float>(1000, 2000)
        let turned = Terrain(origin: origin, spacing: 1, columns: columns, rows: rows, heights: heights)
        // (x, y) of the built-in hill lies at origin + (row from the top, x + 420) here.
        func place(_ p: SIMD2<Float>) -> SIMD2<Float> {
            origin + SIMD2(Float(columns - 1) - (p.y + 420), p.x + 420)
        }
        let site = QuarrySite(terrain: turned, start: place(SIMD2(0, 0)), end: place(SIMD2(180, 0)))
        let face = try Self.small(site)
        #expect(face.blocks.filter { !$0.skin }.count > 1000)
        #expect(abs(face.faceLine(90)) < 12)
        #expect(simd_distance(face.world(SIMD2(180, 0)), place(SIMD2(180, 0))) < 1e-3)
        let flat = Terrain(
            origin: .zero, spacing: 2, columns: 300, rows: 300, heights: Array(repeating: 5, count: 90_000))
        #expect(throws: QuarryFace.Failure.noFace) {
            try QuarryFace(site: QuarrySite(terrain: flat, start: SIMD2(100, 300), end: SIMD2(400, 300)))
        }
        #expect(throws: QuarryFace.Failure.stripTooShort) {
            try QuarryFace(site: QuarrySite(terrain: flat, start: SIMD2(100, 300), end: SIMD2(110, 300)))
        }
    }

    @Test("Each firing order fires every point once, at the stagger, starting at the first time")
    func firingOrders() throws {
        let face = try Self.small()
        for order in QuarryFiringOrder.allCases {
            let row = QuarryFiringPattern.row(
                face: face, count: 12, first: 1.8, stagger: 0.07, order: order)
            #expect(row.count == 12)
            let times = row.map(\.time).sorted()
            for (k, t) in times.enumerated() { #expect(abs(t - (1.8 + 0.07 * Float(k))) < 1e-5) }
            #expect(zip(row, row.dropFirst()).allSatisfy { $0.position.x < $1.position.x })
        }
        let right = QuarryFiringPattern.row(face: face, count: 5, order: .rightToLeft)
        #expect(right.first!.time > right.last!.time)
        let centre = QuarryFiringPattern.row(face: face, count: 5, order: .centreOut)
        #expect(centre[2].time == centre.map(\.time).min())
    }

    @Test("The launch law is the stated one: bounded, and nothing held moves")
    func launchLaw() throws {
        let face = try Self.small()
        var blocks = face.blocks
        let launch = QuarryLaunch()
        let row = QuarryFiringPattern.row(face: face)
        let state = launch.apply(to: &blocks, firings: row, face: face)
        for (n, block) in face.blocks.enumerated() {
            let speed = simd_length(state.velocity[n])
            #expect(speed <= launch.speed0 * 1.2 + 1e-3)
            if block.skin { #expect(speed == 0 && state.fire[n] == .greatestFiniteMagnitude) }
        }
    }

    @Test("Packed poses come back within millimetres and a tenth of a degree, interpolated between")
    func poseCacheRoundTrip() {
        let bodies = 200
        var random = QuarryRandom(seed: 3)
        let low = SIMD3<Float>(-90, -190, -6)
        let high = SIMD3<Float>(290, 110, 110)
        func pose() -> [SIMD4<Float>] {
            (0..<bodies).flatMap { _ -> [SIMD4<Float>] in
                let p = SIMD3(random.float(-80, 280), random.float(-180, 100), random.float(0, 100))
                let q = simd_normalize(SIMD4(random.unit(), random.float(-1, 1)))
                return [SIMD4(p, 1), q]
            }
        }
        let frames = [pose(), pose(), pose()]
        var still = [Bool](repeating: false, count: bodies)
        still[7] = true
        let cache = QuarryPoseCache(rest: frames[0], still: still, frames: 3, low: low, high: high, stride: 2)
        for (f, frame) in frames.enumerated() {
            frame.withUnsafeBufferPointer { cache.store(frame: f, pose: $0.baseAddress!) }
        }
        var out = [SIMD4<Float>](repeating: .zero, count: 2 * bodies)
        for f in [0, 2] {
            out.withUnsafeMutableBufferPointer { cache.decode(frame: f, into: $0.baseAddress!) }
            for n in 0..<bodies where n != 7 {
                let a = frames[f][2 * n]
                #expect(
                    simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(out[2 * n].x, out[2 * n].y, out[2 * n].z))
                        < 0.006)
                let q = frames[f][2 * n + 1]
                #expect(abs(simd_dot(q, out[2 * n + 1])) > 0.9999)
            }
        }
        // The middle frame is between the two stored ones.
        out.withUnsafeMutableBufferPointer { cache.decode(frame: 1, into: $0.baseAddress!) }
        let a = frames[0][0]
        let b = frames[2][0]
        let mid = (SIMD3(a.x, a.y, a.z) + SIMD3(b.x, b.y, b.z)) / 2
        #expect(simd_distance(mid, SIMD3(out[0].x, out[0].y, out[0].z)) < 0.01)
        // The still block stays at rest; it is not stored.
        #expect(out[14] == SIMD4(frames[0][14].x, frames[0][14].y, frames[0][14].z, 1))
        #expect(cache.bytes < 3 * bodies * 32)
    }

    @Test("A pose cache can be decoded while it fills: only frames already stored are shown")
    func poseCacheFillsWhileRead() async {
        let bodies = 3000
        let frames = 61
        let low = SIMD3<Float>(-90, -190, -6)
        let high = SIMD3<Float>(290, 110, 110)
        // Block n sits at x = frame; it lets go at frame 10.
        func pose(_ f: Int) -> [SIMD4<Float>] {
            (0..<bodies).flatMap { n -> [SIMD4<Float>] in
                [SIMD4(Float(f), Float(n % 100), 5, f >= 10 ? 1 : 0), SIMD4(0, 0, 0, 1)]
            }
        }
        let cache = QuarryPoseCache(
            rest: pose(0), still: [Bool](repeating: false, count: bodies), frames: frames, low: low,
            high: high, stride: 2)
        #expect(cache.available == 0)
        let writer = Task.detached {
            for f in 0..<frames {
                pose(f).withUnsafeBufferPointer { cache.store(frame: f, pose: $0.baseAddress!) }
            }
        }
        var out = [SIMD4<Float>](repeating: .zero, count: 2 * bodies)
        var shown = 0
        while !cache.isComplete || shown < frames - 1 {
            let available = cache.available
            // Never more than the frames stored; a frame between keyframes waits for the next.
            #expect(available <= cache.filled)
            #expect(available == frames || available % 2 == 1 || available == 0)
            guard available > 0 else { continue }
            shown = available - 1
            out.withUnsafeMutableBufferPointer { cache.decode(frame: shown, into: $0.baseAddress!) }
            #expect(abs(out[0].x - Float(shown)) < 0.01)
            #expect(out[0].w == (shown >= 10 ? 1 : 0))
        }
        await writer.value
        #expect(cache.available == frames)
        #expect(cache.release(0) == 10)
    }

    @Test("Beds take each kind of rock in about its share, and weathering and face tags stay in their bits")
    func bedsAndWeathering() throws {
        var counts = [Int](repeating: 0, count: QuarryRock.Kind.allCases.count)
        for k in -2000..<2000 { counts[QuarryRock.kind(bed: k).rawValue] += 1 }
        let shares = counts.map { Float($0) / 4000 }
        for (share, expected) in zip(shares, [Float(0.42), 0.24, 0.22, 0.12]) {
            #expect(abs(share - expected) < 0.04, "\(shares)")
        }
        #expect(QuarryRock.weathering(depth: 0) == 1)
        #expect(QuarryRock.weathering(depth: QuarryRock.weatheredDepth) == 0)
        #expect(QuarryRock.weathering(depth: 2) > QuarryRock.weathering(depth: 4))
        let tag = QuarryRock.faceTag(weathering: 1, random: 1)
        #expect(tag & QuarryRock.bodyMask == 0)
        #expect((tag >> QuarryRock.bodyBits) & 31 == 31)
        // Every vertex's block index survives the tag above it, and the face nearest the old
        // surface is the most weathered.
        let face = try Self.small()
        for v in face.vertices { #expect(Int(v.body & QuarryRock.bodyMask) < face.blocks.count) }
        let grades = face.vertices.map { Int(($0.body >> QuarryRock.bodyBits) & 31) }
        #expect(grades.contains(0) && grades.contains(31))
    }

    @Test("Zingg's shapes are told apart: a cube, a slab, a rod and a blade")
    func shapes() {
        func box(_ x: Float, _ y: Float, _ z: Float) -> QuarryPolyhedron {
            .box(low: .zero, high: SIMD3(x, y, z))
        }
        #expect(QuarryRock.shape(box(1, 1, 1)) == .equant)
        #expect(QuarryRock.shape(box(2, 2, 0.4)) == .disc)
        #expect(QuarryRock.shape(box(3, 0.8, 0.8)) == .rod)
        #expect(QuarryRock.shape(box(3, 1.2, 0.3)) == .blade)
    }

    @Test("Shale beds split into thinner pieces than limestone ones, and chipped corners stay closed")
    func bedsBreakTheirOwnWay() {
        // A tall column through many beds, cut by the fracture with no Voronoi cell around it.
        let column = QuarryPolyhedron.box(low: SIMD3(0, 0, -20), high: SIMD3(3, 3, 20))
        let pieces = QuarryFracture.fracture(column, intensity: 1, minimumVolume: 0.01)
        var thickness: [QuarryRock.Kind: [Float]] = [:]
        for piece in pieces {
            let (low, high) = piece.extent(along: QuarryFace.beddingNormal)
            thickness[QuarryRock.kind(at: piece.volumeAndCentroid.centroid), default: []].append(high - low)
        }
        func mean(_ v: [Float]?) -> Float { (v ?? []).reduce(0, +) / Float(max(v?.count ?? 0, 1)) }
        #expect(mean(thickness[.shale]) < mean(thickness[.limestone]), "\(thickness.mapValues { $0.count })")
        let volume = pieces.reduce(Float(0)) { $0 + $1.volumeAndCentroid.volume }
        #expect(abs(volume - 360) < 1, "the pieces fill the column")
        var piece = QuarryPolyhedron.box(low: .zero, high: SIMD3(1, 1, 1))
        var random = QuarryRandom(seed: 3)
        QuarryFracture.chipCorners(&piece, count: 3, size: 1, random: &random)
        let chipped = piece.volumeAndCentroid.volume
        #expect(chipped < 1 && chipped > 0.88)
    }

    @Test("Neighbouring cells meet in one face in each bed's metric, so they never overlap")
    func bedMetricsShareFaces() {
        // The plane two sites see between them is the same from either side.
        let a = SIMD3<Float>(1, 2, 3)
        let b = SIMD3<Float>(2.1, 1.4, 3.9)
        for kind in QuarryRock.Kind.allCases {
            let stretch = QuarryRock.stretch(kind)
            let n = QuarryFace.beddedNormal(b - a, stretch: stretch)
            let m = QuarryFace.beddedNormal(a - b, stretch: stretch)
            #expect(simd_distance(n, -m) < 1e-5)
        }
        #expect(QuarryRock.stretch(.limestone) < QuarryRock.stretch(.shale))
    }

    @Test("The chips' shapes are closed convex stones of 4 to 12 triangles, not all alike")
    func chipShapes() {
        let all = QuarryChipShapes.make()
        #expect(all.count == QuarryChipShapes.count * QuarryChipShapes.vertices)
        var flatness: [Float] = []
        for shape in 0..<QuarryChipShapes.count {
            let v = (0..<QuarryChipShapes.vertices).map {
                let p = all[shape * QuarryChipShapes.vertices + $0]
                return SIMD3(p.x, p.y, p.z)
            }
            var area = SIMD3<Float>.zero
            var volume: Float = 0
            var triangles = 0
            for t in 0..<(v.count / 3) {
                let (a, b, c) = (v[3 * t], v[3 * t + 1], v[3 * t + 2])
                let cross = simd_cross(b - a, c - a)
                guard simd_length(cross) > 1e-7 else { continue }
                triangles += 1
                area += cross
                volume += simd_dot(a, simd_cross(b, c)) / 6
            }
            #expect(triangles >= 4 && triangles <= 12)
            #expect(simd_length(area) < 1e-4, "closed")
            #expect(volume > 0.01, "outward and solid")
            let extent = v.reduce(SIMD3<Float>.zero) { simd_max($0, simd_abs($1)) }
            flatness.append(extent.min() / extent.max())
        }
        #expect((flatness.min() ?? 1) < 0.35 && (flatness.max() ?? 0) > 0.55, "\(flatness)")
    }

    @Test("A face kept without its meshes keeps the layout, the blocks and their spheres")
    func withoutMesh() throws {
        let face = try Self.small()
        let kept = face.withoutMesh()
        #expect(kept.vertices.isEmpty && kept.indices.isEmpty && kept.dressingVertices.isEmpty)
        #expect(kept.meshID == face.meshID && face.meshID != 0)
        #expect(kept.chipAnchors.count == face.chipAnchors.count)
        #expect(kept.blocks.map(\.centre) == face.blocks.map(\.centre))
        #expect(kept.spheres.count == face.spheres.count && kept.terrain.heights == face.terrain.heights)
    }

    @Test("The dressing covers the steep face past both ends of the strip, its foot as well")
    func dressingCoversTheEnds() throws {
        var face = try Self.small()
        face.buildDressing(level: 1)
        let points = face.dressingVertices.map { SIMD3($0.x, $0.y, $0.z) }
        // Cells on a 2 m grid, for the nearest dressing to a point on the face.
        var grid: [SIMD3<Int32>: [Int32]] = [:]
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>(p / 2, rounding: .down) }
        for (n, p) in points.enumerated() { grid[key(p), default: []].append(Int32(n)) }
        func nearest(_ p: SIMD3<Float>) -> Float {
            var best = Float.infinity
            let k = key(p)
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 {
                        for n in grid[k &+ SIMD3(dx, dy, dz)] ?? [] {
                            best = min(best, simd_distance(points[Int(n)], p))
                        }
                    }
                }
            }
            return best
        }
        var far: [String] = []
        var checked = 0
        let xs =
            Array(stride(from: Float(-60), through: -15, by: 5))
            + Array(stride(from: face.length + 15, through: face.length + 60, by: 5))
        for x in xs {
            let line = face.faceLine(x)
            let floor = face.oldHeight(x, line - 12)
            let top = face.oldHeight(x, line + 12)
            guard top - floor > 10 else { continue }
            // From the foot to near the brow: the point on the old surface at each height.
            for share: Float in [0.15, 0.3, 0.5, 0.7] {
                let z = floor + share * (top - floor)
                var y = line - 12
                while y < line + 12, face.oldHeight(x, y) < z { y += 0.1 }
                let p = SIMD3(x, y, z)
                checked += 1
                let d = nearest(p)
                if d > 1.5 { far.append(String(format: "(%.0f, %.1f, %.1f) %.1f m", x, y, z, d)) }
            }
        }
        #expect(checked > 40)
        #expect(far.count <= checked / 20, "bare face at \(far)")
    }
}
