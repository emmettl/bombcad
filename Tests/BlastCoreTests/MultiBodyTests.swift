import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Independent structural bodies", .serialized)
struct MultiBodyTests {
    func scene(clamped: Bool = true, shells: Bool = false) throws -> Scenario {
        let first = Box(x: 2...2.5, y: 2...4, height: 2)
        let second = Box(x: 8...8.5, y: 2...4, height: 2)
        func model(_ box: Box, size: Float) -> StructureModel {
            var body = StructureModel(
                solids: [box], material: .plainConcrete, elementSize: size, fixedBase: true)
            if clamped { body.supports = [Box(min: box.min - 0.01, max: box.max + 0.01)] }
            if shells { body.elementKind = .shell }
            return body
        }
        var scene = Scenario(
            name: "Two walls", domainSize: SIMD3(12, 8, 6), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(5, 3, 1)),
            gauges: [Gauge("Left", at: SIMD3(1.5, 3, 1)), Gauge("Right", at: SIMD3(9, 3, 1))],
            structure: model(first, size: 0.25))
        try scene.addStructureObject(model(second, size: 0.5), name: "Second wall")
        return scene
    }

    func configuration(refinement: Int = 0) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.skipStillAir = false
        configuration.refinement = refinement
        configuration.refinementMemory = 16 * 1024 * 1024
        configuration.airSleepThreshold = 0
        configuration.airSleepCrossings = 0
        return configuration
    }

    @Test("Stationary bodies of different mesh sizes match the equivalent fixed scene", arguments: [0, 2])
    func fixedParity(refinement: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try scene()
        var fixed = scene
        fixed.boxes = scene.structuralObjects.flatMap { $0.structure!.solids }
        for object in scene.structuralObjects { try fixed.updateStructureObject(id: object.id, model: nil) }
        let config = configuration(refinement: refinement)
        let moving = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        let rigid = try BlastSolver(device: device, scenario: fixed, cellSize: 0.5, configuration: config)
        #expect(moving.bodies.count == 2)
        #expect(moving.fluidCellCount == rigid.fluidCellCount)
        let result = moving.advance(until: 0.004)
        rigid.advance(until: 0.004)
        #expect(result.isStable && !result.unsupportedInteraction)
        #expect(moving.bodies.allSatisfy { $0.time == moving.time })
        var error: Float = 0
        for k in 0..<moving.grid.nz {
            for j in 0..<moving.grid.ny {
                for i in 0..<moving.grid.nx {
                    let a = moving.primitive(i, j, k)
                    let b = rigid.primitive(i, j, k)
                    error = max(error, abs(a.pressure - b.pressure) / max(b.pressure, 1))
                }
            }
        }
        #expect(error < 1e-5, "Relative pressure error: \(error)")
        for object in scene.structuralObjects {
            let body = try #require(moving.body(id: object.id))
            #expect(body.summary()?.maxDisplacement == 0)
            #expect(body.solids?.model.elementSize == object.structure?.elementSize)
        }
    }

    @Test(
        "Reordering does not change loads, geometry ownership or coupled responses", arguments: [false, true])
    func orderIndependence(shells: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try scene(clamped: false, shells: shells)
        var reordered = scene
        try reordered.reorderObjects(scene.objects.map(\.id).reversed())
        let first = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(refinement: 2))
        let second = try BlastSolver(
            device: device, scenario: reordered, cellSize: 0.5, configuration: configuration(refinement: 2))
        #expect(first.advance(until: 0.006).isStable)
        #expect(second.advance(until: 0.006).isStable)
        #expect(!first.interObjectContactDetected && !second.interObjectContactDetected)
        #expect(first.gaugeHistories == second.gaugeHistories)
        for object in scene.structuralObjects {
            let a = try #require(first.body(id: object.id))
            let b = try #require(second.body(id: object.id))
            #expect(a.summary() == b.summary())
            let left = try #require(a.solids?.nodeBuffer ?? a.shells?.nodeBuffer)
            let right = try #require(b.solids?.nodeBuffer ?? b.shells?.nodeBuffer)
            #expect(
                Data(bytes: left.contents(), count: left.length)
                    == Data(bytes: right.contents(), count: right.length))
        }
        let surface = try #require(first.structureSurface())
        #expect(Set(surface.objectIDs) == Set(scene.structuralObjects.map(\.id)))
        #expect(surface.object.count == surface.faceCount)
        #expect(Set(surface.object) == [0, 1])
        #expect(surface.points.map(\.x).max()! > 8)
    }

    @Test("Each compiled body retains its independent prescribed-load mechanics")
    func independentMechanics() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try scene(clamped: false)
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        for object in scene.structuralObjects {
            let compiled = try #require(solver.body(id: object.id)?.solids)
            let reference = try StructureSolver(device: device, model: object.structure!)
            let load = PressureLoad(
                axis: 0, positiveSide: false, history: [SIMD2(0, 10_000), SIMD2(0.002, 0)])
            compiled.appliedLoad = load
            reference.appliedLoad = load
            compiled.advance(steps: 20)
            reference.advance(steps: 20)
            #expect(compiled.summary() == reference.summary())
            #expect(
                Data(bytes: compiled.nodeBuffer.contents(), count: compiled.nodeBuffer.length)
                    == Data(bytes: reference.nodeBuffer.contents(), count: reference.nodeBuffer.length))
        }
    }

    @Test("A body entering another envelope stops further steps and cannot restart silently")
    func unsupportedInteraction() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try scene(clamped: false)
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        let first = try #require(solver.body(id: scene.structuralObjects[0].id)?.solids)
        first.mutateNodes { nodes in
            for index in nodes.indices { nodes[index].displacement.x += 6 }
        }
        let result = solver.advance(steps: 8)
        #expect(result.unsupportedInteraction)
        #expect(solver.interObjectContactDetected)
        #expect(result.steps <= 1)
        let stopped = solver.time
        #expect(solver.advance(steps: 8).steps == 0)
        #expect(solver.time == stopped)
        solver.restart()
        #expect(!solver.interObjectContactDetected)
    }

    @Test("Intersecting initial envelopes are rejected before simulation")
    func initialOverlap() throws {
        var scene = try scene()
        let id = scene.structuralObjects[1].id
        try scene.updateStructureObject(id: id, model: scene.structure!)
        #expect(throws: SceneObjectError.self) { try scene.validateStructuralSeparation() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(throws: SceneObjectError.self) {
            try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        }
    }

    @Test("Replacing the body set removes old masks without turning them into scenery")
    func replacementMasks() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try scene()
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        var remaining = scene
        try remaining.updateStructureObject(id: scene.structuralObjects[0].id, model: nil)
        let reference = try BlastSolver(device: device, scenario: remaining, cellSize: 0.5)
        try solver.setStructures(remaining.structuralObjects)
        solver.restart()
        #expect(solver.fluidCellCount == reference.fluidCellCount)
        try solver.setStructures([])
        solver.restart()
        #expect(solver.fluidCellCount == solver.grid.cellCount)
    }

    @Test("Mixed and shell bodies export with stable face ownership")
    func renderingAndExport() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var scene = try scene(shells: true)
        let first = scene.structuralObjects[0]
        var mixed = first.structure!
        mixed.solids.append(Box(x: 2...2.5, y: 4...4.5, height: 2))
        mixed.elementKind = .solid
        mixed.solidElementKind = [nil, .shell]
        mixed.supports = [Box(min: mixed.bounds.min - 0.01, max: mixed.bounds.max + 0.01)]
        try scene.updateStructureObject(id: first.id, model: mixed)
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(refinement: 2))
        #expect(solver.body(id: first.id)?.mixed != nil)
        #expect(solver.advance(until: 0.001).isStable)
        #expect(!solver.interObjectContactDetected)
        let surface = try #require(solver.structureSurface())
        #expect(Set(surface.objectIDs) == Set(scene.structuralObjects.map(\.id)))
        #expect(surface.object.count == surface.faceCount)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("two-bodies.usda")
        let writer = try USDSceneWriter(url: url, scenario: scene, frameInterval: 0.001)
        try writer.append(surface)
        try writer.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("primvars:object.timeSamples"))
        for object in scene.structuralObjects { #expect(text.contains(object.id.uuidString)) }
    }
}
