import Foundation
import simd

/// A district's envelope loads in seconds, without running the air (roadmap, Horizons 2): each
/// component's peak load and impulse from its geometry alone (how far it is from the charge, how
/// squarely it faces it, and how many buildings stand in the way), Kingery–Bulmash's reflected
/// and incident values corrected by a few terms fitted to BombCAD's own district runs
/// (docs/surrogate-first-look.md). The loads go into the same SDOF damage as a run's histories
/// (`EnvelopeDamageAssessment`), as a triangular pulse of that peak and impulse.
///
/// It is an estimate, never a run: the blast's channelling down streets, its reflections off the
/// buildings behind and its diffraction round corners are in it only as far as the fitted terms
/// carry them on average.
public enum FacadeLoadSurrogate {
    /// What a component's load is predicted from.
    public struct Features: Sendable, Equatable {
        /// From the charge to the middle of the component's outer face, m.
        public var distanceM: Double
        /// The outer face's normal against the direction to the charge: 1 facing it squarely, 0
        /// side-on, −1 facing away.
        public var cosIncidence: Double
        /// Other buildings the line from the charge passes through on its way, over the ground
        /// (`Raster.sight`).
        public var buildingsCrossed: Int
        /// How far that line runs inside other buildings, m.
        public var blockedM: Double
        /// How high the ground between rises above the straight line from the ground under the
        /// charge to the ground under the component, m: a hill in the way.
        public var ridgeM: Double
        /// The ground under the component above the ground under the charge, m.
        public var groundRiseM: Double
        /// The middle of the component above the ground beneath it, m.
        public var heightM: Double
        /// How far behind the last building in the way the component stands, m (0 with none).
        public var shadowM: Double
        /// The open air in front of it: how far straight out from its face before another
        /// building or the ground, m, up to `Raster.frontReachM`.
        public var frontM: Double
        /// The knife edge in the way (emmettl/bombcad-work#4): of the cells along the line that
        /// hold other buildings or blocks, the one whose top stands highest above the line for its
        /// distances (the most over √(1/a + 1/b), a and b its distances from the charge and from
        /// the component): how far that top stands above the line, m, negative where the line
        /// clears it; −∞ with nothing under the line at all.
        public var edgeM: Double = -.infinity
        /// That edge's distances along the line from the charge and to the component, m.
        public var edgeFromChargeM: Double = 0
        public var edgeToTargetM: Double = 0
        /// That edge's top above the ground under it, m.
        public var edgeTopM: Double = 0
        /// How far that edge's obstruction reaches to the nearer side of the line, square to it in
        /// plan, at the line's height (`Raster.edgeSideReachM` at most), m; 0 where the line clears it.
        public var edgeSideM: Double = 0
        /// That edge's obstruction's width across the line, square to it in plan at the line's
        /// height (its reach to both sides, each `Raster.edgeSideReachM` at most), m; 0 where the
        /// line clears it. Measured, not a term (emmettl/bombcad-work#56: a narrow obstacle, such
        /// as Beirut's grain silos, shields far less than a city block close in).
        public var edgeWidthM: Double = 0
        /// The top of the last building in the way (the one `shadowM` is measured from) above the
        /// ground under it, m; 0 with none.
        public var lastTopM: Double = 0
        /// A street the line runs down: the line's last stretch before the component with walls
        /// on both sides of it within `Raster.canyonReachM` (`Raster.canyon`), its length, m, and
        /// the lower side's mean height over it, m; 0 with none.
        public var canyonM: Double = 0
        public var canyonHeightM: Double = 0
        /// How open the charge's surroundings are: the median, over `Raster.openRays` plan
        /// directions, of how far the air runs from the charge before another building or the
        /// ground (`Raster.openReach`), m, up to `Raster.openReachM`. The same for every component
        /// of one charge, so the estimates measure it once per charge and set it here; NaN where it
        /// was not measured. Only `Coefficients.CloseIn.shielding` reads it
        /// (emmettl/bombcad-work#56: behind buildings close in, a charge in a street loads the
        /// façades far less than the branch's open-façade ratio, a charge in the open about as much).
        public var chargeOpenM: Double = .nan
        /// The learned field model's peak over the surrogate's for this component at the estimate's
        /// yield (emmettl/bombcad-work#67, `LearnedField.PeakMap.adjusted`): `predict` multiplies
        /// its peak by it. 1, which changes nothing to the bit, unless the option is on and this is
        /// a ground-floor façade strip the model reads; at a yield drawn away from the estimate's
        /// the same ratio is kept.
        public var learnedPeakFactor: Double = 1
        /// Where that peak is the model's and its own scatter is asked for
        /// (`LearnedField.Estimator.scatter`, emmettl/bombcad-work#69): the log-SD of its peak by
        /// scaled distance, which the glass's and the walls' chances draw for this strip's peak
        /// in place of the surrogate's. nil, which changes nothing, otherwise.
        public var learnedPeakScatter: [LearnedField.Scatter.Band]? = nil
    }

    /// The buildings' blocks on a plan grid, for following a straight line from the charge
    /// through them.
    public struct Raster: Sendable {
        public let origin: SIMD2<Float>
        public let cell: Float
        public let columns: Int
        public let rows: Int
        /// Each cell's blocks: a range of `entries`, cells x fastest.
        let starts: [Int32]
        /// A block over a cell: its bottom and top and its owner (index in the objects).
        let entries: [(low: Float, high: Float, owner: Int32)]
        /// Each cell's highest block top, m (−∞ with none), whatever its owner: the walls a
        /// street runs between.
        let tops: [Float]
        let terrain: Terrain?

