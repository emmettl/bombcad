import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Scattering")
struct ScatteringTests {
    let size: SIMD3<Double> = [5, 4, 3]
    // Fixed identities, because a receiver's diffuse tail is seeded from its identity.
    let source = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "S", position: [1.3, 1.1, 1.2])
    let receiver = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "R", position: [3.7, 2.9, 1.6])

    private func settings(alpha: Double, scattering: Double, duration: Double = 0.3) -> RoomResponseSettings {
        RoomResponseSettings(
            room: ShoeboxRoom(size: size, material: .uniform(alpha, scattering: scattering, name: "Test")),
            source: source, receivers: [receiver], airAbsorption: false, duration: duration,
            maximumReflectionOrder: 200, diffuseRays: 20_000)
    }

    private func t30(_ samples: [Float], band: Int) -> Double? {
        DecayAnalysis.reverberationTime(
            DecayAnalysis.octaveBand(samples, sampleRate: 48_000, band: band), sampleRate: 48_000)
    }

    @Test("In a rigid, fully scattering room the detected energy arrives at the diffuse-field rate 4πc/V")
    func detectorNormalization() {
        let room = ShoeboxRoom(size: size, material: .uniform(0, scattering: 1, name: "Rigid"))
        let tracer = DiffuseRayTracer(
            room: room, source: source.position, atmosphere: .standard, airAbsorption: false,
            rayCount: 20_000, seed: 3)
        // One receiver in the open, one near a corner whose detection sphere crosses three walls.
        let energy = tracer.trace(receivers: [receiver.position, [0.2, 0.2, 0.2]], duration: 0.5)
        let expected = 4 * Double.pi * Atmosphere.standard.soundSpeed / room.volume
        for receiver in energy {
            let rate = receiver[4][200..<500].reduce(0, +) / 0.3
            #expect(abs(rate / expected - 1) < 0.03)
        }
    }

    @Test("Without scattering nothing is traced and the image-source response is unchanged")
    func noScattering() throws {
        var a = settings(alpha: 0.3, scattering: 0)
        let first = try RoomResponseGenerator.generate(a)
        a.diffuseRays = 50_000
        a.randomSeed = 99
        let second = try RoomResponseGenerator.generate(a)
        #expect(first.response.channels == second.response.channels)
        #expect(first.diagnostics.scatteredFraction == [0])
        #expect(first.diagnostics.diffuseRays == 0)
    }

    @Test("Scattering weakens each specular reflection by √(1 − s)")
    func specularPart() {
        var room = ShoeboxRoom(size: size, material: .anechoic)
        room.floor = SurfaceMaterial(
            name: "Floor", absorption: Array(repeating: 0.36, count: 8),
            scattering: Array(repeating: 0.75, count: 8),
            reference: "Test")
        let model = ImageSourceModel(
            room: room, source: source.position, atmosphere: .standard, airAbsorption: false)
        var gains: [Double] = []
        model.forEachArrival(at: receiver.position, duration: 1, maximumOrder: 1, includeDirect: false) {
            delay, _, g in gains.append(g[0] * delay * Atmosphere.standard.soundSpeed)
        }
        // sqrt((1 - 0.36)(1 - 0.75)) = 0.4
        #expect(gains.count == 1)
        #expect(abs(gains[0] - 0.4) < 1e-12)
    }

    @Test("Full scattering brings the decay close to the diffuse-field estimate; specular decay stays longer")
    func diffuseDecay() throws {
        let alpha = 0.5
        let specular = try RoomResponseGenerator.generate(settings(alpha: alpha, scattering: 0))
        let diffuse = try RoomResponseGenerator.generate(settings(alpha: alpha, scattering: 1))
        // Eyring's formula takes every free path to be the mean; Kuttruff's correction for their spread,
        // with relative variance about 0.4 in rooms of ordinary shape, lengthens it.
        let spread = 0.4
        let eyring =
            try #require(diffuse.diagnostics.eyringReverberationTime[4]) / (1 + spread / 2 * log(1 - alpha))
        var diffuseTimes: [Double] = []
        var specularTimes: [Double] = []
        for band in 4...7 {
            diffuseTimes.append(try #require(t30(diffuse.response.channels[0], band: band)))
            specularTimes.append(try #require(t30(specular.response.channels[0], band: band)))
        }
        // In this small, absorbent room the difference is about 8%, and single bands of one random
        // realization vary by a few percent, so compare the averages.
        #expect(diffuseTimes.reduce(0, +) < 0.97 * specularTimes.reduce(0, +))
        let mean = diffuseTimes.reduce(0, +) / Double(diffuseTimes.count)
        #expect(abs(mean / eyring - 1) < 0.06, "mean \(mean) s against corrected Eyring \(eyring) s")
        #expect((diffuse.diagnostics.scatteredFraction?[0] ?? 0) > 0.5)
    }

    @Test("The same seed reproduces a response; another seed changes its detail but not its energy")
    func seeds() throws {
        var a = settings(alpha: 0.4, scattering: 0.5, duration: 0.2)
        let first = try RoomResponseGenerator.generate(a)
        #expect(try RoomResponseGenerator.generate(a).response.channels == first.response.channels)
        a.randomSeed = 2
        let other = try RoomResponseGenerator.generate(a)
        #expect(other.response.channels != first.response.channels)
        // The traced energy hardly depends on the seed.
        func traced(_ seed: UInt64) -> Double {
            DiffuseRayTracer(
                room: a.room, source: a.source.position, atmosphere: .standard, airAbsorption: false,
                rayCount: a.diffuseRays, seed: seed
            ).trace(receivers: [receiver.position], duration: a.duration)[0][4].reduce(0, +)
        }
        #expect(abs(traced(2) / traced(1) - 1) < 0.05)
        // Its rendering is one random realization, whose band energy over a short decay varies by about
        // a decibel, as it does between nearby points in a real room.
        func energy(_ x: [Float]) -> Double {
            DecayAnalysis.octaveBand(x, sampleRate: 48_000, band: 4).reduce(0) {
                $0 + Double($1) * Double($1)
            }
        }
        let ratio = energy(other.response.channels[0]) / energy(first.response.channels[0])
        #expect(abs(10 * log10(ratio)) < 1.5)
    }

    @Test("Materials and settings saved before scattering existed decode as purely specular with defaults")
    func compatibility() throws {
        let material = #"{"name":"Old","absorption":[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1],"reference":"x"}"#
        let decoded = try JSONDecoder().decode(SurfaceMaterial.self, from: Data(material.utf8))
        #expect(decoded.scattering == Array(repeating: 0, count: 8))

        let current = settings(alpha: 0.2, scattering: 0)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["diffuseRays"] = nil
        object["randomSeed"] = nil
        let old = try JSONDecoder().decode(
            RoomResponseSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.diffuseRays == 40_000 && old.randomSeed == 1)
        #expect(old.receivers == current.receivers)
    }

    @Test("Scattering coefficients outside 0 to 1 and implausible ray counts are rejected")
    func validation() {
        var bad = settings(alpha: 0.2, scattering: 0)
        bad.room.west.scattering[3] = 1.2
        #expect(throws: AcousticError.self) { try bad.validate() }
        var rays = settings(alpha: 0.2, scattering: 0)
        rays.diffuseRays = 10
        #expect(throws: AcousticError.self) { try rays.validate() }
    }
}

@Suite("Parallel generation")
struct ParallelGenerationTests {
    @Test("Responses are identical however the work is shared, and cancelling stops every worker")
    func deterministicAndCancellable() async throws {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.3, scattering: 0.4, name: "Test")),
            source: RoomPoint(name: "S", position: [1.3, 1.1, 1.2]),
            receivers: [
                RoomPoint(name: "A", position: [3.7, 2.9, 1.6]),
                RoomPoint(name: "B", position: [3.5, 1.2, 1.4]),
                RoomPoint(name: "C", position: [2.0, 3.1, 2.2]),
            ], airAbsorption: false, duration: 0.15, maximumReflectionOrder: 40, diffuseRays: 8_000)
        // The synchronous and asynchronous forms.
        let first = try RoomResponseGenerator.generate(settings, cancellation: CancellationFlag())
        let second = try await RoomResponseGenerator.generate(settings)
        #expect(first.response.channels == second.response.channels)
        // Each receiver alone gives the same channel as in company.
        var alone = settings
        alone.receivers = [settings.receivers[1]]
        let single = try RoomResponseGenerator.generate(alone, cancellation: CancellationFlag())
        #expect(single.response.channels[0] == first.response.channels[1])

        var long = settings
        long.duration = 2
        long.maximumReflectionOrder = 150
        let flag = CancellationFlag()
        flag.cancel()
        let start = Date()
        #expect(throws: CancellationError.self) {
            try RoomResponseGenerator.generate(long, cancellation: flag)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite("Rays beyond the order limit")
