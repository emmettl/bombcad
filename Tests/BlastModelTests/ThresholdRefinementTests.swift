import Foundation
import Testing
import simd

@testable import BlastModel

/// The quick estimate's close calls, chosen and cut out for the solver (emmettl/bombcad-work#34).
@Suite("Threshold refinement's plan")
struct ThresholdRefinementTests {
    /// A street 200 m long, the charge at x = 20, buildings at x = 50, 80 and 150, and a block.
    static func street(charge x: Float = 20) throws -> (Scenario, [UUID]) {
        var scene = Scenario(
            name: "Street", domainSize: SIMD3(200, 100, 20),
            boxes: [Box(min: SIMD3(100, 10, 0), max: SIMD3(110, 20, 3))],
            charge: Charge(mass: 50, position: SIMD3(x, 50, 0.5)))
        var ids: [UUID] = []
        for at: Float in [50, 80, 150] {
            ids.append(
                try scene.addEnvelopeObject(
                    BuildingEnvelope(solids: [Box(min: SIMD3(at, 42, 0), max: SIMD3(at + 10, 58, 9))])))
        }
        return (scene, ids)
    }

    @Test("A building's doubt is its most unsettled chance among those the view shows")
    func doubts() {
        let owner = UUID()
        let side = FacadeLoadSurrogate.SideGlass(
            owner: owner, axis: 0, outward: -1, distanceM: 30, someBroken: 0.5, blownOut: 0.05,
            fractionBroken: 0.2, thrownPast3b: 0, openingsBlownOut: 0)
        let walls = FacadeLoadSurrogate.StructureChance(owner: owner, wallsModerate: 0.7)
        #expect(
            ThresholdRefinement.doubts(glass: [side], structure: [], quantities: [.someBroken])[owner] == 1)
        // The damage colouring: the blown-out windows and the walls, not glass merely broken.
        let damage = ThresholdRefinement.doubts(glass: [side], structure: [walls])[owner] ?? 0
        #expect(abs(damage - 0.6) < 1e-12)
        #expect(
            ThresholdRefinement.doubts(glass: [side], structure: [], quantities: [.thrownPast3b])[owner] == 0)
    }

    @Test("The nearest close calls, on a scene cut round them on the same cells, moved to the origin")
    func plan() throws {
        let (scene, ids) = try Self.street()
        let doubts = [ids[0]: 0.9, ids[1]: 0.9, ids[2]: 0.1]
        let plan = try ThresholdRefinement.plan(
            scene: scene, cellSize: 1, doubts: doubts, maxCells: 10_000_000)
        #expect(plan.buildings == [ids[0], ids[1]])
        // 70 m to the far side of the second, and 4 m/kg^(1/3) of clearance: whole cells from 0.
        let half = 70 + 4 * cbrt(Float(50))
        #expect(plan.scene.domainSize == SIMD3((20 + half).rounded(.up), 100, 20))
        #expect(plan.shift == .zero)
        #expect(plan.scene.charge.position == scene.charge.position)
        // The third building lies outside; the block is clipped to the cut.
        #expect(Set(plan.scene.envelopeObjects.map(\.id)) == [ids[0], ids[1]])
        #expect(
            plan.scene.boxes == [Box(min: SIMD3(100, 10, 0), max: SIMD3((20 + half).rounded(.up), 20, 3))])
        #expect((plan.readyAtS[ids[0]] ?? 0) < (plan.readyAtS[ids[1]] ?? 0))
        #expect(plan.untilS == plan.readyAtS[ids[1]])
        #expect(plan.drawKeys[ids[0]] == scene.object(id: ids[0])?.drawKey)
        #expect(!plan.corridors.isEmpty)
        // Too few cells for both: the nearer alone, the farther left out.
        let small = try ThresholdRefinement.plan(
            scene: scene, cellSize: 1, doubts: doubts, maxCells: plan.cells - 1)
        #expect(small.buildings == [ids[0]] && small.leftOut == 1)
    }

    @Test("A cut away from the corner moves everything by the same whole cells")
    func moved() throws {
        let (scene, ids) = try Self.street(charge: 120)
        let plan = try ThresholdRefinement.plan(
            scene: scene, cellSize: 1, doubts: [ids[2]: 0.9], maxCells: 10_000_000)
        #expect(plan.buildings == [ids[2]])
        let low = -plan.shift
        #expect(low.x > 0 && low.x == low.x.rounded() && low.y == 0)
        #expect(plan.scene.charge.position == scene.charge.position + plan.shift)
        let before = try #require(scene.object(id: ids[2])?.bounds)
        let after = try #require(plan.scene.object(id: ids[2])?.bounds)
        #expect(after.min == before.min + plan.shift && after.max == before.max + plan.shift)
    }

    @Test("No plan without close calls, nor for a scene the cut cannot carry")
    func refusals() throws {
        var (scene, ids) = try Self.street()
        #expect(throws: ThresholdRefinement.Refusal.noCloseCalls) {
            try ThresholdRefinement.plan(
                scene: scene, cellSize: 1, doubts: [ids[0]: 0.2], maxCells: 10_000_000)
        }
        #expect(throws: ThresholdRefinement.Refusal.tooLarge(cells: 75 * 100 * 20)) {
            try ThresholdRefinement.plan(scene: scene, cellSize: 1, doubts: [ids[0]: 0.9], maxCells: 1000)
        }
        scene.additionalCharges = [Charge(mass: 5, position: SIMD3(10, 10, 0.5))]
        #expect(throws: ThresholdRefinement.Refusal.unsupported("more than one charge")) {
            try ThresholdRefinement.plan(
                scene: scene, cellSize: 1, doubts: [ids[0]: 0.9], maxCells: 10_000_000)
        }
    }
}
