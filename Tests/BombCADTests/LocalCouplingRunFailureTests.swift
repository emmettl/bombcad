import BlastCore
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Local coupling run failure", .serialized)
struct LocalCouplingRunFailureTests {
    @Test("A storage stop reaches the editor and cannot be kept as a completed run")
    func exhaustedPool() async throws {
        var scene = try MultiBodyFixture.scene()
        scene.domainSize = SIMD3(40, 32, 8)
        let second = scene.structuralObjects[1]
        var body = second.structure!
        body.solids = [Box(min: SIMD3(24, 18, 0), max: SIMD3(24.5, 20, 2))]
        try scene.updateStructureObject(id: second.id, model: body)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        let deadline = ContinuousClock.now + .seconds(20)
        while !model.experimentIsReady {
            try #require(model.errorMessage == nil && ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        var runtime: BlastSolver?
        var setupError: Error?
        model.onSample = { solver in
            guard runtime == nil else { return }
            runtime = solver
            do {
                solver.configuration.bodyCouplingLayout = .tiled
                solver.configuration.bodyCouplingTileCapacity = solver.couplingStatistics.activeTiles + 4
                try solver.setStructures(scene.structuralObjects)
                solver.restart()
                solver.body(id: scene.structuralObjects[0].id)!.solids!.mutateNodes { nodes in
                    for index in nodes.indices { nodes[index].displacement.x += 12 }
                }
            } catch { setupError = error }
        }
        model.run()
        try #require(setupError == nil)
        let solver = try #require(runtime)
        while model.isRunning {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(solver.couplingCapacityExceeded && !solver.interObjectContactDetected)
        #expect(model.errorMessage?.contains("Local coupling storage") == true)
        #expect(!model.canKeepRun && model.savedRuns.isEmpty)
    }
}
