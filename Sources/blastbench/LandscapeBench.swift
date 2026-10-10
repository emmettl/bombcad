import BlastCore
import Foundation
import Metal
import simd

// Large surface bursts at landscape scale (docs/large-scenes.md):
//
//   blastbench landscape [--mass 500000] [--dx 8,4] [--zmax 40] [--height 0.5] [--refine 2]
//                        [--refine-levels 2] [--refine-threshold 0.1] [--gravity] [--time s]
//   [--out dir]   (CSV of every gauge and the ground's peak profile; default
//                  /Volumes/StudioData/bombcad/landscape)
//
// A hemispherical TNT surface burst on rigid ground in a quarter of its domain: the charge sits in
// the corner where the two mirrored sides meet the ground, a quarter of it in the domain, so that
// the air sees the whole charge. Gauges stand on the ground along one mirrored side and along the
// diagonal at scaled distances out to `--zmax` m/kg^(1/3), and are compared with the
// Kingery-Bulmash curves.

func runLandscape(device: MTLDevice) throws {
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/landscape")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try runLandscapeBurst(device: device, out: out)
}

/// What one run's gauges and ground recorded.
private struct LandscapeGauge {
    var name: String
    var scaledDistance: Double
    var range: Double
    var peak: Double
    var impulse: Double
    var arrival: Double
}

