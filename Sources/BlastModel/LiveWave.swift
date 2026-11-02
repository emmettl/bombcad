import Foundation
import simd

/// The blast wave, live (emmettl/bombcad-work#112 item 2; docs/live-wave.md): when the front
/// arrives over a district's plan, how strong it is there and how it decays, worked out in tens of
/// milliseconds from the plan alone, so that the front can be drawn sweeping the streets as the
/// charge is dragged, and scrubbed or replayed at once, without a solver run.
///
/// **The path.** The shortest way from the charge to each cell over the plan's surface, the ground
/// with its buildings standing on it: round a building or over its roof, whichever is shorter, as
/// a front diffracts. It is found by Dijkstra's method on the plan's cells, each joined to its 32
/// neighbours within a 3 × 3 cell step (an angle at most 9° from any direction, so no more than
/// 1.3% longer than the straight line in the open), with a bucket queue as wide as a cell, which
/// is exact for steps at least a cell long.
///
/// **Its strength and time.** Kingery–Bulmash's hemispherical surface burst (`KingeryBulmash`) at
/// the path's scaled length: the arrival, the incident peak, the positive phase's duration and the
/// Friedlander decay that gives its impulse. A fitted correction (`Coefficients`) takes the peak
/// and the arrival towards BombCAD's own 4 m district runs, by the scaled length and by how much
/// longer the path is than the straight line (`ln(L/R)`, 0 in sight): the shadow behind buildings.
public enum LiveWave {
    // MARK: - The plan

    /// A district's plan, cells x fastest from the origin: each cell's buildings' height over the
    /// ground (0 with none) and its ground. `LearnedField.Plan` and `scenebench field-export` lay out
    /// the same plan on 4 m cells.
    public struct Plan: Sendable {
        public let columns: Int
        public let rows: Int
        public let cell: Float
        public let height: [Float]
        public let ground: [Float]

        public init(columns: Int, rows: Int, cell: Float, height: [Float], ground: [Float]) {
            precondition(columns > 0 && rows > 0 && cell > 0, "a plan of some cells")
            precondition(height.count == columns * rows && ground.count == columns * rows, "a value a cell")
            self.columns = columns
            self.rows = rows
            self.cell = cell
            self.height = height
            self.ground = ground
        }

        /// The plan of `scene` on cells `cell` m across over its domain from its origin: the tallest
        /// block over each cell's centre, as the air holds it, and the ground there.
        public init(scene: Scenario, cell: Float) {
            let grid = scene.grid(cellSize: cell)
            let (nx, ny) = (grid.nx, grid.ny)
            var ground = [Float](repeating: 0, count: nx * ny)
            if let terrain = scene.terrain {
                ground.withUnsafeMutableBufferPointer { out in
                    concurrently(iterations: ny) { j in
                        for i in 0..<nx {
                            out[i + nx * j] = terrain.height(
                                at: SIMD2((Float(i) + 0.5) * cell, (Float(j) + 0.5) * cell))
                        }
                    }
                }
            }
            var top = [Float](repeating: -.greatestFiniteMagnitude, count: nx * ny)
            for block in scene.envelopeObjects.flatMap({ $0.envelope?.blocks ?? [] }) + scene.boxes {
                let i0 = max(0, Int((block.min.x / cell - 0.5).rounded(.up)))
                let i1 = min(nx - 1, Int((block.max.x / cell - 0.5).rounded(.up)) - 1)
                let j0 = max(0, Int((block.min.y / cell - 0.5).rounded(.up)))
                let j1 = min(ny - 1, Int((block.max.y / cell - 0.5).rounded(.up)) - 1)
                guard i0 <= i1, j0 <= j1 else { continue }
                for j in j0...j1 {
                    for i in i0...i1 { top[i + nx * j] = max(top[i + nx * j], block.max.z) }
                }
            }
            self.init(
                columns: nx, rows: ny, cell: cell, height: zip(top, ground).map { $0 > $1 ? $0 - $1 : 0 },
                ground: ground)
        }

        /// The cell size for `scene`'s plan: `finest` m, coarsened in steps of it until the plan has
        /// no more than `maximumCells`, so that a recompute stays live on any domain.
        public static func cellSize(for scene: Scenario, finest: Float = 4, maximumCells: Int = 1_700_000)
            -> Float
        {
            var cell = finest
            while Double(scene.domainSize.x / cell) * Double(scene.domainSize.y / cell) > Double(maximumCells)
            {
                cell += finest
            }
            return cell
        }

