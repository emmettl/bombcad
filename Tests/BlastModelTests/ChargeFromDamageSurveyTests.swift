import Foundation
import Testing
import simd

@testable import BlastModel

/// A survey put on the scene's buildings for the Charge from the Damage panel, and the marks a
/// project keeps (emmettl/bombcad-work#116, stage 3).
@Suite("The charge from marked damage: surveys and kept marks")
struct ChargeFromDamageSurveyTests {
    /// A dBASE III table of text fields, as GEER's structural assessment is written.
    static func dbf(_ fields: [String], _ rows: [[String]]) -> Data {
        let width = 40
        var data = Data([0x03, 126, 11, 2])
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        data += le32(rows.count)
        data += le16(32 + 32 * fields.count + 1)
        data += le16(1 + width * fields.count)
        data += Data(repeating: 0, count: 20)
        for name in fields {
            var descriptor = Data(name.utf8.prefix(10))
            descriptor += Data(repeating: 0, count: 11 - descriptor.count)
            descriptor += Data([UInt8(ascii: "C"), 0, 0, 0, 0, UInt8(width), 0])
            descriptor += Data(repeating: 0, count: 14)
            data += descriptor
        }
        data += Data([0x0D])
        for row in rows {
            data += Data([0x20])
            for value in row {
                var cell = Data(value.utf8.prefix(width))
                cell += Data(repeating: 0x20, count: width - cell.count)
                data += cell
            }
        }
        return data + Data([0x1A])
    }

    @Test("A marks CSV and GEER's structural table put on the scene's buildings, matched and not")
    func survey() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "survey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Three buildings, 20 m squares at 100 m, 200 m and 300 m east of the scene's corner.
        let footprints: [[(low: SIMD2<Double>, high: SIMD2<Double>)]] = [100.0, 200, 300].map {
            [(SIMD2($0, 100), SIMD2($0 + 20, 120))]
        }
        let charge = SIMD2(150.0, 110.0)
        // A marks CSV about the charge: the first building's glass broken, the second's walls
        // heavy as masonry, and one at nothing.
        let csv = folder.appending(path: "marks.csv")
        try """
        building,east,north,height,footprint,built,walls,glass,seen
        0,-40,0,10,400,0.3,concrete,broken,-
        1,60,0,10,400,0.3,masonry,-,heavy
        -1,500,500,10,400,0.3,concrete,whole,-
        """.write(to: csv, atomically: true, encoding: .utf8)
        #expect(!ChargeFromDamage.surveyNeedsCorner(csv))
        let marks = try ChargeFromDamage.readSurvey(csv, corner: nil, charge: charge)
        #expect(marks.entries.count == 3)
        var match = ChargeFromDamage.match(marks, footprints: footprints)
        #expect(match.matched == 2 && match.unmatched == 1)
        #expect(match.marks[0]?.glass == .broken)
        #expect(match.marks[1]?.walls == .heavy && match.marks[1]?.masonry == true)

        // GEER's buildings, by longitude and latitude from the scene's corner.
        let corner = SIMD2(35.5, 33.9)
        let placement = MapBuildingPlacement(origin: corner, resolution: 1)
        func lonLat(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let east = ElevationGrid.metresPerDegree * cos(corner.y * .pi / 180)
            return corner + p / SIMD2(east, ElevationGrid.metresPerDegree)
        }
        #expect(simd_distance(placement.position(lonLat(SIMD2(310, 110))), SIMD2(310, 110)) < 1e-6)
        let rows: [(SIMD2<Double>, String, String)] = [
            (SIMD2(310, 110), "D4", "Stone masonry bearing walls"),  // heavy, stone
            (SIMD2(210, 125), "D2", "Reinforced concrete frame"),  // 5 m off the second: damaged
            (SIMD2(110, 110), "D2-D3", "Stone masonry bearing walls"),  // straddles D3: left out
            (SIMD2(110, 110), "D1", "Timber"),  // not weighed: left out
            (SIMD2(800, 800), "D0", "RC frame"),  // no building near
        ]
        let table = folder.appending(path: "structure.dbf")
        try Self.dbf(
            ["Latitude", "Longitude", "Damage_Cla", "Str_Type", "VID"],
            rows.map { p, damage, type in
                let at = lonLat(p)
                return [String(at.y), String(at.x), damage, type, "0"]
            }
        ).write(to: table)
        #expect(ChargeFromDamage.surveyNeedsCorner(table))
        #expect(throws: (any Error).self) {
            try ChargeFromDamage.readSurvey(table, corner: nil, charge: charge)
        }
        let structure = try ChargeFromDamage.readSurvey(table, corner: corner, charge: charge)
        #expect(structure.entries.count == 3 && structure.skipped == 2)
        match = ChargeFromDamage.match(structure, footprints: footprints)
        #expect(match.matched == 2 && match.unmatched == 1)
        #expect(match.marks[2]?.walls == .heavy && match.marks[2]?.masonry == true)
        #expect(match.marks[1]?.walls == .damaged && match.marks[1]?.masonry == false)
        // The folder reads both.
        let both = try ChargeFromDamage.readSurvey(folder, corner: corner, charge: charge)
        #expect(both.entries.count == 6 && both.parts.count == 2)
    }

    @Test("Kept marks are read back, and a file without the later fields still reads")
    func kept() throws {
        let saved = ChargeFromDamage.SavedMarks(
            marks: [
                .init(id: UUID(), glass: .broken, walls: nil),
                .init(id: UUID(), glass: nil, walls: .heavy, wallsAs: .masonry),
            ],
            reference: [10, 20], weighing: "independent", corner: [35.5, 33.9])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(ChargeFromDamage.SavedMarks.self, from: data) == saved)
        let bare = try JSONDecoder().decode(
            ChargeFromDamage.SavedMarks.self,
            from: Data(#"{"marks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","glass":2}]}"#.utf8))
        #expect(bare.marks.count == 1 && bare.marks[0].glass == .broken && bare.weighing == nil)
    }
}
