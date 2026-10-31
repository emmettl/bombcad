import Foundation
import Testing

@testable import BlastModel

/// What envelope buildings are built of: from map tags, IFC layers, the editor, or assumed.
@Suite("Envelope constructions")
struct EnvelopeConstructionTests {
    @Test("A map building's material tag gives concrete, masonry or timber; anything else says nothing")
    func map() {
        let id = UUID()
        #expect(
            EnvelopeConstruction.fromMap(objectID: id, material: "concrete")?.walls == .reinforcedConcrete)
        let brick = EnvelopeConstruction.fromMap(objectID: id, material: "brick")
        #expect(
            brick?.walls == .unreinforcedMasonry && brick?.wallThicknessM == 0.215 && brick?.source == .map)
        // Wood and its variants: walls and roof of the one timber the model has (since 31 October 2026).
        for value in ["wood", "Wood", "timber", "timber_framing", "wood_frame", "log"] {
            let timber = EnvelopeConstruction.fromMap(objectID: id, material: value)
            #expect(timber?.walls == .crossLaminatedTimber && timber?.roof == .crossLaminatedTimber)
            #expect(
                timber?.wallThicknessM == 0.105 && timber?.roofThicknessM == 0.105 && timber?.source == .map)
            #expect(timber?.detail.contains("building:material=\(value)") == true)
            // The earlier rule, by name: a wood tag said nothing.
            #expect(EnvelopeConstruction.fromMap(objectID: id, material: value, readsWood: false) == nil)
        }
        #expect(
            EnvelopeConstruction.fromMap(objectID: id, material: "brick", readsWood: false)?.walls
                == .unreinforcedMasonry)
        #expect(EnvelopeConstruction.fromMap(objectID: id, material: "glass") == nil)
        #expect(EnvelopeConstruction.fromMap(objectID: id, material: nil) == nil)
    }

    @Test(
        "A map's wood-tagged building is timber in a laid-out district, and burns from outside; not when unread"
    )
    func mapWoodInDistrict() throws {
        // Three houses on a street, OpenStreetMap XML: wood, timber framing, and untagged.
        func way(_ id: Int, _ x: Double, _ material: String?) -> String {
            let nodes = (0..<4).map { "<nd ref=\"\(id * 10 + $0)\"/>" }.joined() + "<nd ref=\"\(id * 10)\"/>"
            let tag = material.map { "<tag k=\"building:material\" v=\"\($0)\"/>" } ?? ""
            let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].enumerated().map { n, c in
                String(
                    format: "<node id=\"%d\" lon=\"%.7f\" lat=\"%.7f\"/>", id * 10 + n, x + c.0 * 1e-4,
                    c.1 * 1e-4)
            }.joined()
            return corners + "<way id=\"\(id)\">\(nodes)<tag k=\"building\" v=\"house\"/>\(tag)</way>"
        }
        let xml =
            "<osm version=\"0.6\">" + way(1, 0.0002, "wood") + way(2, 0.0005, "timber_framing")
            + way(3, 0.0008, nil) + "</osm>"
        let buildings = try MapBuilding.readOSM(Data(xml.utf8))
        #expect(buildings.map(\.material) == ["wood", "timber_framing", nil])
        func laid(readsWood: Bool) throws -> [EnvelopeConstruction] {
            var layout = DistrictLayout(buildings: buildings, charge: SIMD2(0.0006, -0.0003), mass: 10)
            layout.readsWoodTags = readsWood
            let (scene, report) = try layout.scene(halfSide: 80, cellSize: 1, height: 40)
            #expect(report.placed.count == 3)
            return scene.envelopeObjects.map { scene.envelopeConstruction(for: $0.id) }
        }
        let read = try laid(readsWood: true)
        #expect(read.map(\.walls) == [.crossLaminatedTimber, .crossLaminatedTimber, .reinforcedConcrete])
        #expect(read.map(\.source) == [.map, .map, .assumed])
        #expect(read.map { FireSpread.cladding($0.walls) } == [.combustible, .combustible, .nonCombustible])
        #expect(read.map { FireSpread.fireRated($0.roof) } == [false, false, true])
        // As before 31 October 2026: the tags unread, every house the default concrete.
        let unread = try laid(readsWood: false)
        #expect(unread.allSatisfy { $0.walls == .reinforcedConcrete && $0.source == .assumed })
    }

    @Test("IFC layers give the larger class of element, at its median structural thickness")
    func ifc() {
        let id = UUID()
        let wall = [
            IFCStructure.Layer(name: "Plaster", thickness: 0.015),
            IFCStructure.Layer(name: "Brick, common", thickness: 0.24),
        ]
        let slab = [IFCStructure.Layer(name: "Concrete C30/37", thickness: 0.2)]
        let construction = EnvelopeConstruction.fromIFC(
            objectID: id, elementLayers: [wall, wall, wall, slab])
        #expect(construction?.walls == .unreinforcedMasonry && construction?.source == .ifc)
        #expect(abs((construction?.wallThicknessM ?? 0) - 0.24) < 1e-6)
        #expect(EnvelopeConstruction.fromIFC(objectID: id, elementLayers: [[]]) == nil)
    }

    @Test("An envelope with none takes the assumed default; one set is saved and reopened")
    func persistence() throws {
        var scene = Scenario(
            name: "Envelopes", domainSize: SIMD3(20, 20, 10), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 1, 0)))
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(5, 5, 0), max: SIMD3(8, 8, 3))]))
        #expect(scene.envelopeConstruction(for: id).source == .assumed)
        scene.setEnvelopeConstruction(
            EnvelopeConstruction(objectID: id, walls: .unreinforcedMasonry, source: .user, detail: "chosen"))
        let data = try JSONEncoder().encode(scene)
        let reopened = try JSONDecoder().decode(Scenario.self, from: data)
        #expect(reopened.envelopeConstruction(for: id).walls == .unreinforcedMasonry)
        #expect(reopened.envelopeConstruction(for: id).source == .user)
        // Setting it again replaces it, and constructions of envelopes no longer present go.
        var edited = reopened
        edited.setEnvelopeConstruction(.assumed(objectID: id))
        edited.setEnvelopeConstruction(.assumed(objectID: UUID()))
        #expect(edited.envelopeConstructions?.count == 1)
    }
}