        /// The surface the wave runs over: the ground, or a roof.
        func surface(_ n: Int) -> Float { ground[n] + height[n] }
    }

    // MARK: - The fitted correction

    /// The correction to Kingery–Bulmash at the path's length, as logarithms: of the peak,
    /// `peak[0] + peak[1] x + peak[2] x² + peak[3] s + peak[4] s x`, and of the arrival,
    /// `arrival[0] + arrival[1] x + arrival[2] s`, where x is ln Z of the path and s is ln(L/R), the
    /// path's excess over the straight line (0 in sight). Each held at its fitted range's ends.
    public struct Coefficients: Sendable, Codable, Equatable {
        public var peak: [Double]
        public var arrival: [Double]
        /// The range of ln Z and of s they were fitted over.
        public var logZRange: ClosedRange<Double>
        public var excessRange: ClosedRange<Double>

        public init(
            peak: [Double], arrival: [Double], logZRange: ClosedRange<Double>,
            excessRange: ClosedRange<Double>
        ) {
            precondition(peak.count == 5 && arrival.count == 3, "five peak terms and three arrival terms")
            self.peak = peak
            self.arrival = arrival
            self.logZRange = logZRange
            self.excessRange = excessRange
        }

        /// Kingery–Bulmash along the path, uncorrected.
        public static let none = Coefficients(
            peak: [0, 0, 0, 0, 0], arrival: [0, 0, 0], logZRange: -3...6, excessRange: 0...3)

        /// Fitted on 4 m runs of made-up districts, Beirut held out (Scripts/fit-live-wave.py,
        /// 1 November 2026; docs/live-wave.md): the peak on the 150 runs of the learned field's
        /// dataset, the arrival on 16 of them run again with `field-export --arrival`.
        public static let fitted = Coefficients(
            peak: [-1.0020, 0.8414, -0.2012, 0.3024, 0.6488], arrival: [-0.1176, 0.0381, -0.1717],
            logZRange: 0.8631...3.3249, excessRange: 0...0.1057)

        func peakCorrection(logZ: Double, excess: Double) -> Double {
            let x = min(max(logZ, logZRange.lowerBound), logZRange.upperBound)
            let s = min(max(excess, excessRange.lowerBound), excessRange.upperBound)
            return peak[0] + peak[1] * x + peak[2] * x * x + peak[3] * s + peak[4] * s * x
        }

        func arrivalCorrection(logZ: Double, excess: Double) -> Double {
            let x = min(max(logZ, logZRange.lowerBound), logZRange.upperBound)
            let s = min(max(excess, excessRange.lowerBound), excessRange.upperBound)
            return arrival[0] + arrival[1] * x + arrival[2] * s
        }
    }

    // MARK: - The field

    /// The wave over a plan for one charge, cells x fastest as the plan's.
    public struct Field: Sendable {
        public let columns: Int
        public let rows: Int
        public let cell: Float
        /// When the front arrives, s; infinity where it never does (a cell walled in).
        public var arrival: [Float]
        /// The peak overpressure, Pa.
        public var peak: [Float]
        /// The positive phase's duration, s.
        public var duration: [Float]
        /// The Friedlander decay's exponent b: p(τ) = P (1 − τ/T) e^(−bτ/T).
        public var decay: [Float]
        /// The path's length over the surface, m, and the straight line's.
        public var path: [Float]
        public var straight: [Float]
        /// The last arrival anywhere on the plan, s.
        public var lastArrival: Float
        /// How long the paths, and the whole field, took to work out, s.
        public var pathSeconds: Double
        public var seconds: Double
        /// Whether the learned refinement corrected it (`Refinement`), and how long that took, s
        /// (in `seconds` as well).
        public var refined = false
        public var refinementSeconds: Double = 0

        /// The overpressure at cell `n` at time `t`, Pa: nothing before the front, the Friedlander
        /// pulse through its positive phase, nothing after it.
        public func overpressure(_ n: Int, at t: Float) -> Float {
            let tau = t - arrival[n]
            guard tau >= 0, tau < duration[n], duration[n] > 0 else { return 0 }
            let x = tau / duration[n]
            return peak[n] * (1 - x) * exp(-decay[n] * x)
        }

        /// The path's excess over the straight line at cell `n`, ln(L/R): 0 in sight.
        public func excess(_ n: Int) -> Float { log(max(path[n], 1e-3) / max(straight[n], 1e-3)) }
    }

