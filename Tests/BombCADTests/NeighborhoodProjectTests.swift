import BlastCore
import DocumentKit
import Metal
import Testing

@testable import BombCAD

@Suite("Neighborhood example")
struct NeighborhoodProjectTests {
    @Test("Sixteen independently owned buildings retain openings and identity after save")
    func persistence() throws {
        let scene = try NeighborhoodExample.make()
        #expect(scene.structuralObjects.count == 16)
        #expect(
            scene.structuralObjects.allSatisfy {
                $0.structure?.openings.count == 1 && $0.structure?.elementKind == .shell
            })
        try scene.validateStructuralSeparation()
        #expect(!scene.chargeIsBlocked)
        let document = ProjectDocument(scenario: scene)
        let reopened = try ProjectDocument(archive: document.makeArchive())
        #expect(reopened.scenario == scene)
    }

    @Test("The neighborhood selects local coupling and completes a bounded Metal smoke case")
    func running() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try NeighborhoodExample.make()
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        #expect(solver.couplingStatistics.layout == "tiled")
        #expect(solver.couplingStatistics.bytes < solver.couplingStatistics.denseCells * 80)
        let result = solver.advance(steps: 2)
        #expect(result.isStable && !result.couplingCapacityExceeded && !result.unsupportedInteraction)
        #expect(solver.bodies.count == 16 && result.steps == 2)
    }
}
