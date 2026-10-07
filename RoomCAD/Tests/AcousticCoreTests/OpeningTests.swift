import Foundation
import Testing

@testable import AcousticCore

@Suite("Openings")
struct OpeningTests {
    let size: SIMD3<Double> = [5, 4, 3]
    let source = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "S", position: [1.3, 1.1, 1.2])
    let receiver = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "R", position: [3.7, 2.9, 1.6])
    /// A door in the north wall, 0.9 × 2 m.
    let door = Opening(name: "Door", surface: .north, centre: [2.5, 1], size: [0.9, 2])

    @Test("An opening is absorption to the statistical models: α' = α(1 − f) + f")
    func effectiveAbsorption() {
        let room = ShoeboxRoom(size: size, material: .uniform(0.1, name: "Plaster"))
        let open = room.withOpenings([door])
        let fraction = 1.8 / (5 * 3)
        #expect(open.north.absorption.allSatisfy { abs($0 - (0.1 * (1 - fraction) + fraction)) < 1e-12 })
        #expect(open.south == room.south)
        // Sabine's absorption area grows by the open area times (1 - α).
        let closed = room.sabineReverberationTime(atmosphere: .standard, airAbsorption: false)[4]!
        let opened = open.sabineReverberationTime(atmosphere: .standard, airAbsorption: false)[4]!
        let area = 24 * log(10) * room.volume / Atmosphere.standard.soundSpeed
        #expect(abs((area / opened - area / closed) - 1.8 * 0.9) < 1e-9)
    }

    @Test("For rays a wall wholly open is a wall that absorbs everything")
    func wholeWall() {
        let base = ShoeboxRoom(size: size, material: .uniform(0.2, scattering: 0.5, name: "Base"))
        var absorbing = base
        absorbing.east = .uniform(1, scattering: 0.5, name: "Absorber")
        func trace(_ room: ShoeboxRoom, _ openings: [Opening]) -> Double {
            var tracer = DiffuseRayTracer(
                room: room, source: source.position, atmosphere: .standard, airAbsorption: false,
                rayCount: 20_000,
                seed: 4)
            tracer.openings = openings
            return tracer.trace(receivers: [receiver.position], duration: 0.3)[0][4].reduce(0, +)
        }
        let open = trace(base, [Opening(name: "Gone", surface: .east, centre: [2, 1.5], size: [4, 3])])
        let absorbed = trace(absorbing, [])
        #expect(abs(open / absorbed - 1) < 0.05)
    }

    @Test("Openings must lie within their surface")
    func validation() {
        let room = ShoeboxRoom(size: size, material: .rigid)
        var settings = RoomResponseSettings(
            room: room, source: source, receivers: [receiver], openings: [door])
        #expect(throws: Never.self) { try settings.validate() }
        settings.openings = [Opening(name: "Too wide", surface: .north, centre: [4.8, 1], size: [0.9, 2])]
        #expect(throws: AcousticError.self) { try settings.validate() }
    }

    @Test("An open door shortens the decay, in both the geometrical model and the wave solver")
    func decay() throws {
        let room = ShoeboxRoom(size: size, material: .uniform(0.15, scattering: 0.3, name: "Hard"))
        let wide = Opening(name: "Wide door", surface: .north, centre: [2.5, 1.25], size: [2, 2.5])
        func response(_ openings: [Opening]) throws -> [Float] {
            let settings = RoomResponseSettings(
                room: room, source: source, receivers: [receiver], airAbsorption: false, duration: 1,
                maximumReflectionOrder: 30, diffuseRays: 5_000, lowFrequencyModel: true,
                crossoverFrequency: 100,
                openings: openings)
            return try RoomResponseGenerator.generate(settings, cancellation: CancellationFlag()).response
                .channels[0]
        }
        func t30(_ samples: [Float], band: Int) throws -> Double {
            let filtered = DecayAnalysis.octaveBand(samples, sampleRate: 48_000, band: band)
            return try #require(DecayAnalysis.reverberationTime(filtered, sampleRate: 48_000))
        }
        let closed = try response([])
        let open = try response([wide])
        // 1 kHz is geometrical; 63 Hz, below the 100 Hz crossover's transition, is the wave solver's.
        #expect(try t30(open, band: 4) < 0.85 * t30(closed, band: 4))
        #expect(try t30(open, band: 0) < 0.85 * t30(closed, band: 0))
    }

    @Test("Settings saved before openings existed have none")
    func compatibility() throws {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: size, material: .rigid), source: source, receivers: [receiver],
            openings: [door])
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object["openings"] = nil
        let old = try JSONDecoder().decode(
            RoomResponseSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.openings.isEmpty)
        let again = try JSONDecoder().decode(RoomResponseSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.openings == [door])
    }
}
