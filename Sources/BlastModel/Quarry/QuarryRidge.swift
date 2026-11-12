import Foundation
import simd

// A cut through a ridge as a terrain scene: the rock above a level floor, between two steep walls
// across the crest, broken into the quarry face's blocks and heaved out by a stylised pattern of
// firings, so that the crest breaks and its rock is thrown up and slides down both flanks
// (emmettl/bombcad-work#131). Illustrative, for the look of it, as the quarry face is: the cut's
// shape and its firings are stylised, chosen by eye; it is no road-cut or excavation design, and it
// says nothing about real fragmentation, flyrock reach or safe distances.

/// Which scene a quarry site lays out.
public enum QuarryScene: String, CaseIterable, Sendable {
    /// A strip of a hillside's face, broken back to a new face behind it.
    case face = "Quarry face"
    /// A cut through a ridge: a notch across its crest, between two walls.
    case ridgeCut = "Ridge cut"
}

/// A ridge cut's shape in the strip's frame (x along the cut's line from its start, y across it,
/// z up as in the ground): a level floor `depth` below the highest ground on the line, `width`
/// wide, between walls rising at `wallSlope` to the old ground, and at the line's ends the same
/// walls where the ground there is still above the floor. Stylised: chosen for the look of a notch
/// in the skyline, not a design of one.
public struct QuarryRidge: Sendable, Equatable {
    /// The defaults, chosen by eye with the built-in ridge so that the broken rock is about the
    /// quarry face's in volume (m).
    public static let defaultWidth: Float = 28
    public static let defaultDepth: Float = 25
    /// The ranges the window offers (m).
    public static let widths: ClosedRange<Float> = 12...40
    public static let depths: ClosedRange<Float> = 8...30
    /// The walls' rise per metre across: about 70°.
    public static let wallSlope: Float = 2.75
    /// Coarse cells against a face's for the same `QuarryFace.Options.blocks` (a face's count
    /// includes its held skin, which a ridge cut has none of).
    public static let siteBoost: Float = 2.1
    /// A small cut is broken into fewer blocks rather than smaller ones: its coarse cells are
    /// capped so that the mean block is no smaller than this across (m), at about 2.7 pieces a
    /// cell. Blocks much smaller than this made the solver's grid finer and larger (28 M cells for
    /// a cut 16 m wide and 14 m deep) and its cost rose with it.
    public static let smallestEdge: Float = 0.62
    static let piecesPerCell: Float = 2.7

    /// The floor's height and the crest's, the highest old ground on the cut's line (m).
    public var floor: Float
    public var crest: Float
    /// Where on the line the crest is (m from the start).
    public var crestX: Float
    /// Half the floor's width (m), before its walls' small wander.
    public var halfWidth: Float
    public var wallSlope: Float
    /// The line's length (m).
    public var length: Float
    /// Along the line, where the cut is at least a metre deep (m from the start).
    public var cutStart: Float
    public var cutEnd: Float
    /// The rock between the old ground and the cut (m³).
    public var cutVolume: Float = 0

    /// The coarse cells to break the cut into, for `wanted` of them: no more than keeps the mean
    /// block `smallestEdge` across.
    public func coarseCells(_ wanted: Int) -> Int {
        let cap = cutVolume / (Self.smallestEdge * Self.smallestEdge * Self.smallestEdge * Self.piecesPerCell)
        return max(100, min(wanted, Int(cap)))
    }

    /// Half the floor's width at `x`: the walls wander a little, so they are not ruled lines.
    public func halfWidth(at x: Float) -> Float {
        halfWidth + 0.9 * sin(x / 13 + 0.7) + 0.5 * sin(x / 5.3 + 2.1)
    }

    /// The ground after the cut at (`x`, `y`), where `old` is the ground there before it.
    public func excavated(old h: Float, x: Float, y: Float) -> Float {
        let wall = max(0, abs(y) - halfWidth(at: x)) * wallSlope
        let ends = max(0, -x, x - length) * wallSlope
        return min(h, floor + wall + ends)
    }

