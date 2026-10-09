import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Support connections")
struct SupportConnectionTests {
    private func material() -> StructureMaterial {
        .elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    }

    private func law(_ stiffness: Float) -> Anchorage {
        Anchorage(
            normalStiffness: stiffness, shearStiffness: stiffness,
            tensileStrength: 1e6, tensionOpening: 0.02, cohesion: 1e6, cohesionSlip: 0.02, friction: 0.6)
    }

    @Test("Different support laws carry their own tributary area on raised solid bearings")
    func raisedSolids() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var body = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(1, 1, 1.5)),
                Box(min: SIMD3(2, 0, 1), max: SIMD3(3, 1, 1.5)),
            ], material: material(), elementSize: 0.25, fixedBase: false)
        body.supports = [
            Box(min: SIMD3(-0.01, -0.01, 0.99), max: SIMD3(1.01, 1.01, 1.01)),
            Box(min: SIMD3(1.99, -0.01, 0.99), max: SIMD3(3.01, 1.01, 1.01)),
        ]
        body.supportAnchorages = [law(1e8), law(3e8)]
        let solver = try StructureSolver(device: device, model: body)
        #expect(abs(solver.supportBearingArea(at: 0) - 1) < 1e-6)
        #expect(abs(solver.supportBearingArea(at: 1) - 1) < 1e-6)
        solver.gravity = 0
        solver.mutateNodes { nodes in
            #expect(nodes.allSatisfy { !$0.isFixed })
            for n in nodes.indices { nodes[n].uz = 1e-5 }
        }
        solver.advance(steps: 1)
        let summary = try #require(solver.anchorSummary())
        #expect(summary.nodes == 50)
        // Two 1 m² bearings with independent stiffness; neither is a clamp.
        #expect(abs(summary.reaction.z + 4000) < 1)
        #expect(summary.meanDamage == 0)
        solver.reset()
        #expect(solver.anchorSummary()?.reaction == .zero)
    }

    @Test("Raised shell and beam bearings carry force and permit lift-off")
    func raisedShells() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for size in [SIMD3<Float>(0.25, 1, 1), SIMD3<Float>(0.25, 0.25, 1)] {
            var body = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(0, 0, 1) + size)],
                material: material(), elementSize: 0.25, fixedBase: false)
            body.elementKind = .shell
            body.supports = [
                Box(min: SIMD3(-0.01, -0.01, 0.99), max: SIMD3(size.x + 0.01, size.y + 0.01, 1.01))
            ]
            body.supportAnchorages = [law(1e8)]
            let solver = try ShellSolver(device: device, model: body)
            #expect(abs(solver.supportBearingArea(at: 0) - size.x * size.y) < 1e-6)
            solver.gravity = 0
            solver.mutateNodes { nodes in
                #expect(nodes.allSatisfy { !$0.isClamped })
                for n in nodes.indices { nodes[n].uz = 1e-5 }
            }
            solver.advance(steps: 1)
            let summary = try #require(solver.anchorSummary())
            #expect(summary.nodes > 0)
            #expect(abs(summary.reaction.z + size.x * size.y * 1000) < 0.1)
            // A friction-only bearing carries no tension when lifted.
            body.supportAnchorages = [.resting()]
            let free = try ShellSolver(device: device, model: body)
            free.gravity = 0
            free.mutateNodes { nodes in for n in nodes.indices { nodes[n].uz = 0.001 } }
            free.advance(steps: 1)
            #expect(free.anchorSummary()?.reaction == .zero)
        }
    }

    @Test("Ideal supports override overlapping finite connections and deletion retains law ownership")
    func clampPrecedenceAndDeletion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var body = StructureModel(
            solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], material: material(), elementSize: 0.25)
        body.baseAnchorage = law(1e8)
        let region = Box(min: SIMD3(repeating: -0.01), max: SIMD3(1.01, 1.01, 0.01))
        body.supports = [region, region, region]
        body.supportAnchorages = [law(2e8), nil, .resting(friction: 0.3)]
        let solver = try StructureSolver(device: device, model: body)
        solver.mutateNodes { #expect($0.filter(\.isFixed).count == 25) }
        #expect(solver.anchorSummary()?.nodes == 0)
        #expect(solver.supportBearingArea(at: 0) == 0)
        body.removeSupport(at: 0)
        #expect(body.anchorage(ofSupport: 0) == nil)
        #expect(body.anchorage(ofSupport: 1) == .resting(friction: 0.3))
    }

    @Test("Connection values and support references are checked on load and solver construction")
    func validationAndPersistence() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var body = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        let original = try JSONEncoder().encode(body)
        let object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(object["supportAnchorages"] == nil)
        body.supports = [body.bounds]
        body.supportAnchorages = [law(1e8)]
        #expect(try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(body)) == body)
        body.supportAnchorages.append(.resting())
        #expect(throws: ImportedMesh.ImportError.self) { try StructureSolver(device: device, model: body) }
        #expect(throws: ImportedMesh.ImportError.self) {
            try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(body))
        }
        var invalid = law(1e8)
        invalid.friction = -1
        #expect(throws: ImportedMesh.ImportError.self) { try invalid.validate() }
        invalid = law(1e8)
        invalid.normalStiffness = 0
        #expect(throws: ImportedMesh.ImportError.self) { try invalid.validate() }
        invalid = law(1e8)
        invalid.tensionPlateau = 0.03
        #expect(throws: ImportedMesh.ImportError.self) { try invalid.validate() }
    }

    /// A 1 m block raised 2 m off the ground, tied to a support across the face on `side` by
    /// `law`, hung under gravity for 0.3 s: its mean vertical displacement, and the bearing area.
    private func hang(_ side: JointSide, law: Anchorage) throws -> (drop: Float, area: Float) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var body = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 2), max: SIMD3(1, 1, 3))], material: material(), elementSize: 0.25,
            fixedBase: false)
        var face = Box(min: SIMD3(-0.01, -0.01, 1.99), max: SIMD3(1.01, 1.01, 3.01))
        face.min[side.axis] = side.direction < 0 ? face.min[side.axis] : face.max[side.axis] - 0.02
        face.max[side.axis] = face.min[side.axis] + 0.02
        body.supports = [face]
        var law = law
        law.side = side
        body.supportAnchorages = [law]
        let solver = try StructureSolver(device: device, model: body)
        let area = solver.supportBearingArea(at: 0)
        // Gravity comes on over 20 ms, so as not to strike the joint.
        for n in 1...20 {
            solver.gravity = 9.81 * Float(n) / 20
            solver.advance(steps: max(1, Int((0.001 / Double(solver.criticalTimeStep)).rounded())))
        }
        solver.advance(steps: Int((0.28 / Double(solver.criticalTimeStep)).rounded()))
        var drop: Float = 0
        solver.mutateNodes { nodes in drop = nodes.reduce(0) { $0 + $1.uz } / Float(nodes.count) }
        return (drop, area)
    }

    @Test("A block on a vertical joint hangs by its cohesion: it holds W below c A and slides down above")
    func verticalJoint() throws {
        let weight: Float = 2400 * 9.81  // per square metre of joint
        for side in [JointSide.negativeX, .positiveY] {
            // Without friction: the block's moment presses the joint's lower half, and friction
            // there would hold it as well.
            func law(_ cohesion: Float) -> Anchorage {
                Anchorage(
                    tensileStrength: 1e6, tensionOpening: 1e-3, cohesion: cohesion, cohesionSlip: 1e-3,
                    friction: 0)
            }
            let holds = try hang(side, law: law(weight / 0.7))
            let slides = try hang(side, law: law(weight / 1.3))
            // Only the face on that side is tied: 1 m².
            #expect(abs(holds.area - 1) < 1e-4)
            #expect(holds.drop > -1e-3, "\(side): \(holds.drop)")
            #expect(slides.drop < -0.1, "\(side): \(slides.drop)")
        }
        // With friction, the pressed half holds it: the moment W b / 2 bears on the lower third
        // with about 0.75 W, whose friction adds 0.45 W to the cohesion.
        let rough = Anchorage(
            tensileStrength: 1e6, tensionOpening: 1e-3, cohesion: weight / 1.3, cohesionSlip: 1e-3,
            friction: 0.6)
        #expect(try hang(.negativeX, law: rough).drop > -1e-3)
    }

    @Test("A block under a soffit joint hangs by its tension: it holds W below f_t A and falls away above")
    func soffitJoint() throws {
        let weight: Float = 2400 * 9.81
        func law(_ tension: Float) -> Anchorage {
            Anchorage(
                tensileStrength: tension, tensionOpening: 1e-3, cohesion: 0, cohesionSlip: 0, friction: 0)
        }
        let holds = try hang(.above, law: law(weight / 0.7))
        let falls = try hang(.above, law: law(weight / 1.3))
        #expect(abs(holds.area - 1) < 1e-4)
        #expect(holds.drop > -1e-3, "\(holds.drop)")
        #expect(falls.drop < -0.1, "\(falls.drop)")
        // A footing stands only under a body, and the ground's connection is only under it.
        var footed = Anchorage.resting()
        footed.footing = Footing()
        footed.side = .above
        #expect(throws: ImportedMesh.ImportError.self) { try footed.validate() }
    }
}