        /// The blocks of `objects`' envelopes on cells `cell` m across, each over the cells whose
        /// centres it covers, as the air's grid would hold it; and the scene's fixed `blocks`
        /// (barrier walls and the like), block n owned by −2 − n (−1 is no building), each over
        /// every cell it overlaps where it is thinner than a cell, so that a thin wall is not lost
        /// between cell centres.
        public init(objects: [SceneObject], blocks: [Box] = [], terrain: Terrain?, cell: Float) {
            var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for block in objects.flatMap({ $0.envelope?.blocks ?? [] }) + blocks {
                low = simd_min(low, SIMD2(block.min.x, block.min.y))
                high = simd_max(high, SIMD2(block.max.x, block.max.y))
            }
            if low.x > high.x {
                low = .zero
                high = SIMD2(repeating: cell)
            }
            // On the air's cells: whole cells from the scene's origin.
            origin = (low / cell).rounded(.down) * cell - cell
            self.cell = cell
            columns = Int(((high.x - origin.x) / cell).rounded(.up)) + 2
            rows = Int(((high.y - origin.y) / cell).rounded(.up)) + 2
            self.terrain = terrain
            var lists = [[(low: Float, high: Float, owner: Int32)]](repeating: [], count: columns * rows)
            for (owner, object) in objects.enumerated() {
                for block in object.envelope?.blocks ?? [] {
                    let i0 = max(0, Int(((block.min.x - origin.x) / cell - 0.5).rounded(.up)))
                    let i1 = min(columns - 1, Int(((block.max.x - origin.x) / cell - 0.5).rounded(.up)) - 1)
                    let j0 = max(0, Int(((block.min.y - origin.y) / cell - 0.5).rounded(.up)))
                    let j1 = min(rows - 1, Int(((block.max.y - origin.y) / cell - 0.5).rounded(.up)) - 1)
                    guard i0 <= i1, j0 <= j1 else { continue }
                    for j in j0...j1 {
                        for i in i0...i1 {
                            lists[i + columns * j].append((block.min.z, block.max.z, Int32(owner)))
                        }
                    }
                }
            }
            for (n, block) in blocks.enumerated() {
                // By centres along a side at least a cell long; by overlap across a thinner one.
                func span(_ lo: Float, _ hi: Float, _ o: Float, _ count: Int) -> ClosedRange<Int>? {
                    let first: Int
                    let last: Int
                    if hi - lo >= cell {
                        first = Int(((lo - o) / cell - 0.5).rounded(.up))
                        last = Int(((hi - o) / cell - 0.5).rounded(.up)) - 1
                    } else {
                        first = Int(((lo - o) / cell).rounded(.down))
                        last = Int(((hi - o) / cell).rounded(.up)) - 1
                    }
                    let a = max(0, first)
                    let b = min(count - 1, last)
                    return a <= b ? a...b : nil
                }
                guard let iRange = span(block.min.x, block.max.x, origin.x, columns),
                    let jRange = span(block.min.y, block.max.y, origin.y, rows)
                else { continue }
                for j in jRange {
                    for i in iRange {
                        lists[i + columns * j].append((block.min.z, block.max.z, Int32(-2 - n)))
                    }
                }
            }
            var starts = [Int32](repeating: 0, count: columns * rows + 1)
            var entries: [(low: Float, high: Float, owner: Int32)] = []
            entries.reserveCapacity(lists.reduce(0) { $0 + $1.count })
            for n in lists.indices {
                starts[n] = Int32(entries.count)
                entries += lists[n]
            }
            starts[lists.count] = Int32(entries.count)
            self.starts = starts
            self.entries = entries
            tops = lists.map { list in list.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.high) } }
        }

        func cellIndex(_ p: SIMD2<Float>) -> SIMD2<Int>? {
            // Each lane converted on its own: SIMD2<Int>(_:) of a float vector takes the generic,
            // slow conversion, a fifth of a drag frame once.
            let f = ((p - origin) / cell).rounded(.down)
            let c = SIMD2(Int(f.x), Int(f.y))
            guard c.x >= 0, c.y >= 0, c.x < columns, c.y < rows else { return nil }
            return c
        }

        /// Whether `p` lies inside a block of an owner other than `excluding`, or below the ground.
        public func isSolid(_ p: SIMD3<Float>, excluding: Int? = nil) -> Bool {
            if let terrain, p.z < terrain.height(at: p) { return true }
            guard let c = cellIndex(SIMD2(p.x, p.y)) else { return false }
            let n = c.x + columns * c.y
            for e in Int(starts[n])..<Int(starts[n + 1]) {
                let entry = entries[e]
                if Int(entry.owner) != excluding, p.z >= entry.low, p.z < entry.high { return true }
            }
            return false
        }

        /// Along the line from `a` to `b` over the ground, at a height above it going evenly from
        /// `a`'s to `b`'s (a surface burst's wave follows the ground): the other owners' buildings
        /// it passes through (not `excluding`'s), how far inside them, m, how far `b` stands
        /// behind the last of them, m, and how high the ground between rises above the straight
        /// line from the ground under `a` to that under `b`, m; and the knife edge in the way
        /// (`Features.edgeM`).
        public func sight(from a: SIMD3<Float>, to b: SIMD3<Float>, excluding: Int) -> Sight {
            let groundA = terrain?.height(at: a) ?? 0
            let groundB = terrain?.height(at: b) ?? 0
            let aboveA = a.z - groundA
            let aboveB = b.z - groundB
            let length = Double(simd_distance(a, b))
            let plan = SIMD2(b.x - a.x, b.y - a.y)
            // Steps a third of a cell long: enough to see a wall a cell thick.
            let steps = max(1, Int((simd_length(plan) / (cell / 3)).rounded(.up)))
            let step = length / Double(steps)
            var sight = Sight()
            var last: Int32 = -1
            var lastBlocked = -1
            var ridge: Float = 0
            var edgeScore = -Double.infinity
            var edgeAt: SIMD3<Float>?
            for s in 0..<steps {
                let t = (Float(s) + 0.5) / Float(steps)
                var p = a + t * (b - a)
                let ground = terrain?.height(at: p) ?? 0
                ridge = max(ridge, ground - (groundA + t * (groundB - groundA)))
                p.z = ground + aboveA + t * (aboveB - aboveA)
                guard let c = cellIndex(SIMD2(p.x, p.y)) else { continue }
                let n = c.x + columns * c.y
                var inside: Int32 = -1
                var top = -Float.greatestFiniteMagnitude
                for e in Int(starts[n])..<Int(starts[n + 1]) {
                    let entry = entries[e]
                    guard Int(entry.owner) != excluding else { continue }
                    top = max(top, entry.high)
                    if inside == -1, p.z >= entry.low, p.z < entry.high { inside = entry.owner }
                }
                if top > -Float.greatestFiniteMagnitude {
                    // How far this column's top stands above the line, for its distances.
                    let from = max(Double(t) * length, 1)
                    let to = max(Double(1 - t) * length, 1)
                    let over = Double(top - p.z)
                    let score = over * (1 / from + 1 / to).squareRoot()
                    if score > edgeScore {
                        edgeScore = score
                        sight.edgeM = over
                        sight.edgeFromChargeM = from
                        sight.edgeToTargetM = to
                        sight.edgeTopM = Double(top - ground)
                        edgeAt = p
                    }
                }
                if inside != -1 {
                    sight.blockedM += step
                    lastBlocked = s
                    sight.lastTopM = Double(top - ground)
                    if inside != last { sight.crossed += 1 }
                }
                last = inside
            }
            sight.shadowM = lastBlocked < 0 ? 0 : Double(steps - 1 - lastBlocked) * step
            sight.ridgeM = Double(ridge)
            // How far the edge's obstruction reaches to the nearer side of the line, square to it in
            // plan, at the line's height there: round its end the blast need not go over the top.
            if let at = edgeAt, sight.edgeM > 0, simd_length(plan) > 0 {
                let side = SIMD2(-plan.y, plan.x) / simd_length(plan)
                func reach(_ direction: SIMD2<Float>) -> Float {
                    var d: Float = 0
                    while d < Self.edgeSideReachM {
                        let q = SIMD2(at.x, at.y) + (d + 0.5 * cell) * direction
                        guard let c = cellIndex(q) else { return d }
                        let n = c.x + columns * c.y
                        var higher = false
                        for e in Int(starts[n])..<Int(starts[n + 1]) where Int(entries[e].owner) != excluding
                        {
                            if entries[e].high > at.z { higher = true }
                        }
                        if !higher { return d }
                        d += cell
                    }
                    return Self.edgeSideReachM
                }
                let (left, right) = (reach(side), reach(-side))
                sight.edgeSideM = Double(min(left, right))
                sight.edgeWidthM = Double(left + right)
            }
            return sight
        }

        /// The furthest `sight` follows the edge's obstruction to the side, m.
        public static let edgeSideReachM: Float = 200

        /// How open `charge`'s surroundings are (`Features.chargeOpenM`): along each of
        /// `openRays` plan directions, evenly spread, how far a line from the charge runs over the
        /// ground (at the charge's height above it, at least `openLineM`) before it enters a
        /// building, a block or the ground, in steps of half a cell, up to `openReachM`; the
        /// median of those reaches, m. A line leaving the raster is open to the end.
        public func openReach(around charge: SIMD3<Float>) -> Double {
            let ground = terrain?.height(at: charge) ?? 0
            let above = max(charge.z - ground, Self.openLineM)
            let step = cell / 2
            var reaches: [Float] = []
            reaches.reserveCapacity(Self.openRays)
            for k in 0..<Self.openRays {
                let angle = 2 * Float.pi * Float(k) / Float(Self.openRays)
                let direction = SIMD2(cos(angle), sin(angle))
                var d = step
                while d < Self.openReachM {
                    let q = SIMD2(charge.x, charge.y) + d * direction
                    guard cellIndex(q) != nil else {
                        d = Self.openReachM
                        break
                    }
                    let z = (terrain?.height(at: SIMD3(q.x, q.y, 0)) ?? 0) + above
                    if isSolid(SIMD3(q.x, q.y, z)) { break }
                    d += step
                }
                reaches.append(min(d, Self.openReachM))
            }
            reaches.sort()
            let n = reaches.count
            return Double(n % 2 == 1 ? reaches[n / 2] : 0.5 * (reaches[n / 2 - 1] + reaches[n / 2]))
        }

        /// `openReach`'s directions, its furthest reach, m, and the least height of its lines over
        /// the ground, m.
        public static let openRays = 72
        public static let openReachM: Float = 400
        public static let openLineM: Float = 1

        /// What `sight` finds along a line.
        public struct Sight: Sendable, Equatable {
            public var crossed = 0
            public var blockedM = 0.0
            public var shadowM = 0.0
            public var ridgeM = 0.0
            /// `Features.edgeM` and its distances and height.
            public var edgeM = -Double.infinity
            public var edgeFromChargeM = 0.0
            public var edgeToTargetM = 0.0
            public var edgeTopM = 0.0
            /// `Features.edgeSideM` and `Features.edgeWidthM`.
            public var edgeSideM = 0.0
            public var edgeWidthM = 0.0
            /// The last building in the way's top above its ground, m.
            public var lastTopM = 0.0
        }

        /// A street the line from `a` to `b` runs down: walking back from `b` toward `a` over the
        /// ground (at a height going evenly from `b`'s above it to `a`'s, as `sight`), while the
        /// line is in the open, the stretch over which some block at least `canyonWallM` tall stands
        /// within `canyonReachM` to each side of it, square to it in plan. Its length, m, and the
        /// lower side's height above its ground, averaged over it, m.
        public func canyon(from a: SIMD3<Float>, to b: SIMD3<Float>) -> (lengthM: Double, heightM: Double) {
            let plan = SIMD2(b.x - a.x, b.y - a.y)
            let planLength = simd_length(plan)
            guard planLength > 0 else { return (0, 0) }
            let along = plan / planLength
            let side = SIMD2(-along.y, along.x)
            let groundA = terrain?.height(at: a) ?? 0
            let groundB = terrain?.height(at: b) ?? 0
            let aboveA = a.z - groundA
            let aboveB = b.z - groundB
            let step = max(cell, 1)
            let reach = Self.canyonReachM
            // The nearest wall to one side of `p`, its height above its ground, or nil.
            func wall(_ p: SIMD2<Float>, _ direction: SIMD2<Float>) -> Float? {
                var d = 0.5 * cell
                while d <= reach {
                    let q = p + d * direction
                    if let c = cellIndex(q) {
                        let height = tops[c.x + columns * c.y] - (terrain?.height(at: q) ?? 0)
                        if height >= Self.canyonWallM { return height }
                    }
                    d += cell
                }
                return nil
            }
            var length: Float = 0
            var heights = 0.0
            var count = 0
            while length < min(planLength, Self.canyonLongestM) {
                let t = 1 - length / planLength
                let at = SIMD2(a.x, a.y) + t * plan
                let ground = terrain?.height(at: at) ?? 0
                if isSolid(SIMD3(at.x, at.y, ground + aboveA + t * (aboveB - aboveA))) { break }
                guard let left = wall(at, side), let right = wall(at, -side) else { break }
                heights += Double(min(left, right))
                count += 1
                length += step
            }
            return count == 0 ? (0, 0) : (Double(length), heights / Double(count))
        }

        /// How far to each side `canyon` looks for a street's walls, m: streets up to about twice
        /// as wide (the fine canyon runs' were 10 and 20 m).
        public static let canyonReachM: Float = 25
        /// The least height a street's wall is counted at, m: not a kerb or a garden wall.
        public static let canyonWallM: Float = 2
        /// The longest stretch `canyon` follows, m.
        public static let canyonLongestM: Float = 600

        /// How far the open air reaches in front of a face: from `p` along `direction` (a unit
        /// vector) to the first building or ground, m, up to `frontReachM`.
        public func reach(from p: SIMD3<Float>, along direction: SIMD3<Float>) -> Double {
            let step = cell / 2
            var travelled: Float = 0
            while travelled < Self.frontReachM {
                travelled += step
                if isSolid(p + travelled * direction) { return Double(travelled) }
            }
            return Double(Self.frontReachM)
        }

        /// The furthest `reach` looks, m.
        public static let frontReachM: Float = 200
    }

    /// The middle of `component`'s outer face, and that face's outward normal.
    public static func outerFace(_ component: EnvelopeComponent) -> (
        centre: SIMD3<Float>, normal: SIMD3<Float>
    ) {
        outerFace(region: component.region, axis: component.axis, outward: component.outward)
    }

    /// The middle of the outer face of a component over `region`, thin along `axis` and facing
    /// out along it to the `outward` side, and that face's outward normal.
    public static func outerFace(region: Box, axis: Int, outward: Int) -> (
        centre: SIMD3<Float>, normal: SIMD3<Float>
    ) {
        var centre = 0.5 * (region.min + region.max)
        centre[axis] = outward > 0 ? region.max[axis] : region.min[axis]
        var normal = SIMD3<Float>.zero
        normal[axis] = Float(outward)
        return (centre, normal)
    }

    /// `component`'s features, `owner` its owner's index in the raster's objects, the charge at
    /// `charge`.
    public static func features(
        _ component: EnvelopeComponent, owner: Int, charge: SIMD3<Float>, raster: Raster
    ) -> Features {
        features(
            region: component.region, axis: component.axis, outward: component.outward, owner: owner,
            charge: charge,
            raster: raster)
    }

    /// The features of a component over `region`, thin along `axis`, facing out to `outward`.
    public static func features(
        region: Box, axis: Int, outward: Int, owner: Int, charge: SIMD3<Float>, raster: Raster
    ) -> Features {
        let (centre, normal) = outerFace(region: region, axis: axis, outward: outward)
        // Half a cell out from the face, in the air beside it.
        let target = centre + 0.5 * raster.cell * normal
        let toCharge = charge - centre
        let distance = simd_length(toCharge)
        let cosine = distance > 0 ? Double(simd_dot(normal, toCharge) / distance) : 1
        let sight = raster.sight(from: charge, to: target, excluding: owner)
        let ground = raster.terrain?.height(at: centre) ?? 0
        let chargeGround = raster.terrain?.height(at: charge) ?? 0
        let canyon = raster.canyon(from: charge, to: target)
        return Features(
            distanceM: Double(distance), cosIncidence: cosine, buildingsCrossed: sight.crossed,
            blockedM: sight.blockedM, ridgeM: sight.ridgeM, groundRiseM: Double(ground - chargeGround),
            heightM: Double(centre.z - ground),
            shadowM: sight.shadowM, frontM: raster.reach(from: target, along: normal), edgeM: sight.edgeM,
            edgeFromChargeM: sight.edgeFromChargeM, edgeToTargetM: sight.edgeToTargetM,
            edgeTopM: sight.edgeTopM, edgeSideM: sight.edgeSideM, edgeWidthM: sight.edgeWidthM,
            lastTopM: sight.lastTopM,
            canyonM: canyon.lengthM,
            canyonHeightM: canyon.heightM)
    }

    /// Whether some of `component`'s cells have air beside their outer face (the recorder leaves
    /// out a component with none: a side against a neighbour, or buried).
    public static func facesAir(_ component: EnvelopeComponent, raster: Raster) -> Bool {
        let dx = raster.cell
        // A strip its cells snapped to nothing.
        guard component.spans.x > 1e-3, component.spans.y > 1e-3 else { return false }
        let (centre, normal) = outerFace(component)
        let axes = (0..<3).filter { $0 != component.axis }
        let region = component.region
        func centres(_ axis: Int) -> [Float] {
            var list: [Float] = []
            var x = (region.min[axis] / dx).rounded(.down) * dx + 0.5 * dx
            while x < region.max[axis] {
                if x >= region.min[axis] { list.append(x) }
                x += dx
            }
            // Thinner than a cell: its middle.
            return list.isEmpty ? [0.5 * (region.min[axis] + region.max[axis])] : list
        }
        for a in centres(axes[0]) {
            for b in centres(axes[1]) {
                var p = centre + 0.5 * dx * normal
                p[axes[0]] = a
                p[axes[1]] = b
                if !raster.isSolid(p) { return true }
            }
        }
        return false
    }

    /// The few terms fitted to BombCAD's runs (`Scripts/fit-surrogate.py`): the logarithm of a
    /// component's peak load (or impulse) over its base, Kingery–Bulmash's incident value raised
    /// toward the reflected one by the square of its facing, is a sum of these times its
    /// features (`terms`).
    public struct Coefficients: Codable, Sendable, Equatable {
        public var peak: [Double]
        public var impulse: [Double]
        /// The share of the pulse spent rising to its peak, itself (not its logarithm) a sum of
        /// these times the terms: on a run's cells a shock rises over several of them, and behind
        /// buildings the load builds up as the air round them fills.
        public var rise: [Double]
        /// Where the fit holds: scaled distances, m/kg^(1/3).
        public var scaledRange: ClosedRange<Double>
        /// The scatter of the fitted runs' loads about it, as the standard deviation of the
        /// logarithm (peak, impulse).
        public var scatter: SIMD2<Double>
        /// What it was fitted to.
        public var fittedTo: String
        /// The close-in branch, below `scaledRange` (none: the terms held at its start there).
        public var closeIn: CloseIn?

        public init(
            peak: [Double], impulse: [Double], rise: [Double], scaledRange: ClosedRange<Double>,
            scatter: SIMD2<Double>, fittedTo: String, closeIn: CloseIn? = nil
        ) {
            self.peak = peak
            self.impulse = impulse
            self.rise = rise
            self.scaledRange = scaledRange
            self.scatter = scatter
            self.fittedTo = fittedTo
            self.closeIn = closeIn
        }

        /// Close in (emmettl/bombcad-work#4, docs/surrogate-first-look.md): Kingery–Bulmash's base
        /// times the fine runs' ratio to it on open façades. The logarithm of a load over its base
        /// is a quadratic in log Z (held within `heldWithin`), fitted on cells `referenceCell`
        /// W^(1/3) across and carried to others by the fitted terms' own cell term; below
        /// `scaledRange` it replaces the fitted terms (the canyon terms still added), and between
        /// `scaledRange`'s start and `blendTo` it gives way to them evenly in log Z.
        public struct CloseIn: Codable, Sendable, Equatable {
            public var peak: [Double]
            public var impulse: [Double]
            public var referenceCell: Double
            public var heldWithin: ClosedRange<Double>
            public var blendTo: Double
            public var fittedTo: String
            /// Whether the branch is taken only by components in sight of the charge (no building
            /// in the way), the rest keeping the fitted terms: a candidate, not adopted
            /// (emmettl/bombcad-work#56). The branch was fitted on open façades; taken by shielded
            /// ones close in, it reads them 1.4–1.9 times the runs' on the mapped start.
            public var inSightOnly: Bool?
            /// Shielding behind buildings in the branch, by how open the charge's surroundings are
            /// (emmettl/bombcad-work#56); none, as fitted: a proposal, not adopted.
            public var shielding: Shielding?

            /// For a component behind buildings (one crossed at least), with its charge's
            /// surroundings open to `Features.chargeOpenM`, the branch's log peak and log impulse
            /// gain `peak` and `impulse` times e^(−open / (`openScale` W^(1/3))): the whole of
            /// them close to a charge in a narrow street, next to nothing for one in the open.
            /// Nothing where the openness was not measured.
            public struct Shielding: Codable, Sendable, Equatable {
                public var peak: Double
                public var impulse: Double
                public var openScale: Double
                public var fittedTo: String

                public init(peak: Double, impulse: Double, openScale: Double, fittedTo: String) {
                    self.peak = peak
                    self.impulse = impulse
                    self.openScale = openScale
                    self.fittedTo = fittedTo
                }

                /// The share of the gains `f` takes for a charge of `mass` kg.
                public func share(_ f: Features, mass: Double) -> Double {
                    guard f.buildingsCrossed > 0, f.chargeOpenM.isFinite, openScale > 0 else { return 0 }
                    return exp(-f.chargeOpenM / (openScale * cbrt(mass)))
                }
            }

            public init(
                peak: [Double], impulse: [Double], referenceCell: Double, heldWithin: ClosedRange<Double>,
                blendTo: Double, fittedTo: String, inSightOnly: Bool? = nil, shielding: Shielding? = nil
            ) {
                self.inSightOnly = inSightOnly
                self.shielding = shielding
                self.peak = peak
                self.impulse = impulse
                self.referenceCell = referenceCell
                self.heldWithin = heldWithin
                self.blendTo = blendTo
                self.fittedTo = fittedTo
            }
        }
    }

    /// The terms' names, in `terms`' order.
    public static let termNames = [
        "1", "facing", "facing away", "log(1 + buildings crossed)", "inside buildings / W^(1/3)",
        "log Z", "height / W^(1/3)", "ridge / W^(1/3)", "ground rise / W^(1/3)", "(log Z)²",
        "log(cell / W^(1/3))", "(log(1 + buildings crossed))²", "canyon, peak", "canyon, impulse",
    ]

    /// The first of the terms measured on the fine runs rather than fitted to the districts (the
    /// canyon's): the close-in branch keeps them.
    public static let geometryTerms = 12

    /// `features`' terms for a charge of `mass` kg on the air's cells `cellSize` m across (a run's
    /// loads depend on its cells: the surrogate gives the run's, not the converged ones). With
    /// `scaledRange`, the scaled distance's terms are held at its ends beyond it: a fitted
    /// quadratic in log Z carried past the runs it was fitted to would drive the correction to
    /// nothing close in (Kingery–Bulmash's base still follows the distance).
    public static func terms(
        _ f: Features, mass: Double, cellSize: Double, scaledRange: ClosedRange<Double>? = nil
    ) -> [Double] {
        let root = cbrt(mass)
        var scaled = max(f.distanceM / root, 0.2)
        if let scaledRange { scaled = min(max(scaled, scaledRange.lowerBound), scaledRange.upperBound) }
        let z = log(scaled)
        let canyon = canyonTerms(f, mass: mass)
        return [
            1, max(f.cosIncidence, 0), max(-f.cosIncidence, 0), log(1 + Double(f.buildingsCrossed)),
            f.blockedM / root, z, f.heightM / root, f.ridgeM / root, f.groundRiseM / root, z * z,
            log(cellSize / root), log(1 + Double(f.buildingsCrossed)) * log(1 + Double(f.buildingsCrossed)),
            canyon.peak, canyon.impulse,
        ]
    }

    /// A street the line runs down (emmettl/bombcad-work#4, docs/hybrid-far-field.md's channelling):
    /// with ℓ the stretch between its walls and h their lower side's height, each over W^(1/3), and u
    /// the logarithm of the scaled distance over the street mouth's, the fine canyon runs' gain over
    /// open ground is about 0.68 u e^(−ℓ/8h) in log peak (the street holds the shock in, then lets it
    /// out over the roofs), and 1.33 u e^(−ℓ/3h) (1 − e^(−(h − 0.6))) in log impulse for walls
    /// above 0.6 W^(1/3), nothing below. Both distances are taken at Z 2 or more, the nearest mouth
    /// the runs had (nearer, the street would begin in the fireball).
    static func canyonTerms(_ f: Features, mass: Double) -> (peak: Double, impulse: Double) {
        let root = cbrt(mass)
        guard f.canyonM > 0, f.canyonHeightM > 0 else { return (0, 0) }
        let scaled = max(f.distanceM / root, 0.2)
        let l = f.canyonM / root
        let h = f.canyonHeightM / root
        let u = log(max(scaled, 2) / max(scaled - l, 2))
        let peak = u * exp(-l / (8 * h))
        let impulse = h > 0.6 ? u * exp(-l / (3 * h)) * (1 - exp(-(h - 0.6))) : 0
        return (peak, impulse)
    }

    /// A component's predicted load.
    public struct Prediction: Sendable, Equatable {
        public var peakPa: Double
        public var impulsePaS: Double
        /// The share of the pulse spent rising to its peak.
        public var riseShare: Double
        /// When the blast reaches it, s.
        public var arrivalS: Double
        /// It lies outside the scaled distances the terms were fitted over
        /// (`Coefficients.scaledRange`), where they are held at the range's end: extrapolated.
        public var outsideFit = false

        public init(
            peakPa: Double, impulsePaS: Double, riseShare: Double, arrivalS: Double, outsideFit: Bool = false
        ) {
            self.peakPa = peakPa
            self.impulsePaS = impulsePaS
            self.riseShare = riseShare
            self.arrivalS = arrivalS
            self.outsideFit = outsideFit
        }
    }

    /// Kingery–Bulmash's base for `features`: (peak Pa, impulse Pa s, arrival s), the incident
    /// values raised toward the reflected ones by the square of the facing, for a hemispherical
    /// surface burst of `mass` kg; scaled distances outside the curves' 0.2–40 taken at their ends.
    public static func base(_ f: Features, mass: Double) -> (peak: Double, impulse: Double, arrival: Double) {
        let root = cbrt(mass)
        let z = min(max(f.distanceM / root, 0.2), 40)
        guard let point = KingeryBulmash.point(at: z) else { return (0, 0, 0) }
        let facing = max(f.cosIncidence, 0) * max(f.cosIncidence, 0)
        let peak = point.incidentPressure + facing * (point.reflectedPressure - point.incidentPressure)
        let impulse =
            (point.scaledIncidentImpulse + facing
                * (point.scaledReflectedImpulse - point.scaledIncidentImpulse))
            * root
        // Beyond the curves, the incident peak and impulse fall as 1/r, and the shock goes on at
        // the speed of sound (as `ChargeInference`); within 0.2 the arrival goes to nothing with r.
        let scaled = f.distanceM / root
        let far = scaled > 40 ? 40 / scaled : 1
        let arrival =
            scaled > 40
            ? point.scaledArrival * root + (f.distanceM - 40 * root) / 340.3
            : point.scaledArrival * root * f.distanceM / (z * root)
        return (peak * far, impulse * far, arrival)
    }

    /// `features`' load for a charge of `mass` kg, as a run on cells `cellSize` m across would
    /// give it, under `coefficients`.
    public static func predict(
        _ f: Features, mass: Double, cellSize: Double, coefficients: Coefficients = .fitted
    ) -> Prediction {
        // No charge, no load (and no arrival).
        guard mass > 0, mass.isFinite else {
            return Prediction(peakPa: 0, impulsePaS: 0, riseShare: 0, arrivalS: 0)
        }
        let (peak, impulse, arrival) = base(f, mass: mass)
        let x = terms(f, mass: mass, cellSize: cellSize, scaledRange: coefficients.scaledRange)
        var p = zip(coefficients.peak, x).reduce(0) { $0 + $1.0 * $1.1 }
        var i = zip(coefficients.impulse, x).reduce(0) { $0 + $1.0 * $1.1 }
        let r = zip(coefficients.rise, x).reduce(0) { $0 + $1.0 * $1.1 }
        let root = cbrt(mass)
        let scaled = f.distanceM / root
        var covered = coefficients.scaledRange
        if let close = coefficients.closeIn, scaled < close.blendTo, coefficients.peak.count > 10,
            coefficients.impulse.count > 10, close.inSightOnly != true || f.buildingsCrossed == 0
        {
            let start = coefficients.scaledRange.lowerBound
            let z = log(min(max(scaled, close.heldWithin.lowerBound), close.heldWithin.upperBound))
            let cell = log(cellSize / root) - log(close.referenceCell)
            // The canyon terms carried over; the fitted ones given way to the branch.
            func geometry(_ c: [Double]) -> Double {
                zip(c, x).enumerated().reduce(0) {
                    $0 + ($1.offset >= geometryTerms ? $1.element.0 * $1.element.1 : 0)
                }
            }
            func branch(_ q: [Double], _ c: [Double]) -> Double {
                q.enumerated().reduce(0) { $0 + $1.element * pow(z, Double($1.offset)) } + c[10] * cell
                    + geometry(c)
            }
            let w = scaled <= start ? 0 : min(log(scaled / start) / log(close.blendTo / start), 1)
            var shieldPeak = 0.0
            var shieldImpulse = 0.0
            if let shielding = close.shielding {
                let share = shielding.share(f, mass: mass)
                shieldPeak = shielding.peak * share
                shieldImpulse = shielding.impulse * share
            }
            p = (1 - w) * (branch(close.peak, coefficients.peak) + shieldPeak) + w * p
            i = (1 - w) * (branch(close.impulse, coefficients.impulse) + shieldImpulse) + w * i
            covered = min(close.heldWithin.lowerBound, covered.lowerBound)...covered.upperBound
        }
        return Prediction(
            peakPa: peak * exp(p) * f.learnedPeakFactor, impulsePaS: impulse * exp(i),
            riseShare: min(max(r, 0), 0.9),
            arrivalS: arrival, outsideFit: !covered.contains(scaled))
    }

    /// The steps a pulse's peak and impulse are rounded to, as a share of each: far finer than
    /// the fit's scatter, and coarse enough that a district's components share their pulses (and
    /// so their SDOF responses, `SDOFResponseMemo`).
    public static let quantum = 0.03

    static func quantized(_ x: Double) -> Double {
        x > 0 ? exp((log(x) / log(1 + quantum)).rounded() * log(1 + quantum)) : 0
    }

    /// `component`'s load as a triangular pulse of `prediction`'s peak and impulse (each rounded
    /// to `quantum`, the rise to a twentieth): rising straight to its peak over its rise share of
    /// twice the impulse over the peak, then falling straight to nothing, in bins `binS` s long
    /// from its arrival (the SDOF follows a load for three of its periods after it ends).
    public static func load(_ component: EnvelopeComponent, _ prediction: Prediction, binS: Double)
        -> EnvelopeComponentLoad
    {
        let pressures = pulse(
            peak: quantized(prediction.peakPa), impulse: quantized(prediction.impulsePaS),
            riseShare: (prediction.riseShare * 20).rounded() / 20, binS: binS)
        return EnvelopeComponentLoad(
            id: component.id, owner: component.owner,
            kind: EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue)!,
            region: component.region,
            axis: component.axis, binS: binS, outerPa: pressures,
            innerPa: [Double](repeating: 0, count: pressures.count),
            supportEdges: component.supportEdges, startS: prediction.arrivalS, outward: component.outward)
    }

    /// A triangular pulse's bins' mean pressures, Pa: `peak` Pa reached over `riseShare` of its
    /// length, then falling straight to nothing, carrying `impulse` Pa s.
    static func pulse(peak: Double, impulse: Double, riseShare: Double, binS: Double) -> [Double] {
        let duration = peak > 0 ? 2 * impulse / peak : 0
        let rise = riseShare * duration
        let count = max(1, Int((duration / binS).rounded(.up)))
        // The impulse to time t, its rise then its fall.
        func impulseTo(_ t: Double) -> Double {
            guard duration > 0 else { return 0 }
            let t = min(max(t, 0), duration)
            if t <= rise { return rise > 0 ? 0.5 * peak * t * t / rise : 0 }
            let fall = duration - rise
            let left = duration - t
            return 0.5 * peak * rise + 0.5 * peak * (fall - left * left / fall)
        }
        // Each bin's mean over its width.
        return (0..<count).map { n -> Double in
            let a = Double(n) * binS
            return (impulseTo(a + binS) - impulseTo(a)) / binS
        }
    }

    /// A first look at `scene`'s envelopes: every component with a face on the air, its features
    /// and its predicted load, laid out on cells `cellSize` m across as a run's would be.
    public struct Estimate: Sendable {
        public var components: [EnvelopeComponent]
        /// Each component's owner, by index in `scene.envelopeObjects`.
        public var owners: [Int]
        /// Each owner's key for its draws (`SceneObject.drawKey`), by index in
        /// `scene.envelopeObjects`; empty for an estimate made without them.
        public var ownerKeys: [UInt64] = []
        public var features: [Features]
        public var predictions: [Prediction]
        /// The predicted loads as a run's recorder would give them, for `EnvelopeDamageAssessment`.
        public var loads: [EnvelopeComponentLoad]
        public var seconds: Double

        /// The components outside the distances the terms were fitted over, their loads extrapolated.
        public var outsideFit: Int { predictions.filter(\.outsideFit).count }
    }

    public static func estimate(
        scene: Scenario, cellSize: Float, binS: Double = 0.7e-3, coefficients: Coefficients = .fitted,
        roofCoefficients: Coefficients? = .roofs
    ) -> Estimate {
        let start = ContinuousClock.now
        let objects = scene.envelopeObjects
        let raster = Raster(objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: cellSize)
        let charge = scene.charge.position
        let mass = Double(scene.charge.mass)
        let open = raster.openReach(around: charge)
        var perObject = [[(EnvelopeComponent, Features, Prediction, EnvelopeComponentLoad)]](
            repeating: [], count: objects.count)
        perObject.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: objects.count) { n in
                guard let envelope = objects[n].envelope else { return }
                out[n] = envelope.components(owner: objects[n].id, cellSize: cellSize)
                    .filter { facesAir($0, raster: raster) }
                    .map { component in
                        var f = features(component, owner: n, charge: charge, raster: raster)
                        f.chargeOpenM = open
                        // Roofs on their own terms, the rest on the façades'.
                        let p = predict(
                            f, mass: mass, cellSize: Double(cellSize),
                            coefficients: component.kind == .roof
                                ? roofCoefficients ?? coefficients : coefficients)
                        return (component, f, p, load(component, p, binS: binS))
                    }
            }
        }
        var result = Estimate(
            components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
        result.ownerKeys = objects.map(\.drawKey)
        for (n, list) in perObject.enumerated() {
            for (component, f, p, l) in list {
                result.components.append(component)
                result.owners.append(n)
                result.features.append(f)
                result.predictions.append(p)
                result.loads.append(l)
            }
        }
        let took = start.duration(to: .now)
        result.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        return result
    }
}

