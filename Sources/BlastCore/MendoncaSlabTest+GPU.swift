import BlastModel
import Foundation
import Metal
import simd

extension MendoncaSlabTest {
    /// Runs `slab`. For studies after the reveal, `adjust` changes the scene and `configure` the air
    /// solver before it is loaded; both leave it as the blind prediction had it by default.
    public static func run(
        device: MTLDevice, slab: Slab, inputs: Inputs, settings: Settings = Settings(),
        adjust: (inout Scenario) -> Void = { _ in }, configure: (BlastSolver) -> Void = { _ in },
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        var scenario = scenario(slab, inputs: inputs, settings: settings)
        adjust(&scenario)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: settings.cellSize)
        solver.configuration.refinement = settings.refinement
        solver.configuration.mappedCharge = settings.mappedCharge
        // The prediction's slabs took their weight as the run started.
        solver.configuration.settlesStructures = false
        configure(solver)
        if settings.airAwake {
            solver.configuration.airSleepThreshold = 0
            solver.configuration.airSleepCrossings = 0
        }
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let s = slabBox(inputs: inputs, settings: settings)
        let h = structure.model.elementSize
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        let bottom = index(s.min.z, 2)
        let top = index(s.max.z, 2)
        let ci = index((s.min.x + s.max.x) / 2, 0)
        let cj = index((s.min.y + s.max.y) / 2, 1)
        let low = index(s.min.y + (inputs.plan - inputs.trestleLength) / 2, 1)
        let high = index(s.max.y - (inputs.plan - inputs.trestleLength) / 2, 1)
        let bearing = Int((settings.bearingWidth / h).rounded())
        let near = index(s.min.x, 0)
        let far = index(s.max.x, 0)
        // Resting on the trestles' timber, free to lift off; held along the span at the near
        // bearing's middle line, and across at the middle of each. With timber bearings, their
        // undersides rest so.
        let seat = settings.timberBearings ? index(s.min.z - settings.railDepth, 2) : bottom
        if settings.softSupportModulus == nil {
            structure.mutateNodes { nodes in
                for j in low...high {
                    for i in Array(near...(near + bearing)) + Array((far - bearing)...far) {
                        guard let n = structure.storedNode(i, j, seat) else { continue }
                        nodes[n].restsOnSupport = true
                        if settings.holdDown { nodes[n].restrain(z: true) }
                        if i == near + bearing / 2 { nodes[n].restrain(x: true) }
                        if j == cj && (i == near + bearing / 2 || i == far - bearing / 2) {
                            nodes[n].restrain(y: true)
                        }
                    }
                }
            }
        }
        func attached(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            for a in (i - 1)...i {
                for b in (j - 1)...j {
                    for c in (k - 1)...k where c >= bottom && c < top {
                        let flag = structure.flag(a, b, c)
                        if flag == .active || flag == .bare { return true }
                    }
                }
            }
            return false
        }
        func centre() -> Float {
            let k = (bottom...top).first { attached(ci, cj, $0) } ?? top
            return -structure.displacement(ci, cj, k).z
        }

        // The gauges sat on the slab and moved with it: each is kept a quarter of the finest air
        // cell beyond the slab's face at its point as it is now, and reads the cell holding that
        // point at the finest level there, or the fluid cell beside it where that cell is solid.
        let finest = solver.grid.cellSize / Float(max(settings.refinement, 1))
        let points = scenario.gauges.map(\.position)
        var placed = points
        var cells = points.map { solver.nearestFluidCell(to: $0) }
        func followSlab() {
            var moved = placed
            for (n, point) in points.enumerated() {
                // The face nearer the gauge as placed: one placed on the top face follows the top.
                let above = point.z >= (s.min.z + s.max.z) / 2
                let (i, j) = (index(point.x, 0), index(point.y, 1))
                guard structure.storedNode(i, j, above ? top : bottom) != nil,
                    attached(i, j, above ? top : bottom)
                else { continue }
                let face = structure.position(i, j, above ? top : bottom).z
                moved[n] = SIMD3(point.x, point.y, face + (above ? 0.25 : -0.25) * finest)
            }
            guard moved != placed else { return }
            placed = moved
            cells = placed.map { solver.grid.cell(containing: $0) }
            solver.moveGauges(cells: cells, points: placed)
        }

