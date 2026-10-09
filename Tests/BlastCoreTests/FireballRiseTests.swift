import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("The fireball's rise and cloud")
struct FireballRiseTests {
    private let ambientTemperature = 288.15
    private let ambientPressure = 101_325.0
    private var ambientDensity: Double { ambientPressure / (CloudRise.gasConstant * ambientTemperature) }

    /// Air of one temperature and pressure at every height: no stratification, and no cooling
    /// by expansion as the cloud rises.
    private var uniform: (Double) -> (temperature: Double, pressure: Double) {
        { [ambientTemperature, ambientPressure] _ in (ambientTemperature, ambientPressure) }
    }

    /// A sphere of gas `excess` times as hot as the air, of `radius`, centred `height` up and
    /// rising at `riseSpeed` at `time`.
    private func handOver(
        radius: Double, height: Double, excess: Double, riseSpeed: Double = 0, time: Double = 0
    ) -> CloudHandOver {
        let temperature = ambientTemperature * (1 + excess)
        let volume = 4 / 3 * Double.pi * pow(radius, 3)
        let mass = ambientPressure * volume / (CloudRise.gasConstant * temperature)
        return CloudHandOver(
            time: time, mass: mass, volume: volume, centre: SIMD3(0, 0, Float(height)),
            temperature: temperature,
            riseSpeed: riseSpeed, hottest: temperature,
            buoyancy: CloudRise.gravity * mass * excess, warmBuoyancy: CloudRise.gravity * mass * excess,
            ambientTemperature: ambientTemperature, ambientPressure: ambientPressure)
    }

    /// The self-similar thermal in uniform surroundings: with the buoyancy F constant, the
    /// impulse (1 + k) ρ (4π/3) b³ w grows as F t, and with b = α z,
    /// z⁴ = 3 F t² / (2π (1 + k) ρ α³).
    private func selfSimilarHeight(force: Double, time: Double, spec: CloudSpec) -> Double {
        pow(
            3 * force * time * time
                / (2 * .pi * (1 + spec.addedMass) * ambientDensity * pow(spec.entrainment, 3)), 0.25)
    }

