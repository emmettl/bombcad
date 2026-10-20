import BlastCore
import Foundation
import Metal
import simd

// `blastbench closeair`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A 1 kg charge burst in the air at each scaled distance above rigid ground, against the
/// Kingery-Bulmash reflected peak and impulse under it (the surface-burst curves at W / 1.8).
/// `--history path` writes the gauge's history at each height to path-Z.csv.
func runCloseAir() throws {
    let distances =
        option("z").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.3, 0.5, 0.75, 1]
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.02
    print(
        "1 kg TNT burst in the air above rigid ground, reflected square on below it; cells \(format(Double(cellSize), 3)) m"
    )
    print(pad("Z", 6) + pad("K-B peak", 12) + pad("model", 14) + pad("K-B impulse", 14) + pad("model", 16))
    var refinement = SolverConfiguration()
    configureRefinement(&refinement)
    let finest =
        refinement.refinement > 1
        ? Int(pow(Double(refinement.refinement), Double(refinement.refinementLevels))) : 1
    for z in distances {
        let height = z
        let size = max(3 * height, 1.2)
        var scenario = Scenario(
            name: "Close-in reflection", domainSize: SIMD3(size, size, 2 * height + 0.4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(size / 2, size / 2, height)),
            gauges: [
                Gauge(
                    "ground",
                    // In the air cell against the ground, refined or not (a quarter of the finest
                    // cell up): a cell further up misses the momentum the gas still carries
                    // towards it.
                    at: SIMD3(
                        size / 2, size / 2,
                        (option("gauge-cells").flatMap { Float($0) } ?? 0.25 / Float(finest)) * cellSize))
            ])
        scenario.reflectiveFaces = .ground
        let solver = try makeAirSolver(scenario, cellSize: cellSize)
        solver.advance(until: Double(height) / 340 + 0.004)
        let samples = solver.gaugeHistories[0]
        let ambient = scenario.atmosphere.pressure
        // `--history path`: the gauge's history, one file per height (path-Z.csv), ms and kPa.
        if let path = option("history") {
            let rows = samples.map { "\($0.time * 1000),\(($0.pressure - ambient) / 1000)" }
            try? (["time_ms,overpressure_kpa"] + rows).joined(separator: "\n")
                .write(toFile: "\(path)-\(format(Double(z), 2)).csv", atomically: true, encoding: .utf8)
        }
        let peak = (samples.map(\.pressure).max() ?? ambient) - ambient
        var impulse: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
        }
        let w = 1.0 / 1.8
        guard let point = KingeryBulmash.point(at: Double(height) / cbrt(w)) else { continue }
        if flag("field") {
            let cell = solver.nearestFluidCell(to: scenario.gauges[0].position)
            print(
                "  field at the gauge: peak \(format(Double(solver.peakOverpressure(cell.i, cell.j, cell.k)) / 1e6, 1)) MPa, impulse \(format(Double(solver.impulse(cell.i, cell.j, cell.k)), 0)) Pa s; \(samples.count) samples"
            )
        }
        print(
            pad(format(Double(z), 2), 6) + pad("\(format(point.reflectedPressure / 1e6, 1)) MPa", 12)
                + pad(
                    "\(format(Double(peak) / 1e6, 1)) (\(format(Double(peak) / point.reflectedPressure * 100, 0))%)",
                    14)
                + pad("\(format(point.reflectedImpulse(mass: w), 0)) Pa s", 14)
                + pad(
                    "\(format(Double(impulse), 0)) (\(format(Double(impulse) / point.reflectedImpulse(mass: w) * 100, 0))%)",
                    16))
    }
}
