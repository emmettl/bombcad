import BlastCore
import Foundation
import Metal
import simd

// Large surface bursts at landscape scale (docs/large-scenes.md):
//
//   blastbench landscape [--mass 500000] [--dx 8,4] [--zmax 40] [--height share] [--refine 2]
//                        [--refine-levels 2] [--refine-threshold 0.1] [--gravity] [--afterburn] [--time s]
//   blastbench landscape --study terrain [--mass 500000] [--dx 4.3] [--gravity] [--refine 2]
//   [--out dir]   (CSV of every gauge and the ground's peak profile; default
//                  /Volumes/StudioData/bombcad/landscape)
//
// A hemispherical TNT surface burst on rigid ground in a quarter of its domain: the charge sits in
// the corner where the two mirrored sides meet the ground, a quarter of it in the domain, so that
// the air sees the whole charge. Gauges stand on the ground along one mirrored side and along the
// diagonal at scaled distances out to `--zmax` m/kg^(1/3), and are compared with the
// Kingery-Bulmash curves.
//
// `--study terrain` is the terrain's shielding study (`blastbench terrain --study shield`, 100 kg
// at x = 5 m before a ridge whose crest is at x = 25 m) with every length scaled by the cube
// root of the charge, so that without gravity it is the same blast; and a valley along the
// centreline with the charge on its floor, for channelling. Each is compared with flat ground.

func runLandscape(device: MTLDevice) throws {
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/landscape")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    if option("study") == "terrain" {
        try runLandscapeTerrain(device: device, out: out)
    } else {
        try runLandscapeBurst(device: device, out: out)
    }
}

