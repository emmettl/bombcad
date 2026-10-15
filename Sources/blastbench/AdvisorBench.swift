import BlastCore
import Foundation
import Metal
import simd

// The cost-against-fidelity advisor's checks (docs/performance.md, "Choosing settings"):
//
//   blastbench advise --calibrate   (the cost model against the timed runs on record)
//   blastbench advise --time        (and against runs timed now: --cases street,open,landscape)
//   [--out dir]   (default /Volumes/StudioData/bombcad/advisor)

func runAdvise(device: MTLDevice) throws {
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/advisor")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try runCostCalibration(device: device, out: out, time: flag("time"))
}

/// A run timed on record, or to time now.
private struct TimedCase {
    var name: String
    var scenario: Scenario
    var cellSize: Float
    var configuration: SolverConfiguration
    var duration: Double
    /// Seconds recorded, and where.
    var recorded: Double?
    var source: String
}

private func timedCases() -> [TimedCase] {
    func configured(
        refine: Int = 1, levels: Int = 1, threshold: Float = 0.1, memory: Int = 1 << 30, burning: Bool = false
    ) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.refinement = refine
        configuration.refinementLevels = levels
        configuration.refinementThreshold = threshold
        configuration.refinementMemory = memory
        configuration.afterburning = burning
        configuration.airModel = burning ? .thermallyPerfect : .idealGas
        return configuration
    }
    let street = ScenarioPreset.streetCanyon.scenario
    let open = ScenarioPreset.openGround.scenario
    let streetEvent = street.acousticCrossingTime
    let openEvent = open.acousticCrossingTime
    // 500 t in a quarter of a 3.3 km square 0.83 km high, its gauges to Z = 40, to 9.41 s.
    var landscape = Scenario(
        name: "Landscape", domainSize: SIMD3(3334, 3334, 833), boxes: [],
        charge: Charge(mass: 125_000, position: .zero))
    landscape.reflectiveFaces = [.zMin, .xMin, .yMin]
    let perf = "performance.md"
    let large = "large-scenes.md"
    return [
        TimedCase(
            name: "street 0.5 m", scenario: street, cellSize: 0.5, configuration: configured(),
            duration: streetEvent, recorded: 0.3, source: perf),
        TimedCase(
            name: "street 0.25 m", scenario: street, cellSize: 0.25, configuration: configured(),
            duration: streetEvent, recorded: 3.2, source: perf),
        TimedCase(
            name: "street 0.125 m", scenario: street, cellSize: 0.125, configuration: configured(),
            duration: streetEvent, recorded: 46, source: perf),
        TimedCase(
            name: "street 0.25 m burning", scenario: street, cellSize: 0.25,
            configuration: configured(burning: true), duration: streetEvent, recorded: 7.5, source: perf),
        TimedCase(
            name: "street 0.5 m by 2", scenario: street, cellSize: 0.5, configuration: configured(refine: 2),
            duration: streetEvent, recorded: 1.2, source: perf),
        TimedCase(
            name: "street 0.25 m by 2", scenario: street, cellSize: 0.25,
            configuration: configured(refine: 2), duration: streetEvent, recorded: 11.5, source: perf),
        TimedCase(
            name: "street 0.5 m by 2, twice", scenario: street, cellSize: 0.5,
            configuration: configured(refine: 2, levels: 2), duration: streetEvent, recorded: 8.8,
            source: perf),
        TimedCase(
            name: "open 0.25 m", scenario: open, cellSize: 0.25, configuration: configured(),
            duration: openEvent, recorded: 5.5, source: perf),
        TimedCase(
            name: "open 0.125 m", scenario: open, cellSize: 0.125, configuration: configured(),
            duration: openEvent, recorded: 97.6, source: perf),
        TimedCase(
            name: "open 0.5 m by 2", scenario: open, cellSize: 0.5, configuration: configured(refine: 2),
            duration: openEvent, recorded: 1.6, source: perf),
        TimedCase(
            name: "open 0.25 m by 2", scenario: open, cellSize: 0.25, configuration: configured(refine: 2),
            duration: openEvent, recorded: 16.0, source: perf),
        TimedCase(
            name: "open 0.5 m by 2, twice", scenario: open, cellSize: 0.5,
            configuration: configured(refine: 2, levels: 2), duration: openEvent, recorded: 8.1, source: perf),
        TimedCase(
            name: "500 t 16 m", scenario: landscape, cellSize: 16, configuration: configured(),
            duration: 9.41, recorded: 0.5, source: large),
        TimedCase(
            name: "500 t 8 m", scenario: landscape, cellSize: 8, configuration: configured(), duration: 9.41,
            recorded: 8.8, source: large),
        TimedCase(
            name: "500 t 4 m", scenario: landscape, cellSize: 4, configuration: configured(), duration: 9.41,
            recorded: 137, source: large),
        TimedCase(
            name: "500 t 16 m twice, 0.1", scenario: landscape, cellSize: 16,
            configuration: configured(refine: 2, levels: 2, memory: 4 << 30), duration: 9.41, recorded: 1.7,
            source: large),
        TimedCase(
            name: "500 t 16 m twice, 0.02", scenario: landscape, cellSize: 16,
            configuration: configured(refine: 2, levels: 2, threshold: 0.02, memory: 4 << 30), duration: 9.41,
            recorded: 6.4, source: large),
        TimedCase(
            name: "500 t 16 m twice, 0.005", scenario: landscape, cellSize: 16,
            configuration: configured(refine: 2, levels: 2, threshold: 0.005, memory: 4 << 30),
            duration: 9.41, recorded: 25, source: large),
        TimedCase(
            name: "500 t 8 m twice, 0.02", scenario: landscape, cellSize: 8,
            configuration: configured(refine: 2, levels: 2, threshold: 0.02, memory: 8 << 30), duration: 9.41,
            recorded: 52, source: large),
        TimedCase(
            name: "500 t 16 m twice, 0.02 burning", scenario: landscape, cellSize: 16,
            configuration: configured(refine: 2, levels: 2, threshold: 0.02, burning: true), duration: 9.41,
            recorded: 11, source: large),
    ]
}

