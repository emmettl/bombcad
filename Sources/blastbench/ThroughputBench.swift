import BlastCore
import Foundation
import Metal
import simd

// `blastbench throughput`.
// Split from main.swift (emmettl/bombcad-work#51).

func runThroughput() throws {
    let scenario = chosenScenario()
    let event = scenario.acousticCrossingTime
    print("Device: \(device.name)")
    print(
        "Scenario: \(scenario.name), \(Int(scenario.charge.mass)) kg TNT equivalent, "
            + "\(format(event * 1000, 0)) ms event (charge to farthest corner at ambient sound speed)")
    print("")
    print(
        pad("cell", 8) + pad("cells", 12) + pad("memory", 10) + pad("steps/s", 10) + pad("Mcell/s", 10)
            + pad("slow-mo", 10) + pad("steps", 8) + pad("swept", 8) + pad("event wall time", 20))

    var stepsPerMetre = 0.0
    var lastSwept = 1.0
    let cellSizes =
        option("dx").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.5, 0.25, 0.125]
    for cellSize in cellSizes {
        let solver = try makeAirSolver(scenario, cellSize: cellSize)
        let cells = solver.grid.cellCount
        // Run the whole event unless it would take minutes; then time a sample and extrapolate
        // the step count from the previous, coarser run. The sample sweeps every tile, since
        // early steps skip far more air than the event as a whole; the estimate assumes the
        // coarser run's swept fraction.
        let runWholeEvent = cells < 20_000_000 || flag("full")
        if flag("no-skip") || !runWholeEvent {
            solver.configuration.skipStillAir = false
            solver.restart()
        }
        let start = ContinuousClock.now
        var steps = 0
        var swept = 1.0
        if runWholeEvent && solver.configuration.refinement > 1 {
            // Batch by batch, to follow how much of the air is refined.
            var refined = 0.0
            var finer = 0.0
            var (most, finerMost) = (0, 0)
            var substeps = SIMD2<Double>.zero
            var batches = 0
            while solver.time < event {
                let result = solver.advance(steps: 64, timeLimit: event)
                if result.steps == 0 { break }
                swept =
                    (swept * Double(steps) + result.sweptFraction * Double(result.steps))
                    / Double(steps + result.steps)
                steps += result.steps
                refined += Double(result.refinedTiles)
                finer += Double(result.finerRefinedTiles)
                most = max(most, result.refinedTiles)
                finerMost = max(finerMost, result.finerRefinedTiles)
                substeps +=
                    SIMD2(result.firstLevelSubsteps, result.secondLevelSubsteps) * Double(result.steps)
                batches += 1
            }
            substeps /= Double(max(steps, 1))
            let blocks = Double(
                ((solver.grid.nx + 3) / 4) * ((solver.grid.ny + 3) / 4) * ((solver.grid.nz + 3) / 4))
            print(
                "  refined blocks of 4 x 4 x 4 cells: \(format(refined / Double(max(batches, 1)), 0)) on average, "
                    + "at most \(most) (room for \(solver.refinementPatchCapacity)), of \(Int(blocks))"
                    + (solver.configuration.refinementLevels > 1
                        ? "; at the second level \(format(finer / Double(max(batches, 1)), 0)) on average, "
                            + "at most \(finerMost) (room for \(solver.finerRefinementPatchCapacity))" : "")
                    + "; substeps per step \(format(substeps.x, 2))"
                    + (solver.configuration.refinementLevels > 1 ? " and \(format(substeps.y, 2))" : ""))
        } else if runWholeEvent {
            let result = solver.advance(until: event)
            (steps, swept) = (result.steps, result.sweptFraction)
        } else {
            let result = solver.advance(steps: 192)
            (steps, swept) = (result.steps, result.sweptFraction)
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let stepRate = Double(steps) / seconds
        if flag("gauges"), runWholeEvent {
            // `--gauges`: each gauge's peak overpressure and positive impulse over the event.
            let ambient = Double(solver.configuration.ambientPressure)
            for (gauge, samples) in zip(scenario.gauges, solver.gaugeHistories) {
                var impulse = 0.0
                for (a, b) in zip(samples, samples.dropFirst()) {
                    impulse += (b.time - a.time) * max(0.5 * Double(a.pressure + b.pressure) - ambient, 0)
                }
                let peak = (samples.map { Double($0.pressure) }.max() ?? ambient) - ambient
                print(
                    "  gauge \(pad(gauge.name, 16)) \(format(peak / 1000, 1)) kPa, \(format(impulse, 0)) Pa s"
                )
            }
        }

        var totalSteps = Double(steps)
        var wallTime = seconds
        if runWholeEvent {
            stepsPerMetre = Double(steps) * Double(cellSize)
            lastSwept = swept
        } else {
            // The step count scales inversely with cell size.
            totalSteps = stepsPerMetre / Double(cellSize)
            swept = flag("no-skip") ? 1 : lastSwept
            wallTime = totalSteps / stepRate * swept
        }
        let slowMotion = wallTime / event
        printResultValues("\(format(Double(cellSize), 3)) m", solver: solver)
        // The structure's size, for Scripts/perf/run-standard.py's record.
        if let summary = solver.bodySummary() {
            print("  structure: \(summary.activeElements + summary.erodedElements) elements")
        }
        print(
            pad("\(format(Double(cellSize), 3)) m", 8)
                + pad("\(format(Double(cells) / 1e6, 1)) M", 12)
                + pad("\(format(Double(solver.memoryFootprint) / 1e9, 2)) GB", 10)
                + pad(format(stepRate, 0), 10)
                + pad(format(stepRate * Double(cells) / 1e6, 0), 10)
                + pad("\(format(slowMotion, 0))x", 10)
                + pad(format(totalSteps, 0), 8)
                + pad("\(format(100 * swept, 0))%", 8)
                + pad("\(format(wallTime, 1)) s" + (runWholeEvent ? "" : " (est.)"), 20))
    }
}
