import Foundation
import Testing
import simd

@testable import BlastModel

/// A window as users and IFC imports model it: an opening cut through a wall, and a pane of glass
/// in it. The opening cuts the wall; the pane is kept, on the wall's midsurface, joined to the
/// opening's reveal.
@Suite("Glazed openings")
struct GlazedOpeningTests {
    /// A 0.2 m reinforced concrete wall across x = 4 to 4.2, 3 m long and 2.5 m high, with a 1 m
    /// square opening from 1 to 2 m along it and 0.5 to 1.5 m up; and, unless `glazed` is false,
    /// a 6 mm pane of annealed glass in the opening, set 50 mm off the wall's middle and 20 mm in
    /// from the reveal, as a window's glass sits in its frame.
    static func wall(glazed: Bool = true) -> StructureModel {
        var model = StructureModel(
            solids: [Box(min: SIMD3(4, 0, 0), max: SIMD3(4.2, 3, 2.5))],
            openings: [Box(min: SIMD3(3.99, 1, 0.5), max: SIMD3(4.21, 2, 1.5))], elementSize: 0.125)
        model.elementKind = .shell
        model.shellLayers = 4
        if glazed {
            model.solids.append(Box(min: SIMD3(4.047, 1.02, 0.52), max: SIMD3(4.053, 1.98, 1.48)))
            model.setMaterial(.annealedGlass, of: 1)
        }
        return model
    }