extension FacadeLoadSurrogate {
    /// What a first look is, in a line.
    public static let method =
        "Each envelope component's load from its distance, facing and the buildings in the way: "
        + "Kingery–Bulmash's incident and reflected values corrected by terms fitted to BombCAD's district "
        + "runs, as a triangular pulse into the same SDOF damage as a run's histories. An estimate, not a run."

    /// Its standing: how it compared with a full run it was not fitted to, worded from the
    /// standing table's figures (validation.md, "Estimates beside a run").
    public static let standing: [String] = {
        let glass = ValidationTables.figure("surrogateGlassSides")
        let concrete = ValidationTables.figure("surrogateConcrete")
        let stone = ValidationTables.figure("surrogateStone")
        let roof = ValidationTables.figure("surrogateRoof")
        let near = ValidationTables.figure("surrogateNearPeak")
        let far = ValidationTables.figure("surrogateFarLoads")
        let shielded = ValidationTables.figure("surrogateCloseInShielded")
        return [
            "An estimate, not a run. Against Beirut's full 4 m runs at 0.2, 0.5 and 1.1 kt, which it was not fitted to:",
            "Glass: each building side's state (none broken, some, blown out) agreed with the run's for \(glass.percent) "
                + "of sides deep in the district, never two states apart; the share of sides broken by distance came "
                + "within 0.1 of the run's to 2 km.",
            "Walls and roofs: not to be relied on. Of the components either called damaged, \(concrete.percent) of the "
                + "concrete, \(stone.percent) of the stone and \(roof.percent) of the roofs took the run's level. Run the "
                + "scene for the structure.",
            "Loads: peaks \(near.ratio) of the run's on the median to Z 20 m/kg^(1/3), each scattered by about ×1.3; "
                + "further out, over hills and near the run's open faces, \(far.ratio) times on the median and far "
                + "more scattered.",
            "Close in, Z 1.5–4.6 m/kg^(1/3), Kingery–Bulmash's base times the open façades' ratio on fine runs; "
                + "a street the line runs down raises the loads by the fine canyon runs' terms; a building or barrier "
                + "in front takes only the districts' few per cent off, less than fine runs take close behind it. "
                + "Behind buildings close in, with the charge among them, it reads \(String(format: "%.1f–%.1f", shielded.low, shielded.high)) "
                + "times the runs' peaks: high.",
            "Outside Z 1.5–38.7 m/kg^(1/3) its terms are held at the range's end and its loads extrapolated: "
                + "marked as such.",
        ]
    }()

