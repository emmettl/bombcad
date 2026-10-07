import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Scattering")
struct ScatteringTests {
    let size: SIMD3<Double> = [5, 4, 3]
    let source = RoomPoint(name: "S", position: [1.3, 1.1, 1.2])
    let receiver = RoomPoint(name: "R", position: [3.7, 2.9, 1.6])

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
        for band in 4...7 {
            let d = try #require(t30(diffuse.response.channels[0], band: band))
            let s = try #require(t30(specular.response.channels[0], band: band))
            #expect(d < s, "band \(band): diffuse \(d) s, specular \(s) s")
            diffuseTimes.append(d)
        }
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
        func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }
        let ratio = energy(other.response.channels[0]) / energy(first.response.channels[0])
        #expect(abs(ratio - 1) < 0.05)
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
