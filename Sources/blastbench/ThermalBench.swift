import BlastCore
import Foundation
import Metal
import simd

// `blastbench thermal`.
// Split from main.swift (emmettl/bombcad-work#51).

func runThermal() throws {
    var scenario = option("preset") == nil ? ScenarioPreset.streetCanyon.scenario : chosenScenario()
    if option("preset") == nil, let terrain = option("terrain") { applyTerrain(terrain, to: &scenario) }
    let scene = FragmentScene(scenario)
    var spec = ThermalSpec()
    if let samples = option("samples").flatMap({ Int($0) }) { spec.samples = samples }
    try spec.validate()
    if let model = option("model").flatMap(FireballModel.init(rawValue:)) { spec.fireball = model }
    if let absorption = option("absorption").flatMap({ Float($0) }) { spec.absorption = absorption }
    try spec.validate()
    let count = option("frames").flatMap { Int($0) } ?? 60
    let frames = (0..<count).map { n -> FireballFrame in
        let s = Float(n) / Float(max(count - 1, 1))
        let radius = 0.5 + 7 * s
        let centre = scenario.charge.position + SIMD3(0, 0, radius * 0.5)
        var frame = FireballFrame(
            time: Double(n) * 0.001, volume: 4 / 3 * Double.pi * pow(Double(radius), 3),
            centre: centre, temperature: 2200 - 400 * s, hottest: 2500)
        guard spec.fireball == .volume else { return frame }
        // For the volume, the sphere in cells 0.25 m a side, above the ground, 2,500 K at its
        // centre and cooler outwards.
        let size: Float = 0.25
        let low = simd_max(centre - radius - size, SIMD3(-1, -1, 0))
        let first = SIMD3<Int32>((low / size).rounded(.down))
        let last = SIMD3<Int32>(((centre + radius + size) / size).rounded(.up))
        let counts = last &- first
        var fills: [UInt8] = []
        var temperatures: [UInt16] = []
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    let x = (SIMD3<Float>(first &+ SIMD3(i, j, k)) + 0.5) * size
                    let d = simd_distance(x, centre)
                    fills.append(d <= radius ? 255 : 0)
                    temperatures.append(d <= radius ? UInt16(2500 - 600 * s * d / radius) : 0)
                }
            }
        }
        frame.cells = LuminousCells(
            voxelSize: size, first: first, counts: counts, fills: fills, temperatures: temperatures,
            products: nil)
        return frame
    }
    /// Times the visibility test within each frame.
    final class Timed: ThermalVisibility, @unchecked Sendable {
        let inner: any ThermalVisibility
        var seconds = 0.0
        var rays = 0
        init(_ inner: any ThermalVisibility) { self.inner = inner }
        func visible(_ rays: [ThermalRay]) -> [Bool] {
            let started = ContinuousClock.now
            defer {
                seconds += (ContinuousClock.now - started) / .seconds(1)
                self.rays += rays.count
            }
            return inner.visible(rays)
        }
    }
    let occluders = ThermalExposure.occluders(scene)
    let metal = MetalThermalVisibility(occluders: occluders, terrain: scene.terrain)
    print("Device: \(device.name), ray tracing \(device.supportsRaytracing ? "yes" : "no")")
    if spec.fireball == .volume {
        // The march on the GPU, then on the CPU; each frame's irradiance and what it radiated.
        var answers: [[Float]] = []
        for name in ["GPU", "CPU"] {
            if name == "CPU" { setenv("BOMBCAD_THERMAL_VISIBILITY", "cpu", 1) }
            var exposure = ThermalExposure(spec: spec, scene: scene)
            let started = ContinuousClock.now
            for frame in frames { exposure.add(frame) }
            let total = (ContinuousClock.now - started) / .seconds(1)
            answers.append(exposure.peakIrradiance)
            print(
                "\(name): \(exposure.receivers.count) receivers, \(format(total / Double(count) * 1000, 1)) ms a frame"
                    + (exposure.marchGPUSeconds.map {
                        ", \(format($0 / Double(count) * 1000, 2)) ms of it the GPU's"
                    } ?? ""))
        }
        unsetenv("BOMBCAD_THERMAL_VISIBILITY")
        let largest = answers[1].max() ?? 0
        let worst = zip(answers[0], answers[1]).map { abs($0 - $1) }.max() ?? 0
        print(
            "Largest difference in peak irradiance: \(format(Double(worst / max(largest, 1)) * 100, 3))% of the highest"
        )
        return
    }
    var answers: [[Float]] = []
    for (name, visibility) in [
        ("CPU", CPUThermalVisibility(occluders: occluders, terrain: scene.terrain) as any ThermalVisibility)
    ]
        + (metal.map { [("GPU", $0 as any ThermalVisibility)] } ?? [])
    {
        let timed = Timed(visibility)
        let exposure = ThermalExposure(spec: spec, scene: scene, visibility: timed)
        func processorSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let started = ContinuousClock.now
        let processor = processorSeconds()
        var irradiance: [Float] = []
        for frame in frames { irradiance += exposure.irradiance(frame) }
        let total = (ContinuousClock.now - started) / .seconds(1)
        let busy = processorSeconds() - processor
        answers.append(irradiance)
        print(
            "\(name): \(exposure.receivers.count) receivers, \(timed.rays / count) rays a frame; "
                + "\(format(total / Double(count) * 1000, 1)) ms a frame, "
                + "\(format(timed.seconds / Double(count) * 1000, 1)) ms of it the visibility test; "
                + "\(format(busy / Double(count) * 1000, 1)) ms of the CPU's cores' time a frame; "
                + "mean irradiance \(format(Double(irradiance.reduce(0, +)) / Double(max(irradiance.count, 1)) / 1000, 2)) kW/m²"
        )
    }
    if let metal {
        let usage = metal.usage
        print(
            "GPU: \(usage.gpuFrames) frames there, \(usage.cpuFrames) answered first on the CPU, "
                + "\(format(usage.gpuSeconds / Double(max(usage.gpuFrames, 1)) * 1000, 2)) ms of GPU time a frame"
        )
        let differing = zip(answers[0], answers[1]).filter { $0 != $1 }.count
        print("Receivers' irradiance differing between CPU and GPU: \(differing) of \(answers[0].count)")
    }
}