    /// The box the broken rock lies in: the line's length, as wide as the walls reach at
    /// `topLevel`, from the floor up.
    public func box(topLevel: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let reach = halfWidth + 1.5 + max(0, topLevel - floor) / wallSlope + 2
        return (SIMD3(-1, -reach, floor - 1), SIMD3(length + 1, reach, topLevel + 1))
    }

    /// Where the render-only rock of the steep ground goes: past the domain along the line, and a
    /// long way along the ridge both ways, as far as the view reaches it.
    public func dressingArea(low: SIMD3<Float>, high: SIMD3<Float>) -> (SIMD2<Float>, SIMD2<Float>) {
        (SIMD2(low.x - 60, -170), SIMD2(high.x + 60, 170))
    }

    /// The layout of a ridge cut on `site`, for `QuarryFace`.
    struct Layout {
        var inward: SIMD2<Float>
        var terrain: Terrain
        var original: [Float]
        var centre: [Float]
        var floor: [Float]
        var top: [Float]
        var floorLevel: Float
        var topLevel: Float
        var low: SIMD3<Float>
        var high: SIMD3<Float>
        var ridge: QuarryRidge
        var cutVolume: Float
        /// The ground on the line falls away from the crest on both sides, by half the cut's depth
        /// at least: a ridge, not a slope or flat ground (where the cut would be a pit).
        var crossesRidge: Bool
    }

    static func layout(site: QuarrySite, origin: SIMD2<Float>, along: SIMD2<Float>) -> Layout {
        let length = site.length
        // Across the line, to its left: a ridge cut has no inside and outside, as a face has.
        let inward = SIMD2<Float>(-along.y, along.x)
        func old(_ x: Float, _ y: Float) -> Float {
            site.terrain.height(at: origin + along * x + inward * y)
        }
        var crest = -Float.infinity
        var crestX: Float = 0
        var x: Float = 0
        var line: [(x: Float, h: Float)] = []
        while x <= length {
            let h = old(x, 0)
            line.append((x, h))
            if h > crest {
                crest = h
                crestX = x
            }
            x += 0.5
        }
        let before = line.filter { $0.x <= crestX }.map(\.h).min() ?? crest
        let after = line.filter { $0.x >= crestX }.map(\.h).min() ?? crest
        let crossesRidge = crest - before >= site.depth / 2 && crest - after >= site.depth / 2
        var ridge = QuarryRidge(
            floor: crest - site.depth, crest: crest, crestX: crestX, halfWidth: site.width / 2,
            wallSlope: wallSlope, length: length, cutStart: 0, cutEnd: length)
        let originXY = SIMD2<Float>(-170, -150)
        let columns = Int(length) + 341
        let rows = 301
        var exc = [Float](repeating: 0, count: columns * rows)
        var oldGrid = exc
        var cutVolume: Float = 0
        for j in 0..<rows {
            let y = originXY.y + Float(j)
            for i in 0..<columns {
                let x = originXY.x + Float(i)
                let h0 = old(x, y)
                let h1 = ridge.excavated(old: h0, x: x, y: y)
                oldGrid[i + columns * j] = h0
                exc[i + columns * j] = h1
                cutVolume += h0 - h1
            }
        }
        let middle = Int(-originXY.y)
        let floorLine = (0..<columns).map { exc[$0 + columns * middle] }
        let topLine = (0..<columns).map { oldGrid[$0 + columns * middle] }
        let deep = (0..<columns).filter { topLine[$0] - floorLine[$0] > 1 }.map { originXY.x + Float($0) }
        ridge.cutVolume = cutVolume
        ridge.cutStart = max(0, deep.min() ?? 0)
        ridge.cutEnd = min(length, deep.max() ?? length)
        var lowest = Float.infinity
        var highest = -Float.infinity
        for j in 0..<rows where abs(originXY.y + Float(j)) < 60 {
            for i in 0..<columns {
                lowest = min(lowest, exc[i + columns * j])
                highest = max(highest, oldGrid[i + columns * j])
            }
        }
        var terrain = Terrain(origin: originXY, spacing: 1, columns: columns, rows: rows, heights: [])
        terrain.heights = exc
        return Layout(
            inward: inward, terrain: terrain, original: oldGrid,
            centre: [Float](repeating: 0, count: columns), floor: floorLine, top: topLine,
            // The solver's domain: down both flanks along the line, a way either side of the cut,
            // and as high as the rock is thrown. (A block past it is still in contact; the grid
            // keeps it in its edge cells.)
            floorLevel: lowest, topLevel: highest, low: SIMD3(-80, -80, lowest - 6),
            high: SIMD3(length + 80, 80, highest + 45), ridge: ridge, cutVolume: cutVolume,
            crossesRidge: crossesRidge)
    }
}

