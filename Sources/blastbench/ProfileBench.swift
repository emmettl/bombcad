import BlastCore
import Foundation
import Metal
import simd

// `blastbench profile`.
// Split from main.swift (emmettl/bombcad-work#51).

func runProfile() throws {
    var scenario: Scenario
    var cellSize = option("dx").flatMap { Float($0) } ?? 0.5
    var end: Double
    if flag("closein") {
        // `closeair`'s burst at Z 0.5 (1 kg 0.5 m above rigid ground), in a domain `--width` m
        // across (1.5 by default) and as high, at least 1.4 m, run until the blast has crossed it.
        if option("dx") == nil { cellSize = 0.04 }
        let width = option("width").flatMap { Float($0) } ?? 1.5
        let height = max(width, 1.4)
        scenario = Scenario(
            name: "Close-in reflection", domainSize: SIMD3(width, width, height), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(width / 2, width / 2, 0.5)))
        scenario.reflectiveFaces = .ground
        let farthest = simd_length(SIMD3(width / 2, width / 2, height - 0.5))
        end = width == 1.5 ? 0.5 / 340 + 0.004 : Double(farthest) / 340 + 0.004
    } else {
        scenario = preset(named: option("preset")).scenario
        // `--terrain hill|ridge|slope|flat|file`, on the preset's ground (cut cells, or `--staircase`).
        if let terrain = option("terrain") { applyTerrain(terrain, to: &scenario) }
        end = scenario.structure == nil ? scenario.acousticCrossingTime : 0.05
    }
    let solver = try makeAirSolver(scenario, cellSize: cellSize)
    try solver.enableGPUProfiling(true, detailed: true)
    let batch = option("steps").flatMap { Int($0) } ?? 4
    let samples = option("samples").flatMap { Int($0) } ?? 8
    let levels = solver.configuration.refinement > 1 ? solver.configuration.refinementLevels : 0
    let ratio = solver.configuration.refinement
    print(
        "\(scenario.name), \(format(Double(cellSize), 3)) m cells"
            + (levels > 0 ? ", refined by \(ratio) in \(levels) level(s)" : ", unrefined")
            + (solver.configuration.afterburning ? ", afterburning" : "")
            + (solver.hasBody ? ", with a deformable structure" : "") + ", \(format(end * 1000, 1)) ms")
    var stages: [String: Double] = [:]
    var (steps, sweptCells) = (0, 0.0)
    var blocks = SIMD2<Double>.zero
    var substeps = SIMD2<Double>.zero
    var coverage: [RefinementCoverage.Level] = []
    var sampled = 0
    let start = ContinuousClock.now
    while solver.time < end {
        let result = solver.advance(steps: batch, timeLimit: end)
        if result.steps == 0 { break }
        for (name, seconds) in solver.lastBatchGPUProfile?.stages ?? [:] {
            stages[name, default: 0] += seconds
        }
        let n = Double(result.steps)
        steps += result.steps
        sweptCells += result.sweptFraction * Double(solver.grid.cellCount) * n
        blocks += SIMD2(Double(result.refinedTiles), Double(result.finerRefinedTiles)) * n
        substeps += SIMD2(result.firstLevelSubsteps, result.secondLevelSubsteps) * n
        // The fit of the patches, at a few moments through the event.
        if levels > 0, Double(sampled) < Double(samples) * solver.time / end,
            let now = solver.refinementCoverage()
        {
            sampled += 1
            for (l, level) in now.levels.enumerated() {
                if coverage.count <= l { coverage.append(RefinementCoverage.Level()) }
                coverage[l].refined += level.refined
                coverage[l].core += level.core
                coverage[l].missed += level.missed
                coverage[l].sharpCells += level.sharpCells
                coverage[l].refinedCells += level.refinedCells
            }
        }
    }
    let wall = ContinuousClock.now - start
    let total = stages.values.reduce(0, +)
    print(
        "\(steps) steps; \(format(total, 2)) s of GPU time in the stages, \(format(Double(wall.components.seconds), 0)) s"
            + " of wall time (profiling's encoders and coverage counts included)")
    print("\n" + pad("stage", 22) + pad("GPU s", 10) + pad("share", 8) + pad("ns per cell update", 20))
    let axes = Double([solver.grid.nx, solver.grid.ny, solver.grid.nz].filter { $0 > 1 }.count)
    let side = Double(4 * ratio)
    // Cell updates per stage kind: a sweep updates each of its cells once per axis.
    func updates(_ name: String) -> Double? {
        if name.hasSuffix("coarse sweeps") { return sweptCells * axes }
        for l in 1...2 where name.contains("L\(l) sweeps") || name.contains("L\(l) ghosts") {
            let b = l == 1 ? blocks.x : blocks.y
            // A level takes r substeps in each step of the grid above it.
            let s = Double(l == 1 ? ratio : ratio * ratio)
            return b / Double(max(steps, 1)) * side * side * side * axes * s
        }
        return nil
    }
    for (name, seconds) in stages.sorted(by: { $0.value > $1.value }) {
        let perCell = updates(name).map { format($0 > 0 ? seconds / $0 * 1e9 : 0, 2) } ?? ""
        print(
            pad(name.replacingOccurrences(of: "air/", with: ""), 22) + pad(format(seconds, 3), 10)
                + pad(format(100 * seconds / max(total, 1e-12), 1) + "%", 8) + pad(perCell, 20))
    }
    if levels > 0 {
        print(
            "\nRefined blocks on average: \(format(blocks.x / Double(max(steps, 1)), 0))"
                + (levels > 1 ? ", \(format(blocks.y / Double(max(steps, 1)), 0)) at the second level" : "")
                + "; substeps per step \(format(substeps.x / Double(max(steps, 1)), 2))"
                + (levels > 1 ? " and \(format(substeps.y / Double(max(steps, 1)), 2))" : ""))
        for (l, level) in coverage.enumerated() {
            print(
                "Level \(l + 1), over \(sampled) moments: \(format(100 * Double(level.core) / Double(max(level.refined, 1)), 1))%"
                    + " of its refined blocks hold a jump (the rest are margin\(l == 0 && levels > 1 ? " and nesting" : "")),"
                    + " \(format(100 * level.efficiency, 1))% of its refined cells lie in one;"
                    + " \(level.missed) blocks with a jump went unrefined")
        }
    }
    // The GPU's cost of a dispatch of no threadgroups, as substeps not taken and empty levels have.
    if let source = try? device.makeLibrary(source: "kernel void nothing() {}", options: nil),
        let function = source.makeFunction(name: "nothing"),
        let pipeline = try? device.makeComputePipelineState(function: function),
        let queue = device.makeCommandQueue(),
        let arguments = device.makeBuffer(bytes: [UInt32(0), 1, 1], length: 12, options: .storageModeShared),
        let one = device.makeBuffer(bytes: [UInt32(1), 1, 1], length: 12, options: .storageModeShared)
    {
        func time(_ buffer: MTLBuffer, _ count: Int) -> Double {
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
            else {
                return 0
            }
            encoder.setComputePipelineState(pipeline)
            for _ in 0..<count {
                encoder.dispatchThreadgroups(
                    indirectBuffer: buffer, indirectBufferOffset: 0,
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            return (commands.gpuEndTime - commands.gpuStartTime) / Double(count)
        }
        _ = time(arguments, 100)
        print(
            "\nAn indirect dispatch of no threadgroups costs \(format(time(arguments, 20_000) * 1e6, 2)) µs of GPU time,"
                + " of one empty threadgroup \(format(time(one, 20_000) * 1e6, 2)) µs")
    }
}