struct OrderLimitTests {
    let room = ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.25, scattering: 0.3, name: "Test"))
    let source = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "S", position: [1.3, 1.1, 1.2])
    let receiver = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "R", position: [2.2, 3.3, 0.9])

    @Test("Rays carry exactly the specular energy of the images the order limit omits")
    func incoherentEnergy() {
        let specular = ShoeboxRoom(size: room.size, material: .uniform(0.25, name: "Specular"))
        var tracer = DiffuseRayTracer(
            room: specular, source: source.position, atmosphere: .standard, airAbsorption: false,
            rayCount: 20_000,
            seed: 1)
        tracer.specularOrderLimit = 4
        let rays = tracer.trace(receivers: [receiver.position], duration: 0.2)[0][4]
        let model = ImageSourceModel(
            room: specular, source: source.position, atmosphere: .standard, airAbsorption: false)
        var images = [Double](repeating: 0, count: rays.count)
        model.forEachArrival(at: receiver.position, duration: 0.2, maximumOrder: 300) { delay, order, gains in
            let bin = Int(delay / DiffuseRayTracer.binWidth)
            if order > 4, bin < images.count { images[bin] += gains[4] * gains[4] }
        }
        for window in [20..<60, 60..<120, 120..<195] {
            let ratio = rays[window].reduce(0, +) / images[window].reduce(0, +)
            #expect(abs(10 * log10(ratio)) < 0.5, "\(window) ms")
        }
    }

    @Test("A low order limit plus rays matches a high one in a room that scatters")
    func hybrid() throws {
        func response(_ order: Int) throws -> [Float] {
            try RoomResponseGenerator.generate(
                RoomResponseSettings(
                    room: room, source: source, receivers: [receiver], airAbsorption: false, duration: 0.3,
                    maximumReflectionOrder: order), cancellation: CancellationFlag()
            ).response.channels[0]
        }
        let full = try response(100)
        let hybrid = try response(4)
        for band in [3, 5] {
            let window = Int(0.05 * 48_000)..<Int(0.25 * 48_000)
            let a = DecayAnalysis.octaveBand(full, sampleRate: 48_000, band: band)[window]
            let b = DecayAnalysis.octaveBand(hybrid, sampleRate: 48_000, band: band)[window]
            let ratio =
                b.reduce(0) { $0 + Double($1) * Double($1) } / a.reduce(0) { $0 + Double($1) * Double($1) }
            #expect(abs(10 * log10(ratio)) < 1.5, "band \(band)")
        }
    }
}
