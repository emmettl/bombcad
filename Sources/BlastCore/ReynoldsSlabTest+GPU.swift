import BlastModel
import Foundation
import Metal
import simd

extension ReynoldsSlabTest {
    public static func run(
        device: MTLDevice, slab: Slab, inputs: Inputs, settings: Settings,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let model = model(slab, inputs: inputs, settings: settings)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let load = load(slab, settings: settings)
        solver.appliedLoad = load

        // As `SlabBenchmark.run`: a pin and a roller on lines of nodes of the unloaded face, the
        // span apart about mid-length, or bearings free to lift.
        let h = model.elementSize
        let span = settings.spanInches * inch
        let first = Int(((64 * inch - span) / 2 / h).rounded())
        let second = Int(((64 * inch + span) / 2 / h).rounded())
        let bearing = settings.sample["bearing"].map { $0 > 0.5 ? Float(inch) : nil } ?? settings.bearingWidth
        solver.mutateNodes { nodes in
            func node(_ i: Int, _ j: Int, _ body: (inout StructureNode) -> Void) {
                if let index = solver.storedNode(i, j, 0) { body(&nodes[index]) }
            }
            for j in 0...solver.ey {
                if let width = bearing {
                    let reach = Int((width / 2 / h + 1e-3).rounded(.down))
                    for offset in -reach...reach {
                        for i in [first + offset, second + offset] { node(i, j) { $0.restsOnSupport = true } }
                    }
                    node(first, j) { $0.restrain(x: true) }
                } else {
                    node(first, j) { $0.restrain(x: true, z: true) }
                    node(second, j) { $0.restrain(z: true) }
                }
            }
        }

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.0001 / solver.criticalTimeStep))
        var nextReport = 0.01
        while solver.time < settings.duration - 1e-9 {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z))
            if solver.time >= nextReport {
                nextReport += 0.01
                progress?(
                    String(format: "%.0f ms: %.2f mm", solver.time * 1000, (history.last?.y ?? 0) * 1000))
            }
        }
        let elapsed = start.duration(to: .now)
        let peak = history.max { $0.y < $1.y } ?? .zero
        let end = Float(solver.time)
        let tail = history.filter { $0.x >= end - settings.restWindow }.map(\.y)
        let damage = damage(solver, first: first, second: second, settings: settings)
        return Result(
            slab: slab.name, settings: settings, elementSize: h, elementCount: solver.elementCount,
            appliedPeak: load.history.map(\.y).max() ?? 0, appliedImpulse: load.impulse,
            loadEnds: load.history.last?.x ?? 0,
            history: history, peak: peak.y, peakTime: peak.x,
            residual: tail.reduce(0, +) / Float(max(tail.count, 1)),
            restRange: (tail.max() ?? 0) - (tail.min() ?? 0),
            fails: !damage.concreteSpans || damage.barElementsRuptured > 0, damage: damage,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Reads the slab's state at the end of the run (see `Damage`).
    static func damage(_ solver: StructureSolver, first: Int, second: Int, settings: Settings) -> Damage {
        let h = solver.model.elementSize
        let (ex, ey, ez) = (solver.ex, solver.ey, solver.ez)
        func flat(_ i: Int, _ j: Int, _ k: Int) -> Int { i + ex * (j + ey * k) }
        var flags = [ElementFlag](repeating: .empty, count: ex * ey * ez)
        var opening = [Float](repeating: 0, count: ex * ey * ez)
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex {
                    flags[flat(i, j, k)] = solver.flag(i, j, k)
                    opening[flat(i, j, k)] = solver.crackOpening(i, j, k) * h
                }
            }
        }
        func intact(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            flags[flat(i, j, k)] == .active && opening[flat(i, j, k)] < settings.brokenOpening
        }
        // Flood from the elements beside the pin's line through intact concrete to the roller's.
        var seen = Set<Int>()
        var stack: [(Int, Int, Int)] = []
        for j in 0..<ey {
            for k in 0..<ez where intact(first, j, k) {
                stack.append((first, j, k))
                seen.insert(flat(first, j, k))
            }
        }
        while let (i, j, k) = stack.popLast() {
            for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let (a, b, c) = (i + di, j + dj, k + dk)
                guard a >= 0, a < ex, b >= 0, b < ey, c >= 0, c < ez, intact(a, b, c) else { continue }
                if seen.insert(flat(a, b, c)).inserted { stack.append((a, b, c)) }
            }
        }
        let concreteSpans = (0..<ey).contains { j in
            (0..<ez).contains { seen.contains(flat(second - 1, j, $0)) }
        }
        var ruptured = 0
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex where flags[flat(i, j, k)] != .empty && solver.steelRatio(i, j, k) != .zero {
                    let plastic = solver.barPlasticStrain(i, j, k)
                    if (0..<2).contains(where: { abs(plastic[$0]) >= 1e8 }) { ruptured += 1 }
                }
            }
        }
        let used = (0..<ey).filter { j in flags[flat(ex / 2, j, 0)] != .empty }
        let middle = Float(ex) / 2
        func x(_ i: Int) -> Float { (Float(i) + 0.5 - middle) * h * 1000 }
        var crushed: [Int] = []
        var crushedCount = 0
        for i in 0..<ex {
            var any = false
            for j in used where flags[flat(i, j, ez - 1)] == .active {
                if solver.plasticStrain(i, j, ez - 1) >= 0.0035 {
                    crushedCount += 1
                    any = true
                }
            }
            if any { crushed.append(i) }
        }
        func gone(_ k: Int) -> Int {
            var count = 0
            for j in used {
                for i in 0..<ex where flags[flat(i, j, k)] == .eroded || flags[flat(i, j, k)] == .bare {
                    count += 1
                }
            }
            return count
        }
        let profile = (0..<ex).map { i -> SIMD2<Float> in
            let values = used.map { j -> Float in
                let f = flags[flat(i, j, 0)]
                return f == .eroded || f == .bare ? 0 : opening[flat(i, j, 0)] * 1000
            }
            return SIMD2(x(i), values.reduce(0, +) / Float(max(values.count, 1)))
        }
        var main: [SIMD2<Float>] = []
        for i in profile.indices where profile[i].y > 0.1 {
            let left = i > 0 ? profile[i - 1].y : 0
            let right = i + 1 < profile.count ? profile[i + 1].y : 0
            if profile[i].y >= left && profile[i].y > right { main.append(profile[i]) }
        }
        func face(_ k: Int) -> [[Float]] {
            used.map { j in
                (0..<ex).map { i in
                    let n = flat(i, j, k)
                    return flags[n] == .eroded ? -1 : flags[n] == .bare ? -2 : opening[n] * 1000
                }
            }
        }
        return Damage(
            concreteSpans: concreteSpans, barElementsRuptured: ruptured,
            removed: flags.filter { $0 == .eroded }.count, bare: flags.filter { $0 == .bare }.count,
            blastFaceCrushed: Float(crushedCount) * h * h, blastFaceGone: Float(gone(ez - 1)) * h * h,
            backFaceGone: Float(gone(0)) * h * h,
            crushedFrom: crushed.first.map(x), crushedTo: crushed.last.map(x),
            backFaceProfile: profile, mainCracks: main, backCracks: face(0), blastCracks: face(ez - 1),
            backPlan: solver.crackPlan(layer: 0, threshold: 1e-4 / h),
            blastPlan: solver.crackPlan(layer: ez - 1, threshold: 1e-4 / h))
    }
}