extension QuarrySite {
    /// The built-in ridge: a long rocky ridge over a plain, its crest about 37 m up, the flank on
    /// one side steeper than the other, with the cut's line across the crest from (-80, 0) to (80, 0).
    public static func builtInRidge() -> QuarrySite {
        let origin = SIMD2<Float>(-560, -640)
        let (columns, rows) = (1121, 1281)
        var heights = [Float](repeating: 0, count: columns * rows)
        heights.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: rows) { j in
                for i in 0..<columns {
                    let p = origin + SIMD2(Float(i), Float(j))
                    output[i + columns * j] = BuiltInRidge.height(p.x, p.y)
                }
            }
        }
        let terrain = Terrain(origin: origin, spacing: 1, columns: columns, rows: rows, heights: heights)
        return QuarrySite(
            terrain: terrain, start: SIMD2(-80, 0), end: SIMD2(80, 0), depth: QuarryRidge.defaultDepth,
            scene: .ridgeCut, width: QuarryRidge.defaultWidth)
    }

    /// The built-in ground of `scene`.
    public static func builtIn(_ scene: QuarryScene) -> QuarrySite {
        scene == .ridgeCut ? builtInRidge() : builtIn()
    }
}

/// The built-in ridge's shape (m). Procedural, chosen by eye.
enum BuiltInRidge {
    /// The crest's line: it wanders a little along the ridge.
    static func axis(_ y: Float) -> Float { 7 * sin(y / 71) + 3 * sin(y / 23 + 0.5) }

    static func height(_ x: Float, _ y: Float) -> Float {
        let a = x - axis(y)
        // The ridge dies down into the plain far along it, so the view never finds its end cut off.
        let t = max(0, min(1, (abs(y) - 330) / 150))
        let fade = 1 - t * t * (3 - 2 * t)
        let crest = (34 + 4 * sin(y / 57 + 1) + 2 * sin(y / 21)) * fade
        // One flank (x < 0) longer and gentler than the other.
        let w = 45 + 6 * tanh(-a / 12)
        let profile = exp(-pow(abs(a) / w, 1.7))
        let plain = 1.5 + 0.004 * x + 1.4 * QuarryNoise.fbm(SIMD3(x / 60, y / 60, 7.7), octaves: 3)
        let rough = 1.6 * QuarryNoise.fbm(SIMD3(x / 22, y / 22, 5.3), octaves: 5) * (0.4 + 0.6 * profile)
        return plain + crest * profile + rough
    }
}

