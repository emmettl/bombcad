import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Local body coupling", .serialized)
struct TiledCouplingTests {
    func configuration(_ layout: BodyCouplingLayout, refinement: Int = 1, skip: Bool = false)
        -> SolverConfiguration
    {
        var config = MultiBodyTests().configuration(refinement: refinement)
        config.bodyCouplingLayout = layout
        config.skipStillAir = skip
        return config
    }

    func compare(_ a: BlastSolver, _ b: BlastSolver) {
        #expect(a.time == b.time && a.stepCount == b.stepCount)
        #expect(a.gaugeHistories == b.gaugeHistories)
        #expect(a.fluidCellCount == b.fluidCellCount)
        #expect(a.totals().mass == b.totals().mass && a.totals().energy == b.totals().energy)
        for k in 0..<a.grid.nz {
            for j in 0..<a.grid.ny {
                for i in 0..<a.grid.nx {
                    #expect(a.primitive(i, j, k) == b.primitive(i, j, k))
                }
            }
        }
        for body in a.bodies {
            let other = b.body(id: body.id)!
            #expect(body.summary() == other.summary())
            for pair in [
                (body.solids?.nodeBuffer, other.solids?.nodeBuffer),
                (body.shells?.nodeBuffer, other.shells?.nodeBuffer),
            ] {
                if let left = pair.0, let right = pair.1 {
                    #expect(
                        Data(bytes: left.contents(), count: left.length)
                            == Data(bytes: right.contents(), count: right.length))
                }
            }
        }
    }

    @Test("Dense and tiled coupling preserve full air states and body loads", arguments: [0, 1, 2], [1, 2])
    func parity(kind: Int, refinement: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var scene = try MultiBodyTests().scene(clamped: false, shells: kind == 1)
        if kind == 2 {
            let first = scene.structuralObjects[0]
            var body = first.structure!
            body.solids.append(Box(x: 2...2.5, y: 4...4.5, height: 2))
            body.solidElementKind = [nil, .shell]
            try scene.updateStructureObject(id: first.id, model: body)
        }
        let dense = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5,
            configuration: configuration(.dense, refinement: refinement))
        let local = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5,
            configuration: configuration(.tiled, refinement: refinement))
        #expect(local.couplingStatistics.layout == "tiled")
        let a = dense.advance(until: 0.003)
        let b = local.advance(until: 0.003)
        #expect(a.isStable && b.isStable && !b.couplingCapacityExceeded && !b.unsupportedInteraction)
        compare(dense, local)
    }

    func spreadScene() throws -> Scenario {
        var scene = try MultiBodyTests().scene()
        scene.domainSize = SIMD3(40, 32, 8)
        scene.charge.mass = 0
        let second = scene.structuralObjects[1]
        var model = second.structure!
        model.solids = [Box(min: SIMD3(24, 18, 0), max: SIMD3(24.5, 20, 2))]
        model.supports = [Box(min: model.bounds.min - 0.01, max: model.bounds.max + 0.01)]
        try scene.updateStructureObject(id: second.id, model: model)
        return scene
    }

    @Test("Movement allocates pages, reopens vacated cells and restart removes old outlines")
    func movement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try spreadScene()
        let dense = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.dense))
        let local = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.tiled))
        let initial = local.couplingStatistics.activeTiles
        let id = scene.structuralObjects[0].id
        for solver in [dense, local] {
            solver.body(id: id)!.solids!.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].displacement.x += 8 }
            }
            #expect(solver.advance(steps: 2).isStable)
        }
        #expect(local.couplingStatistics.activeTiles > initial)
        #expect(!local.couplingCapacityExceeded)
        compare(dense, local)
        let stale = local.grid.cell(containing: SIMD3(10.25, 3, 1))
        #expect(
            local.maskBuffer.contents().load(
                fromByteOffset: local.grid.index(stale.i, stale.j, stale.k), as: UInt8.self) == 1)
        local.restart()
        #expect(
            local.maskBuffer.contents().load(
                fromByteOffset: local.grid.index(stale.i, stale.j, stale.k), as: UInt8.self) == 0)
        let original = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.tiled))
        #expect(local.fluidCellCount == original.fluidCellCount)
    }

    @Test("Exhausted pools halt explicitly without reporting body contact")
    func budget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try spreadScene()
        let probe = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.tiled))
        var config = configuration(.tiled)
        config.bodyCouplingTileCapacity = probe.couplingStatistics.activeTiles + 4
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        solver.body(id: scene.structuralObjects[0].id)!.solids!.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].displacement.x += 12 }
        }
        let result = solver.advance(steps: 3)
        #expect(result.couplingCapacityExceeded && !result.unsupportedInteraction)
        #expect(!solver.interObjectContactDetected)
        let stopped = solver.time
        #expect(solver.advance(steps: 3).steps == 0 && solver.time == stopped)
        solver.restart()
        #expect(!solver.couplingCapacityExceeded)
    }

    @Test("Frozen-air mechanics do not consume new pages and body replacement removes old masks")
    func frozenAndReplacement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try spreadScene()
        var config = configuration(.tiled)
        config.airSleepThreshold = 1
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        #expect(solver.advance(steps: 64).isStable)
        #expect(solver.airIsAsleep)
        let pages = solver.couplingStatistics.activeTiles
        solver.body(id: scene.structuralObjects[0].id)!.solids!.mutateNodes { nodes in
            for index in nodes.indices { nodes[index].displacement.x += 12 }
        }
        let result = solver.advance(steps: 4)
        #expect(result.isStable && !result.couplingCapacityExceeded && !result.unsupportedInteraction)
        #expect(solver.couplingStatistics.activeTiles == pages)
        var single = scene
        try single.updateStructureObject(id: scene.structuralObjects[0].id, model: nil)
        try solver.setStructures(single.structuralObjects)
        solver.restart()
        let reference = try BlastSolver(device: device, scenario: single, cellSize: 0.5)
        #expect(solver.couplingStatistics.layout == "dense")
        #expect(solver.fluidCellCount == reference.fluidCellCount)
    }

    @Test("Automatic allocation saves storage for separated structures and preserves the one-body path")
    func storage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try spreadScene()
        let dense = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.dense))
        let auto = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.automatic))
        #expect(auto.couplingStatistics.layout == "tiled")
        #expect(auto.couplingStatistics.bytes < dense.couplingStatistics.bytes)
        var one = scene
        try one.updateStructureObject(id: scene.structuralObjects[1].id, model: nil)
        let single = try BlastSolver(
            device: device, scenario: one, cellSize: 0.5, configuration: configuration(.tiled))
        #expect(single.couplingStatistics.layout == "dense")
    }

    @Test(
        "Widely separated bodies preserve refined air with and without sleeping tiles",
        arguments: [false, true])
    func spreadParity(skip: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var scene = try spreadScene()
        scene.charge.mass = 0.02
        let dense = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5,
            configuration: configuration(.dense, refinement: 2, skip: skip))
        let local = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5,
            configuration: configuration(.tiled, refinement: 2, skip: skip))
        for solver in [dense, local] { #expect(solver.advance(until: 0.002).isStable) }
        compare(dense, local)
    }

    @Test("Skipping still air agrees across layouts and object reorder")
    func skipAndReorder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try MultiBodyTests().scene(clamped: false)
        var reordered = scene
        try reordered.reorderObjects(scene.objects.map(\.id).reversed())
        let dense = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.dense, skip: true))
        let a = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration(.tiled, skip: true))
        let b = try BlastSolver(
            device: device, scenario: reordered, cellSize: 0.5,
            configuration: configuration(.tiled, skip: true))
        for solver in [dense, a, b] { #expect(solver.advance(until: 0.004).isStable) }
        compare(dense, a)
        compare(a, b)
    }

    @Test("Loose debris crosses tile boundaries with the same air reaction and momentum budget")
    func debris() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var scene = Scenario(
            name: "Two debris packets", domainSize: SIMD3(32, 16, 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [Box(min: SIMD3(8, 6, 3), max: SIMD3(8.25, 6.25, 3.25))],
                material: .structuralSteel, elementSize: 0.25, fixedBase: false))
        try scene.addStructureObject(
            StructureModel(
                solids: [Box(min: SIMD3(20, 6, 3), max: SIMD3(20.25, 6.25, 3.25))],
                material: .structuralSteel, elementSize: 0.25, fixedBase: false))
        scene.reflectiveFaces = []
        func make(_ layout: BodyCouplingLayout, drag: Bool = true) throws -> BlastSolver {
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: 0.5, configuration: configuration(layout))
            solver.fill { _, _, _ in Primitive(density: 1.225, velocity: SIMD3(100, 0, 0), pressure: 101_325)
            }
            for body in solver.bodies {
                let solid = body.solids!
                solid.gravity = 0
                solid.groundContact = false
                solid.debrisDrag = drag
                solid.erode { _, _, _ in true }
                solid.mutateNodes { nodes in
                    for index in nodes.indices {
                        nodes[index].displacement.x = -0.05
                        nodes[index].velocity = SIMD3(50, 0, 0)
                    }
                }
            }
            solver.mutateMask { mask in for i in mask.indices { mask[i] = 0 } }
            return solver
        }
        let dense = try make(.dense)
        let local = try make(.tiled)
        let passive = try make(.dense, drag: false)
        for solver in [dense, local, passive] {
            #expect(solver.advance(until: 0.003).isStable)
            #expect(!solver.couplingCapacityExceeded && !solver.interObjectContactDetected)
        }
        compare(dense, local)
        func bodyMomentum(_ solver: BlastSolver) -> SIMD3<Double> {
            solver.bodies.reduce(.zero) { $0 + $1.solids!.momentum() }
        }
        let gained = bodyMomentum(local) - bodyMomentum(passive)
        let lost = local.momentum() - passive.momentum()
        #expect(gained.x > 0)
        #expect(abs(gained.x + lost.x) / gained.x < 0.01)
        for body in local.bodies {
            body.solids!.mutateNodes { nodes in
                #expect(nodes.allSatisfy { $0.displacement.x > 0.0625 })
            }
        }
    }
}
