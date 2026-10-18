import BlastCore
import Foundation
import Metal
import simd

/// `blastbench groundmotion`: the ground shock under Xia et al.'s 1 t TNT surface burst (Applied
/// Sciences 12, 7987, 2022), at their gauges' ranges and depth, against what they measured
/// (`Fixtures/XiaChen2022`). A quarter of the burst in a corner of the domain on the recommended
/// air, its ground streamed to the soil columns and the manuals' estimate a frame at a time; and
/// the same columns driven by Kingery–Bulmash's Friedlander pulse, to see how much is the air.
func runGroundMotion(device: MTLDevice) throws {
    let mass = option("mass").flatMap(Double.init) ?? 1000
    let cells = (option("dx") ?? "0.5,0.25").split(separator: ",").compactMap { Float($0) }
    let ranges = (option("ranges") ?? "21,42").split(separator: ",").compactMap { Float($0) }
    let depth = option("depth").flatMap(Float.init) ?? 0.5
    let density = option("density").flatMap(Float.init) ?? 2050
    let speed = option("speed").flatMap(Float.init) ?? 457
    let ratios = (option("ratios") ?? "1,2,3").split(separator: ",").compactMap { Float($0) }
    let frame = option("frame").flatMap(Double.init) ?? 2e-4
    let step = option("column-step").flatMap(Float.init) ?? SoilProfile.defaultTimeStep
    let out = URL(fileURLWithPath: option("out") ?? ".", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let scale = cbrt(mass)
    let farthest = Double(ranges.max() ?? 42)
    guard let last = KingeryBulmash.point(at: farthest / scale),
        let lastDuration = KingeryBulmash.scaledDuration(at: farthest / scale)
    else { throw CocoaError(.coderInvalidValue) }
    let duration =
        option("time").flatMap(Double.init) ?? (last.scaledArrival + 3 * lastDuration) * scale + 0.01
    let measured = try? JSONDecoder().decode(
        XiaMeasurement.self,
        from: Data(
            contentsOf: URL(fileURLWithPath: option("measured") ?? "Fixtures/XiaChen2022/ground-motion.json"))
    )

    // The soils: elastic, and unloading at each ratio's multiple of the loading speed.
    let soil = GroundSoil(density: density, waveSpeed: speed)
    func spec(_ ratio: Float?, dx: Float) -> GroundShockSpec {
        var spec = GroundShockSpec()
        spec.soil = soil
        spec.points = ranges.map { SIMD2($0, 0.25 * dx) }
        spec.depths = [0, depth]
        spec.arrivalThreshold = 500
        if let ratio {
            spec.model = .column
            spec.profile = SoilProfile(
                layers: [
                    SoilLayer(
                        thickness: 1, density: density, waveSpeed: speed,
                        unloadingWaveSpeed: ratio > 1 ? speed * ratio : nil)
                ], timeStep: step)
        }
        return spec
    }
    // The half-space: the soil with a Poisson's ratio of `--poisson` (0.3), centred on the charge
    // in the domain's corner, with the charge's direct source at its calibrated share and without.
    let poisson = option("poisson").flatMap(Float.init) ?? 0.3
    let shearRatio = ((1 - 2 * poisson) / (2 * (1 - poisson))).squareRoot()
    let halfCell = option("half-cell").flatMap(Float.init)
    // Soil that yields (stage 3): at each `--friction` angle, with `--cohesion` (Pa, 0) and
    // unloading at `--hs-unloading` (2) times the loading speed, the direct source at
    // `--plastic-share` (the default share if left out).
    let frictions = (option("friction") ?? "").split(separator: ",").compactMap { Float($0) }
    let cohesion = option("cohesion").flatMap(Float.init) ?? 0
    let unloading = option("hs-unloading").flatMap(Float.init) ?? 2
    let plasticShare = option("plastic-share").flatMap(Float.init)
    func halfSpec(share: Float?, dx: Float, friction: Float? = nil) -> GroundShockSpec {
        var spec = spec(nil, dx: dx)
        spec.model = .halfspace
        spec.profile = SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 1, density: density, waveSpeed: speed,
                    unloadingWaveSpeed: friction != nil && unloading > 1 ? speed * unloading : nil,
                    shearWaveSpeed: speed * shearRatio, frictionAngle: friction,
                    cohesion: friction != nil ? cohesion : nil)
            ], timeStep: step)
        spec.halfSpace = HalfSpaceSetup(
            centre: .zero, chargeMass: Float(mass), elasticShare: share, cellSize: halfCell)
        return spec
    }
    let models: [(String, (Float) -> GroundShockSpec)] =
        [("estimate", { spec(nil, dx: $0) })]
        + ratios.map { ratio in ("column r=\(format(Double(ratio), 0))", { spec(ratio, dx: $0) }) }
        + (flag("no-halfspace")
            ? []
            : [
                ("halfspace", { halfSpec(share: nil, dx: $0) }),
                ("halfspace, air only", { halfSpec(share: 0, dx: $0) }),
            ])
        + frictions.flatMap { phi -> [(String, (Float) -> GroundShockSpec)] in
            let name = "yielding \(format(Double(phi), 0))°"
            return [
                (name, { halfSpec(share: plasticShare, dx: $0, friction: phi) }),
                (name + ", air only", { halfSpec(share: 0, dx: $0, friction: phi) }),
            ]
        }
    print(
        String(
            format:
                "%.0f kg of TNT on rigid ground; soil %.0f kg/m³ loading at %.0f m/s; gauges at %@ m, %.2f m deep; to %.3f s",
            mass, density, speed, ranges.map { format(Double($0), 0) }.joined(separator: ", "), depth,
            duration))

    var report: [String: Any] = [
        "mass_kg": mass, "density": density, "wave_speed": speed, "depth_m": depth, "frame_s": frame,
        "column_step_s": step,
    ]
    var runs: [[String: Any]] = []

    // Kingery–Bulmash: a Friedlander pulse with the curves' peak, impulse, duration and arrival,
    // framed as the run frames its ground, on cells of the finest size.
    func friedlander(at range: Float) -> (arrival: Double, peak: Double, duration: Double, decay: Double)? {
        let z = Double(range) / scale
        guard let point = KingeryBulmash.point(at: z), let td = KingeryBulmash.scaledDuration(at: z) else {
            return nil
        }
        let (peak, impulse, positive) = (
            point.incidentPressure, point.incidentImpulse(mass: mass), td * scale
        )
        // ∫₀^td P(1 − t/td)e^(−bt/td) dt = P td (b − 1 + e^(−b))/b²: b for the curves' impulse.
        var (low, high) = (1e-3, 20.0)
        for _ in 0..<80 {
            let b = (low + high) / 2
            let value = peak * positive * (b - 1 + exp(-b)) / (b * b)
            if value > impulse { low = b } else { high = b }
        }
        return (point.arrival(mass: mass), peak, positive, (low + high) / 2)
    }
    /// Kingery–Bulmash's ground along the x axis at `time`, a cell at every dx: the Friedlander
    /// pulse's overpressure, its peak once arrived, and its positive impulse in closed form,
    /// ∫₀^s P(1 − u/T)e^(−bu/T) du = PT[(1 − e^(−bX))/b − (1 − e^(−bX)(1 + bX))/b²], X = min(s/T, 1).
    func kbSlice(time: Double, dx: Float) -> GroundSlice {
        let nx = Int32(ceil(Double(ranges.max()! * 1.2 + 10) / Double(dx)))
        var values = [Float](repeating: 0, count: 3 * Int(nx) * 2)
        for k in 0..<Int(nx) {
            guard let f = friedlander(at: (Float(k) + 0.5) * dx) else { continue }
            let s = time - f.arrival
            guard s >= 0 else { continue }
            let p = f.peak * (1 - s / f.duration) * exp(-f.decay * s / f.duration)
            let x = min(s / f.duration, 1)
            let b = f.decay
            let impulse =
                f.peak * f.duration * ((1 - exp(-b * x)) / b - (1 - exp(-b * x) * (1 + b * x)) / (b * b))
            for j in 0..<2 {
                let base = 3 * (k + Int(nx) * j)
                values[base] = Float(p)
                values[base + 1] = Float(f.peak)
                values[base + 2] = Float(impulse)
            }
        }
        return GroundSlice(
            time: time, cellSize: dx, grid: SIMD3(nx, 2, 4), first: .zero, counts: SIMD2(nx, 2),
            values: values, ambientDensity: 1.225, ambientPressure: 101_325, gamma: 1.4)
    }

    for dx in cells {
        var consumers = models.map { GroundShockConsumer(spec: $0.1(dx)) }
        var kbConsumers = models.map { GroundShockConsumer(spec: $0.1(dx)) }
        var air: [String: Any] = [:]
        if !flag("kb-only") {
            // A quarter of the burst, in the corner, as the landscape bench sets it.
            let reach = Float(1.15 * farthest)
            let height = max(0.25 * reach, Float(1.5 * (farthest * scale).squareRoot()))
            var scenario = Scenario(
                name: "Xia 1 t surface burst", domainSize: SIMD3(reach, reach, height), boxes: [],
                charge: Charge(mass: Float(mass / 4), position: .zero))
            scenario.reflectiveFaces = [.zMin, .xMin, .yMin]
            scenario.gauges = ranges.map {
                Gauge("ground \(format(Double($0), 0)) m", at: SIMD3($0, 0.25 * dx, 0.25 * dx))
            }
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var configuration = SolverConfiguration.recommended.balloonStart
            configureRefinement(&configuration)
            configuration.gravity = chosenGravity()
            applyChosenAir(&configuration)
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: dx, configuration: configuration)
            // The ground under every model's points, and round the half-space's disc.
            let regions = consumers.map { $0.region(cellSize: dx) }
            let region = (
                low: regions.map(\.low).reduce(regions[0].low, simd_min),
                high: regions.map(\.high).reduce(regions[0].high, simd_max)
            )
            print(
                String(
                    format: "\n%.3f m cells: %d x %d x %d = %.1fM cells%@", dx, solver.grid.nx,
                    solver.grid.ny,
                    solver.grid.nz, Double(solver.grid.cellCount) / 1e6,
                    configuration.afterburning ? ", afterburning" : ""))
            let started = ContinuousClock.now
            var next = 0.0
            var frames = 0
            var consumed = 0.0
            while true {
                if solver.time >= next - 1e-9 {
                    let clock = ContinuousClock.now
                    let slice = solver.groundSlice(low: region.low, high: region.high)
                    for n in consumers.indices { consumers[n].consume(slice) }
                    consumed += elapsedSeconds(ContinuousClock.now - clock)
                    frames += 1
                    next += frame
                }
                guard solver.time < duration - 1e-9 else { break }
                let result = solver.advance(steps: 64, timeLimit: min(next, duration))
                if result.steps == 0 || !result.isStable {
                    print("  stopped at \(solver.time) s: \(result.isStable ? "no progress" : "unstable")")
                    break
                }
            }
            let elapsed = elapsedSeconds(ContinuousClock.now - started)
            print(
                String(
                    format: "  %d steps, %d frames in %.0f s; the ground models took %.2f s",
                    solver.stepCount, frames,
                    elapsed, consumed))
            let ambient = scenario.atmosphere.pressure
            for (n, history) in solver.gaugeHistories.enumerated() {
                let peak = Double((history.map(\.pressure).max() ?? ambient) - ambient)
                air["gauge \(format(Double(ranges[n]), 0)) m"] = [
                    "peak_pa": peak, "impulse_pa_s": positivePhaseImpulse(history, ambient: ambient),
                    "arrival_s": arrivalTime(history, ambient: ambient),
                ]
            }
            air["steps"] = solver.stepCount
            air["seconds"] = elapsed
        }
        // The same frames from Kingery–Bulmash.
        var t = 0.0
        while t <= duration + 1e-9 {
            let slice = kbSlice(time: t, dx: dx)
            for n in kbConsumers.indices { kbConsumers[n].consume(slice) }
            t += frame
        }

        func summary(_ consumer: GroundShockConsumer) -> [[String: Any]] {
            consumer.result(frameInterval: frame).points.map { point in
                var entry: [String: Any] = [
                    "range_m": Double(point.position.x), "peak_pa": Double(point.peakOverpressure),
                    "impulse_pa_s": Double(point.impulse), "front_speed": Double(point.frontSpeed),
                    "regime": point.regime?.rawValue ?? "none",
                ]
                entry["arrival_s"] = point.arrival
                entry["responses"] = point.responses.map { r -> [String: Any] in
                    var v: [String: Any] = [
                        "depth_m": Double(r.depth), "stress_pa": Double(r.stress),
                        "velocity": Double(r.verticalVelocity),
                        "displacement": Double(r.verticalDisplacement),
                    ]
                    v["acceleration_down"] = r.verticalAcceleration.map { Double($0) }
                    v["acceleration_up"] = r.upwardAcceleration.map { Double($0) }
                    v["horizontal"] = r.horizontalVelocity.map { Double($0) }
                    v["residual"] = r.residualDisplacement.map { Double($0) }
                    v["arrival_s"] = r.arrival
                    if flag("histories") { v["history"] = r.history.map { $0.map(Double.init) } }
                    return v
                }
                return entry
            }
        }
        var run: [String: Any] = ["dx": dx, "air": air]
        run["model"] = Dictionary(uniqueKeysWithValues: zip(models.map(\.0), consumers.map(summary)))
        run["kingery_bulmash"] = Dictionary(
            uniqueKeysWithValues: zip(models.map(\.0), kbConsumers.map(summary)))
        runs.append(run)

        // The table: at each range, what reached the ground and the soil's response at depth.
        for (label, set) in [("the air model", consumers), ("Kingery–Bulmash", kbConsumers)] {
            if label == "the air model", flag("kb-only") { continue }
            let results = set.map { $0.result(frameInterval: frame) }
            print("\n  Fed by \(label):")
            for (n, range) in ranges.enumerated() {
                let point = results[0].points[n]
                print(
                    String(
                        format: "    %.0f m: %.1f kPa, %.0f Pa·s, arrives %.1f ms, front %.0f m/s (%@)",
                        range,
                        point.peakOverpressure / 1000, point.impulse, (point.arrival ?? -1) * 1000,
                        point.frontSpeed,
                        point.regime?.rawValue ?? "none"))
                let truth = measured?.ranges.first { abs($0.range - Double(range)) < 0.5 }
                for (m, result) in results.enumerated() {
                    guard let response = result.points[n].responses.last else { continue }
                    var line = String(
                        format: "      %-20@ v %.4f m/s, d %.2f mm", models[m].0 as NSString,
                        response.verticalVelocity,
                        response.verticalDisplacement * 1000)
                    if let a = response.verticalAcceleration, let up = response.upwardAcceleration {
                        line += String(format: ", a %.1f down %.1f up m/s²", a, up)
                    }
                    if let h = response.horizontalVelocity { line += String(format: ", horizontal %.4f", h) }
                    if let truth {
                        line += String(
                            format: "; measured vertical a %.2f down, v %.4f, horizontal %.4f (integrated)",
                            truth.verticalAccelerationDown, truth.integratedVerticalVelocity,
                            truth.integratedHorizontalSpeed ?? .nan)
                    }
                    print(line)
                }
            }
        }
    }
    report["runs"] = runs
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let tag = cells.map { format(Double($0), 3) }.joined(separator: "-")
    try data.write(to: out.appending(path: "groundmotion-dx\(tag)\(flag("kb-only") ? "-kb" : "").json"))
}