        func meanLift() -> Float {
            var weighted: Double = 0
            var total: Double = 0
            structure.mutateNodes { nodes in
                for node in nodes {
                    weighted += Double(node.mass) * Double(node.uz)
                    total += Double(node.mass)
                }
            }
            return Float(weighted / max(total, 1e-12))
        }
        // From the slab at rest under its own weight, as the tests' gauges read.
        solver.settleStructures()
        func bearings() -> SIMD2<Float> {
            SIMD2(
                structure.displacement(near + bearing / 2, cj, bottom).z,
                structure.displacement(far - bearing / 2, cj, bottom).z)
        }
        let rest = (centre: centre(), lift: meanLift(), bearings: bearings())
        var bodyHistory: [SIMD4<Float>] = [.zero]

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = [SIMD2(0, 0)]
        var nextSample = settings.sampleInterval
        var nextReport = 0.01
        var blownUp = false
        var slept: Double?
        while solver.time < settings.duration {
            let result = solver.advance(steps: 4, timeLimit: settings.duration)
            if !result.isStable {
                blownUp = true
                break
            }
            if result.steps == 0 && !solver.airIsAsleep { break }
            if slept == nil && solver.airIsAsleep { slept = solver.time }
            if !solver.airIsAsleep { followSlab() }
            if solver.time >= nextSample - 1e-9 {
                let u = centre() - rest.centre
                if !u.isFinite {
                    blownUp = true
                    break
                }
                history.append(SIMD2(Float(solver.time), u))
                let seats = bearings() - rest.bearings
                bodyHistory.append(SIMD4(Float(solver.time), meanLift() - rest.lift, seats.x, seats.y))
                while nextSample <= solver.time + 1e-9 { nextSample += settings.sampleInterval }
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                progress(
                    String(
                        format: "%4.0f ms: centre %6.2f mm, %d elements failed%@", solver.time * 1000,
                        (history.last?.y ?? 0) * 1000, structure.summary().erodedElements,
                        solver.airIsAsleep ? ", air asleep" : ""))
            }
        }
        let elapsed = ContinuousClock.now - start