extension QuarryFiringPattern {
    /// A ridge cut's firings, stylised for the eye: one row along the cut's line through the crest
    /// (fewer than 10 firings) or two staggered rows either side of its middle, evenly spaced over
    /// the deep part of the cut, each about halfway down from the old ground to the floor, fired in
    /// `order` along the line (left to right is from the line's start to its end; centre out is
    /// from the crest down both flanks). No charges, layouts or loadings of any kind: each firing
    /// only gives nearby blocks a velocity by `QuarryLaunch`'s law. Not a blast-design aid.
    public static func ridge(
        face hillside: QuarryFace, count: Int = 16, first: Float = 1.8, stagger: Float = 0.1,
        order: QuarryFiringOrder = .leftToRight
    ) -> [QuarryFiring] {
        guard let ridge = hillside.ridge, count > 0 else { return [] }
        let rows = count >= 10 ? 2 : 1
        var a = ridge.cutStart + 6
        var b = ridge.cutEnd - 6
        if b - a < 4 {
            let middle = (ridge.cutStart + ridge.cutEnd) / 2
            (a, b) = (middle - 2, middle + 2)
        }
        var points: [SIMD2<Float>] = []
        for row in 0..<rows {
            let n = rows == 1 ? count : (row == 0 ? (count + 1) / 2 : count / 2)
            // The second row stands between the first's firings.
            let shift: Float = rows == 2 && row == 1 ? 0.5 : 0
            let y: Float = rows == 1 ? 0 : (row == 0 ? -1 : 1) * ridge.halfWidth * 0.45
            for i in 0..<n {
                let share = (Float(i) + shift) / max(Float(n - 1) + 0.5 * Float(rows - 1), 1)
                points.append(SIMD2(a + (b - a) * min(1, share), y))
            }
        }
        let rank = ranks(points.map { $0.x - ridge.crestX }, order: order)
        return points.enumerated().map { n, p in
            let top = hillside.height(hillside.original, p.x, p.y)
            let floor = hillside.height(hillside.terrain.heights, p.x, p.y)
            return QuarryFiring(
                position: SIMD3(p.x, p.y, floor + (top - floor) * 0.5),
                time: first + stagger * Float(rank[n]))
        }
    }
}

extension QuarryLaunch {
    /// Share of a ridge cut's launch that is up: the crest heaves.
    public static let ridgeLift: Float = 0.8