/// What `Fixtures/XiaChen2022/ground-motion.json` holds of each gauge, for the bench's table.
private struct XiaMeasurement: Decodable {
    struct Range: Decodable {
        var range: Double
        var verticalAccelerationDown: Double
        var integratedVerticalVelocity: Double
        var integratedHorizontalSpeed: Double?
    }
    var ranges: [Range]
}

private func elapsedSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

/// `blastbench groundmotion --calibrate`: the half-space's direct source alone, no air, against
/// UFC 3-340-01's direct-induced peak particle velocity, v = f · 160 · (R/W^(1/3))^(−n) ft/s with
/// f = 0.14 for a surface burst, in dense sand (n = 2.5; c_P 1,600 ft/s, 488 m/s; 1,900 kg/m³;
/// Poisson's ratio 0.3), for 1 t of TNT, 0.5 m down. The source's elastic share for the model's
/// peak resultant velocity to equal UFC's at R/W^(1/3) = 8 ft/lb^(1/3) is the calibration.
func runGroundMotionCalibration() throws {
    let mass = option("mass").flatMap(Double.init) ?? 1000
    let probe = option("probe").flatMap(Float.init) ?? 0.01
    let (density, speed, n) = (Float(1900), Float(488), 2.5)
    let scaled = [4.0, 6.0, 8.0, 12.0, 16.0]
    let pounds = cbrt(mass * 2.204_62)
    let ranges = scaled.map { Float($0 * pounds * 0.3048) }
    // Soil that yields, with `--friction` (degrees), `--cohesion` (Pa) and `--hs-unloading`.
    let friction = option("friction").flatMap(Float.init)
    let unloading = option("hs-unloading").flatMap(Float.init) ?? 2
    var spec = GroundShockSpec()
    spec.model = .halfspace
    spec.points = ranges.map { SIMD2($0, 0) }
    spec.depths = [option("depth").flatMap(Float.init) ?? 0.5]
    spec.profile = SoilProfile(
        layers: [
            SoilLayer(
                thickness: 1, density: density, waveSpeed: speed,
                unloadingWaveSpeed: friction != nil && unloading > 1 ? speed * unloading : nil,
                shearWaveSpeed: speed * SoilLayer.defaultShearRatio, frictionAngle: friction,
                cohesion: friction != nil ? option("cohesion").flatMap(Float.init) ?? 0 : nil)
        ])
    let setup = HalfSpaceSetup(
        centre: .zero, chargeMass: Float(mass), elasticShare: probe,
        cellSize: option("half-cell").flatMap(Float.init))
    let engine = try HalfSpaceGroundShock(spec: spec, setup: setup)
    let end = Double(ranges.max()!) / (Double(speed) * Double(SoilLayer.defaultShearRatio) * 0.9) + 0.05
    let empty = [(overpressure: Float, peak: Float, impulse: Float)?](
        repeating: nil, count: engine.grid.radialCells)
    var t = 0.0
    while t < end {
        t += 1e-3
        engine.consume(rings: empty, time: t)
    }
    print(
        String(
            format:
                "Direct source alone, %.0f kg, share %.3g: dense sand %.0f kg/m³ at %.0f m/s, n = %.1f, %.2f m deep; grid %.3f m%@",
            mass, probe, density, speed, n, spec.depths[0], engine.grid.spacing,
            friction.map { String(format: "; yielding at %.0f°, unloading ×%.1f", $0, unloading) } ?? ""))
    var calibrated = Double.nan
    for (k, range) in ranges.enumerated() {
        let model = engine.peakResultant[k]
        let ufc = DirectInducedSource.ufcPeakVelocity(range: Double(range), mass: mass, n: n)
        let share = Double(probe) * pow(ufc / model, 2)
        if scaled[k] == 8 { calibrated = share }
        print(
            String(
                format:
                    "  %5.1f ft/lb^(1/3), %5.1f m: model %.4f m/s, UFC %.4f m/s, ratio %.2f; share for UFC here %.3g",
                scaled[k], range, model, ufc, model / ufc, share))
    }
    print(String(format: "Calibrated share at 8 ft/lb^(1/3): %.3g", calibrated))
    print(
        String(
            format: "Yielding took %.3g J of the source's %.3g J", engine.stepper.yieldingLoss,
            engine.stepper.work))
}
