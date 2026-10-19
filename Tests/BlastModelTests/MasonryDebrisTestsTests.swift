import Foundation
import Testing

@testable import BlastModel

/// Keys's brick walls (`MasonryDebrisTests`) against the digitised histograms in
/// Fixtures/Keys2016.
@Suite("Brick walls' debris")
struct MasonryDebrisTestsTests {
    private func fixture() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Keys2016/debris.json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let walls = try #require(object["structures"] as? [[String: Any]])
        return Dictionary(
            uniqueKeysWithValues: walls.compactMap { wall in (wall["id"] as? String).map { ($0, wall) } })
    }

    @Test("The trials' masses are the digitised ones, readings under 1 kg taken as zero")
    func masses() throws {
        let walls = try fixture()
        #expect(walls.count == 9)
        for trial in MasonryDebrisTests.trials {
            let wall = try #require(walls[trial.id])
            #expect(abs(Float(try #require(wall["first_bin_m"] as? Double)) - trial.firstBin) < 1e-4)
            #expect(Float(try #require(wall["bin_m"] as? Double)) == MasonryDebrisTests.binWidth)
            let read = try #require(wall["masses_kg"] as? [Double]).map { $0 < 1 ? 0 : Float($0) }
            #expect(read.count == trial.masses.count)
            #expect(zip(read, trial.masses).allSatisfy { abs($0 - $1) < 0.05 }, "\(trial.id)")
        }
    }

    @Test("The tunnel walls' masses are the digitised ones, readings under 1 kg taken as zero")
    func tunnelMasses() throws {
        let walls = try fixture()
        for trial in MasonryDebrisTests.tunnelTrials {
            let wall = try #require(walls[trial.id])
            #expect(Float(try #require(wall["bin_m"] as? Double)) == trial.bin)
            let read = try #require(wall["masses_kg"] as? [Double]).map { $0 < 1 ? 0 : Float($0) }
            #expect(
                zip(read, trial.masses).allSatisfy { abs($0 - $1) < 0.6 } && read.count == trial.masses.count,
                "\(trial.id)")
        }
    }

    @Test("The spread's statistics: WR1A's debris lies within a metre or so of the wall")
    func spread() throws {
        let wr1a = try #require(MasonryDebrisTests.trials.first { $0.id == "WR1A" })
        let spread = MasonryDebrisTests.Spread(firstBin: wr1a.firstBin, masses: wr1a.masses)
        #expect(abs(spread.total - 342) < 0.5)
        #expect(abs(spread.mean - 0.23) < 0.01)
        #expect(spread.median == 0.25 && spread.p90 == 1.25 && spread.furthest == 3)
    }
}
