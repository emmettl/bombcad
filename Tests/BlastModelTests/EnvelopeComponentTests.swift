import Foundation
import Testing
import simd

@testable import BlastModel

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