    /// The ridge cut's launch: as the face's law (`apply`), but out along the line down the flank
    /// a block is on rather than out of a face, and more upward, so the crest heaves and breaks and
    /// its rock is thrown up and over and slides down both flanks. Blocks within a few metres of the
    /// cut's walls stay put (the distance wanders, as at a face's new face), so the walls are left
    /// rough. Illustrative, chosen by eye.
    func applyRidge(to blocks: inout [QuarryFace.Block], firings: [QuarryFiring], face hillside: QuarryFace)
        -> (
            fire: [Float], velocity: [SIMD3<Float>], spin: [SIMD3<Float>], swell: [SIMD4<Float>]
        )
    {
        guard let ridge = hillside.ridge else { return apply(to: &blocks, firings: firings, face: hillside) }
        var random = QuarryRandom(seed: 77)
        var fire = [Float](repeating: .greatestFiniteMagnitude, count: blocks.count)
        var velocity = [SIMD3<Float>](repeating: .zero, count: blocks.count)
        var spin = velocity
        var swell = [SIMD4<Float>](repeating: .zero, count: blocks.count)
        let around: [SIMD2<Float>] = (0..<8).map {
            SIMD2(cos(Float($0) * .pi / 4), sin(Float($0) * .pi / 4))
        }
        for (n, block) in blocks.enumerated() {
            let c = block.centre
            guard !firings.isEmpty, !block.skin else { continue }
            if hillside.height(hillside.original, c.x, c.y)
                - hillside.height(hillside.terrain.heights, c.x, c.y)
                < 0.3
            {
                continue
            }
            // Within `hold` of a wall (where the ground after the cut stands above the block's middle)
            // the block stays.
            let raggedness = QuarryNoise.fbm(c * SIMD3<Float>(0.05, 0.05, 0.03) + 19, octaves: 3)
            let hold = 2.6 - 9 * raggedness
            if hold > 0,
                around.contains(where: {
                    hillside.height(hillside.terrain.heights, c.x + $0.x * hold, c.y + $0.y * hold) > c.z
                        + 0.3
                })
            {
                continue
            }
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
            let speed = speed0 * pow(r0 / max(r, r0), exponent)
            let radial = simd_normalize(c - nearest.position + SIMD3<Float>(0, 0, 0.5))
            let outward = hillside.outward(at: c)
            var base = 0.55 * radial + 0.45 * outward
            if simd_length_squared(base) < 1e-4 { base = radial }
            var direction = simd_normalize(base)
            direction.z += Self.ridgeLift * (0.6 + 0.4 * random.float())
            direction = simd_normalize(direction + 0.18 * random.unit())
            fire[n] = nearest.time + r / front
            // The heave (stage 3a): the rock over the cut swells up as a mass before it breaks. A
            // column swells together (by its distance in plan to the nearest firing, over a wide
            // reach), less toward the cut's walls, so the crest rises as a dome; slowly, and
            // carried while it swells (the solver holds up `ridgeCarried` of a swelling block's
            // weight): uncarried, gravity took back more than the swell gave, and the crest's top
            // only sank before it broke.
            let plan = SIMD2(c.x - nearest.position.x, c.y - nearest.position.y)
            let reach = simd_length(plan) / ridgeSwellReach
            let wall = ridge.halfWidth(at: c.x) + max(0, c.z - ridge.floor) / ridge.wallSlope - abs(c.y)
            let shoulder = min(1, max(0, wall / ridgeShoulder))
            let amplitude = ridgeSwell * exp(-reach * reach) * shoulder * shoulder * (3 - 2 * shoulder) + 0.2
            let thisRise = ridgeRise + 0.3 * min(1, r / 25)
            // Mostly up, and a little out down the flank.
            let swellVelocity =
                simd_normalize(0.3 * outward + SIMD3<Float>(0, 0, 1)) * amplitude / (0.5 * thisRise)
            swell[n] = SIMD4(swellVelocity, thisRise)
            // It lets go moving as it swelled, and breaks: part of the law's launch on top, no more
            // than the law's fastest in all.
            var launch = swellVelocity + ridgeBreak * direction * max(0.25, speed * random.float(0.7, 1.2))
            let most = speed0 * 1.2
            if simd_length(launch) > most { launch *= most / simd_length(launch) }
            velocity[n] = launch
            spin[n] =
                random.unit()
                * min(9, simd_length(velocity[n]) * random.float(0.3, 1.5) / max(block.size, 0.3))
        }
        return (fire, velocity, spin, swell)
    }
}

extension QuarryFace {
    /// Out of the rock at `p`, horizontally: out of a face, or down the flank of a ridge along the
    /// cut's line (none on the crest itself, where the ground is level along it).
    public func outward(at p: SIMD3<Float>) -> SIMD3<Float> {
        guard ridge != nil else { return SIMD3(0, -1, 0) }
        let slope = (height(original, p.x + 2, p.y) - height(original, p.x - 2, p.y)) / 4
        return SIMD3(-max(-1, min(1, slope / 0.3)), 0, 0)
    }

    /// Whether a block at `p` shows on the old surface: near the top, or near the face (a face's)
    /// or flank (a ridge's) in front of it.
    public func exposed(_ p: SIMD3<Float>) -> Bool {
        if height(original, p.x, p.y) - p.z < 2.5 { return true }
        if ridge == nil { return height(original, p.x, p.y - 2.5) < p.z }
        return height(original, p.x - 2.5, p.y) < p.z || height(original, p.x + 2.5, p.y) < p.z
    }

    /// The dust field's box: its low corner and its size (m).
    public var dustBox: (low: SIMD3<Float>, extent: SIMD3<Float>) {
        if ridge != nil {
            // Both flanks and the ridge either side of the cut.
            return (
                SIMD3(-45, -100, floorLevel - 3),
                SIMD3(length + 90, 200, max(129, topLevel - floorLevel + 80))
            )
        }
        return (SIMD3(-45, -165, floorLevel - 3), SIMD3(length + 102, 237, 129))
    }
}

