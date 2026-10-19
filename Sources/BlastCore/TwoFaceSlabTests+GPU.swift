import BlastModel
import Foundation
import Metal
import simd

extension TwoFaceSlabTests {
    /// Runs either set's scenario, its slab's thickness along `thicknessAxis` with the charge on
    /// the low side, reading `probes` (offsets in the slab's plane from the centre of its far face)
    /// and holding the slab by `hold`.
    static func run(
        device: MTLDevice, scenario: Scenario, slab: Box, thicknessAxis: Int,
        probes: [(String, SIMD3<Float>)],
        cellSize: Float, refinement: Int, duration: Double, chargeTowardsLow: Bool, afterburning: Bool,
        airModel: AirModel?, openFaces: OpenFaces, balloonStart: Bool,
        hold: (StructureSolver, UnsafeMutableBufferPointer<StructureNode>, (Float, Int) -> Int) -> Void,
        prepare: ((StructureSolver) -> Void)?, progress: ((String) -> Void)?,
        inspect: ((StructureSolver, Double) -> Void)? = nil,
        configure: (inout SolverConfiguration) -> Void = { _ in }
    ) throws -> Result {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // The mapped one-dimensional start since 18 October 2026; `balloonStart` keeps the hot-gas
        // balloon these comparisons were recorded on before then (with afterburning; the ideal gas
        // was mapped already).
        solver.configuration.mappedCharge =
            balloonStart ? !afterburning : SolverConfiguration.recommended.mappedCharge
        solver.configuration.afterburning = afterburning
        solver.configuration.openFaces = openFaces
        // As the app's "Afterburning and hot air": both or neither.
        solver.configuration.airModel = airModel ?? (afterburning ? .thermallyPerfect : .idealGas)
        solver.configuration.refinement = refinement
        configure(&solver.configuration)
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let h = structure.model.elementSize
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        structure.mutateNodes { nodes in hold(structure, nodes, index) }
        prepare?(structure)
        // Probes on the far face; displacement along the thickness axis, away from the charge.
        let sign: Float = chargeTowardsLow ? 1 : -1
        let nodes: [(Int, Int, Int)] = probes.map { _, point in
            (index(point.x, 0), index(point.y, 1), index(point.z, 2))
        }
        // From the slab at rest under its own weight, as the tests' gauges read.
        solver.settleStructures()
        func along(_ node: (Int, Int, Int)) -> Float {
            structure.storedNode(node.0, node.1, node.2) != nil
                ? structure.displacement(node.0, node.1, node.2)[thicknessAxis] : 0
        }
        let rest = nodes.map(along)
        let start = ContinuousClock.now
        var histories = [[SIMD2<Float>]](repeating: [], count: probes.count)
        var nextReport = 0.01
        var workAtPeak: [Double]?
        var highest = -Float.infinity
        let ambient = scenario.atmosphere.pressure
        while solver.time < duration {
            let result = solver.advance(steps: 8, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            for (n, node) in nodes.enumerated() {
                histories[n].append(SIMD2(Float(solver.time), sign * (along(node) - rest[n])))
            }
            inspect?(structure, solver.time)
            if structure.tracesWork, let first = histories[0].last?.y, first > highest {
                highest = first
                workAtPeak = structure.workTotals()
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                progress(
                    String(
                        format: "%3.0f ms: %@ %5.1f mm, %d elements failed", solver.time * 1000, probes[0].0,
                        (histories[0].last?.y ?? 0) * 1000, structure.summary().erodedElements))
            }
        }
        let elapsed = ContinuousClock.now - start
        // Damage on each face and through the thickness, by columns along the thickness axis.
        let a = (thicknessAxis + 1) % 3
        let b = (thicknessAxis + 2) % 3
        let dims = [structure.ex, structure.ey, structure.ez]
        let low = index(slab.min[thicknessAxis], thicknessAxis)
        let high = index(slab.max[thicknessAxis], thicknessAxis) - 1
        var front = 0
        var back = 0
        var through = 0
        for p in 0..<dims[a] {
            for q in 0..<dims[b] {
                func cell(_ k: Int) -> (Int, Int, Int) {
                    var c = [0, 0, 0]
                    c[a] = p
                    c[b] = q
                    c[thicknessAxis] = k
                    return (c[0], c[1], c[2])
                }
                let lowCell = cell(low)
                guard structure.flag(lowCell.0, lowCell.1, lowCell.2) != .empty else { continue }
                // Concrete gone: removed, or left as its bars alone, which a hole's bars are.
                let failed = (low...high).map { k -> Bool in
                    let c = cell(k)
                    let flag = structure.flag(c.0, c.1, c.2)
                    return flag == .eroded || flag == .bare
                }
                let lowFace = failed.first == true || structure.damage(lowCell.0, lowCell.1, lowCell.2) >= 1
                let highCell = cell(high)
                let highFace =
                    failed.last == true || structure.damage(highCell.0, highCell.1, highCell.2) >= 1
                if chargeTowardsLow {
                    front += lowFace ? 1 : 0
                    back += highFace ? 1 : 0
                } else {
                    front += highFace ? 1 : 0
                    back += lowFace ? 1 : 0
                }
                if failed.allSatisfy({ $0 }) { through += 1 }
            }
        }
        let cellArea = h * h
        var peaks: [Float] = []
        var rebounds: [Float] = []
        var residuals: [Float] = []
        for history in histories {
            let top = history.max { $0.y < $1.y } ?? .zero
            peaks.append(top.y)
            rebounds.append(-(history.filter { $0.x > top.x }.map(\.y).min() ?? top.y))
            let tail = history.filter { $0.x >= Float(duration) - 0.01 }
            residuals.append(tail.reduce(0) { $0 + $1.y } / Float(max(tail.count, 1)))
        }
        return Result(
            probes: probes.map(\.0), histories: histories, peaks: peaks, rebounds: rebounds,
            residuals: residuals,
            damagedFront: Float(front) * cellArea, damagedBack: Float(back) * cellArea,
            hole: (4 * Float(through) * cellArea / .pi).squareRoot(),
            gaugePeaks: solver.gaugeHistories.map { ($0.map(\.pressure).max() ?? ambient) - ambient },
            gaugeArrivals: solver.gaugeHistories.map { samples in
                Float(samples.first { $0.pressure - ambient > 0.1e6 }?.time ?? 0)
            },
            gaugeImpulses: solver.gaugeHistories.map { samples in
                var total: Float = 0
                for (p, q) in zip(samples, samples.dropFirst()) {
                    total += Float(q.time - p.time) * max(0.5 * (p.pressure + q.pressure) - ambient, 0)
                }
                return total
            },
            workAtPeak: workAtPeak, work: structure.tracesWork ? structure.workTotals() : nil,
            summary: structure.summary(),
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Runs one of Wu's slabs: probes on the underside 300 mm from the centre across the span (as
    /// the measuring point was placed), 300 mm along it, and at the centre.
    public static func run(
        device: MTLDevice, test: WuTest, cellSize: Float = 0.025, refinement: Int = 2,
        elementSize: Float = 0.0125,
        duration: Double = 0.1, heldLengthwise: Bool = false,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        roomy: Bool = false, balloonStart: Bool = false,
        adjust: (inout Scenario) -> Void = { _ in },
        prepare: ((StructureSolver) -> Void)? = nil, progress: ((String) -> Void)? = nil,
        inspect: ((StructureSolver, Double) -> Void)? = nil,
        configure: (inout SolverConfiguration) -> Void = { _ in }
    ) throws -> Result {
        // `roomy`: every open face moved out to `Scenario.structureFaceClearance`, the scene with it.
        let pad = roomy ? scenario(test).openFaceRoom(step: 0.5) : (low: .zero, high: .zero)
        let wuSlab = Self.wuSlab.moved(by: pad.low)
        let wuCentre = Self.wuCentre + pad.low
        var scenario = scenario(test, elementSize: elementSize, pad: pad)
        adjust(&scenario)
        let c = SIMD3(wuCentre.x, wuCentre.y, wuSlab.min.z)
        let probes: [(String, SIMD3<Float>)] = [
            ("300 mm across", c + SIMD3(0, 0.3, 0)), ("300 mm along", c + SIMD3(0.3, 0, 0)), ("centre", c),
        ]
        return try run(
            device: device, scenario: scenario, slab: wuSlab, thicknessAxis: 2, probes: probes,
            cellSize: cellSize,
            refinement: refinement, duration: duration, chargeTowardsLow: false, afterburning: afterburning,
            airModel: airModel, openFaces: openFaces, balloonStart: balloonStart,
            hold: { structure, nodes, index in
                let h = structure.model.elementSize
                let bottom = index(wuSlab.min.z, 2)
                let top = index(wuSlab.max.z, 2)
                let mid = (bottom + top) / 2
                for j in 0...structure.ey {
                    for i in 0...structure.ex {
                        let x = structure.origin.x + Float(i) * h
                        let fromEdge = min(x - wuSlab.min.x, wuSlab.max.x - x)
                        guard fromEdge <= wuBearing + 1e-4 else { continue }
                        // Resting on the beam, held down along the clamps' line half a bearing in.
                        if let n = structure.storedNode(i, j, bottom) { nodes[n].restsOnSupport = true }
                        if abs(fromEdge - wuBearing / 2) <= h / 2 + 1e-4,
                            let n = structure.storedNode(i, j, top)
                        {
                            nodes[n].isHeldDown = true
                        }
                        let first = x - wuSlab.min.x < wuSlab.max.x - x
                        if abs(fromEdge - wuBearing / 2) < h / 2, heldLengthwise || first,
                            let n = structure.storedNode(i, j, mid)
                        {
                            nodes[n].restrain(x: true, y: j == structure.ey / 2)
                        }
                    }
                }
            }, prepare: prepare, progress: progress, inspect: inspect, configure: configure)
    }

    /// Runs one of Wang's slabs: probes on the back face at the five gauges' heights, the edges
    /// held as `edges` says; with `afterburning`, the products burn on in the air, as an
    /// aluminised charge's do.
    public static func run(
        device: MTLDevice, test: WangTest, cellSize: Float = 0.025, refinement: Int = 1,
        elementSize: Float = 0.0125, duration: Double = 0.1, edges: WangEdges = .fixed,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        roomy: Bool = false, balloonStart: Bool = false,
        adjust: (inout Scenario) -> Void = { _ in },
        prepare: ((StructureSolver) -> Void)? = nil, progress: ((String) -> Void)? = nil,
        inspect: ((StructureSolver, Double) -> Void)? = nil,
        configure: (inout SolverConfiguration) -> Void = { _ in }
    ) throws -> Result {
        // `roomy`: every open face moved out to `Scenario.structureFaceClearance`, the scene with it.
        let pad = roomy ? scenario(test).openFaceRoom(step: 0.5) : (low: .zero, high: .zero)
        let wangSlab = Self.wangSlab.moved(by: pad.low)
        let wangCentre = Self.wangCentre + pad.low
        var scenario = scenario(test, elementSize: elementSize, pad: pad)
        adjust(&scenario)
        let back = SIMD3(wangCentre.x, wangSlab.max.y, wangCentre.z)
        let probes = wangGaugeHeights.enumerated().map { n, dz in
            ("D\(n + 1)", back + SIMD3(0, 0, dz))
        }
        return try run(
            device: device, scenario: scenario, slab: wangSlab, thicknessAxis: 1, probes: probes,
            cellSize: cellSize,
            refinement: refinement, duration: duration, chargeTowardsLow: true, afterburning: afterburning,
            airModel: airModel, openFaces: openFaces, balloonStart: balloonStart,
            hold: { structure, nodes, index in
                let h = structure.model.elementSize
                if edges == .hinged {
                    let mid = (index(wangSlab.min.y, 1) + index(wangSlab.max.y, 1)) / 2
                    for k in 0...structure.ez {
                        for i in 0...structure.ex {
                            let p = structure.origin + SIMD3(Float(i), 0, Float(k)) * h
                            let edge = min(
                                min(p.x - wangSlab.min.x, wangSlab.max.x - p.x),
                                min(p.z - wangSlab.min.z, wangSlab.max.z - p.z))
                            if abs(edge - wangEdge / 2) < h / 2 + 1e-4, edge >= 0,
                                let n = structure.storedNode(i, mid, k)
                            {
                                nodes[n].isFixed = true
                            }
                        }
                    }
                    return
                }
                for k in 0...structure.ez {
                    for j in 0...structure.ey {
                        for i in 0...structure.ex {
                            let p = structure.origin + SIMD3(Float(i), Float(j), Float(k)) * h
                            let edge = min(
                                min(p.x - wangSlab.min.x, wangSlab.max.x - p.x),
                                min(p.z - wangSlab.min.z, wangSlab.max.z - p.z))
                            guard edge <= wangEdge + 1e-4, let n = structure.storedNode(i, j, k) else {
                                continue
                            }
                            if edges == .sliding {
                                nodes[n].restrain(y: true)
                            } else {
                                nodes[n].isFixed = true
                            }
                        }
                    }
                }
            }, prepare: prepare, progress: progress, inspect: inspect, configure: configure)
    }
}
