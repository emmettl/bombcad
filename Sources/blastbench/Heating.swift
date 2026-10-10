import BlastCore
import Foundation

/// `blastbench heating`: what the receivers' surface heating costs a frame on a scene's receivers
/// (the street's by default), fed a made-up irradiance, and how its peak surface temperatures
/// converge with the grid and the step on a pulse like the afterburning street's.
func runHeating() throws {
    let scenario = option("preset") == nil ? ScenarioPreset.streetCanyon.scenario : chosenScenario()
    let scene = FragmentScene(scenario)
    let spec = ThermalSpec()
    try spec.validate()
    let grids = ThermalExposure.surfaceGrids(scene: scene, spec: spec)
    let count = grids.reduce(0) { $0 + $1.receivers.count }
    let frames = option("frames").flatMap { Int($0) } ?? 171
    func processorSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    // A pulse rising to its peak at 50 ms and gone by 170 ms, each receiver its own share of it,
    // a third of them in shadow throughout.
    func pulse(_ t: Double) -> Double { t < 0.05 ? t / 0.05 : max(0, (0.17 - t) / 0.12) }
    let shares = (0..<count).map { n -> Double in
        let hash = (UInt64(n) &* 0x9E37_79B9_7F4A_7C15) >> 40
        return n % 3 == 0 ? 0 : Double(hash % 1000) / 1000
    }
    for (name, lit) in [("A third in shadow", shares), ("All lit", shares.map { max($0, 0.5) })] {
        var heating = SurfaceHeating(spec: spec.heating, grids: grids, scene: scene)
        var seconds = 0.0
        var busy = 0.0
        for f in 0..<frames {
            let t = Double(f) * 0.001
            let irradiance = lit.map { Float(3e6 * $0 * pulse(t)) }
            let started = ContinuousClock.now
            let processor = processorSeconds()
            heating.advance(to: t, irradiance: irradiance)
            seconds += (ContinuousClock.now - started) / .seconds(1)
            busy += processorSeconds() - processor
        }
        let hottest = heating.peakTemperature.max() ?? 0
        print(
            "\(name): \(count) receivers, \(heating.layout.materials.count) materials; "
                + "\(format(seconds / Double(frames) * 1000, 2)) ms a frame, "
                + "\(format(busy / Double(frames) * 1000, 2)) ms of the CPU's cores' time; hottest \(format(Double(hottest), 0)) K"
        )
    }

    // Convergence: one receiver of each material under 3 MW/m² at the peak, against the finest.
    print("Peak surface temperature rise under the pulse, 3 MW/m² at its peak (K):")
    let ground = Scenario(
        name: "Heating", domainSize: SIMD3(2, 2, 2), boxes: [],
        charge: Charge(mass: 1, position: SIMD3(1, 1, 1)))
    let flat = FragmentScene(ground)
    var single = ThermalSpec()
    single.groundSpacing = 2
    let one = ThermalExposure.surfaceGrids(scene: flat, spec: single)
    func peak(_ material: String, cells: Int, resolved: Float, step: Float) -> Double {
        var heating = single.heating
        heating.ground = material
        heating.cells = cells
        heating.resolvedTime = resolved
        heating.maximumStep = step
        var model = SurfaceHeating(spec: heating, grids: one, scene: flat)
        for f in 0...200 {
            let t = Double(f) * 0.001
            model.advance(to: t, irradiance: [Float(3e6 * pulse(t))])
        }
        return Double(model.peakTemperature[0] - heating.ambient)
    }
    let levels: [(cells: Int, resolved: Float)] = [(16, 1e-4), (32, 2.5e-5), (64, 6.25e-6), (128, 1.5625e-6)]
    let steps: [Float] = [1e-3, 5e-4, 2.5e-4, 1.25e-4]
    for material in [
        "concrete", "masonry", "steel", "glass pane", "timber", "asphalt", "steel sheet", "canvas",
    ] {
        // The grid against the finest grid; the step against a step of 10 µs on the default grid.
        let finest = peak(material, cells: 256, resolved: 4e-7, step: 1e-5)
        let grid = levels.map { peak(material, cells: $0.cells, resolved: $0.resolved, step: 1e-5) }
        let reference = peak(material, cells: 32, resolved: 2.5e-5, step: 1e-5)
        let step = steps.map { peak(material, cells: 32, resolved: 2.5e-5, step: $0) }
        func percent(_ values: [Double], _ against: Double) -> String {
            values.map { format(100 * ($0 / against - 1), 3) + "%" }.joined(separator: " ")
        }
        print(
            "  \(material): \(format(finest, 1)); grid 16/32/64/128 \(percent(grid, finest)); "
                + "step 1/0.5/0.25/0.125 ms \(percent(step, reference))")
    }
}