    /// Its standing, worded from the standing table's figures (docs/live-wave.md, "Judged against
    /// the solver").
    public static let standing: [String] = {
        let sight = ValidationTables.figure("liveWavePeakSight")
        let shielded = ValidationTables.figure("liveWavePeakShielded")
        let arrival = ValidationTables.figure("liveWaveArrivalShielded")
        return [
            "\(EvidenceLevel.illustrative.title). An estimate, not a run: Kingery–Bulmash along the shortest paths "
                + "round and over buildings, corrected by terms fitted to BombCAD's own 4 m runs of made-up districts.",
            String(
                format:
                    "Against Beirut's 4 m runs it was not fitted to, cell by cell 2 m over the ground: peaks within ×1.25 "
                    + "on %.0f%% of cells in sight of the charge and %.0f%% of those behind buildings; arrivals beyond "
                    + "200 m %.1f–%.1f%% out on average behind buildings, less in sight.",
                100 * sight.low, 100 * shielded.low, 100 * arrival.low, 100 * arrival.high),
            "Within 200 m behind buildings its peaks read high, up to ×1.7, and its arrivals up to 10% early. It is "
                + "the 4 m runs' wave, under-resolved close in as they are; one charge on the ground; one pulse, no "
                + "reflections or channelling but on average.",
        ]
    }()

    /// The height over the surface the field is for: a standing person's, the learned field's 2 m.
    public static let above: Float = 2

    /// The wave over `plan` from a surface burst of `mass` kg of TNT at `charge` (scene metres).
    public static func field(
        plan: Plan, charge: SIMD3<Float>, mass: Double, coefficients: Coefficients = .fitted
    ) -> Field {
        let start = ContinuousClock.now
        let (path, straight) = paths(plan: plan, charge: charge)
        let pathSeconds = (ContinuousClock.now - start) / .seconds(1)
        let count = plan.columns * plan.rows
        let root = cbrt(max(mass, 1e-6))
        let table = Table.shared
        var arrival = [Float](repeating: .infinity, count: count)
        var peak = [Float](repeating: 0, count: count)
        var duration = [Float](repeating: 0, count: count)
        var decay = [Float](repeating: 0, count: count)
        let chunk = 4096
        arrival.withUnsafeMutableBufferPointer { arrival in
            peak.withUnsafeMutableBufferPointer { peak in
                duration.withUnsafeMutableBufferPointer { duration in
                    decay.withUnsafeMutableBufferPointer { decay in
                        concurrently(iterations: (count + chunk - 1) / chunk) { c in
                            for n in (c * chunk)..<min(count, (c + 1) * chunk) {
                                let length = Double(path[n])
                                guard length.isFinite else { continue }
                                let z = max(length, 0.5 * Double(plan.cell)) / root
                                let logZ = log(z)
                                let excess = log(max(length, 1e-3) / max(Double(straight[n]), 1e-3))
                                let kb = table.at(logZ: logZ)
                                arrival[n] = Float(
                                    kb.scaledArrival * root
                                        * exp(coefficients.arrivalCorrection(logZ: logZ, excess: excess)))
                                peak[n] = Float(
                                    kb.peak * exp(coefficients.peakCorrection(logZ: logZ, excess: excess)))
                                duration[n] = Float(kb.scaledDuration * root)
                                decay[n] = Float(kb.decay)
                            }
                        }
                    }
                }
            }
        }
        let last = arrival.lazy.filter(\.isFinite).max() ?? 0
        return Field(
            columns: plan.columns, rows: plan.rows, cell: plan.cell, arrival: arrival, peak: peak,
            duration: duration, decay: decay, path: path, straight: straight, lastArrival: last,
            pathSeconds: pathSeconds, seconds: (ContinuousClock.now - start) / .seconds(1))
    }

    // MARK: - The paths

    /// A step to a neighbour: its offset, its length in cells, and the cells it passes over.
    struct Step {
        var di: Int
        var dj: Int
        var length: Float
        /// The cells whose inside the step's line crosses, ends left out: it is barred if any
        /// stands above both its ends.
        var over: [(Int, Int)]
        /// Where the line passes through a corner of four cells, the two on either side of it: it
        /// is barred if both stand above both its ends (between two buildings meeting at a corner).
        var between: [((Int, Int), (Int, Int))]
    }