private func runLandscapeTerrain(device: MTLDevice, out: URL) throws {
    let mass = option("mass").flatMap(Float.init) ?? 500_000
    let s = cbrt(mass / 100)
    let dx = option("dx").flatMap(Float.init) ?? 0.25 * s
    let domain = SIMD3<Float>(72, 24, 20) * s
    let crest = 25 * s
    let duration = 0.24 * Double(s)
    let gauges: [Float] = [11, 15, 19, 22, 25, 28, 31, 34, 38, 42, 48, 54, 60, 66].map { $0 * s }
    let spacing = min(dx, 0.25 * s)
    print(
        String(
            format:
                "%.0f kg surface burst at x = %.0f m, lengths %.2f times those for 100 kg; %.2f m cells%@",
            mass, 5 * s, s, dx, chosenGravity() == nil ? "" : "; gravity in the air"))
    func run(_ terrain: Terrain?, _ blocks: [Box] = []) throws -> ProfileRun {
        try profileRun(
            device: device, mass: mass, domain: domain, terrain: terrain, blocks: blocks, dx: dx,
            duration: duration, gauges: gauges, chargeAt: 5 * s)
    }
    let flat = try run(nil)
    print(String(format: "flat: %d cells, %d steps, %.1f s", flat.cells, flat.steps, flat.seconds))
    var cases: [(name: String, terrain: Terrain?, blocks: [Box])] = [2, 4, 8].map { h in
        (
            "ridge \(format(Double(h * s), 0)) m",
            .ridge(domain: domain, spacing: spacing, crest: crest, height: h * s, halfWidth: 2 * h * s), []
        )
    }
    cases.append(
        (
            "steep ridge \(format(Double(4 * s), 0)) m",
            .ridge(domain: domain, spacing: spacing, crest: crest, height: 4 * s, halfWidth: 4 * s), []
        ))
    cases.append(
        (
            "wall \(format(Double(4 * s), 0)) m",
            nil, [Box(x: (crest - 0.25 * s)...(crest + 0.25 * s), y: 0...domain.y, height: 4 * s)]
        ))
    // Valleys along x, the centreline their axis: a floor 4 (scaled) metres wide, flanks rising
    // over 8 to a plateau `depth` up.
    for depth: Float in [4, 8] {
        let valley = Terrain.sampled(
            domain: domain, spacing: spacing, source: "valley \(depth * s) m deep"
        ) { p in depth * s * min(1, max(0, abs(p.y) - 2 * s) / (8 * s)) }
        cases.append(("valley \(format(Double(depth * s), 0)) m deep", valley, []))
    }
    var csv =
        "case,x_m,gauge_peak_pa,flat_gauge_peak_pa,gauge_impulse_pa_s,flat_gauge_impulse_pa_s,arrival_s,flat_arrival_s\n"
    for (name, terrain, blocks) in cases {
        let run = try run(terrain, blocks)
        print(String(format: "\n%@: %d steps, %.1f s", name as NSString, run.steps, run.seconds))
        print("  x/scale   x m    peak/flat  impulse/flat  arrival ms (flat)")
        for (g, x) in gauges.enumerated() {
            print(
                String(
                    format: "  %5.1f  %7.0f    %5.2f      %5.2f       %7.1f (%7.1f)", x / s, x,
                    run.gaugePeaks[g] / flat.gaugePeaks[g], run.gaugeImpulses[g] / flat.gaugeImpulses[g],
                    run.arrivals[g] * 1000, flat.arrivals[g] * 1000))
            csv +=
                "\(name),\(x),\(run.gaugePeaks[g]),\(flat.gaugePeaks[g]),\(run.gaugeImpulses[g]),"
                + "\(flat.gaugeImpulses[g]),\(run.arrivals[g]),\(flat.arrivals[g])\n"
        }
    }
    let tag =
        "m\(Int(mass))-dx\(dx)" + (option("refine").map { "-r\($0)" } ?? "")
        + (chosenGravity() == nil ? "" : "-g")
    try csv.write(to: out.appending(path: "terrain-\(tag).csv"), atomically: true, encoding: .utf8)
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
    let scale = cbrt(mass)
    let reach = Float(1.05 * zMax * scale)
    // The open top reflects a little; what it sends down reaches a ground gauge at range R within
    // its positive phase (about 2 W^(1/3) long) unless the top is at least sqrt(R W^(1/3)) up:
    // half as much again, or a quarter of the reach, whichever is higher (`--height` as a share).
    let heightShare =
        option("height").flatMap(Float.init)
        ?? max(0.25, Float(1.5 * (zMax * scale * scale).squareRoot()) / reach)
    let axis = [1, 1.5, 2, 3, 4, 5, 7, 10, 14, 20, 28, 40].filter { $0 <= zMax }
    let diagonal = [2, 5, 14, 40].filter { $0 <= zMax }
    let last = KingeryBulmash.point(at: zMax)!
    let duration =
        option("time").flatMap(Double.init)
        ?? (last.scaledArrival + 1.5 * (KingeryBulmash.scaledDuration(at: zMax) ?? 0.01)) * scale
    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    configuration.gravity = chosenGravity()
    if flag("afterburn") {
        // As the app's "Afterburning and hot air".
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
    }
    print(
        String(
            format:
                "%.0f t of TNT on rigid ground, a quarter of it in a %.0f by %.0f by %.0f m corner; gauges to Z = %.0f (%.0f m), to %.2f s%@",
            mass / 1000, reach, reach, heightShare * reach, zMax, zMax * scale, duration,
            (configuration.gravity == nil ? "" : ", with gravity")
                + (configuration.afterburning ? ", afterburning" : "")))
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
        let setUp = seconds(ContinuousClock.now - built)
        let grid = solver.grid
        print(
            String(
                format:
                    "\n%.2f m cells (%.3f m/kg^(1/3)): %d x %d x %d = %.1fM cells, %.2f GB held, set up in %.1f s",
                dx, Double(dx) / scale, grid.nx, grid.ny, grid.nz, Double(grid.cellCount) / 1e6,
                Double(solver.memoryFootprint) / 1e9, setUp))
        // With `--frames`, the fireball is cut out for a thermal consumer every so many seconds.
        let frameInterval = option("frames").flatMap(Double.init)
        let thermal = ThermalSpec()
        if frameInterval != nil { solver.frameRequest = FrameRequest(thermal: thermal) }
        var nextFrame = frameInterval ?? duration
        var frames = 0
        var frameSeconds = 0.0
        var largestBox = 0
        let started = ContinuousClock.now
        var mostPatches = [Int](repeating: 0, count: 2)
        var reported = 0.0
        while solver.time < duration - 1e-9 {
            let result = solver.advance(steps: 64, timeLimit: min(nextFrame, duration))
            if let frameInterval, solver.time >= min(nextFrame, duration) - 1e-9 {
                let clock = ContinuousClock.now
                let frame = solver.fireball(for: thermal)
                frameSeconds += seconds(ContinuousClock.now - clock)
                frames += 1
                largestBox = max(
                    largestBox,
                    frame.cells.map { Int($0.counts.x) * Int($0.counts.y) * Int($0.counts.z) } ?? 0)
                nextFrame += frameInterval
            }
            for (n, count) in solver.refinementPatchesInUse.enumerated() {
                mostPatches[n] = max(mostPatches[n], count)
            }
            if result.steps == 0 || !result.isStable {
                print("  stopped at \(solver.time) s: \(result.isStable ? "no progress" : "unstable")")
                break
            }
            if solver.time >= reported + duration / 8 {
                reported = solver.time
                print(
                    String(
                        format: "  %.2f s after %d steps, %.0f s", solver.time, solver.stepCount,
                        seconds(ContinuousClock.now - started)))
            }
        }
        let seconds = seconds(ContinuousClock.now - started)
        if frames > 0 {
            print(
                String(
                    format:
                        "  %d fireball frames, %.1f ms each on the CPU after the batch; largest voxel box %d",
                    frames, 1000 * frameSeconds / Double(frames), largestBox))
        }
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
            + (configuration.afterburning ? "-ab" : "")
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

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}
