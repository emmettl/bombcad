import Foundation
import Testing
import simd

@testable import BlastModel

/// A New District scene's place on the map, and a survey's longitudes and latitudes put on its
/// buildings by it (emmettl/bombcad-work#116).
@Suite("A scene's place on the map")
struct SceneLocationTests {
    static let charge = SIMD2(10.123456789, 55.987654321)

    /// A longitude and latitude `east` and `north` metres from the charge.
    static func place(_ east: Double, _ north: Double) -> SIMD2<Double> {
        let k = ElevationGrid.metresPerDegree
        return charge + SIMD2(east / (k * cos(charge.y * .pi / 180)), north / k)
    }

    /// 20 m squares at these places about the charge, each named by its index.
    static func layout(at places: [SIMD2<Double>]) -> DistrictLayout {
        let buildings = places.enumerated().map { n, p in
            MapBuilding(
                id: "way/\(n)",
                rings: [
                    [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10), SIMD2(-10, -10)].map {
                        Self.place(p.x + $0.x, p.y + $0.y)
                    }
                ], height: 9)
        }
        return DistrictLayout(buildings: buildings, charge: charge, mass: 1_000)
    }

    /// A CSV of façades, one for each place, all broken.
    static func survey(_ places: [SIMD2<Double>]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "survey-\(UUID().uuidString).csv")
        var text = "lat,lon,class\n"
        for p in places {
            let at = place(p.x, p.y)
            text += "\(at.y),\(at.x),2\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func footprints(_ envelope: BuildingEnvelope) -> [(low: SIMD2<Double>, high: SIMD2<Double>)] {
        envelope.blocks.map {
            (low: SIMD2(Double($0.min.x), Double($0.min.y)), high: SIMD2(Double($0.max.x), Double($0.max.y)))
        }
    }

    @Test("Saved and read back to the bit; one without a far field leaves it out of the file")
    func roundTrip() throws {
        let layout = Self.layout(at: [.zero])
        let location = layout.hybridLocation(nearHalfSide: 197, halfSide: 3_001, cellSize: 4)
        let data = try JSONEncoder().encode(location)
        #expect(try JSONDecoder().decode(SceneLocation.self, from: data) == location)
        #expect(location.isValid && location.far != nil)
        let plain = layout.location(halfSide: 200)
        let plainData = try JSONEncoder().encode(plain)
        #expect(try JSONDecoder().decode(SceneLocation.self, from: plainData) == plain)
        #expect(!String(decoding: plainData, as: UTF8.self).contains("far"))
        var wrong = plain
        wrong.scene.latitude = .nan
        #expect(!wrong.isValid)
    }

    @Test("A survey's place lands on the right building of a laid-out district")
    func wholeDistrict() throws {
        let places = [SIMD2(-60.0, 40.0), SIMD2(90.0, -70.0), SIMD2(30.0, 120.0)]
        let layout = Self.layout(at: places)
        let (scene, report) = try layout.scene(halfSide: 300, cellSize: 4)
        let file = try Self.survey(places)
        defer { try? FileManager.default.removeItem(at: file) }
        let survey = try ChargeFromDamage.readSurvey(
            file, location: layout.location(halfSide: 300),
            charge: SIMD2(Double(scene.charge.position.x), Double(scene.charge.position.y)))
        let objects = scene.envelopeObjects
        let match = ChargeFromDamage.match(
            survey, footprints: objects.map { Self.footprints($0.envelope!) }, within: 0)
        #expect(match.matched == 3 && match.unmatched == 0)
        for (n, object) in objects.enumerated() {
            let mapID = try #require(report.placed.first { $0.objectID == object.id }?.id)
            #expect(match.marks[n]?.glass == .broken, "\(mapID)")
        }
    }

    @Test("Near and far each by their own mapping: the far field's is metres from the near one's")
    func nearAndFar() throws {
        // At 56° N and 2.5 km out the two mappings differ by metres. One building in the near box,
        // one far east, one far north-east.
        let places = [SIMD2(50.0, 30.0), SIMD2(2_600.0, 40.0), SIMD2(1_800.0, 2_200.0)]
        let layout = Self.layout(at: places)
        let (near, far, _) = try layout.hybrid(
            handoverM: 150, nearHalfSide: 200, radius: 3_500, halfSide: 3_504, cellSize: 4)
        let location = layout.hybridLocation(nearHalfSide: 200, halfSide: 3_504, cellSize: 4)
        #expect(near.envelopeObjects.count == 1 && far.buildings.count == 2)
        let frame = try #require(location.far)
        for building in places.dropFirst() {
            let at = Self.place(building.x, building.y)
            #expect(simd_length(frame.position(at) - location.scene.position(at)) > 1)
        }

        // Matched with no reach at all, so the place has to be in the building's own rectangles.
        let footprints =
            near.envelopeObjects.map { Self.footprints($0.envelope!) }
            + far.buildings.map { Self.footprints($0.envelope) }
        let file = try Self.survey(places)
        defer { try? FileManager.default.removeItem(at: file) }
        let survey = try ChargeFromDamage.readSurvey(file, location: location, charge: .zero)
        let match = ChargeFromDamage.match(survey, footprints: footprints, within: 0, far: [1, 2])
        #expect(match.matched == 3 && match.unmatched == 0 && match.marks.count == 3)

        // Each lands within a cell of its own building's middle, the far ones too.
        for (entry, n) in zip(survey.entries, [0, 1, 2]) {
            let at = n == 0 ? entry.place : try #require(entry.farPlace)
            let rects = footprints[n]
            let low = rects.map(\.low).reduce(SIMD2(repeating: Double.infinity)) { simd_min($0, $1) }
            let high = rects.map(\.high).reduce(SIMD2(repeating: -Double.infinity)) { simd_max($0, $1) }
            #expect(simd_length(at - (low + high) / 2) < 4, "building \(n)")
        }
    }

    @Test("Without a place on the map a survey in longitudes and latitudes is refused, saying why")
    func unknown() throws {
        let file = try Self.survey([.zero])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect {
            _ = try ChargeFromDamage.readSurvey(file, location: nil, charge: .zero)
        } throws: { error in
            let words = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return words.contains("doesn't record where its scene lies on the map")
        }
    }
}
