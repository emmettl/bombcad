import Foundation
import Testing
import simd

@testable import BlastCore

/// Floor plans read from DXF (`DXFDrawing`, `FloorPlan`): the example house drawn by centrelines,
/// and the Duplex Apartment's ground floor cut from its IFC, drawn by both faces as architects draw.
@Suite("Floor plans")
struct FloorPlanTests {
    static func sample(_ name: String) throws -> DXFDrawing {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Plans/\(name)")
        return try DXFDrawing(data: Data(contentsOf: url))
    }

    @Test("The reader takes lines, polylines with bulges, arcs and inserted blocks, mirrored or not")
    func reader() throws {
        let text = """
              0
            SECTION
              2
            HEADER
              9
            $INSUNITS
             70
            4
              0
            ENDSEC
              0
            SECTION
              2
            BLOCKS
              0
            BLOCK
              2
            WIN
             10
            0
             20
            0
              0
            LINE
              8
            0
             10
            0
             20
            0
             11
            1000
             21
            0
              0
            ENDBLK
              0
            ENDSEC
              0
            SECTION
              2
            ENTITIES
              0
            LWPOLYLINE
              8
            WALLS
             90
            3
             70
            1
             10
            0
             20
            0
             42
            1
             10
            2000
             20
            0
             10
            2000
             20
            1000
              0
            INSERT
              8
            WINDOWS
              2
            WIN
             10
            500
             20
            500
             50
            90
              0
            ARC
              8
            DOORS
             10
            0
             20
            0
             40
            900
             50
            0
             51
            90
            230
            -1
              0
            ENDSEC
              0
            EOF
            """
        let drawing = try DXFDrawing(data: Data(text.utf8))
        #expect(drawing.metresPerUnit == 0.001)
        #expect(Set(drawing.layers) == ["WALLS", "WINDOWS", "DOORS", "0"])
        let segments = drawing.segments()
        // The window's line turned a quarter, on the insert's layer, from the block's layer 0.
        let window = segments.filter { $0.layer == "WINDOWS" }
        #expect(window.count == 1 && window[0].block == "WIN")
        #expect(simd_distance(window[0].b, SIMD2(500, 1500)) < 1e-6)
        // The bulge of 1 is a half circle under the first edge, from (0, 0) to (2000, 0).
        let arc = segments.filter { $0.layer == "WALLS" }.flatMap { [$0.a, $0.b] }
        #expect(arc.contains { abs($0.y + 1000) < 1 })
        // The mirrored arc (extrusion −z) runs from 90° to 180°.
        let door = segments.filter { $0.layer == "DOORS" }.flatMap { [$0.a, $0.b] }
        #expect(door.allSatisfy { $0.x <= 1e-6 && $0.y >= -1e-6 })
        #expect(throws: DXFDrawing.ReadError.self) {
            try DXFDrawing(data: Data("AutoCAD Binary DXF\r\n".utf8))
        }
    }

    @Test("The example house's centrelines raise its walls, partition, door and each storey's windows")
    func centrelines() throws {
        let drawing = try Self.sample("house-plan.dxf")
        var options = FloorPlan.Options()
        options.metresPerUnit = try #require(drawing.metresPerUnit)
        options.roles = [
            "WALL-EXT": .wall(.cavityBrickBlock), "WALL-INT": .wall(.block100), "DOOR": .door,
            "WINDOW-GF": .window, "WINDOW-FF": .window,
        ]
        options.layerStoreys = ["DOOR": 0, "WINDOW-GF": 0, "WINDOW-FF": 1]
        let plan = FloorPlan.analyse(drawing, options: options)
        #expect(plan.walls.count == 5, "\(plan.walls)")
        #expect(plan.walls.filter { abs($0.thickness - 0.28) < 1e-6 }.count == 4)
        // The outer walls meet at their corners' outer faces; the partition at their midlines.
        let partition = try #require(plan.walls.first { abs($0.thickness - 0.1) < 1e-6 })
        #expect(abs(partition.from - 0.14) < 1e-6 && abs(partition.to - 5.86) < 1e-6)
        #expect(plan.walls.filter { $0.thickness > 0.2 }.allSatisfy { abs($0.from) < 1e-6 })
        #expect(plan.openings.filter { $0.kind == .door }.count == 1)
        #expect(plan.openings.filter { $0.kind == .window && $0.storey == 0 }.count == 2)
        #expect(plan.openings.filter { $0.kind == .window && $0.storey == 1 }.count == 3)
        let elements = try FloorPlan.buildingElements(plan, options: options)
        // Per storey 5 walls; 6 openings; first floor, roof and the ground slab.
        #expect(elements.filter { $0.ifcClass == "IfcWall" }.count == 10)
        #expect(elements.filter { $0.ifcClass == "IfcWindow" }.count == 5)
        #expect(elements.filter { $0.ifcClass == "IfcDoor" }.count == 1)
        #expect(elements.filter { $0.ifcClass == "IfcSlab" }.count == 2)
        #expect(elements.filter { $0.ifcClass == "IfcRoof" }.count == 1)
        // As a structure: walls and slabs shells, windows panes, the door an opening; the
        // cavity walls masonry carrying the block's mass, as the IFC route gives them.
        let structure = try IFCStructure(elements: elements)
        let roles = Dictionary(grouping: structure.members, by: \.role).mapValues(\.count)
        #expect(roles[.shell] == 13 && roles[.pane] == 5 && roles[.opening] == 1, "\(roles)")
        #expect(
            structure.members.filter { $0.name.contains("wall") && $0.role == .shell }
                .allSatisfy {
                    [StructureMaterial.masonry.name, StructureMaterial.concreteBlock.name].contains(
                        $0.material)
                })
    }

    static func cutPlan(_ name: String) throws -> FloorPlan.Analysis {
        let drawing = try sample(name)
        var options = FloorPlan.Options()
        options.metresPerUnit = try #require(drawing.metresPerUnit)
        options.roles = FloorPlan.guessedRoles(drawing.layers)
        return FloorPlan.analyse(drawing, options: options)
    }

    /// The four outer walls, each the length of its side of the plan.
    static func outerWalls(_ plan: FloorPlan.Analysis, thickness: Double) -> [FloorPlan.Wall] {
        let low = plan.walls.map(\.rectangle.min).reduce(SIMD2(repeating: Double.infinity)) {
            simd_min($0, $1)
        }
        let high = plan.walls.map(\.rectangle.max).reduce(SIMD2(repeating: -Double.infinity)) {
            simd_max($0, $1)
        }
        let size = high - low
        return plan.walls.filter { wall in
            abs(wall.thickness - thickness) < 0.002 && abs(wall.length - size[wall.axis]) < 0.01
        }
    }

    @Test("The Duplex's floors, cut from its IFC and drawn by both faces, give its walls and openings")
    func faces() throws {
        // Ground floor: the IFC's 4 windows and the 6 of its 8 doors that the cut at 1 m crosses,
        // every one in its wall, and the outer walls whole, 417 mm, through the doors beside
        // their corners.
        let ground = try Self.cutPlan("duplex-level-1.dxf")
        #expect(ground.notes.contains { $0.contains("drawn by their outlines") })
        #expect(Self.outerWalls(ground, thickness: 0.417).count == 4, "\(ground.walls)")
        #expect(ground.openings.filter { $0.kind == .window && $0.layer == "IFCWINDOW" }.count == 4)
        #expect(ground.openings.filter { $0.kind == .door && $0.layer == "IFCDOOR" }.count == 6)
        #expect(ground.openings.allSatisfy { $0.layer != nil }, "\(ground.openings)")
        // Partitions 124 mm, as in the IFC.
        #expect(ground.walls.filter { abs($0.thickness - 0.124) < 0.002 }.count >= 5)
        // First floor: the outer walls whole; a gap in an inside wall (the landing) is a doorway,
        // not a window; the corners' mitre seams are joints, not walls.
        let first = try Self.cutPlan("duplex-level-2.dxf")
        #expect(Self.outerWalls(first, thickness: 0.417).count == 4, "\(first.walls)")
        #expect(first.openings.filter { $0.layer == nil }.allSatisfy { $0.kind == .door })
        #expect(first.openings.filter { $0.kind == .window }.count >= 10)
        #expect(first.angledLines == 0 && first.angled.isEmpty)
        // The small house: three walls of 200 mm; its fourth, 24 mm, is thinner than any wall.
        let small = try Self.cutPlan("small-house.dxf")
        #expect(small.walls.count == 3 && small.walls.allSatisfy { abs($0.thickness - 0.2) < 0.002 })
        // Each floor raises into a structure, its walls shells and its windows panes.
        for plan in [ground, first] {
            let structure = try IFCStructure(
                elements: FloorPlan.buildingElements(plan, options: FloorPlan.Options()))
            #expect(structure.members.contains { $0.role == .shell })
            #expect(structure.members.contains { $0.role == .pane })
        }
    }

    static func houseOptions(_ drawing: DXFDrawing) throws -> FloorPlan.Options {
        var options = FloorPlan.Options()
        options.metresPerUnit = try #require(drawing.metresPerUnit)
        options.roles = [
            "WALL-EXT": .wall(.cavityBrickBlock), "WALL-INT": .wall(.block100), "DOOR": .door,
            "WINDOW-GF": .window, "WINDOW-FF": .window,
        ]
        options.layerStoreys = ["DOOR": 0, "WINDOW-GF": 0, "WINDOW-FF": 1]
        return options
    }

    @Test("The house drawn turned by 17° is turned square to its walls and read as drawn square")
    func turnedPlan() throws {
        let drawing = try Self.sample("house-plan-turned.dxf")
        let plan = FloorPlan.analyse(drawing, options: try Self.houseOptions(drawing))
        #expect(abs(plan.turn - 17) < 0.2, "turned \(plan.turn)°")
        #expect(plan.angled.isEmpty && plan.angledLines == 0)
        #expect(plan.walls.count == 5, "\(plan.walls)")
        #expect(plan.walls.filter { abs($0.thickness - 0.28) < 1e-6 }.count == 4)
        // The same walls as drawn square, to the millimetre: 8 by 6 m over their faces.
        let size = plan.bounds.max - plan.bounds.min
        #expect(abs(size.x - 8) < 0.01 && abs(size.y - 6) < 0.01, "\(size)")
        #expect(plan.openings.filter { $0.kind == .door }.count == 1)
        #expect(plan.openings.filter { $0.kind == .window && $0.storey == 0 }.count == 2)
        #expect(plan.openings.filter { $0.kind == .window && $0.storey == 1 }.count == 3)
    }

    @Test("A curved bay drawn by a bulge is raised as walls turned in plan, chord by chord, tied in")
    func bay() throws {
        let drawing = try Self.sample("house-plan-bay.dxf")
        let options = try Self.houseOptions(drawing)
        let plan = FloorPlan.analyse(drawing, options: options)
        // A bulge of 0.4 sweeps 87°: six chords of under 15°, each a wall 280 mm thick.
        #expect(plan.angled.count == 6, "\(plan.angled)")
        #expect(plan.angled.allSatisfy { abs($0.thickness - 0.28) < 1e-6 })
        // Chord by chord they share their corners, and the bay's ends meet the front wall's midline.
        let ends = plan.angled.flatMap { [$0.a, $0.b] }
        let shared = ends.filter { p in ends.filter { simd_distance($0, p) < 1e-6 }.count >= 2 }
        #expect(shared.count == 10, "\(ends)")
        let front = try #require(plan.walls.first { $0.axis == 0 && abs($0.offset - 0.14) < 1e-6 })
        #expect(ends.filter { abs($0.y - front.offset) < 1e-6 }.count == 2)
        // Its window, on each floor, in a chord; left open.
        #expect(plan.angledOpenings.count == 2 && plan.angledOpenings.allSatisfy { $0.kind == .window })
        #expect(plan.notes.contains { $0.contains("left open") })
        // As a structure: each chord's stretch a shell in its own plane, upright, tied to the walls
        // and slabs it meets.
        var structural = IFCStructure.Options()
        structural.inclinedPlates = true
        let structure = try IFCStructure(
            elements: FloorPlan.buildingElements(plan, options: options), options: structural)
        let turned = structure.members.filter { $0.notes.contains { $0.contains("Turned in plan") } }
        #expect(turned.count >= 12, "\(turned.count) of \(structure.members.count)")
        let model = structure.model
        let frames = model.solids.indices.filter { model.inclination(of: $0)?.frame != nil }
        #expect(frames.count == turned.count)
        for index in frames {
            let frame = try #require(model.inclination(of: index)?.frame)
            #expect(abs(frame.up.z - 1) < 1e-6 && abs(frame.along.z) < 1e-6)
        }
        let mesh = try ShellMesh(model: model)
        // Every chord's elements upright (axis 3), and each chord tied to what it meets.
        let chordElements = mesh.elements.filter { frames.contains($0.solid) }
        #expect(!chordElements.isEmpty && chordElements.allSatisfy { $0.axis == 3 })
        // A wall turned in plan with an opening through it (two stretches, one element) is not
        // taken as whole.
        let left = try FloorPlan.uprightMesh(
            from: SIMD2(0, 0), to: SIMD2(0.8, 0.6), thickness: 0.2, z0: 0, z1: 2.5)
        let right = try FloorPlan.uprightMesh(
            from: SIMD2(1.6, 1.2), to: SIMD2(2.4, 1.8), thickness: 0.2, z0: 0, z1: 2.5)
        #expect(IFCStructure.uprightPlane(left.triangles) != nil)
        #expect(IFCStructure.uprightPlane(left.triangles + right.triangles) == nil)
        let tied = Set(mesh.contactTies.flatMap { [$0.first, $0.second] })
        #expect(frames.filter { tied.contains($0) }.count >= frames.count / 2, "\(mesh.contactTies)")
    }

    @Test("The Duplex's first floor: its lines at an angle are its corners' mitre seams, taken as joints")
    func duplexMitres() throws {
        let plan = try Self.cutPlan("duplex-level-2.dxf")
        // Sixteen short lines at 45° in the four corners, from each one's outer point to its inner.
        #expect(plan.angled.isEmpty && plan.angledLines == 0, "\(plan.notes)")
        #expect(plan.notes.contains { $0.contains("16 short lines at an angle") }, "\(plan.notes)")
        #expect(Self.outerWalls(plan, thickness: 0.417).count == 4)
    }
}
