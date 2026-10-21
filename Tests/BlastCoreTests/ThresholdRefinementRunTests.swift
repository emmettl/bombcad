import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The quick estimate's close calls run in the air on a scene cut round them
/// (emmettl/bombcad-work#34): each judged as the blast passes it, within a budget, cancellable.
@Suite("Threshold refinement's run")
struct ThresholdRefinementRunTests {
    /// A street with the charge at x = 20 and two glazed buildings, both close calls.
    static func plan() throws -> ThresholdRefinement.Plan {
        var scene = Scenario(
            name: "Street", domainSize: SIMD3(200, 100, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 50, 0.5)))
        var ids: [UUID] = []
        for at: Float in [40, 70] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(at, 42, 0), max: SIMD3(at + 10, 58, 8))]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
            ids.append(id)
        }
        return try ThresholdRefinement.plan(
            scene: scene, cellSize: 2, doubts: Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.9) }),
            maxCells: 10_000_000)
    }

    @Test("Each building is judged once the blast has passed it, nearest first, and the run ends")
    func refines() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plan = try Self.plan()
        #expect(plan.buildings.count == 2)
        var configuration = SolverConfiguration.recommended
        configuration.refinement = 2
        let run = ThresholdRefinementRun(plan: plan, budgetS: 600)
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var times: [Double] = []
        }
        let seen = Seen()
        let (ending, final) = run.run(device: device, cellSize: 2, configuration: configuration) { progress in
            seen.lock.lock()
            seen.times.append(progress.simulatedS)
            seen.lock.unlock()
        }
        #expect(ending == .finished)
        #expect(Set(final.refined.buildings) == Set(plan.buildings))
        #expect(Set(final.refined.damage.map(\.id)) == Set(plan.buildings))
        #expect(Set(final.refined.structure.map(\.owner)) == Set(plan.buildings))
        #expect(Set(final.refined.glass.map(\.owner)) == Set(plan.buildings))
        #expect(
            final.refined.glass.allSatisfy {
                (0...1).contains($0.someBroken) && (0...1).contains($0.blownOut)
            })
        // The nearer building's answer no later than the farther's.
        let first = try #require(final.readyWallS[plan.buildings[0]])
        let second = try #require(final.readyWallS[plan.buildings[1]])
        #expect(first <= second)
        #expect(final.simulatedS >= plan.untilS * (1 - 1e-6))
        #expect(!seen.times.isEmpty)
        // The front faces of the nearer building are loaded harder than the farther's.
        let near =
            final.refined.glass.filter { $0.owner == plan.buildings[0] }.map(\.fractionBroken).max() ?? 0
        let far =
            final.refined.glass.filter { $0.owner == plan.buildings[1] }.map(\.fractionBroken).max() ?? 0
        #expect(near >= far)
    }

    @Test("Cancelled or out of budget, it stops with what it has judged")
    func stops() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plan = try Self.plan()
        let cancelled = ThresholdRefinementRun(plan: plan, budgetS: 600)
        cancelled.cancel()
        let (ending, final) = cancelled.run(device: device, cellSize: 2, configuration: .recommended) { _ in }
        #expect(ending == .cancelled && final.refined.buildings.isEmpty)
        let broke = ThresholdRefinementRun(plan: plan, budgetS: 0)
        let (spent, none) = broke.run(device: device, cellSize: 2, configuration: .recommended) { _ in }
        #expect(spent == .budget && none.refined.buildings.isEmpty)
    }
}