    /// `estimate`'s damage, each building judged on its components' pulses as a run's are on
    /// their histories (`EnvelopeDamageAssessment`), the SDOF responses remembered between them;
    /// and how long it took, s.
    public static func damage(_ estimate: Estimate, constructions: (UUID) -> EnvelopeConstruction) -> (
        buildings: [EnvelopeBuildingDamage], seconds: Double, memo: SDOFResponseMemo
    ) {
        let start = ContinuousClock.now
        let (buildings, memo) = SDOFResponseMemo.remembering {
            EnvelopeDamageAssessment.assess(loads: estimate.loads, constructions: constructions)
        }
        let took = start.duration(to: .now)
        return (
            buildings, Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18, memo
        )
    }
}

extension FacadeLoadSurrogate.Coefficients {
    /// Fitted to four runs of two made-up districts on 4 m cells (`Scripts/fit-surrogate.py`;
    /// docs/surrogate-first-look.md): a dense one of 7,235 buildings at 20, 100 and 500 t, and the
    /// sparse test fixture at 20 t. The canyon terms are the fine canyon runs' (1 t on 0.5 m cells)
    /// and held; the close-in branch is the fine protective layouts' open façades (1 t on 0.5 m cells,
    /// `Scripts/fit-close-in.py`; emmettl/bombcad-work#4). Beirut held out, to judge it on.
    public static let fitted = FacadeLoadSurrogate.Coefficients(
        peak: [
            -3.108, -0.319, -0.165, -0.022, -0.001, 1.609, -0.260, -0.073, 0.023, -0.293, -0.286, 0.000,
            0.683,
            0.000,
        ],
        impulse: [
            -0.186, -0.468, -0.161, 0.123, -0.021, 0.571, -0.103, -0.202, -0.008, -0.130, 0.251, 0.000, 0.000,
            1.334,
        ],
        rise: [
            -0.074, -0.027, -0.030, 0.014, 0.038, 0.389, 0.075, -0.444, 0.628, -0.098, -0.105, 0.000, 0.000,
            0.000,
        ],
        scaledRange: 4.6...38.7, scatter: SIMD2(0.240, 0.168),
        fittedTo: "made-up districts: dense at 20, 100 and 500 t, sparse at 20 t (4 m cells)",
        closeIn: CloseIn(
            peak: [-1.574, 1.768, -0.545], impulse: [-0.218, 0.397, -0.226], referenceCell: 0.05,
            heldWithin: 1.5...8, blendTo: 8,
            fittedTo: "open façades of the protective layouts L1-L6, 1 t on 0.5 m cells"))
}