    /// The elements of `solid`, and whether each of its nodes round its edge (at the extremes of
    /// its plane) is a node of `wall`'s elements too.
    static func pane(in mesh: ShellMesh, solid: Int, wall: Int) -> (elements: Int, joined: Bool) {
        let elements = mesh.elements.filter { $0.solid == solid }
        guard let axis = elements.first?.axis else { return (0, false) }
        let wallNodes = Set(
            mesh.elements.filter { $0.solid == wall }.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let nodes = Set(elements.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let points = nodes.map { mesh.positions[Int($0)] }
        let low = points.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = points.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let edge = nodes.filter { n in
            let p = mesh.positions[Int(n)]
            return (0..<3).contains { k in
                k != axis && (abs(p[k] - low[k]) < 1e-5 || abs(p[k] - high[k]) < 1e-5)
            }
        }
        return (elements.count, !edge.isEmpty && edge.isSubset(of: wallNodes))
    }

    @Test("A pane in a wall's opening is kept, on the wall's midsurface, joined to the reveal")
    func handBuilt() throws {
        let mesh = try ShellMesh(model: Self.wall())
        let (elements, joined) = Self.pane(in: mesh, solid: 1, wall: 0)
        // The opening is 8 elements square; the pane fills it, to the reveal.
        #expect(elements == 64, "\(elements) pane elements")
        #expect(joined)
        let glass = try #require(mesh.elements.first { $0.solid == 1 })
        #expect(abs(glass.thickness - 0.006) < 1e-6)
        #expect(abs(mesh.positions[Int(glass.nodes[0])].x - 4.1) < 1e-5)
        // The wall itself has no elements in the opening.
        #expect(
            !mesh.elements.contains { e in
                guard e.solid == 0 else { return false }
                let centre = (0..<4).reduce(SIMD3<Float>.zero) { $0 + mesh.positions[Int(e.nodes[$1])] } / 4
                return centre.y > 1 && centre.y < 2 && centre.z > 0.5 && centre.z < 1.5
            })
        // Without the pane the opening is open, as before.
        let open = try ShellMesh(model: Self.wall(glazed: false))
        #expect(open.elements.count == mesh.elements.count - 64)
        // As solids, the pane is there and the rest of the opening is not.
        let model = Self.wall()
        #expect(model.occupies(SIMD3(4.05, 1.5, 1)) && !model.occupies(SIMD3(4.1, 1.5, 1)))
        #expect(model.occupies(SIMD3(4.1, 0.5, 1)))
    }

    @Test("An envelope keeps what its openings hold: a door stays solid, a converted pane a pane")
    func envelope() throws {
        let wall = Box(min: SIMD3(4, 0, 0), max: SIMD3(4.2, 3, 2.5))
        let opening = Box(min: SIMD3(3.99, 1, 0), max: SIMD3(4.21, 2, 2))
        let door = Box(min: SIMD3(4.08, 1, 0), max: SIMD3(4.12, 2, 2))
        let envelope = try BuildingEnvelope(solids: [wall, door], openings: [opening])
        // The door is one block of its own; the opening is open beside it, through the wall.
        #expect(envelope.blocks.filter { $0 == door }.count == 1)
        #expect(envelope.blockSources.filter { $0 == .solid(1) }.count == 1)
        #expect(envelope.occupies(SIMD3(4.1, 1.5, 1)) && !envelope.occupies(SIMD3(4.03, 1.5, 1)))
        #expect(envelope.occupies(SIMD3(4.03, 1.5, 2.1)))
        // Picking and placement checks see it too.
        let pieces = ImportPlacementReport.subtracting([opening], from: door, limit: 16)
        #expect(pieces.complete && pieces.boxes == [door])
        // A detailed wall with glass in its opening: the wall cut round the opening, the glass a pane.
        let converted = try BuildingEnvelope(structure: Self.wall())
        #expect(converted.panes == [Self.wall().solids[1]])
        #expect(converted.occupies(SIMD3(4.05, 1.5, 1)) && !converted.occupies(SIMD3(4.1, 1.5, 1)))
    }

    @Test("An imported glazed window's pane is meshed in its wall's opening and joined to it")
    func imported() throws {
        // As IFCStructure leaves it: the wall's hole an opening, the window a pane on the wall's
        // midsurface (IFCStructureTests "openingsAndPanes").
        let wall = ImportedMesh.BuildingElement(
            globalID: String(format: "%022d", 1), name: "Wall", ifcClass: "IfcWall", storey: "Ground",
            mesh: try Self.mesh([
                Box(min: SIMD3(0, 0, 0), max: SIMD3(1, 0.2, 3)),
                Box(min: SIMD3(2.5, 0, 0), max: SIMD3(4, 0.2, 3)),
                Box(min: SIMD3(1, 0, 0), max: SIMD3(2.5, 0.2, 0.75)),
                Box(min: SIMD3(1, 0, 2.25), max: SIMD3(2.5, 0.2, 3)),
            ]))
        let window = ImportedMesh.BuildingElement(
            globalID: String(format: "%022d", 2), name: "Window", ifcClass: "IfcWindow", storey: "Ground",
            mesh: try Self.mesh([Box(min: SIMD3(1, 0.05, 0.75), max: SIMD3(2.5, 0.15, 2.25))]),
            materials: [.init(name: "Glass")])
        let structure = try IFCStructure(elements: [wall, window], options: .init(elementSize: 0.25))
        let pane = try #require(structure.members.first { $0.role == .pane }?.solid)
        let host = try #require(structure.members.first { $0.name == "Wall" }?.solid)
        let mesh = try ShellMesh(model: structure.model)
        let (elements, joined) = Self.pane(in: mesh, solid: pane, wall: host)
        #expect(elements > 0 && joined, "\(elements) pane elements")
        #expect(
            mesh.elements.filter { $0.solid == pane }.allSatisfy {
                structure.model.materials[$0.material] == .annealedGlass
            })
    }

    /// A closed OBJ mesh of `boxes`, each drawn in by half a millimetre where there are several,
    /// so that they do not touch (as IFCStructureTests draws them).
    static func mesh(_ boxes: [Box]) throws -> ImportedMesh {
        var text = ""
        for (n, var box) in boxes.enumerated() {
            if boxes.count > 1 {
                box.min += SIMD3(repeating: 0.0005)
                box.max -= SIMD3(repeating: 0.0005)
            }
            for k in 0..<8 {
                let p = SIMD3(
                    k & 1 == 0 ? box.min.x : box.max.x, k & 2 == 0 ? box.min.y : box.max.y,
                    k & 4 == 0 ? box.min.z : box.max.z)
                text += "v \(p.x) \(p.y) \(p.z)\n"
            }
            for face in [
                [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
            ] {
                let v = face.map { 8 * n + $0 + 1 }
                text += "f \(v[0]) \(v[1]) \(v[2])\nf \(v[0]) \(v[2]) \(v[3])\n"
            }
        }
        return try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
    }
}
