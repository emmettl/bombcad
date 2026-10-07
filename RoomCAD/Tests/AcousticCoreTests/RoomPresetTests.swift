import Foundation
import Testing

@testable import AcousticCore

@Suite("Room presets")
struct RoomPresetTests {
    let base = RoomResponseSettings(
        room: ShoeboxRoom(size: [5, 4, 3], material: .rigid),
        source: RoomPoint(name: "Speaker", position: [1, 1, 1]),
        receivers: [RoomPoint(name: "Mic", position: [3, 2, 1])], sampleRate: 96_000, lowFrequencyCutoff: 30,
        diffuseRays: 12_000, randomSeed: 7)

    @Test("Every preset gives valid settings with published absorption on every surface")
    func valid() throws {
        #expect(RoomPresets.all.count == 10)
        #expect(Set(RoomPresets.all.map(\.id)).count == 10)
        for preset in RoomPresets.all {
            let settings = preset.applied(to: base)
            try settings.validate()
            #expect(settings.room.size == preset.size)
            #expect(settings.receivers.count == 2)
            #expect(
                ([settings.source] + settings.receivers).allSatisfy { settings.room.contains($0.position) })
            #expect((0.5...8).contains(settings.duration))
            #expect(settings.estimatedImageCount < 3_000_000, "\(preset.id)")
            for surface in Surface.allCases {
                let material = settings.room[surface]
                #expect(material.reference.hasPrefix("Absorption: Vorländer"), "\(preset.id) \(surface)")
                #expect(material.reference.contains("Scattering:"), "\(preset.id) \(surface)")
                #expect(material.scatters, "\(preset.id) \(surface)")
            }
        }
    }

    @Test("Loading a preset keeps processing settings and the points' identities and names")
    func keeps() throws {
        let preset = try #require(RoomPresets.all.first { $0.id == "classroom" })
        let settings = preset.applied(to: base)
        #expect(settings.sampleRate == 96_000 && settings.lowFrequencyCutoff == 30)
        #expect(settings.diffuseRays == 12_000 && settings.randomSeed == 7)
        #expect(settings.source.id == base.source.id && settings.source.name == "Speaker")
        #expect(settings.receivers[0].id == base.receivers[0].id && settings.receivers[0].name == "Mic")
        #expect(settings.receivers[1].name == "Right")
        // Published scattering where a preset fits: rows of desks over the floor.
        #expect(settings.room.floor.reference.contains("classroom tables"))
        #expect(settings.room.floor.name.hasPrefix("Linoleum"))
    }

    @Test("Livelier rooms get longer responses")
    func durations() throws {
        func duration(_ id: String) throws -> Double {
            try #require(RoomPresets.all.first { $0.id == id }).applied(to: base).duration
        }
        #expect(try duration("vocal-booth") < duration("office"))
        #expect(try duration("office") < duration("chamber-hall"))
        #expect(try duration("chamber-hall") < duration("stone-church"))
    }
}
