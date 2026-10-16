import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// IFC elements meshed as a structure of shells and beams (`IFCStructure`), from elements built
/// of boxes here so that the converter is not needed.
@Suite("IFC structure", .gpuThreads)
struct IFCStructureTests {
    /// An element of closed boxes, each turned by `turn` radians about y through its own centre.
    /// Boxes that would touch are drawn 1 mm apart, as one element's mesh cannot hold touching
    /// solids.
    private func element(
        _ n: Int, _ name: String, _ ifcClass: String, _ boxes: [Box], turn: Float = 0,
        materials: [IFCStructure.Layer]? = nil, storey: String = "Ground"
    ) throws -> ImportedMesh.BuildingElement {
        var text = ""
        var base = 0
        for var box in boxes {
            if boxes.count > 1 {
                box.min += SIMD3(repeating: 0.0005)
                box.max -= SIMD3(repeating: 0.0005)
            }
            let centre = 0.5 * (box.min + box.max)
            for k in 0..<8 {
                var p = SIMD3(
                    k & 1 == 0 ? box.min.x : box.max.x, k & 2 == 0 ? box.min.y : box.max.y,
                    k & 4 == 0 ? box.min.z : box.max.z)
                let d = p - centre
                p = centre + SIMD3(d.x * cos(turn) + d.z * sin(turn), d.y, -d.x * sin(turn) + d.z * cos(turn))
                text += "v \(p.x) \(p.y) \(p.z)\n"
            }
            // The six faces, outward, as triangles (vertices numbered from 1).
            for face in [
                [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
            ] {
                let v = face.map { base + $0 + 1 }
                text += "f \(v[0]) \(v[1]) \(v[2])\nf \(v[0]) \(v[2]) \(v[3])\n"
            }
            base += 8
        }
        let mesh = try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
        return ImportedMesh.BuildingElement(
            globalID: String(format: "%022d", n), name: name, ifcClass: ifcClass, storey: storey,
            mesh: mesh,
            materials: materials)
    }

    private func box(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Box { Box(min: a, max: b) }

    /// A 4 m square room 3 m high: four walls 0.2 m thick under a 0.2 m slab, and a column in its
    /// middle.
    private func room(concrete: Bool = true) throws -> [ImportedMesh.BuildingElement] {
        let layers = concrete ? [IFCStructure.Layer(name: "Concrete C30/37")] : nil
        return [
            try element(
                1, "South wall", "IfcWall", [box(SIMD3(0, 0, 0), SIMD3(4, 0.2, 3))], materials: layers),
            try element(
                2, "North wall", "IfcWall", [box(SIMD3(0, 3.8, 0), SIMD3(4, 4, 3))], materials: layers),
            try element(
                3, "West wall", "IfcWall", [box(SIMD3(0, 0.2, 0), SIMD3(0.2, 3.8, 3))], materials: layers),
            try element(
                4, "East wall", "IfcWall", [box(SIMD3(3.8, 0.2, 0), SIMD3(4, 3.8, 3))], materials: layers),
            try element(5, "Roof", "IfcSlab", [box(SIMD3(0, 0, 3), SIMD3(4, 4, 3.2))], materials: layers),
            try element(
                6, "Column", "IfcColumn", [box(SIMD3(1.85, 1.85, 0), SIMD3(2.15, 2.15, 3))], materials: layers
            ),
        ]
    }

    @Test(
        "Walls, a slab and a column square to the axes become shells and a beam, tied where they meet, and stand"
    )
    func room() throws {
        let structure = try IFCStructure(elements: room(), options: .init(elementSize: 0.25))
        #expect(structure.members.filter { $0.role == .shell }.count == 5)
        #expect(structure.members.filter { $0.role == .beam }.count == 1)
        #expect(structure.model.elementKind == .shell && structure.model.solids.count == 6)
        // Each wall meets the slab and two others; the column meets the slab.
        #expect(structure.connections.filter { $0.kind.contains("slab") }.count == 5)
        #expect(structure.connections.filter { $0.kind == "wall–wall, tied rigidly" }.count == 4)
        #expect(structure.members.allSatisfy { !$0.assumed && $0.material == "Concrete C30" })
        #expect(structure.model.fixedBase && structure.model.baseAnchorage == IFCStructure.Options().base)
        #expect(structure.supports.contains { $0.contains("base on the ground") })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try ShellSolver(device: device, model: structure.model)
        #expect(solver.beamCount > 0)
        solver.damping = 50
        solver.advance(steps: Int(0.3 / Double(solver.criticalTimeStep)))
        #expect(solver.summary().maxDisplacement < 1e-3)
        var mass: Float = 0
        solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
        let reaction = try #require(solver.anchorSummary()).reaction.z
        #expect(abs(reaction - mass * 9.81) < 0.02 * mass * 9.81)
    }

    @Test("Materials come from the IFC's names; finishes stay rigid; others take the flagged default")
    func materials() throws {
        let wall = box(SIMD3(0, 0, 0), SIMD3(4, 0.42, 3))
        let elements = [
            try element(
                1, "Cavity wall", "IfcWall", [wall],
                materials: [
                    .init(name: "Masonry - Brick", thickness: 0.092),
                    .init(name: "Misc. Air Layers - Air Space", thickness: 0.025),
                    .init(name: "Insulation", thickness: 0.05),
                    .init(name: "Masonry - Concrete Block", thickness: 0.193),
                    .init(name: "Plasterboard", thickness: 0.016),
                ]),
            try element(
                2, "Partition", "IfcWall", [box(SIMD3(0, 2, 0), SIMD3(4, 2.1, 3))],
                materials: [
                    .init(name: "Plasterboard"), .init(name: "Metal - Stud Layer"),
                    .init(name: "Plasterboard"),
                ]),
            try element(
                3, "Timber wall", "IfcWall", [box(SIMD3(0, 4, 0), SIMD3(4, 4.2, 3))],
                materials: [.init(name: "Wood - Spruce")]),
            try element(
                4, "Steel column", "IfcColumn", [box(SIMD3(5, 0, 0), SIMD3(5.3, 0.3, 3))],
                materials: [.init(name: "Steel S355")]),
        ]
        let structure = try IFCStructure(elements: elements)
        let cavity = try #require(structure.members.first { $0.name == "Cavity wall" })
        #expect(
            cavity.role == .shell && cavity.material == StructureMaterial.concreteBlock.name
                && !cavity.assumed)
        let solid = try #require(cavity.solid)
        #expect(abs(structure.model.solids[solid].size.y - 0.193) < 1e-4)
        #expect(structure.members.first { $0.name == "Partition" }?.role == .rigid)
        let timber = try #require(structure.members.first { $0.name == "Timber wall" })
        #expect(timber.assumed && timber.materialSource.contains("timber"))
        #expect(
            structure.members.first { $0.name == "Steel column" }?.material
                == StructureMaterial.structuralSteel.name)
        #expect(
            structure.assumptions.contains { $0.contains("default material") && $0.contains("Timber wall") })
        // A part's chosen material replaces what the IFC gives, and is not an assumption.
        let chosen = try IFCStructure(elements: elements, chosen: [elements[2].partID: .masonry])
        #expect(
            chosen.members.first { $0.name == "Timber wall" }.map { !$0.assumed && $0.material == "Masonry" }
                == true)
        #expect(IFCStructure.grade(in: "Concrete C25/30") == 25 && IFCStructure.grade(in: "Concrete") == nil)
    }

    @Test("A hole through a wall is an opening; a glazed window in it is a pane of glass on its midsurface")
    func openingsAndPanes() throws {
        // A 4 m wall with a 1.5 m square hole from 1 to 2.5 m along it and 0.75 to 2.25 m up.
        let wall = try element(
            1, "Wall", "IfcWall",
            [
                box(SIMD3(0, 0, 0), SIMD3(1, 0.2, 3)), box(SIMD3(2.5, 0, 0), SIMD3(4, 0.2, 3)),
                box(SIMD3(1, 0, 0), SIMD3(2.5, 0.2, 0.75)), box(SIMD3(1, 0, 2.25), SIMD3(2.5, 0.2, 3)),
            ])
        let window = try element(
            2, "Window", "IfcWindow", [box(SIMD3(1, 0.05, 0.75), SIMD3(2.5, 0.15, 2.25))],
            materials: [.init(name: "Glass")])
        let structure = try IFCStructure(elements: [wall, window], options: .init(elementSize: 0.25))
        #expect(structure.model.openings.count == 1)
        let opening = try #require(structure.model.openings.first)
        #expect(abs(opening.min.x - 1) < 0.13 && abs(opening.max.x - 2.5) < 0.13)
        #expect(abs(opening.min.z - 0.75) < 0.13 && abs(opening.max.z - 2.25) < 0.13)
        let pane = try #require(structure.members.first { $0.role == .pane }?.solid)
        let glass = structure.model.solids[pane]
        #expect(abs(glass.size.y - 0.006) < 1e-5 && abs(0.5 * (glass.min.y + glass.max.y) - 0.1) < 1e-5)
        #expect(structure.model.solidMaterial[pane] == .annealedGlass)
        // A window that names no glass, as most IFC files' do, is glazed all the same, flagged.
        let plain = try element(
            2, "Window", "IfcWindow", [box(SIMD3(1, 0.05, 0.75), SIMD3(2.5, 0.15, 2.25))])
        let assumed = try #require(
            try IFCStructure(elements: [wall, plain], options: .init(elementSize: 0.25)).members.first {
                $0.name == "Window"
            })
        #expect(
            assumed.role == .pane && assumed.assumed
                && assumed.notes.contains { $0.contains("taken as glazed") })
        // A door's opening stays open.
        let door = try element(2, "Door", "IfcDoor", [box(SIMD3(1, 0.05, 0), SIMD3(2.5, 0.15, 2.25))])
        let open = try IFCStructure(elements: [wall, door])
        #expect(open.members.first { $0.name == "Door" }?.role == .opening && open.model.solids.count == 1)
    }

    @Test("Inclined elements stay rigid; gaps up to the tolerance are closed so members are tied")
    func inclinedAndGaps() throws {
        let rafter = try element(
            8, "Rafter", "IfcBeam", [box(SIMD3(0, 1, 3.2), SIMD3(4, 1.2, 3.4))], turn: 0.5)
        // The slab 30 mm above the walls' tops.
        var elements = try room().filter { $0.ifcClass == "IfcWall" }
        elements.append(try element(5, "Roof", "IfcSlab", [box(SIMD3(0, 0, 3.03), SIMD3(4, 4, 3.23))]))
        elements.append(rafter)
        let structure = try IFCStructure(elements: elements)
        #expect(structure.members.first { $0.name == "Rafter" }?.role == .rigid)
        #expect(structure.report.rigidParts == [rafter.partID])
        #expect(structure.assumptions.contains { $0.contains("Gaps closed") && $0.contains("30 mm") })
        #expect(structure.connections.filter { $0.kind.contains("slab") }.count == 4)
        // Past the tolerance they stay apart.
        let apart = try IFCStructure(elements: elements, options: .init(gap: 0.02))
        #expect(apart.connections.filter { $0.kind.contains("slab") }.isEmpty)
    }

    @Test(
        "Walls on a strip footing stand on footings of their own set into the soil; a slab on grade they pass through stays rigid"
    )
    func footingsAndGrade() throws {
        var elements = try room().filter { $0.ifcClass == "IfcWall" }
        // Lift the room 0.5 m onto a footing ring 0.6 m wide.
        elements = try elements.enumerated().map { n, wall in
            try element(
                n + 1, wall.name, "IfcWall",
                [
                    Box(
                        min: wall.mesh.bounds.min + SIMD3(0, 0, 0.5),
                        max: wall.mesh.bounds.max + SIMD3(0, 0, 0.5))
                ],
                materials: wall.materials)
        }
        elements.append(
            try element(
                9, "Footing", "IfcFooting",
                [
                    box(SIMD3(-0.2, -0.2, 0), SIMD3(4.2, 0.4, 0.5)),
                    box(SIMD3(-0.2, 3.6, 0), SIMD3(4.2, 4.2, 0.5)),
                    box(SIMD3(-0.2, 0.4, 0), SIMD3(0.4, 3.6, 0.5)),
                    box(SIMD3(3.6, 0.4, 0), SIMD3(4.2, 3.6, 0.5)),
                ]))
        let structure = try IFCStructure(elements: elements)
        #expect(!structure.model.fixedBase)
        let footed = structure.model.supportAnchorages.compactMap { $0?.footing }
        #expect(footed.count == 4)
        // 0.5 m deep, less the 1 mm the helper draws its boxes apart by.
        #expect(footed.allSatisfy { abs($0.thickness - 0.5) < 2e-3 && $0.embedment?.depth == $0.thickness })
        // The walls 0.2 m thick on footings 0.6 m wide: 0.2 m over each side across them.
        #expect(
            footed.allSatisfy {
                abs(max($0.overhang.x, $0.overhang.y) - 0.2) < 0.03 && min($0.overhang.x, $0.overhang.y) == 0
            })
        #expect(structure.model.solids.allSatisfy { $0.min.z >= -1e-4 } && structure.shift.z == -0.5)
        // A slab on grade that the walls pass through to the ground.
        var graded = try room().filter { $0.ifcClass == "IfcWall" }
        graded.append(try element(7, "Floor", "IfcSlab", [box(SIMD3(0, 0, 0), SIMD3(4, 4, 0.15))]))
        let slab = try IFCStructure(elements: graded)
        #expect(slab.members.first { $0.name == "Floor" }?.role == .rigid)
        #expect(slab.model.fixedBase && slab.model.solids.count == 4)
    }

    @Test("A slab on grade a little above the base rests on the ground, and the walls on it stand")
    func raisedSlabOnGrade() throws {
        // A floor 127 mm thick 10 mm above the base, the walls standing on it, beside a 150 mm
        // slab at the base.
        var elements = [
            try element(7, "Floor", "IfcSlab", [box(SIMD3(0, 0, 0.01), SIMD3(4, 4, 0.137))]),
            try element(8, "Porch", "IfcSlab", [box(SIMD3(0, -2, 0), SIMD3(4, 0, 0.15))]),
        ]
        elements += try room().filter { $0.ifcClass == "IfcWall" }.enumerated().map { n, wall in
            var low = wall.mesh.bounds.min
            low.z = 0.137
            return try element(n + 1, wall.name, "IfcWall", [Box(min: low, max: wall.mesh.bounds.max)])
        }
        let structure = try IFCStructure(elements: elements)
        #expect(structure.supports.contains { $0.contains("Floor: rests on the ground") })
        // The porch, its midsurface 1.5 mm off the floor's, is put on the floor's.
        #expect(structure.assumptions.contains { $0.contains("apart in level") && $0.contains("Porch") })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try ShellSolver(device: device, model: structure.model)
        solver.damping = 50
        solver.advance(steps: Int(0.3 / Double(solver.criticalTimeStep)))
        var mass: Float = 0
        solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
        let reaction = try #require(solver.anchorSummary()).reaction.z
        #expect(solver.summary().maxDisplacement < 1e-3, "\(solver.summary().maxDisplacement)")
        #expect(abs(reaction - mass * 9.81) < 0.02 * mass * 9.81, "\(reaction) against \(mass * 9.81)")
    }

    @Test("Walls of the lowest storey with nothing under them are tied to the ground at their foot")
    func unfounded() throws {
        // The floor inside the walls, 10 mm up; the walls stand beside it from its top, on a
        // foundation the IFC leaves out.
        var elements = [
            try element(7, "Floor", "IfcSlab", [box(SIMD3(0.2, 0.2, 0.01), SIMD3(3.8, 3.8, 0.137))])
        ]
        elements += try room().filter { $0.ifcClass == "IfcWall" }.enumerated().map { n, wall in
            var low = wall.mesh.bounds.min
            low.z = 0.137
            return try element(n + 1, wall.name, "IfcWall", [Box(min: low, max: wall.mesh.bounds.max)])
        }
        let structure = try IFCStructure(elements: elements)
        #expect(structure.supports.filter { $0.contains("foundation left out") }.count == 4)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try ShellSolver(device: device, model: structure.model)
        #expect(structure.model.supports.indices.allSatisfy { solver.supportBearingArea(at: $0) > 0 })
    }

    @Test("A member tied to nothing that stands on a support is said to fall")
    func loose() throws {
        // The room, and a beam hanging in the air half a metre above its roof.
        var elements = try room(concrete: true)
        elements.append(try element(9, "Loose beam", "IfcBeam", [box(SIMD3(0, 2, 3.7), SIMD3(4, 2.3, 4))]))
        let structure = try IFCStructure(elements: elements)
        #expect(
            structure.members.first { $0.name == "Loose beam" }?.notes.contains { $0.contains("will fall") }
                == true)
        #expect(structure.members.filter { $0.notes.contains { $0.contains("will fall") } }.count == 1)
        #expect(
            structure.assumptions.contains { $0.hasPrefix("1 of 7 members") && $0.contains("Loose beam") })
        // Untied from the room, the roof falls too.
        let roof = try #require(structure.members.first { $0.name == "Roof" })
        let keys = Set(
            structure.connections.filter { $0.first == roof.id || $0.second == roof.id }.map(\.key))
        let untied = try IFCStructure(elements: elements, options: .init(untied: keys))
        #expect(
            untied.members.first { $0.name == "Roof" }?.notes.contains { $0.contains("will fall") } == true)
    }

    @Test("Members that touch but that the mesh does not meet are tied at their nearest nodes, flagged")
    func contactTies() throws {
        // A 50 mm topping laid on the room's roof, face to face: parallel plates the mesh keeps
        // apart, tied where they touch.
        var elements = try room(concrete: true)
        elements.append(
            try element(
                9, "Topping", "IfcSlab", [box(SIMD3(0, 0, 3.2), SIMD3(4, 4, 3.25))],
                materials: [.init(name: "Concrete C30/37")]))
        let structure = try IFCStructure(elements: elements)
        #expect(structure.model.tiesTouching == true)
        let topping = try #require(structure.members.first { $0.name == "Topping" })
        #expect(!topping.notes.contains { $0.contains("will fall") })
        let tie = try #require(
            structure.connections.first { $0.first == topping.id || $0.second == topping.id })
        #expect(tie.kind.contains("inferred"))
        #expect(structure.assumptions.contains { $0.contains("tied rigidly at their nearest nodes") })
        let mesh = try ShellMesh(model: structure.model)
        #expect(mesh.contactTies.count == 1 && mesh.contactTies[0].nodes > 0)
        // Untied, it is loose again.
        let apart = try IFCStructure(elements: elements, options: .init(untied: [tie.key]))
        #expect(
            apart.members.first { $0.name == "Topping" }?.notes.contains { $0.contains("will fall") } == true)
        // Saved and read back, the switch stays.
        let model = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(structure.model))
        #expect(model.tiesTouching == true)
    }

    @Test("A foundation slab above a pit, a beam on the ground and a wall on a rigid arch are held")
    func heldRules() throws {
        // A pit's floor sets the lowest level; the foundation slab is 0.4 m above it with
        // nothing under it: it rests on the ground at its soffit.
        let pit = try element(1, "Pit floor", "IfcSlab", [box(SIMD3(1, 1, 0), SIMD3(2.5, 2.5, 0.3))])
        let slab = try element(2, "Foundation slab", "IfcSlab", [box(SIMD3(0, 0, 0.4), SIMD3(8, 6, 0.9))])
        // A ground beam lying on the ground: its centreline is above it.
        let ground = try element(3, "Ground beam", "IfcBeam", [box(SIMD3(10, 0, 0), SIMD3(16, 0.3, 0.4))])
        // A wall standing on an inclined (so rigid) arch.
        let arch = try element(4, "Arch", "IfcSlab", [box(SIMD3(20, 0, 0), SIMD3(26, 3, 1))], turn: 0.3)
        let wall = try element(5, "Spandrel", "IfcWall", [box(SIMD3(21, 1, 1.7), SIMD3(25, 1.2, 4))])
        let structure = try IFCStructure(elements: [pit, slab, ground, arch, wall])
        #expect(
            structure.supports.contains {
                $0.hasPrefix("Foundation slab: on the lowest storey near") && $0.contains("soffit")
            })
        #expect(structure.supports.contains { $0.hasPrefix("Ground beam: lies on the ground") })
        #expect(structure.supports.contains { $0.hasPrefix("Spandrel:") })
        #expect(!structure.members.contains { $0.notes.contains { $0.contains("will fall") } })
    }

    @Test("A slab on grade within its foundation walls, of the storey above theirs, rests on the ground")
    func slabOnGrade() throws {
        // Foundation walls 1.25 m high round a 4 m square; the slab on the fill between them is of
        // the ground floor, its top level with theirs.
        let walls = try [
            box(SIMD3(0, 0, 0), SIMD3(4.4, 0.2, 1.25)), box(SIMD3(0, 4.2, 0), SIMD3(4.4, 4.4, 1.25)),
            box(SIMD3(0, 0.2, 0), SIMD3(0.2, 4.2, 1.25)), box(SIMD3(4.2, 0.2, 0), SIMD3(4.4, 4.2, 1.25)),
        ].enumerated().map {
            try element(
                $0.offset + 1, "Foundation wall \($0.offset + 1)", "IfcWall", [$0.element], storey: "T/FDN")
        }
        let slab = try element(
            9, "Slab on grade", "IfcSlab", [box(SIMD3(0.2, 0.2, 1.1), SIMD3(4.2, 4.2, 1.25))],
            storey: "Level 1")
        let structure = try IFCStructure(elements: walls + [slab])
        #expect(
            structure.supports.contains {
                $0.hasPrefix("Slab on grade: within walls of the foundation") && $0.contains("soffit")
            })
        #expect(!structure.members.contains { $0.notes.contains { $0.contains("will fall") } })
        // A slab as high above the lowest level as a storey is not.
        let floor = try element(
            9, "First floor", "IfcSlab", [box(SIMD3(0.2, 0.2, 2.8), SIMD3(4.2, 4.2, 3))], storey: "Level 1")
        let tall = try walls.indices.map { n -> ImportedMesh.BuildingElement in
            var b = [
                box(SIMD3(0, 0, 0), SIMD3(4.4, 0.2, 3)), box(SIMD3(0, 4.2, 0), SIMD3(4.4, 4.4, 3)),
                box(SIMD3(0, 0.2, 0), SIMD3(0.2, 4.2, 3)), box(SIMD3(4.2, 0.2, 0), SIMD3(4.4, 4.2, 3)),
            ][n]
            b.max.z = 3
            return try element(n + 1, "Wall \(n + 1)", "IfcWall", [b], storey: "Ground")
        }
        let upper = try IFCStructure(elements: tall + [floor])
        #expect(!upper.supports.contains { $0.hasPrefix("First floor:") })
        // A floor on top of 0.6 m crawl-space walls is carried by them, not the ground.
        let low = try walls.indices.map { n -> ImportedMesh.BuildingElement in
            var b = [
                box(SIMD3(0, 0, 0), SIMD3(4.4, 0.2, 3)), box(SIMD3(0, 4.2, 0), SIMD3(4.4, 4.4, 3)),
                box(SIMD3(0, 0.2, 0), SIMD3(0.2, 4.2, 3)), box(SIMD3(4.2, 0.2, 0), SIMD3(4.4, 4.2, 3)),
            ][n]
            b.max.z = 0.6
            return try element(n + 1, "Wall \(n + 1)", "IfcWall", [b], storey: "Crawl space")
        }
        let suspended = try element(
            9, "Ground floor", "IfcSlab", [box(SIMD3(0, 0, 0.6), SIMD3(4.4, 4.4, 0.8))], storey: "Ground")
        #expect(
            !(try IFCStructure(elements: low + [suspended])).supports.contains {
                $0.hasPrefix("Ground floor:")
            })
    }

    @Test(
        "Foundation slabs of a storey above the pit's own, and a slab inside walls on footings, rest on the ground"
    )
    func foundationStoreys() throws {
        // The pit's floor is a storey of its own and sets the lowest level; the foundation slab
        // 0.4 m above it, with nothing under it, is of the next storey.
        let pit = try element(
            1, "Pit floor", "IfcSlab", [box(SIMD3(1, 1, 0), SIMD3(2.5, 2.5, 0.3))], storey: "Pit")
        let slab = try element(
            2, "Foundation slab", "IfcSlab", [box(SIMD3(3, 0, 0.4), SIMD3(9, 6, 0.95))], storey: "Foundation")
        let structure = try IFCStructure(elements: [pit, slab])
        #expect(
            structure.supports.contains {
                $0.hasPrefix("Foundation slab: on a storey starting near the lowest level")
            })
        // Foundation walls 1 m high standing 0.9 m up (on footings the IFC leaves out), and the
        // slab on the fill between them 1.77 m up.
        let walls = try [
            box(SIMD3(20, 0, 0.9), SIMD3(24.4, 0.2, 1.9)), box(SIMD3(20, 4.2, 0.9), SIMD3(24.4, 4.4, 1.9)),
            box(SIMD3(20, 0.2, 0.9), SIMD3(20.2, 4.2, 1.9)),
            box(SIMD3(24.2, 0.2, 0.9), SIMD3(24.4, 4.2, 1.9)),
        ].enumerated().map {
            try element(
                $0.offset + 3, "Foundation wall \($0.offset + 1)", "IfcWall", [$0.element],
                storey: "Foundation")
        }
        let grade = try element(
            9, "Slab on grade", "IfcSlab", [box(SIMD3(20.2, 0.2, 1.75), SIMD3(24.2, 4.2, 1.9))],
            storey: "Ground")
        let footed = try IFCStructure(elements: [pit] + walls + [grade])
        #expect(footed.supports.contains { $0.hasPrefix("Slab on grade: within walls of the foundation") })
    }

    @Test("A duplicate, given no elements of its own by the mesh, is not reported as falling")
    func duplicate() throws {
        var elements = try room(concrete: true)
        elements.append(try element(9, "Roof copy", "IfcSlab", [box(SIMD3(0, 0, 3), SIMD3(4, 4, 3.2))]))
        let structure = try IFCStructure(elements: elements)
        #expect(!structure.members.contains { $0.notes.contains { $0.contains("will fall") } })
    }

    @Test("A connection the user unticks leaves the pair apart, untied, and says so")
    func untied() throws {
        let elements = try room(concrete: true)
        let tied = try IFCStructure(elements: elements)
        let joint = try #require(tied.connections.first { $0.kind.contains("slab") })
        let untied = try IFCStructure(elements: elements, options: .init(untied: [joint.key]))
        let kept = try #require(untied.connections.first { $0.key == joint.key })
        #expect(kept.kind.contains("untied"))
        let solids = [joint.first, joint.second].map { id in
            untied.model.solids[untied.members.first { $0.id == id }!.solid!]
        }
        let gap = (0..<3).map {
            max(solids[0].min[$0] - solids[1].max[$0], solids[1].min[$0] - solids[0].max[$0])
        }.max()!
        // The wall drawn back from the 0.2 m roof until its top is over half an element from the
        // roof's midsurface: 35 mm.
        #expect(abs(gap - IFCStructure.untiedGap(elementSize: 0.25, thickness: 0.2)) < 1e-4)
        #expect(abs(IFCStructure.untiedGap(elementSize: 0.25, thickness: 0.2) - 0.035) < 1e-6)
        #expect(
            untied.assumptions.contains { $0.hasPrefix("\(tied.connections.count - 1) connections inferred") }
        )
        // The choice survives saving the options.
        let options = try JSONDecoder().decode(
            IFCStructure.Options.self, from: JSONEncoder().encode(IFCStructure.Options(untied: [joint.key])))
        #expect(options.untied == [joint.key])
    }

    @Test("Past the solver's eight materials the nearest of a kind are merged, and it says by how much")
    func mergedMaterials() throws {
        // Twelve steel I-beams of different depths, each a material of its own.
        var elements: [ImportedMesh.BuildingElement] = []
        for n in 0..<12 {
            let d = 0.2 + Float(n) * 0.03
            let (b, tf, tw): (Float, Float, Float) = (0.15, 0.012, 0.007)
            let y = Float(n) * 1.0
            elements.append(
                try element(
                    n + 1, "Beam \(n)", "IfcBeam",
                    [
                        box(SIMD3(0, y - b / 2, 3), SIMD3(5, y + b / 2, 3 + tf)),
                        box(SIMD3(0, y - tw / 2, 3 + tf), SIMD3(5, y + tw / 2, 3 + d - tf)),
                        box(SIMD3(0, y - b / 2, 3 + d - tf), SIMD3(5, y + b / 2, 3 + d)),
                    ], materials: [.init(name: "Steel S355")]))
        }
        let structure = try IFCStructure(elements: elements)
        #expect(structure.model.materials.count <= StructureModel.maxMaterials)
        let note = try #require(structure.assumptions.first { $0.contains("merged into") })
        #expect(note.contains("stiffness changed by up to"))
        #expect(structure.members.contains { $0.material?.contains("merged") == true })
        // Under the limit nothing is merged.
        let few = try IFCStructure(elements: Array(elements.prefix(4)))
        #expect(!few.assumptions.contains { $0.contains("merged into") })
    }

    @Test("A slab of a plank and a turned lattice bar is square by its volume, and one member")
    func assembly() throws {
        let owner = ImportedMesh.BuildingElement.Assembly(
            id: String(format: "%022d", 50), name: "Plank floor", ifcClass: "IfcSlab")
        var plank = try element(
            1, "Plank", "IfcBuildingElementProxy", [box(SIMD3(0, 0, 0), SIMD3(6, 2.4, 0.06))])
        var bar = try element(
            2, "Lattice", "IfcBuildingElementProxy", [box(SIMD3(1, 1, 0.06), SIMD3(1.3, 1.02, 0.08))],
            turn: 0.3)
        plank.assembly = owner
        bar.assembly = owner
        let structure = try IFCStructure(elements: [plank, bar])
        let floor = try #require(structure.members.first)
        #expect(structure.members.count == 1 && floor.name == "Plank floor" && floor.role == .shell)
        #expect(floor.parts.map(Set.init) == [plank.partID, bar.partID])
        #expect(floor.notes.contains { $0.contains("Built of 2 parts") })
        // An assembly kept rigid keeps every part an obstacle in the air.
        var lump = owner
        lump.ifcClass = "IfcBuildingElementProxy"
        plank.assembly = lump
        bar.assembly = lump
        let wall = try element(3, "Wall", "IfcWall", [box(SIMD3(0, 3, 0), SIMD3(4, 3.2, 3))])
        let mixed = try IFCStructure(elements: [plank, bar, wall])
        #expect(Set(mixed.report.rigidParts) == [plank.partID, bar.partID])
    }

    @Test(
        "Parallel plates closer than a fifth of an element share a midsurface; a cavity apart they stay apart"
    )
    func nearPlates() throws {
        // Two walls side by side in x, their midsurfaces `offset` apart in y, under a slab
        // spanning both: two near midsurfaces would leave a sliver of slab elements between them.
        func mesh(_ offset: Float) throws -> ShellMesh {
            let model = StructureModel(
                solids: [
                    box(SIMD3(0, 0, 0), SIMD3(4, 0.2, 3)),
                    box(SIMD3(4.5, offset, 0), SIMD3(8.5, offset + 0.2, 3)),
                    box(SIMD3(0, -1, 3), SIMD3(8.5, 2, 3.2)),
                ], elementSize: 0.25)
            return try ShellMesh(model: model)
        }
        let near = try mesh(0.002)
        #expect(near.elements.allSatisfy { $0.size.min() >= 0.2 * 0.25 - 1e-4 })
        let apart = try mesh(0.15)
        let levels = Set(apart.positions.map(\.y))
        #expect(levels.contains { abs($0 - 0.1) < 1e-5 } && levels.contains { abs($0 - 0.25) < 1e-5 })
    }

    @Test("A flanged beam is a rectangle 0.6 of its depth wide, as stiff, strong and heavy as the shape")
    func flangedBeam() throws {
        // A 400 mm deep I-section, flanges 180 × 15 mm, web 8 mm, 5 m long along x.
        let (d, b, tf, tw): (Float, Float, Float, Float) = (0.4, 0.18, 0.015, 0.008)
        let beam = try element(
            1, "Steel beam", "IfcBeam",
            [
                box(SIMD3(0, -b / 2, 3 - d / 2), SIMD3(5, b / 2, 3 - d / 2 + tf)),
                box(SIMD3(0, -tw / 2, 3 - d / 2 + tf), SIMD3(5, tw / 2, 3 + d / 2 - tf)),
                box(SIMD3(0, -b / 2, 3 + d / 2 - tf), SIMD3(5, b / 2, 3 + d / 2)),
            ], materials: [.init(name: "Steel S355")])
        let structure = try IFCStructure(elements: [beam])
        let index = try #require(structure.members.first?.solid)
        let section = structure.model.solids[index]
        let depth = beam.mesh.bounds.size.z
        #expect(abs(section.size.y - 0.6 * depth) < 1e-4 && abs(section.size.z - depth) < 1e-4)
        let material = try #require(
            structure.model.solidMaterial[index] ?? structure.model.material as StructureMaterial?)
        // The area of the three boxes as drawn, each 1 mm smaller than given.
        let area = 2 * (b - 0.001) * (tf - 0.001) + (tw - 0.001) * (d - 2 * tf - 0.001)
        let steel = StructureMaterial.structuralSteel
        // E I and ρ A as the rule of thumb for wide-flange shapes gives them.
        let rectangle = section.size.y * depth
        #expect(
            abs(
                material.youngsModulus * section.size.y * pow(depth, 3) / 12
                    / (steel.youngsModulus * 0.175 * area * depth * depth) - 1)
                < 0.03)
        #expect(abs(material.density * rectangle / (steel.density * area) - 1) < 0.03)
    }
}