    /// The cells a step's line from (0, 0) to (di, dj) crosses, and the pairs at the corners it
    /// passes through, cells centred on whole numbers.
    static func crossed(_ di: Int, _ dj: Int) -> (over: [(Int, Int)], between: [((Int, Int), (Int, Int))]) {
        // Where x or y crosses a cell's edge (a half), in t along the line.
        var breaks: [Double] = [0, 1]
        for (d, n) in [(di, 0), (dj, 1)] where d != 0 {
            _ = n
            for k in 0..<abs(d) { breaks.append((Double(k) + 0.5) / Double(abs(d))) }
        }
        breaks.sort()
        var over: [(Int, Int)] = []
        var between: [((Int, Int), (Int, Int))] = []
        func cell(_ t: Double) -> (Int, Int) {
            (Int((Double(di) * t).rounded()), Int((Double(dj) * t).rounded()))
        }
        for (a, b) in zip(breaks, breaks.dropFirst()) where b - a > 1e-9 {
            let c = cell(0.5 * (a + b))
            if c != (0, 0) && c != (di, dj) && !over.contains(where: { $0 == c }) { over.append(c) }
        }
        // A break where x and y cross at once is a corner: the line passes between the two cells
        // there that it does not enter.
        for t in breaks where t > 1e-9 && t < 1 - 1e-9 {
            let x = Double(di) * t
            let y = Double(dj) * t
            let fx = x - x.rounded(.down)
            let fy = y - y.rounded(.down)
            guard abs(fx - 0.5) < 1e-9, abs(fy - 0.5) < 1e-9 else { continue }
            let (i, j) = (Int(x.rounded(.down)), Int(y.rounded(.down)))
            let corners = [(i, j), (i + 1, j), (i, j + 1), (i + 1, j + 1)]
            let sides = corners.filter { c in
                !over.contains(where: { $0 == c }) && c != (0, 0) && c != (di, dj)
            }
            if sides.count == 2 && !between.contains(where: { $0.0 == sides[0] && $0.1 == sides[1] }) {
                between.append((sides[0], sides[1]))
            }
        }
        return (over, between)
    }

    /// The 32 steps within 3 × 3 cells: along the axes, the diagonals, and (2,1), (3,1), (3,2)
    /// each way round.
    static let steps: [Step] = {
        var steps: [Step] = []
        for (a, b) in [(1, 0), (1, 1), (2, 1), (3, 1), (3, 2)] {
            var seen = Set<[Int]>()
            for (x, y) in [(a, b), (b, a)] {
                for (sx, sy) in [(1, 1), (-1, 1), (1, -1), (-1, -1)] {
                    let (di, dj) = (sx * x, sy * y)
                    guard seen.insert([di, dj]).inserted else { continue }
                    let (over, between) = crossed(di, dj)
                    steps.append(
                        Step(
                            di: di, dj: dj, length: Float(sqrt(Double(di * di + dj * dj))), over: over,
                            between: between))
                }
            }
        }
        return steps
    }()

