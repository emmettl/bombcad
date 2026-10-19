import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

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
}
