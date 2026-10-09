import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite(
    "The receivers' view of the fireball on the GPU's ray-tracing hardware",
    .enabled(if: MTLCreateSystemDefaultDevice()?.supportsRaytracing == true))
struct ThermalVisibilityTests {
    private func scene(_ blocks: [Box], domain: SIMD3<Float> = SIMD3(100, 100, 50)) -> FragmentScene {
        var scenario = Scenario(
            name: "Thermal", domainSize: domain, boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(50, 50, 10)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    private func sphere(_ centre: SIMD3<Float>, radius: Float, temperature: Float) -> FireballFrame {
        FireballFrame(
            time: 0, volume: 4 / 3 * Double.pi * pow(Double(radius), 3), centre: centre,
            temperature: temperature, hottest: temperature)
    }

    /// Sixty blocks of every shape, some overlapping, some thin as a sheet, some off the ground,
    /// with the fireball among them.
    private var cluttered: [Box] {
        var random = SplitMix(seed: 7)
        return (0..<60).map { n in
            let low = SIMD3<Float>(
                random.next(in: 5...90), random.next(in: 5...90), n % 5 == 0 ? random.next(in: 1...8) : 0)
            var size = SIMD3<Float>(
                random.next(in: 0.5...12), random.next(in: 0.5...12), random.next(in: 1...20))
            if n % 7 == 0 { size.x = 0.05 }
            return Box(min: low, max: low + size)
        }
    }

    /// The largest difference between two receivers' irradiances, relative where it is over 1 W/m².
    private func worst(_ expected: [Float], _ found: [Float]) -> Float {
        zip(expected, found).map { abs($0 - $1) / max($0, 1) }.max() ?? 0
    }

    /// The irradiance at every receiver with each visibility test, for a few fireballs.
    private func compare(_ scene: FragmentScene, frames: [FireballFrame], spec: ThermalSpec = ThermalSpec())
        throws
    {
        let occluders = ThermalExposure.occluders(scene)
        let metal = try #require(MetalThermalVisibility(occluders: occluders))
        let gpu = ThermalExposure(spec: spec, scene: scene, visibility: metal)
        let cpu = ThermalExposure(
            spec: spec, scene: scene, visibility: CPUThermalVisibility(occluders: occluders))
        for frame in frames {
            let expected = cpu.irradiance(frame)
            let found = gpu.irradiance(frame)
            #expect(expected.contains { $0 > 0 })
            let difference = worst(expected, found)
            #expect(difference < 1e-5, "\(difference) at a receiver, fireball at \(frame.centre)")
        }
        #expect(metal.usage.gpuFrames + metal.usage.cpuFrames == frames.count)
    }

    @Test("The GPU's test gives the CPU's irradiance on the thermal tests' scenes")
    func testScenes() throws {
        var spec = ThermalSpec()
        spec.groundSpacing = 4
        spec.samples = 64
        // With nothing but the ground in the way, the CPU's test is as quick.
        #expect(MetalThermalVisibility(occluders: []) == nil)
        #expect(ThermalExposure.defaultVisibility(occluders: []) is CPUThermalVisibility)
        try compare(
            scene([Box(min: SIMD3(54, 40, 0), max: SIMD3(55, 60, 30))]),
            frames: [
                sphere(SIMD3(50, 50, 5), radius: 1, temperature: 2000),
                sphere(SIMD3(50, 50, 0), radius: 3, temperature: 1800),
            ], spec: spec)
    }

    @Test("And on sixty blocks of every shape, the street canyon, and a structure's outline")
    func clutteredScenes() throws {
        var spec = ThermalSpec()
        spec.groundSpacing = 5
        spec.surfaceSpacing = 3
        spec.samples = 32
        try compare(
            scene(cluttered),
            frames: [
                sphere(SIMD3(50, 50, 4), radius: 3, temperature: 2000),
                sphere(SIMD3(30, 60, 12), radius: 6, temperature: 1700),
            ], spec: spec)
        try compare(
            FragmentScene(ScenarioPreset.streetCanyon.scenario),
            frames: [sphere(SIMD3(30, 30, 3), radius: 5, temperature: 2000)], spec: spec)
        let box = ScenarioPreset.concreteBox.scenario
        #expect(!FragmentScene(box).structure.isEmpty)
        try compare(
            FragmentScene(box),
            frames: [sphere(box.charge.position + SIMD3(0, 0, 1), radius: 1.5, temperature: 2000)],
            spec: spec)
    }

    @Test("A GPU slow to answer is overtaken by the CPU, with the same answer")
    func busyGPU() throws {
        let scene = scene(cluttered)
        let occluders = ThermalExposure.occluders(scene)
        let metal = try #require(MetalThermalVisibility(occluders: occluders))
        // Every frame held back from the GPU until the CPU has answered.
        metal.stalls = true
        var spec = ThermalSpec()
        spec.groundSpacing = 5
        spec.surfaceSpacing = 3
        spec.samples = 32
        let gpu = ThermalExposure(spec: spec, scene: scene, visibility: metal)
        let cpu = ThermalExposure(
            spec: spec, scene: scene, visibility: CPUThermalVisibility(occluders: occluders))
        let frames = (0..<4).map { sphere(SIMD3(50, 50, 4 + Float($0)), radius: 3, temperature: 2000) }
        for frame in frames {
            #expect(worst(cpu.irradiance(frame), gpu.irradiance(frame)) < 1e-5)
        }
        #expect(metal.usage.cpuFrames == frames.count)
        // And once the GPU is free again, whichever answers first, the answer is the same.
        metal.stalls = false
        #expect(worst(cpu.irradiance(frames[0]), gpu.irradiance(frames[0])) < 1e-5)
        #expect(metal.usage.gpuFrames + metal.usage.cpuFrames == frames.count + 1)
    }
}

/// A small seeded generator, so the cluttered scene is the same each time.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + Float(next() >> 40) / Float(1 << 24) * (range.upperBound - range.lowerBound)
    }
}