private func runLandscapeBurst(device: MTLDevice, out: URL) throws {
    let mass = option("mass").flatMap(Double.init) ?? 500_000
    let cells = (option("dx") ?? "8").split(separator: ",").compactMap { Float($0) }
    let zMax = option("zmax").flatMap(Double.init) ?? 40
    let heightShare = option("height").flatMap(Float.init) ?? 0.5
    let scale = cbrt(mass)
    let reach = Float(1.05 * zMax * scale)
    let axis = [1, 1.5, 2, 3, 4, 5, 7, 10, 14, 20, 28, 40].filter { $0 <= zMax }
    let diagonal = [2, 5, 14, 40].filter { $0 <= zMax }
    let last = KingeryBulmash.point(at: zMax)!
    let duration =
        option("time").flatMap(Double.init)
        ?? (last.scaledArrival + 1.5 * (KingeryBulmash.scaledDuration(at: zMax) ?? 0.01)) * scale
    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    configuration.gravity = chosenGravity()
    print(
        String(
            format:
                "%.0f t of TNT on rigid ground, a quarter of it in a %.0f by %.0f by %.0f m corner; gauges to Z = %.0f (%.0f m), to %.2f s%@",
            mass / 1000, reach, reach, heightShare * reach, zMax, zMax * scale, duration,
            configuration.gravity == nil ? "" : ", with gravity"))
    let refineTag =
        configuration.refinement > 1
        ? "-r\(configuration.refinement)x\(configuration.refinementLevels)-t\(configuration.refinementThreshold)"
        : ""
    for dx in cells {
        var scenario = Scenario(
            name: "Landscape burst", domainSize: SIMD3(reach, reach, heightShare * reach), boxes: [],
            charge: Charge(mass: Float(mass / 4), position: .zero))
        scenario.reflectiveFaces = [.zMin, .xMin, .yMin]
        var gauges: [(name: String, z: Double, at: SIMD3<Float>)] = axis.map { z in
            ("axis Z \(z)", z, SIMD3(Float(z * scale), 0.25 * dx, 0.25 * dx))
        }
        gauges += diagonal.map { z in
            let side = Float(z * scale / 2.0.squareRoot())
            return ("diagonal Z \(z)", z, SIMD3(side, side, 0.25 * dx))
        }
        scenario.gauges = gauges.map { Gauge($0.name, at: $0.at) }
        let built = ContinuousClock.now
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: dx, configuration: configuration)
        let setUp = ContinuousClock.now - built
        let grid = solver.grid
        print(
            String(
                format:
                    "\n%.2f m cells (%.3f m/kg^(1/3)): %d x %d x %d = %.1fM cells, %.2f GB held, set up in %.1f s",
                dx, Double(dx) / scale, grid.nx, grid.ny, grid.nz, Double(grid.cellCount) / 1e6,
                Double(solver.memoryFootprint) / 1e9, Double(setUp.components.seconds)))
        let started = ContinuousClock.now
        var mostPatches = [Int](repeating: 0, count: 2)
        var reported = 0.0
        while solver.time < duration - 1e-9 {
            let result = solver.advance(steps: 64, timeLimit: duration)
            for (n, count) in solver.refinementPatchesInUse.enumerated() {
                mostPatches[n] = max(mostPatches[n], count)
            }
            if result.steps == 0 || !result.isStable {
                print("  stopped at \(solver.time) s: \(result.isStable ? "no progress" : "unstable")")
                break
            }
            if solver.time >= reported + duration / 8 {
                reported = solver.time
                let elapsed = ContinuousClock.now - started
                print(
                    String(
                        format: "  %.2f s after %d steps, %.0f s", solver.time, solver.stepCount,
                        Double(elapsed.components.seconds)))
            }
        }
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        let ambient = scenario.atmosphere.pressure
        var results: [LandscapeGauge] = []
        for (gauge, history) in zip(gauges, solver.gaugeHistories) {
            let peak = Double((history.map(\.pressure).max() ?? ambient) - ambient)
            results.append(
                LandscapeGauge(
                    name: gauge.name, scaledDistance: gauge.z, range: gauge.z * scale, peak: peak,
                    impulse: positivePhaseImpulse(history, ambient: ambient),
                    arrival: arrivalTime(history, ambient: ambient)))
        }
        print(
            String(
                format: "  %d steps in %.0f s; refined patches at most %@ of %d, %d", solver.stepCount,
                seconds,
                mostPatches.map(String.init).joined(separator: ", "), solver.refinementPatchCapacity,
                solver.finerRefinementPatchCapacity))
        print("  gauge              range m   peak kPa (KB)        impulse Pa s (KB)      arrival ms (KB)")
        var csv =
            "gauge,scaled_distance,range_m,peak_pa,kb_peak_pa,impulse_pa_s,kb_impulse_pa_s,arrival_s,kb_arrival_s\n"
        for result in results {
            let kb = KingeryBulmash.point(at: result.scaledDistance)!
            let kbImpulse = kb.incidentImpulse(mass: mass)
            let kbArrival = kb.arrival(mass: mass)
            print(
                pad(result.name, 18) + pad(format(result.range, 0), 9)
                    + pad(
                        "\(format(result.peak / 1000, 1)) (\(format(kb.incidentPressure / 1000, 1)), \(format(100 * result.peak / kb.incidentPressure, 0))%)",
                        22)
                    + pad(
                        "\(format(result.impulse, 0)) (\(format(kbImpulse, 0)), \(format(100 * result.impulse / kbImpulse, 0))%)",
                        24)
                    + "\(format(result.arrival * 1000, 0)) (\(format(kbArrival * 1000, 0)))")
            csv +=
                "\(result.name),\(result.scaledDistance),\(result.range),\(result.peak),\(kb.incidentPressure),"
                + "\(result.impulse),\(kbImpulse),\(result.arrival),\(kbArrival)\n"
        }
        csv += "# cells \(grid.cellCount), steps \(solver.stepCount), seconds \(seconds), "
        csv += "memory \(solver.memoryFootprint), patches \(mostPatches)\n"
        // The ground's peak overpressure along the mirrored side, every cell, against the curve.
        var profile = "range_m,scaled_distance,peak_pa,kb_peak_pa\n"
        for i in 0..<grid.nx {
            let range = (Double(i) + 0.5) * Double(dx)
            let z = range / scale
            guard let kb = KingeryBulmash.point(at: z) else { continue }
            profile += "\(range),\(z),\(solver.peakOverpressure(i, 0, 0)),\(kb.incidentPressure)\n"
        }
        let tag =
            "m\(Int(mass / 1000))t-dx\(dx)-h\(heightShare)\(refineTag)"
            + (configuration.gravity == nil ? "" : "-g")
        try csv.write(to: out.appending(path: "burst-\(tag).csv"), atomically: true, encoding: .utf8)
        try profile.write(
            to: out.appending(path: "burst-profile-\(tag).csv"), atomically: true, encoding: .utf8)
    }
}

/// The impulse of the first positive phase: from the shock's arrival (a twentieth of its peak)
/// until the pressure first falls back to ambient.
func positivePhaseImpulse(_ history: [GaugeSample], ambient: Float) -> Double {
    let peak = (history.map(\.pressure).max() ?? ambient) - ambient
    guard peak > 0, let start = history.firstIndex(where: { $0.pressure - ambient > 0.05 * peak }) else {
        return 0
    }
    var total = 0.0
    for n in start..<(history.count - 1) {
        let a = Double(history[n].pressure - ambient)
        let b = Double(history[n + 1].pressure - ambient)
        if a <= 0 { break }
        total += 0.5 * (a + max(b, 0)) * (history[n + 1].time - history[n].time)
    }
    return total
}
