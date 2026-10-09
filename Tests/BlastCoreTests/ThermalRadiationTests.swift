import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Thermal radiation from the fireball")
struct ThermalRadiationTests {
    private func scene(blocks: [Box] = [], domain: SIMD3<Float> = SIMD3(100, 100, 50)) -> FragmentScene {
        var scenario = Scenario(
            name: "Thermal", domainSize: domain, boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(50, 50, 10)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    private func sphere(_ centre: SIMD3<Float>, radius: Float, temperature: Float, time: Double = 0)
        -> FireballFrame
    {
        FireballFrame(
            time: time, volume: 4 / 3 * Double.pi * pow(Double(radius), 3), centre: centre,
            temperature: temperature, hottest: temperature)
    }

    private var spec: ThermalSpec {
        var spec = ThermalSpec()
        spec.samples = 2048
        spec.groundSpacing = 10
        return spec
    }

    @Test("A sphere seen face on, or at an angle, gives the view factor (r/d)² cos θ")
    func viewFactor() {
        let exposure = ThermalExposure(spec: spec, scene: scene())
        let frame = sphere(SIMD3(50, 50, 20), radius: 2, temperature: 2000)
        let power = Float(ThermalExposure.stefanBoltzmann * pow(2000, 4))
        let below = SIMD3<Float>(50, 50, 10)
        // Face on: (2/10)².
        let faceOn = exposure.irradiance(
            at: ThermalReceiver(position: below, normal: SIMD3(0, 0, 1), surface: "test"), frame, power: power
        )
        #expect(abs(faceOn / (power * 0.04) - 1) < 0.02, "\(faceOn / (power * 0.04))")
        // Tilted 60° away: half.
        let tilted = SIMD3<Float>(sin(.pi / 3), 0, cos(.pi / 3))
        let atAngle = exposure.irradiance(
            at: ThermalReceiver(position: below, normal: tilted, surface: "test"), frame, power: power)
        #expect(abs(atAngle / (power * 0.02) - 1) < 0.03, "\(atAngle / (power * 0.02))")
        // Facing away: nothing. Inside the fireball: all of it.
        let away = exposure.irradiance(
            at: ThermalReceiver(position: below, normal: SIMD3(0, 0, -1), surface: "test"), frame,
            power: power)
        #expect(away == 0)
        let inside = exposure.irradiance(
            at: ThermalReceiver(position: SIMD3(50, 50, 20.5), normal: SIMD3(0, 0, 1), surface: "test"),
            frame,
            power: power)
        #expect(inside == power)
        // Just outside its surface, nearly all of it, and never more however close.
        for gap: Float in [0.01, 0.001, 0.0001] {
            let skimming = exposure.irradiance(
                at: ThermalReceiver(
                    position: SIMD3(50, 50, 18 - gap), normal: SIMD3(0, 0, 1), surface: "test"),
                frame, power: power)
            #expect(skimming > 0.9 * power && skimming <= power, "\(skimming / power) at \(gap) m")
        }
    }

    @Test("A block between hides the fireball, and the ground clips what is below it")
    func occlusion() {
        let wall = Box(min: SIMD3(54, 40, 0), max: SIMD3(55, 60, 30))
        let exposure = ThermalExposure(spec: spec, scene: scene(blocks: [wall]))
        let frame = sphere(SIMD3(50, 50, 5), radius: 1, temperature: 2000)
        let behind = ThermalReceiver(position: SIMD3(60, 50, 5), normal: SIMD3(-1, 0, 0), surface: "test")
        #expect(exposure.irradiance(at: behind, frame, power: 1) == 0)
        let front = ThermalReceiver(position: SIMD3(53.99, 50, 5), normal: SIMD3(-1, 0, 0), surface: "test")
        #expect(exposure.irradiance(at: front, frame, power: 1) > 0)
        // A hemisphere on the ground, seen from straight above, is half a sphere's surface but
        // presents the same disc: its view factor is that of the whole sphere.
        let open = ThermalExposure(spec: spec, scene: scene())
        let up = ThermalReceiver(position: SIMD3(50, 50, 10), normal: SIMD3(0, 0, -1), surface: "test")
        let whole = open.irradiance(at: up, sphere(SIMD3(50, 50, 3), radius: 1, temperature: 2000), power: 1)
        let half = open.irradiance(at: up, sphere(SIMD3(50, 50, 0), radius: 1, temperature: 2000), power: 1)
        #expect(abs(whole / (1 / 49.0) - 1) < 0.03 && abs(half / 0.01 - 1) < 0.03, "\(whole), \(half)")
    }

    @Test("The fluence is the irradiance integrated over the frames")
    func fluence() {
        var exposure = ThermalExposure(spec: spec, scene: scene())
        let centre = SIMD3<Float>(50, 50, 10)
        for time in [0.0, 0.01, 0.02] {
            exposure.add(sphere(centre, radius: 2, temperature: 1800, time: time))
        }
        exposure.add(FireballFrame(time: 0.03, volume: 0, centre: .zero, temperature: 0, hottest: 0))
        let irradiance = exposure.irradiance(sphere(centre, radius: 2, temperature: 1800))
        let n = try! #require(exposure.receivers.firstIndex { $0.surface == "ground" })
        // Constant for 20 ms, then falling to nothing over the last 10 ms.
        let expected = Double(irradiance[n]) * 0.025
        #expect(abs(Double(exposure.fluence[n]) / expected - 1) < 1e-4)
        #expect(exposure.peakIrradiance[n] == irradiance[n] && irradiance[n] > 0)
        #expect(exposure.result.summary.first?.hasPrefix("Fireball: largest 4.0 m across") == true)
        // The sphere, centred 10 m up, entirely above the ground: σT⁴ 4πr² for 20 ms and half
        // that, on average, for the last 10.
        let power = ThermalExposure.stefanBoltzmann * pow(1800, 4) * 4 * Double.pi * 4
        #expect(abs(exposure.result.radiatedEnergy / (power * 0.025) - 1) < 1e-3)
        #expect(abs(exposure.result.chargeEnergy - 4.184e6) < 1)
    }

    @Test("Receivers cover the ground and the faces the air touches")
    func receivers() {
        var spec = ThermalSpec()
        spec.groundSpacing = 10
        spec.surfaceSpacing = 1
        let block = Box(min: SIMD3(10, 10, 0), max: SIMD3(20, 30, 5))
        let receivers = ThermalExposure.receivers(scene: scene(blocks: [block]), spec: spec)
        let ground = receivers.filter { $0.surface == "ground" }
        // 10 × 10 points, two of them (15, 15) and (15, 25) under the block.
        #expect(ground.count == 98)
        let faces = receivers.filter { $0.surface == "block 0" }
        // Top 10 × 20, sides 2 × 20 × 5 and 2 × 10 × 5; not the underside.
        #expect(faces.count == 200 + 200 + 100)
        #expect(faces.allSatisfy { !block.contains($0.position) })
    }

    @Test("A hot sphere in the air is found as the fireball, its size, place and temperature")
    func extraction() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Hot", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.125)
        let centre = SIMD3<Float>(4, 3.5, 4)
        let pressure: Float = 101_325
        solver.mutateState { cells in
            for k in 0..<64 {
                for j in 0..<64 {
                    for i in 0..<64 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.125
                        let hot = simd_distance(x, centre) < 1.5
                        let t: Float = hot ? 2500 : 300
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: pressure / (287.05 * t), velocity: .zero, pressure: pressure),
                            gamma: 1.4)
                    }
                }
            }
        }
        let fireball = solver.fireball(luminousTemperature: 1500)
        #expect(abs(fireball.radius - 1.5) < 0.03, "\(fireball.radius)")
        #expect(simd_distance(fireball.centre, centre) < 0.01)
        #expect(abs(fireball.temperature - 2500) < 5 && abs(fireball.hottest - 2500) < 5)
        #expect(solver.fireball(luminousTemperature: 3000).volume == 0)
    }

    @Test("Descriptions out of range are refused, and missing fields take their defaults")
    func descriptions() throws {
        let decoded = try JSONDecoder().decode(ThermalSpec.self, from: Data(#"{"emissivity": 0.5}"#.utf8))
        #expect(decoded.emissivity == 0.5 && decoded.luminousTemperature == 1500 && decoded.samples == 128)
        try decoded.validate()
        for change in [
            { (s: inout ThermalSpec) in s.emissivity = 1.5 }, { $0.samples = 4 }, { $0.groundSpacing = 0 },
        ] {
            var spec = ThermalSpec()
            change(&spec)
            #expect(throws: (any Error).self) { try spec.validate() }
        }
    }
}
