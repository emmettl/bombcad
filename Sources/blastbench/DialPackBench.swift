import BlastCore
import Foundation
import Metal
import simd

// `blastbench dialpack`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The thermal radiation's cost a frame on a scene's receivers, with the visibility tested on the
/// CPU and on the GPU, for a fireball growing from 1 to 15 m across over the frames, as the street's
/// does with afterburning; and whether the two agree.
/// Dial Pack, 500 tons of TNT as a sphere resting on the ground (Suffield, 1970), whose thermal
/// radiation DREO Report 642 measured at 600 and 1,700 m: the fireball reckoned frame by frame as
/// the volume, its opaque shape and its equivalent sphere (both at emissivity 1) radiate it to an
/// instrument at each range aimed along the ground at it, and what it radiated, round it and as
/// the gas lost it. `--csv` writes every frame; `Scripts/compare-dial-pack.py` sets it against the
/// report (Samples/DialPack1970).
func runDialPack() throws {
    let tons = option("tons").flatMap { Float($0) } ?? 500
    let mass = tons * 907.185  // short tons
    let cellSize = option("dx").flatMap { Float($0) } ?? 4
    let side = option("domain").flatMap { Float($0) } ?? 480
    let duration = option("time").flatMap { Double($0) } ?? 1
    // TNT at 1,600 kg/m³, its sphere's centre one radius up.
    let radius = cbrt(3 * mass / (4 * .pi * 1600))
    var scenario = Scenario(
        name: "Dial Pack", domainSize: SIMD3(side, side, side / 2), boxes: [],
        // On the mapped start (the default since 20 October 2026; `--mapped` is kept), on the ground as
        // a surface burst, so that it can be mapped: one radius up it is neither on the ground nor
        // three cells clear of it. `--balloon-start`: the balloon one radius up, as first run.
        charge: Charge(mass: mass, position: SIMD3(side / 2, side / 2, flag("balloon-start") ? radius : 0)))
    scenario.gauges = []
    var configuration = SolverConfiguration.recommended.balloonStart
    configureRefinement(&configuration)
    configuration.afterburning = true
    configuration.airModel = .thermallyPerfect
    if let time = option("burn-time").flatMap({ Float($0) }) { configuration.afterburnTime = time / 1000 }
    configuration.radiativeCooling = try chosenCooling()
    configuration.gravity = chosenGravity()
    configuration.mixing = chosenMixing()
    configuration.afterburnLimit = chosenBurnLimit()
    configuration.afterburnMixing = chosenBurnMixing()
    if configuration.afterburnMixing != nil, configuration.mixing == nil {
        configuration.mixing = SubgridMixing()
    }
    // The mapped start, its fireball before the grid's clock from the one-dimensional solution.
    if !flag("balloon-start") { configuration.mappedCharge = true }
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    var volume = ThermalSpec()
    // A receiver or so on the ground: only the instruments are reckoned.
    volume.groundSpacing = side
    // `--hot-air`/`--grey-air`: the gas absorbing as hot air does, or only grey, whatever the default.
    if flag("hot-air") { volume.hotAirAbsorption = true }
    if flag("grey-air") { volume.hotAirAbsorption = false }
    var shape = volume
    shape.fireball = .shape
    var sphere = volume
    sphere.fireball = .sphere
    let scene = FragmentScene(scenario)
    let models = [("volume", volume), ("shape", shape), ("sphere", sphere)].map {
        (name: $0.0, exposure: ThermalExposure(spec: $0.1, scene: scene))
    }
    let ranges: [Float] = [600, 1700]
    // South of ground zero, 1.5 m up, facing it along the ground.
    let points = ranges.map { range in
        ThermalReceiver(
            position: SIMD3(side / 2, side / 2 - range, 1.5), normal: SIMD3(0, 1, 0), surface: "instrument")
    }
    solver.frameRequest = FrameRequest(thermal: volume)
    // `--budget out.csv`: the fireball's energy budget each frame, read back from the state (DialPackBudget).
    var budget = option("budget").map { _ in
        DialPackBudget(
            configuration: configuration, spec: volume, chargeMass: mass,
            ambientTemperature: configuration.ambientPressure / (1.225 * AirModel.gasConstant))
    }
    var frameTimes: [Double] = []
    var t = 0.0005
    while t < duration - 1e-9 {
        frameTimes.append(t)
        t += t < 0.01 ? 0.0005 : (t < 0.1 ? 0.0025 : (t < 0.3 ? 0.01 : 0.025))
    }
    frameTimes.append(duration)
    print(
        String(
            format:
                "Dial Pack: %.0f t of TNT (%.0f short tons), a sphere %.2f m in radius on the ground, %.0f m cells, %.0f by %.0f by %.0f m, to %.2f s%@",
            mass / 1000, tons, radius, cellSize, side, side, side / 2, duration,
            (configuration.radiativeCooling == nil ? "" : ", the gas cooling")
                + (configuration.gravity == nil ? "" : ", with gravity")
                + (configuration.mixing == nil ? "" : ", sub-grid mixing")
                + (configuration.afterburnLimit == nil ? "" : ", afterburning's extinction limit")
                + (configuration.afterburnMixing.map {
                    String(format: ", afterburning limited by the mixing (C %.3g)", $0.coefficient)
                } ?? "")))
    var lines = [
        "time_s,diameter_m,temperature_K,hottest_K,centre_m,radiated_W,gas_lost_J,"
            + models.flatMap { model in ranges.map { "\(model.name)_\(Int($0))_W_m2" } }.joined(
                separator: ",")
    ]
    var last: (time: Double, values: [Float])?
    var fluence = [Double](repeating: 0, count: models.count * ranges.count)
    var peak = [Float](repeating: 0, count: models.count * ranges.count)
    var radiated = 0.0
    var lastPower: (time: Double, power: Double)?
    let started = ContinuousClock.now
    // With gravity, the gas the cloud's rise would be handed at 1 s, everything at least 500 K.
    var early: CloudHandOver?
    // Before a mapped start's clock, the fireball from the one-dimensional solution.
    var oneD: [Double: FireballFrame] = [:]
    // `--early-voxels n --early-samples s`: the early frames' resolution.
    solver.earlyFrameVoxelLimit = option("early-voxels").flatMap { Int($0) }
    solver.earlyFrameSampleCount = option("early-samples").flatMap { Int($0) }
    for frame in solver.earlyFireballFrames(for: volume, at: frameTimes) { oneD[frame.time] = frame }
    for target in frameTimes where oneD[target] != nil || target > solver.time - 1e-9 {
        while oneD[target] == nil, solver.time < target - 1e-9 {
            let result = solver.advance(steps: 256, timeLimit: target)
            if result.steps == 0 || !result.isStable { break }
        }
        if configuration.gravity != nil, early == nil, solver.time >= 1 - 1e-6 {
            early = solver.cloudHandOver(hotterThan: 500)
        }
        let frame = oneD[target] ?? solver.fireball(for: volume)
        let now = oneD[target]?.time ?? solver.time
        if oneD[target] == nil { budget?.record(solver, at: now) }
        var values: [Float] = []
        for model in models { values += model.exposure.irradiance(frame, at: points) }
        let power = models[0].exposure.radiatedPower(frame)
        if let last {
            for n in values.indices {
                fluence[n] += 0.5 * Double(last.values[n] + values[n]) * (now - last.time)
            }
        }
        if let lastPower { radiated += 0.5 * (lastPower.power + power) * (now - lastPower.time) }
        for n in values.indices { peak[n] = max(peak[n], values[n]) }
        last = (now, values)
        lastPower = (now, power)
        // `--frame-detail`: what each frame's voxels hold, the luminous gas's absorptions among it.
        if flag("frame-detail"), let cells = frame.cells {
            let lit = cells.fills.indices.filter { cells.fills[$0] > 0 }
            let air = lit.map { Double(cells.airAbsorption?[$0] ?? 0) }
            let products = lit.map { Double(cells.products?[$0] ?? 0) }
            let hot = lit.map { Double(cells.temperatures[$0]) }
            print(
                String(
                    format:
                        "  %.2f ms: %d voxels of %.2f m lit; hot air absorbs %.3g/m mean, %.3g at most; products %.3g kg/m³ mean; %.0f K hottest voxel",
                    now * 1e3, lit.count, cells.voxelSize, air.reduce(0, +) / Double(max(lit.count, 1)),
                    air.max() ?? 0, products.reduce(0, +) / Double(max(lit.count, 1)), hot.max() ?? 0))
        }
        lines.append(
            [
                String(format: "%.5f", now), String(format: "%.2f", 2 * frame.radius),
                String(format: "%.0f", frame.temperature), String(format: "%.0f", frame.hottest),
                String(format: "%.1f", frame.centre.z), String(format: "%.4g", power),
                String(format: "%.4g", solver.radiatedEnergy),
            ].joined(separator: ",") + "," + values.map { String(format: "%.4g", $0) }.joined(separator: ","))
    }
    let charge = Double(scenario.charge.energy)
    for (m, model) in models.enumerated() {
        let text = ranges.enumerated().map { r, range in
            String(
                format: "%.0f m: %.2f kJ/m², peak %.2f kW/m²", range, fluence[m * ranges.count + r] / 1000,
                peak[m * ranges.count + r] / 1000)
        }.joined(separator: "; ")
        print("  as its \(model.name): \(text)")
    }
    print(
        String(
            format: "  radiated round it, the volume: %.3g J, %.2f%% of the charge's energy%@", radiated,
            100 * radiated / charge,
            configuration.radiativeCooling == nil
                ? ""
                : String(
                    format: "; the gas lost %.3g J, %.2f%%", solver.radiatedEnergy,
                    100 * solver.radiatedEnergy / charge)))
    if let early, let gravity = configuration.gravity, solver.time > early.time {
        // The cloud's integral model, from the 1 s hand-over, against the air model's own gas.
        var spec = CloudSpec()
        spec.lapseRate = Double(gravity.lapseRate)
        spec.spread = false
        spec.duration = solver.time - early.time + 1
        let cloud = CloudResult(spec: spec, handOver: early)
        let late = solver.cloudHandOver(hotterThan: 500)
        let predicted = cloudAt(cloud, solver.time)
        print(
            String(
                format:
                    "  gas at least 500 K: at %.2f s %.0f t at %.0f K, its centre %.1f m up, rising at %.1f m/s; at %.2f s %.0f t, %.1f m up, %.1f m/s; the cloud's rise from the first: %.1f m up, %.1f m/s",
                early.time, early.mass / 1000, early.temperature, Double(early.centre.z), early.riseSpeed,
                solver.time, late.mass / 1000, Double(late.centre.z), late.riseSpeed, predicted.height,
                predicted.speed))
    }
    if let budget, let path = option("budget") {
        let summary = budget.summary(
            charge: charge, endFuel: solver.speciesTotals().fuel, lost: solver.radiatedEnergy)
        for line in summary { print(line) }
        try (budget.lines.joined(separator: "\n") + "\n").write(
            toFile: path, atomically: true, encoding: .utf8)
    }
    print(
        String(
            format: "  %d steps, simulated in %.0f s", solver.stepCount,
            (ContinuousClock.now - started) / .seconds(1)))
    if let path = option("csv") {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
