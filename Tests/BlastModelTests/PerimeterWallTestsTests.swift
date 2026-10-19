import Foundation
import Testing

@testable import BlastModel

/// Alsubaei's perimeter walls (`PerimeterWallTests`) against the derived data in
/// Fixtures/Alsubaei2015, and the scenes built from them.
@Suite("Perimeter walls under field blasts", .timeLimit(.minutes(120)))
struct PerimeterWallTestsTests {
    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Alsubaei2015/walls.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private func matches(_ measured: PerimeterWallTests.Measured, _ values: [Any]) -> Bool {
        zip(measured.values, values).allSatisfy { held, row in
            guard let number = row as? Double else { return held == nil }
            return held.map { abs($0 - Float(number)) < 1e-3 } ?? false
        } && measured.values.count == values.count
    }

    @Test("The measured peaks and factors match the derived data")
    func measured() throws {
        let data = try fixture()
        let half = try #require(data["halfScale"] as? [String: Any])
        let shots = try #require((half["noWall"] as? [String: Any])?["shots"] as? [[String: Any]])
        #expect(shots.count == PerimeterWallTests.halfScaleNoWall.count)
        for (shot, held) in zip(shots, PerimeterWallTests.halfScaleNoWall) {
            #expect(abs(held.anfo - Float(try #require(shot["anfo_kg"] as? Double))) < 1e-4)
            #expect(matches(held, try #require(shot["peak_kPa"] as? [Any])))
        }
        let factors = try #require(
            (half["behindPlaneWall"] as? [String: Any])?["factors"] as? [[String: Any]])
        for (row, held) in zip(factors, PerimeterWallTests.halfScaleFactors) {
            #expect(abs(held.chargeToColumn - Float(try #require(row["chargeToColumn_m"] as? Double))) < 1e-4)
            #expect(matches(held, try #require(row["pressure"] as? [Any])))
        }
        let street = try #require(data["halfScaleStreet"] as? [String: Any])
        let streetShots = try #require((street["noWall"] as? [String: Any])?["shots"] as? [[String: Any]])
        for (shot, held) in zip(streetShots, PerimeterWallTests.streetNoWall) {
            #expect(matches(held, try #require(shot["peak_kPa"] as? [Any])))
        }
        let cases = try #require(
            (street["planeWallReductionAtP1"] as? [String: Any])?["cases"] as? [[String: Any]])
        for (row, held) in zip(cases, PerimeterWallTests.streetFactors) {
            let reduction = Float(try #require(row["level"] as? Double))
            #expect(abs(held.values[0]! - (1 - reduction)) < 1e-4)
        }
        let full = try #require(data["fullScaleCanopied"] as? [String: Any])
        #expect(matches(PerimeterWallTests.canopiedNoWall, try #require(full["noWallPeak_kPa"] as? [Any])))
        let behind = try #require(full["behindWallPeak_kPa"] as? [String: Any])
        for (name, values) in PerimeterWallTests.canopiedBehind {
            let key = try #require(behind.keys.first { $0.hasPrefix(name + " ") })
            let row = try #require(behind[key] as? [Double])
            #expect(zip(values, row).allSatisfy { abs($0 - Float($1)) < 1e-3 })
        }
        let explosive = try #require(data["explosive"] as? [String: Any])
        #expect(
            abs(PerimeterWallTests.tntFactor - Float(try #require(explosive["tntFactor"] as? Double))) < 1e-6)
    }

    @Test("The scene puts the wall, the canopy and the gauges where the thesis does")
    func scene() {
        let layout = PerimeterWallTests.canopied
        let scenario = PerimeterWallTests.scenario(
            layout, anfo: 125, wall: true, columnWidth: nil, wallLength: 6, cellSize: 0.1)
        #expect(abs(scenario.charge.mass - 102.5) < 1e-3)
        #expect(scenario.charge.position.z == 1)
        let boxes = scenario.rigidBoxes
        #expect(boxes.count == 2)
        let stem = boxes[0]
        #expect(abs(stem.min.x - scenario.charge.position.x - 4) < 1e-5)
        #expect(abs(stem.max.y - stem.min.y - 6) < 1e-5)
        #expect(abs(boxes[1].max.z - 2.4) < 1e-5)
        #expect(abs(boxes[1].max.x - boxes[1].min.x - 1.2) < 1e-5)
        #expect(scenario.gauges.count == 4)
        #expect(abs(scenario.gauges[0].position.x - scenario.charge.position.x - 16.4) < 1e-5)
        // With columns, the gauges sit half a cell in front of each column's face.
        let half = PerimeterWallTests.scenario(
            PerimeterWallTests.halfScale, anfo: 6.46, wall: false, columnWidth: 0.2, wallLength: nil,
            cellSize: 0.05)
        #expect(half.rigidBoxes.count == 3)
        #expect(half.gauges.count == 12)
        for (c, box) in half.rigidBoxes.enumerated() {
            #expect(abs(half.gauges[4 * c].position.x - (box.min.x - 0.025)) < 1e-5)
        }
    }

    @Test("Normal reflection runs from twice the overpressure for weak shocks towards eight for strong")
    func reflection() {
        #expect(abs(PerimeterWallTests.normalReflection(100) / 100 - 2) < 1e-3)
        let strong = PerimeterWallTests.normalReflection(1e9)
        #expect(strong / 1e9 > 7.9 && strong / 1e9 < 8)
        // 100 kPa side-on reflects to about 2.74 times (Rankine–Hugoniot, γ = 1.4).
        #expect(abs(PerimeterWallTests.normalReflection(100e3) / 100e3 - 2.74) < 0.01)
    }
}
