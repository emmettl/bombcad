import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Terraced houses", .gpuThreads)
struct TerracedHousesTests {
    @Test(
        "Under a flat roof the row settles on its seats, covering on roof and walls, ties idle; then a charge loads it, nothing blowing up"
    )
    func settlesAndRuns() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(
            device: device,
            scenario: ScenarioPreset.terracedRow(title: "Terraced row", faceClearance: 0, pitch: nil),
            cellSize: 0.5,
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            configuration: .recommended.balloonStart)
        solver.settleStructures()
        #expect(solver.settlements.allSatisfy { $0.settled })
        let shells = try #require(solver.bodies.first?.shells)
        let model = shells.model
        func weight(_ solid: Int) -> Float {
            let box = model.solids[solid]
            let size = box.max - box.min
            return size.x * size.y * size.z * model.material(of: solid).density * 9.81
        }
        var floors: Float = 0
        var roofs: Float = 0
        var ties: Float = 0
        var covering: Float = 0
        for index in model.supports.indices {
            let law = try #require(model.anchorage(ofSupport: index))
            let force = try #require(shells.pairSummary(support: index)).force
            if law.closingGap != nil {
                ties += simd_length(force)
            } else if law.cohesion == 0 {
                covering += force.z
            } else if index % 4 < 2 {
                floors += force.z  // seats 4 to 15, two per plate, floor then roof
            } else {
                roofs += force.z
            }
        }
        let floorWeight = (0..<3).reduce(Float(0)) { $0 + weight(10 + 2 * $1) }
        let roofWeight = (0..<3).reduce(Float(0)) { $0 + weight(11 + 2 * $1) }
        #expect(abs(floors / floorWeight - 1) < 0.03, "floors carry \(floors) N of \(floorWeight)")
        #expect(abs(covering / weight(16) - 1) < 0.03, "covering rests with \(covering) N of \(weight(16))")
        #expect(roofs > roofWeight + 0.5 * weight(16), "roofs carry \(roofs) N, themselves \(roofWeight)")
        #expect(ties < 1e3, "ties carry \(ties) N at rest")
        var rest: [SIMD3<Float>] = []
        shells.mutateNodes { nodes in rest = nodes.map(\.displacement) }
        #expect(TerracedRowDamage(shells: shells, rest: rest).houses.allSatisfy { $0.category == .none })

        let result = solver.advance(until: 0.04)
        #expect(result.isStable)
        let summary = shells.summary()
        #expect(!summary.hasBlownUp)
        #expect(summary.maxDisplacement > 0.001, "front wall moved \(summary.maxDisplacement * 1000) mm")
    }

    @Test(
        "Under a 40° roof the rafters bear on walls and purlins and the tiles hang on them, nothing sliding; then a charge loads it"
    )
    func pitchedSettlesAndRuns() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(
            device: device, scenario: ScenarioPreset.terracedRow(title: "Terraced row", faceClearance: 0),
            cellSize: 0.5,
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            configuration: .recommended.balloonStart)
        solver.settleStructures()
        #expect(solver.settlements.allSatisfy { $0.settled })
        let shells = try #require(solver.bodies.first?.shells)
        let model = shells.model
        func weight(_ solid: Int) -> Float {
            let box = model.solids[solid]
            let size = box.max - box.min
            let volume =
                model.inclination(of: solid).map {
                    let plane = $0.plane(in: box)
                    return plane.lengths.x * plane.lengths.y * $0.thickness
                } ?? size.x * size.y * size.z
            return volume * model.material(of: solid).density * 9.81
        }
        let slopes = model.solids.indices.filter { model.inclination(of: $0)?.trimsWalls == true }
        let coverings = model.solids.indices.filter(TerracedRowDamage.isCovering(in: model))
        #expect(slopes.count == 2 && coverings.count == 2)
        let coveringSeats = TerracedRowDamage.coveringSeats(of: model)
        #expect(coveringSeats.count == 2)
        var ceilings: Float = 0
        var rafters = PartPairs.Summary()
        var tiles = PartPairs.Summary()
        for index in model.supports.indices where index >= 4 {
            let part = try #require(shells.pairSummary(support: index))
            if index < 16 {
                if index % 4 >= 2 { ceilings += part.force.z }
            } else if coveringSeats.contains(index) {
                tiles = tiles.combined(with: part)
            } else {
                rafters = rafters.combined(with: part)
            }
        }
        let ceilingWeight = (0..<3).reduce(Float(0)) { $0 + weight(11 + 2 * $1) }
        let roofWeight = slopes.reduce(Float(0)) { $0 + weight($1) }
        let tileWeight = coverings.reduce(Float(0)) { $0 + weight($1) }
        // The ceilings carry only themselves now; the tiles hang on the slopes, the slopes bear on
        // the walls and purlins with the tiles' weight.
        #expect(abs(ceilings / ceilingWeight - 1) < 0.03, "ceilings carry \(ceilings) N of \(ceilingWeight)")
        #expect(
            abs(tiles.force.z / tileWeight - 1) < 0.03, "tiles rest with \(tiles.force.z) N of \(tileWeight)")
        #expect(
            abs(rafters.force.z / (roofWeight + tileWeight) - 1) < 0.05,
            "rafters carry \(rafters.force.z) N of \(roofWeight + tileWeight)")
        // The cavity ties tie the leaves alone and carry nothing at rest.
        let ties = try (0..<4).reduce(PartPairs.Summary()) {
            $0.combined(with: try #require(shells.pairSummary(support: $1)))
        }
        #expect(simd_length(ties.force) < 1e3, "ties carry \(ties.force) N at rest")
        // Nothing slides: the tiles held on their nibs, the rafters on their seats.
        #expect(tiles.maxSlip < 1e-3 && tiles.separated == 0 && tiles.unseated == 0, "tiles \(tiles)")
        #expect(rafters.maxSlip < 1e-3 && rafters.unseated == 0, "rafters \(rafters)")
        var rest: [SIMD3<Float>] = []
        shells.mutateNodes { nodes in rest = nodes.map(\.displacement) }
        let row = TerracedRowDamage(shells: shells, rest: rest)
        #expect(row.houses.allSatisfy { $0.category == .none && $0.seatsLost.count == 3 })

        let result = solver.advance(until: 0.04)
        #expect(result.isStable)
        let summary = shells.summary()
        #expect(!summary.hasBlownUp)
        #expect(summary.maxDisplacement > 0.001, "front wall moved \(summary.maxDisplacement * 1000) mm")
    }
}
