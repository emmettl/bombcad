import BlastCore
import Foundation
import Metal
import simd

// `blastbench aircost`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Where a refined run's GPU time goes: the GPU time of each of the air's stages over a whole
/// event (each in an encoder of its own, so the sums leave out the gaps between them), the work
/// each did per cell, how closely the patches fit the jumps the threshold flags, and the GPU's
/// cost of an empty dispatch.
/// `blastbench aircost [--preset street] [--dx 0.5] [--rounds 40] [--steps 4] [--skip] [--cut]`: the GPU time
/// of a cell's update under each air: the ideal gas with copying faces (the core), hot air alone,
/// afterburning with the ideal gas, and the recommended air (afterburning, hot air and far-field
/// faces). Every cell is swept (with `--skip`, still air is skipped, as runs do, and the times
/// follow the air the blast has reached). The airs are stepped in turn, a few steps at a time, so
/// that whatever else the GPU is doing falls on them alike: the minimum over the rounds is the
/// unloaded cost, and the quartile and median beside it show how loaded the GPU was.
func runAirCost() throws {
    let scenario = preset(named: option("preset")).scenario
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.5
    let rounds = option("rounds").flatMap { Int($0) } ?? 40
    let batch = option("steps").flatMap { Int($0) } ?? 4
    var core = SolverConfiguration()
    core.skipStillAir = flag("skip")
    var hot = core
    hot.airModel = .thermallyPerfect
    var burning = core
    burning.afterburning = true
    // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
    var recommended = SolverConfiguration.recommended.balloonStart
    recommended.skipStillAir = flag("skip")
    var airs = [
        ("ideal gas, copying faces", core), ("hot air", hot), ("afterburning, ideal gas", burning),
        ("recommended", recommended),
    ]
    // `--cut`: the recommended air again, with the preset's structure outlined by cut cells.
    if flag("cut") {
        var cut = recommended
        cut.structureCutCells = true
        airs.append(("recommended, cut structure", cut))
    }
    // `--refined`: the recommended air refined once by 2 everywhere, and refined but confined to a
    // box the blast never reaches: the refinement's cost a step with no blocks at all.
    if flag("refined") {
        var refined = recommended
        refined.refinement = 2
        refined.refinementThreshold = 0.005
        airs.append(("recommended, refined", refined))
        var empty = refined
        empty.refinementConfinedTo = [RefinementRegion(low: SIMD3(0, 0, 0), high: SIMD3(0.01, 0.01, 0.01))]
        airs.append(("refined, no blocks", empty))
        var half = refined
        half.refinementConfinedTo = [
            RefinementRegion(
                low: .zero,
                high: SIMD3(scenario.domainSize.x / 2, scenario.domainSize.y, scenario.domainSize.z))
        ]
        airs.append(("refined, half the domain", half))
    }
    let solvers = try airs.map { _, configuration in
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        try solver.enableGPUProfiling(true)
        _ = solver.advance(steps: 8)
        return solver
    }
    let cells = Double(solvers[0].grid.cellCount)
    print(
        "\(scenario.name), \(format(Double(cellSize), 3)) m cells, "
            + (flag("skip") ? "still air skipped" : "every cell swept")
            + "; \(rounds) rounds of \(batch) steps")
    var times = [[Double]](repeating: [], count: airs.count)
    var blocks = [Int](repeating: 0, count: airs.count)
    for _ in 0..<rounds {
        for (n, solver) in solvers.enumerated() {
            let result = solver.advance(steps: batch)
            if let air = solver.lastBatchGPUProfile?.airS, result.steps > 0 {
                times[n].append(air / Double(result.steps))
            }
            blocks[n] += result.refinedTiles
        }
    }
    print(
        "\n" + pad("air", 26) + pad("ns/update min", 15) + pad("q25", 8) + pad("median", 8)
            + pad("against core", 14)
            + pad("bytes/cell", 12) + pad("µs/step min", 12) + pad("blocks", 8))
    let base = times[0].min() ?? 1
    for (n, (name, _)) in airs.enumerated() {
        let sorted = times[n].sorted()
        guard let low = sorted.first else { continue }
        // A step sweeps each cell along each axis.
        func perUpdate(_ seconds: Double) -> String { format(seconds / cells / 3 * 1e9, 3) }
        print(
            pad(name, 26) + pad(perUpdate(low), 15) + pad(perUpdate(sorted[sorted.count / 4]), 8)
                + pad(perUpdate(sorted[sorted.count / 2]), 8) + pad(format(low / base, 2), 14)
                + pad(format(Double(solvers[n].memoryFootprint) / cells, 1), 12)
                + pad(format(low * 1e6, 1), 12)
                + pad("\(blocks[n] / rounds)", 8))
    }
}