        let peak = history.max { $0.y < $1.y } ?? .zero
        let afterPeak = history.filter { $0.x > peak.x }.map(\.y)
        let end = history.last ?? .zero
        let tail = history.filter { $0.x >= end.x - 0.01 }
        let ambient = scenario.atmosphere.pressure
        let gaugeResults = zip(scenario.gauges, solver.gaugeHistories).map { gauge, samples -> GaugeResult in
            let over = samples.map { (time: $0.time, p: $0.pressure - ambient) }
            let arrival = over.first { $0.p > 2e3 }?.time
            var first: Float = 0
            var all: Float = 0
            var inFirst = arrival != nil
            for (a, b) in zip(over, over.dropFirst()) {
                let mean = Float(0.5 * (Double(a.p) + Double(b.p)))
                let dt = Float(b.time - a.time)
                all += dt * max(mean, 0)
                if let arrival, a.time >= arrival, inFirst {
                    if b.p < 0 { inFirst = false } else { first += dt * mean }
                }
            }
            return GaugeResult(
                name: gauge.name, position: gauge.position, peak: over.map(\.p).max() ?? 0,
                arrival: arrival.map(Float.init), impulse: first, impulseAllPositive: all)
        }
        let grid = stride(from: 0.0, through: settings.pressureRecord, by: settings.pressureInterval)
        let pressureHistory = solver.gaugeHistories.map { samples -> [Float] in
            var n = 0
            return grid.map { t in
                guard let first = samples.first, t >= first.time else { return 0 }
                while n + 1 < samples.count && samples[n + 1].time <= t { n += 1 }
                guard n + 1 < samples.count else { return samples[n].pressure - ambient }
                let a = samples[n]
                let b = samples[n + 1]
                let f = Float((t - a.time) / max(b.time - a.time, 1e-12))
                return a.pressure + (b.pressure - a.pressure) * f - ambient
            }
        }
        return Result(
            slab: slab, settings: settings, elementSize: h, elementCount: structure.elementCount,
            cellCount: solver.grid.cellCount, peakDisplacement: peak.y, peakTime: peak.x,
            endDisplacement: end.y,
            endDisplacementMean: tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1)),
            largestRebound: peak.y - (afterPeak.min() ?? peak.y), history: history, bodyHistory: bodyHistory,
            gauges: gaugeResults,
            pressureHistory: pressureHistory,
            damage: damage(structure, slab: s, inputs: inputs, settings: settings), blownUp: blownUp,
            airSleptAt: slept,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Reads the slab's state at the end of the run (see `Damage`).
    static func damage(_ structure: StructureSolver, slab s: Box, inputs: Inputs, settings: Settings)
        -> Damage
    {
        let h = structure.model.elementSize
        let ex = structure.ex
        let ey = structure.ey
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        let bottom = index(s.min.z, 2)
        let top = index(s.max.z, 2)
        let bearing = Int((settings.bearingWidth / h).rounded())
        let near = index(s.min.x, 0)
        let far = index(s.max.x, 0)
        let barLayer = index(s.min.z + inputs.barDepth - h / 2, 2)
        let layers = top - bottom
        func flat(_ i: Int, _ j: Int, _ k: Int) -> Int { i + ex * (j + ey * (k - bottom)) }
        let count = ex * ey * layers
        var flags = [ElementFlag](repeating: .empty, count: count)
        var opening = [Float](repeating: 0, count: count)
        for k in bottom..<top {
            for j in 0..<ey {
                for i in 0..<ex {
                    let f = structure.flag(i, j, k)
                    flags[flat(i, j, k)] = f
                    opening[flat(i, j, k)] = structure.crackOpening(i, j, k) * h
                }
            }
        }
        func intact(_ n: Int) -> Bool { flags[n] == .active && opening[n] < settings.brokenOpening }
        func flood(from seeds: [(Int, Int, Int)], through: (Int, Int, Int) -> Bool) -> Set<Int> {
            var seen = Set<Int>()
            var stack = seeds.filter { through($0.0, $0.1, $0.2) }
            for seed in stack { seen.insert(flat(seed.0, seed.1, seed.2)) }
            while let (i, j, k) = stack.popLast() {
                for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let (a, b, c) = (i + di, j + dj, k + dk)
                    guard a >= 0, a < ex, b >= 0, b < ey, c >= bottom, c < top, through(a, b, c) else {
                        continue
                    }
                    if seen.insert(flat(a, b, c)).inserted { stack.append((a, b, c)) }
                }
            }
            return seen
        }
        let nearColumns = near..<(near + bearing)
        let farColumns = (far - bearing)..<far
        var seeds: [(Int, Int, Int)] = []
        for i in nearColumns { for j in 0..<ey { for k in bottom..<top { seeds.append((i, j, k)) } } }
        let reached = flood(from: seeds) { intact(flat($0, $1, $2)) }
        let concreteSpans = farColumns.contains { i in
            (0..<ey).contains { j in (bottom..<top).contains { k in reached.contains(flat(i, j, k)) } }
        }
        func barsIntact(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            guard k == barLayer else { return false }
            let f = flags[flat(i, j, k)]
            guard f == .active || f == .bare else { return false }
            let ratio = structure.steelRatio(i, j, k)
            let plastic = structure.barPlasticStrain(i, j, k)
            return (0..<2).contains { ratio[$0] > 0 && abs(plastic[$0]) < 1e8 }
        }
        let barReach = flood(
            from: nearColumns.flatMap { i in (0..<ey).map { (i, $0, barLayer) } }, through: barsIntact)
        let barsSpan = farColumns.contains { i in
            (0..<ey).contains { barReach.contains(flat(i, $0, barLayer)) }
        }
        var ruptured = 0
        for j in 0..<ey {
            for i in 0..<ex where flags[flat(i, j, barLayer)] != .empty {
                let plastic = structure.barPlasticStrain(i, j, barLayer)
                if (0..<2).contains(where: { abs(plastic[$0]) >= 1e8 }) { ruptured += 1 }
            }
        }
        // Pieces: active or bare elements joined face to face.
        var assigned = Set<Int>()
        var sizes: [Int] = []
        for k in bottom..<top {
            for j in 0..<ey {
                for i in 0..<ex {
                    let n = flat(i, j, k)
                    guard flags[n] == .active || flags[n] == .bare, !assigned.contains(n) else { continue }
                    let piece = flood(from: [(i, j, k)]) { a, b, c in
                        let f = flags[flat(a, b, c)]
                        return f == .active || f == .bare
                    }
                    assigned.formUnion(piece)
                    sizes.append(piece.count)
                }
            }
        }
        let total = flags.filter { $0 != .empty }.count
        let cellArea = h * h
        func face(_ k: Int) -> [[Float]] {
            (0..<ey).map { j in
                (0..<ex).map { i in
                    let n = flat(i, j, k)
                    return flags[n] == .eroded ? -1 : flags[n] == .bare ? -2 : opening[n] * 1000
                }
            }
        }
        var topCrushed = 0
        for j in 0..<ey {
            for i in 0..<ex where flags[flat(i, j, top - 1)] == .active {
                if structure.plasticStrain(i, j, top - 1) >= 0.0035 { topCrushed += 1 }
            }
        }
        let gone = { (k: Int) in
            (0..<count).filter { $0 / (ex * ey) == k - bottom }.filter {
                flags[$0] == .eroded || flags[$0] == .bare
            }.count
        }
        return Damage(
            concreteSpans: concreteSpans, barsSpan: barsSpan, collapses: !concreteSpans,
            pieces: sizes.filter { $0 >= 10 }.count,
            largestShare: Float(sizes.max() ?? 0) / Float(max(total, 1)),
            removed: flags.filter { $0 == .eroded }.count, bare: flags.filter { $0 == .bare }.count,
            barElementsRuptured: ruptured, topGone: Float(gone(top - 1)) * cellArea,
            topCrushed: Float(topCrushed) * cellArea, bottomGone: Float(gone(bottom)) * cellArea,
            bottomCracks: face(bottom), topCracks: face(top - 1),
            bottomPlan: structure.crackPlan(layer: bottom, threshold: 1e-4 / h),
            topPlan: structure.crackPlan(layer: top - 1, threshold: 1e-4 / h))
    }
}
