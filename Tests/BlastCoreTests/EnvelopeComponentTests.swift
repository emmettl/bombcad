import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Envelope components from the geometry alone (the component spec, v1.2).
@Suite("Envelope components")
struct EnvelopeComponentTests {
    let owner = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    @Test("The street study's building has one panel a wall and one roof panel, every edge supported")
    func streetBuilding() throws {
        var scene = try StreetInteractionStudy.make(.isolated, clamped: true)
        let id = try #require(scene.structuralObjects.first?.id)
        try scene.useEnvelope(id: id)
        let envelope = try #require(scene.envelopeObjects.first?.envelope)
        let components = envelope.components(owner: id, cellSize: 0.5)
        #expect(components.map(\.kind) == [.wall, .wall, .wall, .wall, .roof])
        #expect(
            components.allSatisfy { $0.id.hasSuffix(".0") && $0.supportEdges == [true, true, true, true] })
        #expect(components[0].id == "\(id.uuidString)/wall/0.0")
        // The front wall faces -y, the back +y, the left -x, the right +x; the roof up.
        #expect(components.map(\.outward) == [-1, 1, -1, 1, 1])
        #expect(components.map(\.axis) == [1, 1, 0, 0, 2])
        #expect(components[0].spans == SIMD2(6, 4))
        #expect(components[0].inPlaneAxes == (0, 2))
    }

    @Test(
        "A wall alone is cut into equal panels at most 6 m wide and 3 m tall; width and height cuts hold nothing"
    )
    func wallAlone() throws {
        let envelope = try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(12, 0.3, 6))])
        let components = envelope.components(owner: owner, cellSize: 0.5)
        #expect(components.count == 4)
        #expect(components.map(\.panel) == [0, 1, 2, 3])
        #expect(components[1].region.min.x == 6 && components[1].region.max.z == 3)
        #expect(components[2].region.min.z == 3 && components[2].region.min.x == 0)
        // On the ground only.
        #expect(components[0].supportEdges == [false, false, true, false])
        #expect(components[3].supportEdges == [false, false, false, false])
    }

    @Test("A slab crossing a wall cuts it there, a support, and no storey cuts follow")
    func slabSupport() throws {
        let envelope = try BuildingEnvelope(solids: [
            Box(min: .zero, max: SIMD3(6, 0.3, 7)),
            Box(min: SIMD3(0, 0, 2.85), max: SIMD3(6, 6, 3.15)),
        ])
        let walls = envelope.components(owner: owner, cellSize: 0.5).filter { $0.kind == .wall }
        #expect(walls.count == 2)
        #expect(walls[0].region.max.z == 3 && walls[1].region.min.z == 3 && walls[1].region.max.z == 7)
        #expect(walls[0].supportEdges[3] && walls[1].supportEdges[2])
    }

    @Test("A block gives façade strips a storey tall on each side, the last taking the remainder, and a roof")
    func block() throws {
        let envelope = try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(10, 8, 7))])
        let components = envelope.components(owner: owner, cellSize: 0.5)
        #expect(components.count == 13)
        let strips = components.filter { $0.kind == .facade }
        #expect(strips.map(\.source) == Array(0..<12))
        #expect(strips.prefix(3).map(\.region.max.z) == [3, 6, 7])
        #expect(strips.map(\.outward) == [-1, -1, -1, 1, 1, 1, -1, -1, -1, 1, 1, 1])
        #expect(strips.map(\.axis) == [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
        #expect(components.last?.kind == .roof && components.last?.id == "\(owner.uuidString)/roof/0.0")
        // 6.5 m: the half metre left over joins the strip below.
        let low = try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(10, 8, 6.5))])
        #expect(
            low.components(owner: owner).filter { $0.kind == .facade }.prefix(2).map(\.region.max.z) == [
                3, 6.5,
            ])
    }

    @Test("Glass in a detailed structure becomes panes, solid in the air, each held on four edges")
    func panes() throws {
        var model = StructureModel(
            solids: [
                Box(min: .zero, max: SIMD3(6, 0.3, 3)), Box(min: SIMD3(2, 0.1, 1), max: SIMD3(4, 0.11, 2)),
            ],
            elementSize: 0.1, fixedBase: true)
        model.openings = [Box(min: SIMD3(2, 0, 1), max: SIMD3(4, 0.3, 2))]
        model.solidMaterial = [nil, .annealedGlass]
        let envelope = try BuildingEnvelope(structure: model)
        #expect(envelope.solids.count == 1 && envelope.panes.count == 1)
        #expect(envelope.occupies(SIMD3(3, 0.105, 1.5)) && !envelope.occupies(SIMD3(3, 0.25, 1.5)))
        #expect(envelope.blockSources.last == .pane(0))
        let pane = try #require(envelope.components(owner: owner).last)
        #expect(pane.kind == .pane && pane.axis == 1 && pane.supportEdges == [true, true, true, true])
        #expect(pane.id == "\(owner.uuidString)/pane/0.0")
        // Encoded only when there are panes; a scene with them saves at its own version.
        let plain = try BuildingEnvelope(solids: model.solids.prefix(1).map { $0 })
        #expect(try !String(decoding: JSONEncoder().encode(plain), as: UTF8.self).contains("panes"))
        #expect(
            try JSONDecoder().decode(BuildingEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        try scene.addEnvelopeObject(plain)
        #expect(!scene.hasEnvelopePanes)
        try scene.addEnvelopeObject(envelope)
        #expect(scene.hasEnvelopePanes)
    }
}