private func runCostCalibration(device: MTLDevice, out: URL, time: Bool) throws {
    let wanted = option("cases").map { Set($0.split(separator: ",").map(String.init)) }
    print("The cost model against timed runs: estimated seconds on an unloaded M4 Max, and the ratio of")
    print("recorded (or, with --time, measured now) to estimated.")
    print(
        pad("case", 34) + pad("cells", 9) + pad("steps", 8) + pad("estimate", 10) + pad("recorded", 10)
            + pad("ratio", 8) + "now")
    var csv = "case,cells,steps,coarse_updates,fine_updates,levels,estimate_s,recorded_s,measured_s,source\n"
    var ratios: [Double] = []
    for item in timedCases() where wanted.map({ set in set.contains { item.name.hasPrefix($0) } }) ?? true {
        let estimate = RunCost.estimate(
            item.scenario, cellSize: item.cellSize, configuration: item.configuration, duration: item.duration
        )
        var measured: Double?
        if time {
            let solver = try BlastSolver(
                device: device, scenario: item.scenario, cellSize: item.cellSize,
                configuration: item.configuration)
            let clock = ContinuousClock.now
            let result = solver.advance(until: item.duration)
            let elapsed = ContinuousClock.now - clock
            let modelled = estimate.coarseUpdates / (Double(estimate.cells) * Double(estimate.steps))
            print(
                String(
                    format: "  %@: %d steps, %.0f%% of the air swept (the model: %.0f%%)", item.name,
                    result.steps,
                    100 * result.sweptFraction, 100 * modelled))
            measured = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        }
        let reference = measured ?? item.recorded
        if let reference { ratios.append(reference / estimate.seconds) }
        let cells = String(format: "%.1fM", Double(estimate.cells) / 1e6)
        let estimated = String(format: "%.1f s", estimate.seconds)
        let recorded: String = item.recorded.map { String(format: "%.1f s", $0) } ?? ""
        let ratio: String = reference.map { String(format: "%.2f", $0 / estimate.seconds) } ?? ""
        let now: String = measured.map { String(format: "%.1f s", $0) } ?? ""
        var line = pad(item.name, 34) + pad(cells, 9) + pad("\(estimate.steps)", 8)
        line += pad(estimated, 10) + pad(recorded, 10) + pad(ratio, 8) + now
        print(line)
        let recordedField: String = item.recorded.map { "\($0)" } ?? ""
        let measuredField: String = measured.map { "\($0)" } ?? ""
        let levels = item.configuration.refinement > 1 ? item.configuration.refinementLevels : 0
        csv +=
            "\"\(item.name)\",\(estimate.cells),\(estimate.steps),\(estimate.coarseUpdates),\(estimate.fineUpdates),"
        csv += "\(levels),\(estimate.seconds),\(recordedField),"
        csv += "\(measuredField),\(item.source)\n"
    }
    if !ratios.isEmpty {
        let logs = ratios.map(log)
        let mean = exp(logs.reduce(0, +) / Double(logs.count))
        print(
            String(
                format: "Geometric mean of the ratios %.2f; from %.2f to %.2f", mean, ratios.min()!,
                ratios.max()!))
    }
    try csv.write(
        to: out.appending(path: time ? "cost-timed.csv" : "cost-calibration.csv"), atomically: true,
        encoding: .utf8)
}
