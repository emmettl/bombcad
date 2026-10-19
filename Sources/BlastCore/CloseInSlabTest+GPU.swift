import BlastModel
import Foundation
import Metal
import simd

extension CloseInSlabTest {
    public static func run(
        device: MTLDevice, test: Test, cellSize: Float = 0.05, elementSize: Float = 0.025,
        duration: Double = 0.3,
        refinement: Int = 1, mappedCharge: Bool = true,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        heldLengthwise: Bool = true, stepsPerSample: Int = 16, roomy: Bool = false,
        balloonStart: Bool = false,
        adjust: (inout Scenario) -> Void = { _ in }, progress: ((String) -> Void)? = nil,
        inspect: ((StructureSolver, Double) -> Void)? = nil, prepare: ((StructureSolver) -> Void)? = nil
    ) throws -> Result {
        // `roomy`: every open face moved out to `Scenario.structureFaceClearance`, the scene with
        // it; probes that `adjust` and `inspect` place by the static coordinates do not follow.
        let pad =
            roomy
            ? scenario(test, elementSize: elementSize).openFaceRoom(step: 0.5)
            : (low: SIMD3<Float>.zero, high: SIMD3<Float>.zero)
        let slab = Self.slab.moved(by: pad.low)
        let boltLines = Self.boltLines.map { $0 + pad.low.x }
        let centre = Self.centre + pad.low
        var scenario = scenario(test, elementSize: elementSize, pad: pad)
        adjust(&scenario)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // The mapped one-dimensional start since 18 October 2026; `balloonStart` keeps the hot-gas
        // balloon these comparisons were recorded on before then (with afterburning; the ideal gas
        // was mapped already).
        solver.configuration.mappedCharge = mappedCharge && (balloonStart ? !afterburning : true)
        solver.configuration.afterburning = afterburning
        solver.configuration.openFaces = openFaces
        // As the app's "Afterburning and hot air": both or neither.
        solver.configuration.airModel = airModel ?? (afterburning ? .thermallyPerfect : .idealGas)
        solver.configuration.refinement = refinement
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        // For benchmarks: a hook before the run, such as a shorter step.
        prepare?(structure)
        let h = structure.model.elementSize
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        let mid = (index(slab.min.z, 2) + index(slab.max.z, 2)) / 2
        let topLayer =
            (0...structure.ez).last { k in structure.storedNode(index(centre.x, 0), 0, k) != nil } ?? 0
        let middleJ = index(centre.y, 1)
        structure.mutateNodes { nodes in
            for j in 0...structure.ey {
                for i in 0...structure.ex {
                    let x = structure.origin.x + Float(i) * h
                    // The ends rest on the blocks behind the bolt lines.
                    if x <= boltLines[0] + 1e-4 || x >= boltLines[1] - 1e-4,
                        let n = structure.storedNode(i, j, 0)
                    {
                        nodes[n].restsOnSupport = true
                    }
                    for bolt in boltLines where abs(x - bolt) <= h + 1e-4 {
                        // The clamping bar holds the top face down; the bolts hold the slab at
                        // mid-depth, lengthwise and, at the middle, across.
                        if let n = structure.storedNode(i, j, topLayer) { nodes[n].isHeldDown = true }
                        if abs(x - bolt) < 1e-4, let n = structure.storedNode(i, j, mid) {
                            nodes[n].restrain(x: heldLengthwise || bolt == boltLines[0], y: j == middleJ)
                        }
                    }
                }
            }
        }
        let ci = index(centre.x, 0)
        // From the slab at rest under its own weight, as the tests' deflections were measured.
        solver.settleStructures()
        let rest = (0...structure.ey).map { j in
            structure.storedNode(ci, j, mid) != nil ? -structure.displacement(ci, j, mid).z : 0
        }
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        var nextReport = 0.01
        var impulse: Float = 0
        while solver.time < duration {
            let result = solver.advance(steps: stepsPerSample, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            var across = (0...structure.ey).compactMap { j in
                structure.storedNode(ci, j, mid) != nil
                    ? -structure.displacement(ci, j, mid).z - rest[j] : nil
            }
            across.sort()
            history.append(SIMD2(Float(solver.time), across.isEmpty ? 0 : across[across.count / 2]))
            if solver.time < 0.005 { impulse = max(impulse, Float(-structure.momentum().z)) }
            inspect?(structure, solver.time)
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                progress(
                    String(
                        format: "%3.0f ms: centre %4.0f mm, %d elements failed", solver.time * 1000,
                        history.last!.y * 1000, structure.summary().erodedElements))
            }
        }
        let elapsed = ContinuousClock.now - start
        // Spalled area: on each face, surface elements removed or cracked open past the width at
        // which a loose one would be removed (the cover holds no bars to bridge it); perforation:
        // a column whose concrete is gone through the thickness.
        var top = 0
        var bottom = 0
        var columns = 0
        var through = false
        for j in 0..<structure.ey {
            for i in 0..<structure.ex where structure.flag(i, j, 0) != .empty {
                columns += 1
                // Concrete gone: removed, or left as its bars alone, which a hole's bars are.
                let failed = (0..<topLayer).map { k -> Bool in
                    let flag = structure.flag(i, j, k)
                    return flag == .eroded || flag == .bare
                }
                if failed.first == true || structure.damage(i, j, 0) >= 1 { bottom += 1 }
                if failed.last == true || structure.damage(i, j, topLayer - 1) >= 1 { top += 1 }
                if failed.allSatisfy({ $0 }) { through = true }
            }
        }
        let tail = history.suffix(max(1, history.count / 5))
        let ambient = scenario.atmosphere.pressure
        return Result(
            history: history, peak: history.map(\.y).max() ?? 0,
            permanent: tail.reduce(0) { $0 + $1.y } / Float(max(tail.count, 1)),
            damagedTop: Float(top) / Float(max(columns, 1)),
            damagedBottom: Float(bottom) / Float(max(columns, 1)),
            perforated: through,
            gaugePeaks: zip(scenario.gauges, solver.gaugeHistories).map { gauge, samples in
                (gauge.name, (samples.map(\.pressure).max() ?? ambient) - ambient)
            },
            gaugeImpulses: solver.gaugeHistories.map { samples in
                var total: Float = 0
                for (a, b) in zip(samples, samples.dropFirst()) {
                    total += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
                }
                return total
            },
            gaugeHistories: solver.gaugeHistories, impulse: impulse, summary: structure.summary(),
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
