import BlastCore
import Foundation
import Metal

/// `blastbench gauging`: Clough and Clubley's 41 kg TNT-equivalent surface burst ("Gauging the
/// fireball", 2013), with boxes 1 m up at 4, 6 and 8 m: when the fireball reaches each box and how
/// large it grows, the gas's temperature at each box and the radiant flux on a gauge facing up
/// on its top, against the paper's cameras, thermocouples and flux gauges (radiant and convective
/// together). Today's air (`recommended`); `--radiate` the gas cooling, `--balloon-start` the
/// balloon, `--dx` (0.25 m), `--time` (1 s).
func runGauging(device: MTLDevice, cooling: RadiativeCooling?) throws {
    let mass: Float = 41
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let duration = option("time").flatMap { Double($0) } ?? 1
    let side: Float = 44
    let centre = SIMD3(side / 2, side / 2, 0)
    let scenario = Scenario(
        name: "Gauging the fireball", domainSize: SIMD3(side, side, side / 2), boxes: [],
        charge: Charge(mass: mass, position: centre))
    var configuration = SolverConfiguration.recommended
    if flag("balloon-start") { configuration.mappedCharge = false }
    configuration.radiativeCooling = cooling
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    var volume = ThermalSpec()
    volume.groundSpacing = side
    // `--hot-air`/`--grey-air`: the gas absorbing as hot air does, or only grey, whatever the default.
    if flag("hot-air") { volume.hotAirAbsorption = true }
    if flag("grey-air") { volume.hotAirAbsorption = false }
    let exposure = ThermalExposure(spec: volume, scene: FragmentScene(scenario))
    let ranges: [Float] = [4, 6, 8]
    // The flux gauges on the boxes' tops, facing up; the thermocouples beside them.
    let gauges = ranges.map {
        ThermalReceiver(position: centre + SIMD3($0, 0, 1.15), normal: SIMD3(0, 0, 1), surface: "gauge")
    }
    let grid = solver.grid
    let cells = ranges.map { grid.cell(containing: centre + SIMD3($0, 0, 1.0)) }
    solver.frameRequest = FrameRequest(thermal: volume)
    var times: [Double] = []
    var t = 0.0005
    while t < duration - 1e-9 {
        times.append(t)
        t += t < 0.01 ? 0.0005 : (t < 0.1 ? 0.0025 : (t < 0.3 ? 0.01 : 0.025))
    }
    times.append(duration)
    print(
        "Gauging the fireball: \(mass) kg TNT on rigid ground, \(cellSize) m cells, to \(duration) s"
            + (configuration.mappedCharge ? ", mapped" : ", the balloon")
            + (cooling == nil ? "" : ", the gas cooling")
            + "; first frame at \(String(format: "%.1f", solver.time * 1e3)) ms")
    var reached = [Double?](repeating: nil, count: ranges.count)
    func range(_ k: Int) -> Float { ranges[k] }
    var peakFlux = [(Float, Double)](repeating: (0, 0), count: ranges.count)
    var peakGas = [(Float, Double)](repeating: (0, 0), count: ranges.count)
    var widest: (Float, Double) = (0, 0)
    var lastLuminous = 0.0
    var radiated = 0.0
    var lastPower: (time: Double, power: Double)?
    var rows: [String] = []
    let shown: Set<Int> = [2, 5, 10, 16, 24, 32, 55, 100, 180, 300, 500, 750, 1000]
    // Before a mapped start's clock, the fireball from the one-dimensional solution.
    var early: [Double: FireballFrame] = [:]
    for frame in solver.earlyFireballFrames(for: volume, at: times) { early[frame.time] = frame }
    for target in times where target > solver.time + 1e-9 || early[target] != nil {
        if early[target] == nil {
            while solver.time < target - 1e-9 {
                let result = solver.advance(steps: 256, timeLimit: target)
                if result.steps == 0 || !result.isStable { break }
            }
        }
        let frame = early[target] ?? solver.fireball(for: volume)
        let now = early[target]?.time ?? solver.time
        let flux = exposure.irradiance(frame, at: gauges)
        let power = exposure.radiatedPower(frame)
        if let lastPower { radiated += 0.5 * (lastPower.power + power) * (now - lastPower.time) }
        lastPower = (now, power)
        // The luminous gas as a hemisphere on the ground.
        let across = 2 * Float(cbrt(3 * frame.volume / (2 * .pi)))
        if across > widest.0 { widest = (across, now) }
        if frame.volume > 0 { lastLuminous = now }
        let gas =
            early[target] != nil
            ? ranges.map { _ in Float(0) }
            : solver.withState { state in
                cells.map { cell -> Float in
                    let c = state[grid.index(cell.i, cell.j, cell.k)]
                    let kinetic =
                        0.5
                        * (c.momentumX * c.momentumX + c.momentumY * c.momentumY + c.momentumZ * c.momentumZ)
                        / c.density
                    let p = configuration.airModel.pressure(
                        density: c.density, internalEnergy: c.energy - kinetic, gamma: configuration.gamma)
                    return configuration.airModel.temperature(density: c.density, pressure: p)
                }
            }
        for k in ranges.indices {
            if reached[k] == nil, across / 2 >= range(k) { reached[k] = now }
            if flux[k] > peakFlux[k].0 { peakFlux[k] = (flux[k], now) }
            if gas[k] > peakGas[k].0 { peakGas[k] = (gas[k], now) }
        }
        let ms = Int((now * 1000).rounded())
        if shown.contains(ms) {
            rows.append(
                String(format: "%6d %8.1f %7.0f %7.0f", ms, across, frame.temperature, frame.hottest)
                    + gas.map { String(format: " %6.0f", $0) }.joined()
                    + flux.map { String(format: " %7.1f", $0 / 1e4) }.joined())
        }
    }
    print("    ms  across m  mean K  hottest   gas K at 4, 6, 8 m     flux W/cm² at 4, 6, 8 m")
    for row in rows { print(row) }
    print(
        String(
            format:
                "Widest %.1f m at %.0f ms (measured 12.5 m at 24 ms); luminous until %.0f ms (measured about 1 s)",
            widest.0, widest.1 * 1e3, lastLuminous * 1e3))
    for (k, range) in ranges.enumerated() {
        let measured = [(3.2, 145.0, 32.0, 480.0), (16, 85, 55, 105), (nil, 30, 180, 74.5)][k]
        print(
            String(format: "  %.0f m: luminous hemisphere reaches it at ", range)
                + (reached[k].map { String(format: "%.1f ms", $0 * 1e3) } ?? "never")
                + (measured.0.map { String(format: " (camera %.1f ms)", $0) } ?? " (never reached)")
                + String(
                    format: "; flux peak %.1f W/cm² at %.0f ms (measured %.0f at %.0f ms, with convection)",
                    peakFlux[k].0 / 1e4, peakFlux[k].1 * 1e3, measured.1, measured.2)
                + String(
                    format: "; gas %.0f K at %.0f ms (thermocouple %.0f °C)", peakGas[k].0,
                    peakGas[k].1 * 1e3, measured.3))
    }
    let charge = Double(scenario.charge.energy)
    print(
        String(format: "Radiated round it %.1f%% of the charge's energy", 100 * radiated / charge)
            + (cooling == nil
                ? "" : String(format: "; the gas lost %.1f%%", 100 * solver.radiatedEnergy / charge)))
}