/// The recorder of each component's load (`EnvelopeComponentRecorder`).
@Suite("Envelope component histories", .serialized, .gpuThreads)
struct EnvelopeComponentHistoryTests {
    /// A 2 m wall, 0.5 m thick, in a closed 8 m box of air.
    func scene(openings: [Box] = []) throws -> Scenario {
        var scene = Scenario(
            name: "Wall", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        scene.reflectiveFaces = .all
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(3, 3, 0), max: SIMD3(5, 3.5, 3))], openings: openings),
            name: "Wall")
        return scene
    }

    @Test("Uniform pressure fills each bin by its overlap with the steps, the last partial")
    func uniform() throws {
        let scene = try scene()
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 103_325))
        solver.restart()
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.001))
        let command = try #require(solver.encodeBatch(steps: 50, timeLimit: 0.00025))
        command.commit()
        command.waitUntilCompleted()
        _ = solver.completeBatch()
        let history = try #require(solver.envelopeComponentHistories()?.first)
        #expect(history.component.kind == .wall && history.binS == 1e-4)
        #expect(history.outerAreaM2 == 6 && history.innerAreaM2 == 6 && history.faceCount == 48)
        // 2,000 Pa over each whole bin of 0.1 ms, and over the part of the last the run reached.
        let bins = Int((solver.time / 1e-4).rounded(.up))
        let expected = (0..<bins).map {
            Float(2000 * (min(solver.time, Double($0 + 1) * 1e-4) - Double($0) * 1e-4))
        }
        for side in [history.outerImpulsePaS, history.innerImpulsePaS] {
            #expect(side.count == bins)
            for (bin, expected) in zip(side, expected) { #expect(abs(bin - expected) < 1e-5) }
        }
        #expect(abs(history.peakOuterPa - 2000) < 0.1 && abs(history.peakNetPa) < 0.1)
        #expect(!history.truncated && !history.invalid && history.outerMaxPa == nil)
    }

    @Test("Each side's binned impulse is the mean of its faces' own integrals")
    func againstFaces() throws {
        // The street study's building, four walls and a roof: components in more than one
        // threadgroup.
        var scene = Scenario(
            name: "Building", domainSize: SIMD3(12, 12, 6), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(6, 1.5, 1)))
        scene.reflectiveFaces = .all
        let solids = [
            Box(min: SIMD3(3, 3, 0), max: SIMD3(9, 3.5, 4)), Box(min: SIMD3(3, 8.5, 0), max: SIMD3(9, 9, 4)),
            Box(min: SIMD3(3, 3.5, 0), max: SIMD3(3.5, 8.5, 4)),
            Box(min: SIMD3(8.5, 3.5, 0), max: SIMD3(9, 8.5, 4)),
            Box(min: SIMD3(3, 3, 4), max: SIMD3(9, 9, 4.5)),
        ]
        try scene.addEnvelopeObject(BuildingEnvelope(solids: solids), name: "Building")
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25)
        try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
        _ = solver.advance(steps: 60)
        let faces = try #require(solver.envelopeExposureSnapshot()?.first?.surfaces)
        let histories = try #require(solver.envelopeComponentHistories())
        #expect(histories.count == 5 && histories.contains { $0.peakOuterPa > 1000 })
        for history in histories {
            let component = history.component
            for (outward, binned) in [
                (component.outward, history.outerImpulsePaS), (-component.outward, history.innerImpulsePaS),
            ] {
                let own = faces.filter { face in
                    let solid = face.positionM - face.normal * 0.125
                    return face.normal[component.axis] == Float(outward)
                        && (0..<3).allSatisfy {
                            solid[$0] >= component.region.min[$0] && solid[$0] <= component.region.max[$0]
                        }
                }
                #expect(!own.isEmpty)
                let mean = own.map { Double($0.signedImpulsePaS) }.reduce(0, +) / Double(own.count)
                let sum = binned.map(Double.init).reduce(0, +)
                #expect(
                    abs(sum - mean) <= 1e-4 * abs(mean) + 1e-6, "\(component.id) \(outward): \(sum) \(mean)")
            }
            #expect(!history.truncated)
            #expect(history.outerMaxPa?.count == history.outerImpulsePaS.count)
            #expect(history.outerMaxPa?.max() == history.peakOuterPa)
        }
    }

    @Test("A face in still air reads the still air: the same bits as reading its cell")
    func stillTiles() throws {
        var scene = Scenario(
            name: "Two walls", domainSize: SIMD3(24, 8, 6), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(2, 4, 1)))
        for x: Float in [5, 19] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 2, 0), max: SIMD3(x + 0.5, 6, 3))]),
                name: "Wall \(x)")
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        func histories(skipping: Bool) throws -> [EnvelopeComponentHistory] {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects,
                options: EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
            solver.envelopeComponentRecorder?.skipStillTiles = skipping
            _ = solver.advance(steps: 40)
            return try #require(solver.envelopeComponentHistories())
        }
        let skipped = try histories(skipping: true)
        let read = try histories(skipping: false)
        // The far wall stays in still air through the run, the near one does not.
        #expect(skipped.first!.peakOuterPa != skipped.last!.peakOuterPa)
        for (a, b) in zip(skipped, read) {
            #expect(a.outerImpulsePaS.map(\.bitPattern) == b.outerImpulsePaS.map(\.bitPattern))
            #expect(a.innerImpulsePaS.map(\.bitPattern) == b.innerImpulsePaS.map(\.bitPattern))
            #expect(a.outerMaxPa!.map(\.bitPattern) == b.outerMaxPa!.map(\.bitPattern))
            #expect(a.peakNetPa.bitPattern == b.peakNetPa.bitPattern)
        }
    }

    @Test("Histories repeat bit for bit however the steps are cut into batches")
    func batching() throws {
        var scene = try scene()
        scene.charge = Charge(mass: 0.05, position: SIMD3(4, 1.5, 1))
        let device = try #require(MTLCreateSystemDefaultDevice())
        func histories(_ batch: Int) throws -> [EnvelopeComponentHistory] {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects,
                options: EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
            for _ in 0..<(48 / batch) { _ = solver.advance(steps: batch) }
            return try #require(solver.envelopeComponentHistories())
        }
        let whole = try histories(48)
        for batch in [1, 5] {
            let cut = try histories(batch == 5 ? 6 : batch)
            for (a, b) in zip(whole, cut) {
                #expect(
                    a.outerImpulsePaS.map(\.bitPattern) == b.outerImpulsePaS.map(\.bitPattern), "\(batch)")
                #expect(
                    a.innerImpulsePaS.map(\.bitPattern) == b.innerImpulsePaS.map(\.bitPattern), "\(batch)")
                #expect(a.peakNetPa.bitPattern == b.peakNetPa.bitPattern)
            }
        }
    }

    @Test("Recording leaves coarse and refined air bit-identical", arguments: [1, 2])
    func passive(refinement: Int) throws {
        var scene = try scene()
        scene.charge = Charge(mass: 0.02, position: SIMD3(4, 1.5, 1))
        var config = SolverConfiguration()
        config.refinement = refinement
        config.refinementMemory = 16 << 20
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plain = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        let observed = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        try observed.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(windowS: 0.01, openingsAsPanes: true))
        _ = plain.advance(steps: 16)
        _ = observed.advance(steps: 16)
        let states = plain.withState { Array($0) }
        observed.withState { cells in
            #expect(
                zip(states, cells).allSatisfy { a, b in
                    a.density == b.density && a.energy == b.energy && a.momentumX == b.momentumX
                        && a.momentumY == b.momentumY && a.momentumZ == b.momentumZ
                })
        }
    }

    @Test("Past the window steps are not binned and say so; a budget too small widens the bins")
    func windowAndBudget() throws {
        let scene = try scene()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 103_325))
        solver.restart()
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.0001))
        let command = try #require(solver.encodeBatch(steps: 50, timeLimit: 0.0004))
        command.commit()
        command.waitUntilCompleted()
        _ = solver.completeBatch()
        let history = try #require(solver.envelopeComponentHistories()?.first)
        #expect(history.truncated && history.outerImpulsePaS.count == 2)
        // One component: 8 bytes a bin; five bins fit 40 bytes, so 1 ms of 0.1 ms bins widens to 0.3 ms.
        let budgeted = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        try budgeted.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.001, memoryBudget: 40))
        _ = budgeted.advance(steps: 1)
        #expect(budgeted.envelopeComponentHistories()?.first.map { abs($0.binS - 3e-4) < 1e-12 } == true)
    }

    @Test("An opening recorded as a pane reads the air just outside the wall on both sides")
    func openingAsPane() throws {
        let scene = try scene(openings: [Box(min: SIMD3(3.5, 3, 1), max: SIMD3(4.5, 3.5, 2))])
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(windowS: 0.001, openingsAsPanes: true))
        let components = try #require(solver.envelopeComponents())
        let opening = try #require(components.last)
        #expect(opening.id.hasSuffix("/opening/0") && opening.kind == .pane && opening.axis == 1)
        _ = solver.advance(steps: 2)
        let history = try #require(solver.envelopeComponentHistories()?.last)
        // Two cells by two on each side.
        #expect(history.outerAreaM2 == 1 && history.innerAreaM2 == 1)
    }

    @Test("Cost: a neighbourhood's histories take a few MB and read no more cells than the surface recorder")
    func cost() throws {
        var scene = Scenario(
            name: "Neighbourhood", domainSize: SIMD3(96, 96, 8), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(4, 4, 1)))
        let template = try #require(
            try StreetInteractionStudy.make(.isolated, clamped: true).structuralObjects.first?.structure)
        for index in 0..<64 {
            let offset = SIMD3<Float>(10 + Float(index % 8) * 10 - 16, 10 + Float(index / 8) * 10 - 6, 0)
            try scene.addEnvelopeObject(
                BuildingEnvelope(
                    solids: template.solids.map { Box(min: $0.min + offset, max: $0.max + offset) }),
                name: "Building \(index + 1)")
        }
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        let before = solver.memoryFootprint
        try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
        let surfaces = solver.memoryFootprint - before
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.06))
        let histories = solver.memoryFootprint - before - surfaces
        let components = try #require(solver.envelopeComponents())
        #expect(components.count == 64 * 5)
        // 320 components, 601 bins of two sides, and their faces once.
        #expect(histories < 2_500_000, "\(histories) bytes")
        let faces = solver.envelopeExposureSnapshot()!.reduce(0) { $0 + $1.surfaces.count }
        let read = solver.envelopeComponentHistories()!.reduce(0) { $0 + $1.faceCount }
        #expect(read <= faces, "\(read) cells read a step against \(faces) faces")
        #expect(surfaces > 0)
    }

    @Test("Beside a moving structure an envelope is recorded and judged, its faces' air never taken")
    func besideMovingStructure() throws {
        // A concrete wall a cell from an envelope's face, thrown 0.3 m towards it by 80 kg.
        var scene = Scenario(
            name: "Wall beside an envelope", domainSize: SIMD3(10, 6, 4), boxes: [],
            charge: Charge(mass: 80, position: SIMD3(4, 3, 1.2)))
        let wall = Box(min: SIMD3(6, 1.5, 0), max: SIMD3(6.25, 4.5, 2.5))
        scene.objects.append(
            SceneObject(
                name: "Wall",
                representation: .deformable(
                    StructureModel(
                        solids: [wall], material: .reinforcedConcrete, elementSize: 0.125, fixedBase: true))))
        try scene.addEnvelopeObject(
            BuildingEnvelope(
                solids: [Box(min: SIMD3(6.5, 1, 0), max: SIMD3(7, 5, 3))],
                panes: [Box(min: SIMD3(6.5, 2, 1), max: SIMD3(6.75, 3, 2))]),
            name: "Envelope")
        let device = try #require(MTLCreateSystemDefaultDevice())
        // The envelope's west face's air: the cells at x 6.25–6.5 m across it.
        let face = (0..<12).flatMap { k in (4..<20).map { j in (25, j, k) } }
        let inside = (0..<12).flatMap { k in (4..<20).map { j in (26, j, k) } }
        func run(observed: Bool) throws -> (solver: BlastSolver, taken: Int) {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            if observed {
                try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                try solver.configureEnvelopeComponents(
                    objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.05))
            }
            var taken = 0
            for _ in 0..<10 {
                _ = solver.advance(until: solver.time + 0.005)
                taken = max(taken, face.filter { solver.isSolid($0.0, $0.1, $0.2) }.count)
                #expect(inside.allSatisfy { solver.isSolid($0.0, $0.1, $0.2) })
            }
            return (solver, taken)
        }
        // Unobserved, the wall takes half the face's air as it comes; observed, none of it.
        let unobserved = try run(observed: false)
        #expect(unobserved.taken > 50, "\(unobserved.taken)")
        let observed = try run(observed: true)
        #expect(observed.taken == 0)
        #expect(observed.solver.keptAirCells?.contains(observed.solver.grid.index(25, 12, 4)) == true)
        let summary = try #require(observed.solver.bodySummary())
        #expect(summary.maxDisplacement > 0.25, "\(summary.maxDisplacement)")
        // Its components are recorded, and the building judged.
        let histories = try #require(observed.solver.envelopeComponentHistories())
        let loads = histories.filter { !$0.invalid }.map(EnvelopeComponentLoad.init)
        #expect(!loads.isEmpty)
        let damage = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { scene.envelopeConstruction(for: $0) },
            rooms: [scene.envelopeObjects[0].id: 1])
        #expect(damage.count == 1 && damage[0].panes == 1)
        // The standing says the envelopes are one way beside the structure, and not without one.
        func says(_ scenario: Scenario) -> Bool {
            let standing = SceneStanding(
                StandingInputs(scenario: scenario, cellSize: 0.25, configuration: .init()))
            return standing.results.filter { $0.kind == .envelopeDamage || $0.kind == .envelopeExposure }
                .allSatisfy { $0.assumptions.contains(StandingScene.envelopesBesideStructures) }
        }
        #expect(says(scene))
        // Nothing is kept without a body: an envelope-only scene runs as before.
        var alone = scene
        try alone.removeObject(id: scene.structuralObjects[0].id)
        let only = try BlastSolver(device: device, scenario: alone, cellSize: 0.25)
        try only.configureEnvelopeExposure(objects: alone.envelopeObjects)
        #expect(only.keptAirCells == nil)
        #expect(!says(alone))
    }
}