    /// Each cell's shortest path from the charge over the surface, and the straight line to it, m,
    /// both to the surface (the field is for `above` over it, which changes neither by much). A
    /// step is barred where it would cross a cell standing above both its ends, or pass through a
    /// corner between two that do, so that a front goes round or over a building, never through a
    /// corner of it. The path hugs the surface: over a roof it climbs the wall and comes down the
    /// far one, where a front through the air is a string stretched over the roof's edges, so
    /// behind a building it is a little long (the fitted terms take that back on average).
    public static func paths(plan: Plan, charge: SIMD3<Float>) -> (path: [Float], straight: [Float]) {
        let (nx, ny, h) = (plan.columns, plan.rows, plan.cell)
        let count = nx * ny
        var straight = [Float](repeating: 0, count: count)
        straight.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: ny) { j in
                let y = (Float(j) + 0.5) * h - charge.y
                for i in 0..<nx {
                    let x = (Float(i) + 0.5) * h - charge.x
                    let z = plan.surface(i + nx * j) - charge.z
                    out[i + nx * j] = (x * x + y * y + z * z).squareRoot()
                }
            }
        }
        // On a plan padded by the steps' reach, its border already settled, so that no step needs
        // its bounds checked.
        let pad = 3
        let px = nx + 2 * pad
        let py = ny + 2 * pad
        var surface = [Float](repeating: 0, count: px * py)
        var distance = [Float](repeating: .infinity, count: px * py)
        var settled = [Bool](repeating: true, count: px * py)
        for j in 0..<ny {
            for i in 0..<nx {
                let m = (i + pad) + px * (j + pad)
                surface[m] = plan.surface(i + nx * j)
                settled[m] = false
            }
        }
        // Each step as offsets in the padded plan: to its end, and to the cells it passes over.
        let steps = Self.steps
        let offsets = steps.map { $0.di + px * $0.dj }
        let lengths = steps.map { $0.length * h }
        var overStart = [0]
        var overOffsets: [Int] = []
        var betweenStart = [0]
        var betweenOffsets: [Int] = []
        for step in steps {
            overOffsets += step.over.map { $0.0 + px * $0.1 }
            overStart.append(overOffsets.count)
            betweenOffsets += step.between.flatMap { [$0.0.0 + px * $0.0.1, $0.1.0 + px * $0.1.1] }
            betweenStart.append(betweenOffsets.count)
        }
        // The bucket queue: a list per bucket one cell wide, each entry a cell and the next. Every
        // step is at least a cell long, so a cell reached from one bucket lands in a later one, and
        // the cells of one bucket cannot shorten each other's paths: the queue is exact.
        let width = h
        var heads = [Int32](repeating: -1, count: 1024)
        var entryCell = [Int32]()
        var entryNext = [Int32]()
        entryCell.reserveCapacity(count * 3)
        entryNext.reserveCapacity(count * 3)
        func push(_ m: Int, _ d: Float) {
            let b = Int(d / width)
            if b >= heads.count {
                heads += [Int32](repeating: -1, count: max(b + 1 - heads.count, heads.count))
            }
            entryCell.append(Int32(m))
            entryNext.append(heads[b])
            heads[b] = Int32(entryCell.count - 1)
        }
        // The charge's own cell and those about it on its own level start from the straight line.
        let ci = min(max(Int(charge.x / h), 0), nx - 1)
        let cj = min(max(Int(charge.y / h), 0), ny - 1)
        let seedRadius = 2
        for dj in -seedRadius...seedRadius {
            for di in -seedRadius...seedRadius {
                let (i, j) = (ci + di, cj + dj)
                guard i >= 0, j >= 0, i < nx, j < ny else { continue }
                let n = i + nx * j
                guard (di == 0 && dj == 0) || abs(plan.surface(n) - plan.surface(ci + nx * cj)) < 0.5 else {
                    continue
                }
                let m = (i + pad) + px * (j + pad)
                distance[m] = straight[n]
                push(m, straight[n])
            }
        }
        surface.withUnsafeBufferPointer { s in
            distance.withUnsafeMutableBufferPointer { d in
                settled.withUnsafeMutableBufferPointer { settled in
                    offsets.withUnsafeBufferPointer { offsets in
                        lengths.withUnsafeBufferPointer { lengths in
                            betweenStart.withUnsafeBufferPointer { betweenStart in
                                overStart.withUnsafeBufferPointer { overStart in
                                    overOffsets.withUnsafeBufferPointer { over in
                                        betweenOffsets.withUnsafeBufferPointer { pairs in
                                            var b = 0
                                            var batch: [Int32] = []
                                            while b < heads.count {
                                                var e = heads[b]
                                                heads[b] = -1
                                                b += 1
                                                // A bucket's cells taken in the plan's order, which keeps
                                                // them near each other in memory: they are all final.
                                                batch.removeAll(keepingCapacity: true)
                                                while e >= 0 {
                                                    let m = entryCell[Int(e)]
                                                    e = entryNext[Int(e)]
                                                    if !settled[Int(m)] { batch.append(m) }
                                                }
                                                if batch.count > 32 { batch.sort() }
                                                for cell in batch {
                                                    let m = Int(cell)
                                                    guard !settled[m] else { continue }
                                                    settled[m] = true
                                                    let du = d[m]
                                                    let su = s[m]
                                                    for k in 0..<offsets.count {
                                                        let v = m + offsets[k]
                                                        guard !settled[v] else { continue }
                                                        let sv = s[v]
                                                        let ceiling = max(su, sv) + 0.5
                                                        let first = overStart[k]
                                                        let last = overStart[k + 1]
                                                        var barred = false
                                                        var o = first
                                                        while o < last {
                                                            if s[m + over[o]] > ceiling {
                                                                barred = true
                                                                break
                                                            }
                                                            o += 1
                                                        }
                                                        var q = betweenStart[k]
                                                        while !barred && q < betweenStart[k + 1] {
                                                            // Between two cells at a corner: barred where both stand above.
                                                            if s[m + pairs[q]] > ceiling
                                                                && s[m + pairs[q + 1]] > ceiling
                                                            {
                                                                barred = true
                                                            }
                                                            q += 2
                                                        }
                                                        if barred { continue }
                                                        let rise = sv - su
                                                        let length = lengths[k]
                                                        let candidate =
                                                            du
                                                            + (rise == 0
                                                                ? length
                                                                : (length * length + rise * rise).squareRoot())
                                                        if candidate < d[v] {
                                                            d[v] = candidate
                                                            let bucket = Int(candidate / width)
                                                            if bucket >= heads.count {
                                                                heads += [Int32](
                                                                    repeating: -1,
                                                                    count: max(
                                                                        bucket + 1 - heads.count, heads.count)
                                                                )
                                                            }
                                                            entryCell.append(Int32(v))
                                                            entryNext.append(heads[bucket])
                                                            heads[bucket] = Int32(entryCell.count - 1)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        var path = [Float](repeating: .infinity, count: count)
        for j in 0..<ny {
            for i in 0..<nx { path[i + nx * j] = distance[(i + pad) + px * (j + pad)] }
        }
        return (path, straight)
    }

    // MARK: - Kingery–Bulmash, tabulated

    /// Kingery–Bulmash's hemispherical surface burst tabulated in ln Z, for a field's million
    /// cells: the scaled arrival, the incident peak, the scaled positive duration and the
    /// Friedlander decay that gives the incident impulse. Below Z 0.2 held there (the arrival from
    /// 0.06); beyond 40 the arrival carried on at the shock's speed there, the peak and impulse in
    /// log-log as `LearnedField.kingeryBulmash`, the duration held.
    struct Table: Sendable {
        struct Entry: Sendable {
            var scaledArrival: Double
            var peak: Double
            var scaledDuration: Double
            var decay: Double
        }

        static let low = log(0.05)
        static let high = log(400.0)
        static let size = 2048
        let entries: [Entry]

        static let shared = Table()

        init() {
            let speed = KingeryBulmash.shockVelocity(at: 40) ?? 343
            let arrival40 = KingeryBulmash.scaledArrival(at: 40) ?? 0.1
            let duration40 = KingeryBulmash.scaledDuration(at: 40) ?? 0.01
            entries = (0..<Self.size).map { k in
                let z = exp(Self.low + (Self.high - Self.low) * Double(k) / Double(Self.size - 1))
                let arrival =
                    z > 40
                    ? arrival40 + (z - 40) / speed
                    : KingeryBulmash.scaledArrival(at: max(z, 0.06)) ?? 0
                let duration = KingeryBulmash.scaledDuration(at: min(max(z, 0.2), 40)) ?? duration40
                // Per unit mass: the root cancels from impulse over peak times duration.
                let kb = LearnedField.kingeryBulmash(z: z, mass: 1)
                let ratio = kb.peak > 0 && duration > 0 ? kb.impulse / (kb.peak * duration) : 0.5
                return Entry(
                    scaledArrival: arrival, peak: kb.peak, scaledDuration: duration, decay: Self.decay(ratio))
            }
        }

        /// The Friedlander exponent b whose pulse's impulse is `ratio` of peak × duration:
        /// 1/b − (1 − e^(−b))/b², 0.5 at b = 0 and falling.
        static func decay(_ ratio: Double) -> Double {
            guard ratio < 0.5 else { return 0 }
            func share(_ b: Double) -> Double { b < 1e-6 ? 0.5 : 1 / b - (1 - exp(-b)) / (b * b) }
            var (lo, hi) = (0.0, 50.0)
            if share(hi) > ratio { return hi }
            for _ in 0..<60 {
                let mid = 0.5 * (lo + hi)
                if share(mid) > ratio { lo = mid } else { hi = mid }
            }
            return 0.5 * (lo + hi)
        }

        func at(logZ: Double) -> Entry {
            let u = (logZ - Self.low) / (Self.high - Self.low) * Double(Self.size - 1)
            let k = min(max(Int(u), 0), Self.size - 2)
            let f = min(max(u - Double(k), 0), 1)
            let (a, b) = (entries[k], entries[k + 1])
            // The peak in log, the rest linearly between the table's points.
            return Entry(
                scaledArrival: a.scaledArrival + f * (b.scaledArrival - a.scaledArrival),
                peak: exp(log(a.peak) + f * (log(b.peak) - log(a.peak))),
                scaledDuration: a.scaledDuration + f * (b.scaledDuration - a.scaledDuration),
                decay: a.decay + f * (b.decay - a.decay))
        }
    }
}