extension QuarryStripGuide {
    /// A ridge cut drawn on the ground: its line across the ridge (`face`), and the outline of its
    /// floor's width, out along the left side and back along the right as one closed loop
    /// (`back`), as points (x, y, height) in the ground's metres.
    public static func ridgeLines(
        terrain: Terrain, start: SIMD2<Float>, end: SIMD2<Float>, width: Float, step: Float = 3
    ) -> Lines {
        let length = simd_distance(start, end)
        guard length > 1e-3 else { return Lines(face: [], back: []) }
        let along = (end - start) / length
        let side = SIMD2<Float>(-along.y, along.x)
        let count = max(2, Int((length / step).rounded(.up)) + 1)
        let line = (0..<count).map { start + along * (length * Float($0) / Float(count - 1)) }
        func lifted(_ p: SIMD2<Float>) -> SIMD3<Float> { SIMD3(p, terrain.height(at: p)) }
        let left = line.map { lifted($0 + side * (width / 2)) }
        let right = line.map { lifted($0 - side * (width / 2)) }
        return Lines(
            face: line.map(lifted), back: left + right.reversed() + (left.first.map { [$0] } ?? []))
    }

    /// A first cut on `terrain`: across the highest ridge at least `margin` in from its edges, at
    /// right angles to the ridge's line there, long enough each way to reach ground `depth` and a
    /// few metres more below its crest. Nil when nothing there drops away on both sides within
    /// 200 m (a slope or a plateau, not a ridge).
    public static func suggestRidgeCut(
        terrain: Terrain, depth: Float = QuarryRidge.defaultDepth, margin: Float = 80
    )
        -> (start: SIMD2<Float>, end: SIMD2<Float>)?
    {
        let extent = SIMD2(Float(terrain.columns - 1), Float(terrain.rows - 1)) * terrain.spacing
        let inset = min(margin, extent.min() / 4)
        let low = terrain.origin + inset
        let high = terrain.origin + extent - inset
        guard all(high .> low) else { return nil }
        // The tops on a grid of about 100 x 100: local highs, highest first.
        let n = 100
        let cell = (high - low) / Float(n - 1)
        var grid = [Float](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n { grid[i + n * j] = terrain.height(at: low + cell * SIMD2(Float(i), Float(j))) }
        }
        var tops: [(Float, SIMD2<Float>)] = []
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let h = grid[i + n * j]
                var highest = true
                for dj in -1...1 {
                    for di in -1...1 where (di, dj) != (0, 0) && grid[i + di + n * (j + dj)] > h {
                        highest = false
                    }
                }
                if highest { tops.append((h, low + cell * SIMD2(Float(i), Float(j)))) }
            }
        }
        tops.sort { $0.0 > $1.0 }
        for (h, p) in tops.prefix(40) {
            // The ridge's line: the way the ground drops least over 40 m either side.
            var axis = SIMD2<Float>(1, 0)
            var least = Float.infinity
            for k in 0..<36 {
                let angle = Float(k) * .pi / 36
                let d = SIMD2(cos(angle), sin(angle))
                let drop = h - 0.5 * (terrain.height(at: p + d * 40) + terrain.height(at: p - d * 40))
                if drop < least {
                    least = drop
                    axis = d
                }
            }
            let across = SIMD2(-axis.y, axis.x)
            // Out each way until the ground is the cut's depth and more below the crest.
            func reach(_ d: SIMD2<Float>) -> Float? {
                var t: Float = 6
                while t <= 200 {
                    if terrain.height(at: p + d * t) < h - depth - 4 { return t + 12 }
                    t += 2
                }
                return nil
            }
            guard let a = reach(-across), let b = reach(across) else { continue }
            return (p - across * a, p + across * b)
        }
        return nil
    }
}