    @Test("A weakly buoyant thermal on the self-similar path follows z ∝ t^½, with b = αz and w = z / 2t")
    func selfSimilarRise() {
        let spec = CloudSpec()
        let height = 10.0
        let radius = spec.entrainment * height
        let excess = 1e-4
        var start = handOver(radius: radius, height: height, excess: excess)
        let force = start.buoyancy
        // The time at which the self-similar thermal is `height` up, and its speed there.
        let t0 = sqrt(
            pow(height, 4) * 2 * .pi * (1 + spec.addedMass) * ambientDensity * pow(spec.entrainment, 3)
                / (3 * force))
        start.time = t0
        start.riseSpeed = height / (2 * t0)
        let times = [t0, 10 * t0, 100 * t0, 1000 * t0]
        let (samples, stabilised) = CloudRise.follow(start, spec: spec, atmosphere: uniform, at: times)
        #expect(samples.count == times.count && stabilised == nil)
        for sample in samples {
            let expected = selfSimilarHeight(force: force, time: sample.time, spec: spec)
            #expect(
                abs(sample.height / expected - 1) < 1e-3,
                "\(sample.time) s: \(sample.height) against \(expected)")
            #expect(abs(sample.radius / (spec.entrainment * sample.height) - 1) < 1e-3)
            #expect(abs(sample.riseSpeed * 2 * sample.time / sample.height - 1) < 1e-3)
        }
        // A thousandfold in time is about thirty times as high.
        #expect(abs(samples[3].height / samples[0].height - sqrt(1000)) < 0.05)
    }

    @Test("A hot fireball in uniform air keeps its buoyancy and joins the self-similar law")
    func hotStart() {
        let spec = CloudSpec()
        let start = handOver(radius: 7, height: 7, excess: 7)
        let times = [0.0, 100, 200, 400, 600]
        let (samples, _) = CloudRise.follow(start, spec: spec, atmosphere: uniform, at: times)
        let force = start.buoyancy
        // Mixing and no expansion: the mass times the excess temperature, and so the buoyancy,
        // is conserved however hot the gas.
        for sample in samples {
            let buoyancy =
                CloudRise.gravity * sample.mass * (sample.temperature / sample.ambientTemperature - 1)
            #expect(abs(buoyancy / force - 1) < 1e-4, "\(buoyancy) against \(force)")
        }
        // Late on, the radius grows as αz and z as t^½, so b² grows steadily at the self-similar
        // rate α² √(3F / (2π (1 + k) ρ α³)), whatever the start's virtual origin in time and height.
        let rate =
            (pow(samples[4].radius, 2) - pow(samples[2].radius, 2)) / (samples[4].time - samples[2].time)
        let expected =
            spec.entrainment * spec.entrainment
            * sqrt(3 * force / (2 * .pi * (1 + spec.addedMass) * ambientDensity * pow(spec.entrainment, 3)))
        #expect(abs(rate / expected - 1) < 0.01, "\(rate / expected)")
        #expect(samples[4].temperature - ambientTemperature < 1 && samples[4].riseSpeed > 0)
    }

    @Test("In a stable atmosphere the cloud stops rising at a height growing as (F / N²)^¼")
    func stratifiedCeiling() {
        var spec = CloudSpec()
        spec.duration = 3000
        let adiabatic = CloudRise.gravity / spec.specificHeat
        // Small starts, a tenth of a metre across, so the rise is far above where they began, and
        // from the self-similar thermal's origin at the ground.
        func ceiling(excess: Double, lapseRate: Double) -> Double {
            let atmosphere = CloudAtmosphere(
                groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: lapseRate,
                tropopause: 11_000)
            let start = handOver(radius: 0.1, height: 0.4, excess: excess)
            let (_, stabilised) = CloudRise.follow(
                start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 3000])
            return stabilised?.height ?? 0
        }
        let standard = ceiling(excess: 0.05, lapseRate: 0.0065)
        // Sixteen times the buoyancy, mg(T − T_air) / T_air, from the same volume: twice the height.
        let stronger = 16 * 0.05 / 1.05
        let buoyant = ceiling(excess: stronger / (1 - stronger), lapseRate: 0.0065)
        #expect(abs(buoyant / standard - 2) < 0.01, "\(buoyant / standard)")
        // A quarter of the stability, N² = (g / T)(g / cp − Γ): √2 times the height.
        let weak = ceiling(excess: 0.05, lapseRate: adiabatic - (adiabatic - 0.0065) / 4)
        #expect(abs(weak / standard - sqrt(2)) < 0.01, "\(weak / standard)")
    }

    @Test("Radiating its heat away, the cloud rises less")
    func radiation() {
        var spec = CloudSpec()
        let start = handOver(radius: 7, height: 7, excess: 7)
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        let dark = CloudRise.follow(start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 600])
        spec.emissivity = 1
        let bright = CloudRise.follow(start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 600])
        let high = try? #require(dark.stabilised)
        let low = try? #require(bright.stabilised)
        #expect((low?.height ?? 1) < (high?.height ?? 0))
    }

    @Test("The standard atmosphere's pressure at the tropopause and above")
    func standardAtmosphere() {
        let atmosphere = CloudAtmosphere(
            groundTemperature: 288.15, groundPressure: 101_325, lapseRate: 0.0065, tropopause: 11_000)
        let tropopause = atmosphere(11_000)
        #expect(abs(tropopause.temperature - 216.65) < 1e-9)
        #expect(abs(tropopause.pressure / 22_632.1 - 1) < 1e-3, "\(tropopause.pressure)")
        #expect(abs(atmosphere(20_000).pressure / 5_474.89 - 1) < 1e-3, "\(atmosphere(20_000).pressure)")
        #expect(atmosphere(20_000).temperature == tropopause.temperature)
    }

    @Test("A hot sphere in the air is handed over with its mass, place, temperature and buoyancy")
    func handOverFromSolver() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Hot", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.125)
        let centre = SIMD3<Float>(4, 3.5, 4)
        let pressure: Float = 101_325
        let ambient = Float(pressure) / (1.225 * 287.05)
        solver.mutateState { cells in
            for k in 0..<64 {
                for j in 0..<64 {
                    for i in 0..<64 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.125
                        let hot = simd_distance(x, centre) < 1.5
                        let t: Float = hot ? 2000 : ambient
                        // The hot gas compressed to twice the pressure, as if the blast had not
                        // quite left it, and rising.
                        let p = hot ? 2 * pressure : pressure
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(
                                density: p / (287.05 * t), velocity: SIMD3(0, 0, hot ? 5 : 0), pressure: p),
                            gamma: 1.4)
                    }
                }
            }
        }
        let handOver = solver.cloudHandOver(hotterThan: 500)
        let volume = 4 / 3 * Double.pi * pow(1.5, 3)
        let mass = 2 * Double(pressure) * volume / (287.05 * 2000)
        #expect(abs(handOver.mass / mass - 1) < 0.02, "\(handOver.mass) against \(mass)")
        #expect(simd_distance(handOver.centre, centre) < 0.01)
        #expect(abs(handOver.riseSpeed - 5) < 1e-3)
        // Brought to the ambient pressure isentropically, cooling by 2^(0.4/1.4).
        let temperature = 2000 / pow(2, 0.4 / 1.4)
        #expect(abs(handOver.temperature / temperature - 1) < 1e-3, "\(handOver.temperature)")
        #expect(abs(handOver.volume / (handOver.mass * 287.05 * temperature / Double(pressure)) - 1) < 1e-3)
        #expect(
            abs(handOver.buoyancy / (9.80665 * handOver.mass * (temperature / Double(ambient) - 1)) - 1)
                < 1e-3)
        #expect(abs(handOver.warmBuoyancy / handOver.buoyancy - 1) < 1e-6)
        #expect(abs(handOver.ambientTemperature - Double(ambient)) < 1e-3)
        #expect(solver.cloudHandOver(hotterThan: 2000).mass == 0)
    }

    @Test("The description takes its defaults from empty JSON and refuses what is out of range")
    func spec() throws {
        let spec = try JSONDecoder().decode(CloudSpec.self, from: Data("{}".utf8))
        #expect(spec == CloudSpec())
        try spec.validate()
        let adiabatic = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"lapseRate": 0.01}"#.utf8))
        #expect(throws: CocoaError.self) { try adiabatic.validate() }
        let wide = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"entrainment": 0}"#.utf8))
        #expect(throws: CocoaError.self) { try wide.validate() }
    }

    @Test(
        "The result samples the cloud more closely early on, and the scene gets it as a sphere after the run")
    func resultAndScene() throws {
        var spec = CloudSpec()
        spec.duration = 60
        spec.frameInterval = 2
        let result = CloudResult(spec: spec, handOver: handOver(radius: 5, height: 5, excess: 5, time: 0.1))
        #expect(result.samples.first?.time == 0.1 && abs((result.samples.last?.time ?? 0) - 60.1) < 1e-9)
        #expect(zip(result.samples, result.samples.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(result.samples.count > 100 && result.samples[1].time - result.samples[0].time < 0.02)
        #expect(result.summary.count == 2 && result.summary[0].hasPrefix("Cloud: "))
        let frames = result.frames()
        #expect(frames.count == 31 && abs(frames[1].time - 2.1) < 1e-9)

        let folder = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "scene.usda")
        var scenario = Scenario(
            name: "Cloud", domainSize: SIMD3(repeating: 10), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(5, 5, 1)))
        scenario.gauges = []
        let writer = try USDSceneWriter(url: url, scenario: scenario, frameInterval: 0.001)
        for _ in 0..<3 { try writer.append(nil) }
        writer.addCloud(frames, centre: SIMD2(5, 5), secondsPerFrame: spec.frameInterval)
        try writer.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("endTimeCode = 33\n") && text.contains("double cloudStartTimeCode = 3\n"))
        #expect(text.contains("double simulatedSecondsPerCloudFrame = 2.0\n"))
        #expect(text.contains("def Sphere \"Cloud\"") && text.contains("            3: \"inherited\""))
        #expect(text.contains("float primvars:temperature.timeSamples"))

        let checker = URL(filePath: "/usr/bin/usdchecker")
        if FileManager.default.isExecutableFile(atPath: checker.path) {
            let process = Process()
            process.executableURL = checker
            process.arguments = [url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
