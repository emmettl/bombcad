import Foundation
import Testing
import simd

@testable import BlastModel

/// Checks the shell elements against plate and beam theory.
@Suite("Shell elements")
struct ShellTests {
    @Test("Walls and roof share nodes along the lines where they meet, and openings are left out")
    func buildingMesh() throws {
        var model = try #require(ScenarioPreset.concreteBox.scenario.structure)
        model.elementKind = .shell
        model.elementSize = 0.25
        let mesh = try ShellMesh(model: model)
        // The front wall's midsurface is at x = 16.125, the roof's at z = 3.375.
        let front = mesh.positions.indices.filter { abs(mesh.positions[$0].x - 16.125) < 1e-4 }
        let roof = Set(mesh.positions.indices.filter { abs(mesh.positions[$0].z - 3.375) < 1e-4 })
        let shared = front.filter { roof.contains($0) }
        // Along y from 11.125 to 20.875 on 0.25 m elements (with the window edges as breakpoints).
        #expect(shared.count >= 40, "\(shared.count) nodes shared by the front wall and the roof")
        // No element is larger than asked for, nor much smaller.
        for element in mesh.elements {
            #expect(element.size.max() <= 0.25 + 1e-4)
            #expect(element.size.min() >= 0.1)
        }
        // A window in the front wall: no element centre inside it.
        for element in mesh.elements
        where element.axis == 0 && abs(mesh.positions[Int(element.nodes.x)].x - 16.125) < 1e-4 {
            let corners = (0..<4).map { mesh.positions[Int(element.nodes[$0])] }
            let centre = corners.reduce(SIMD3<Float>.zero, +) / 4
            #expect(!(centre.y > 12.5 && centre.y < 14.5 && centre.z > 1 && centre.z < 2.25))
        }
        // Every wall has a mat of bars near each face.
        for element in mesh.elements {
            #expect(element.bars.count == 2)
        }
        #expect(throws: BlastError.self) {
            var columns = model
            // A block as long as it is wide is neither a wall nor a column.
            columns.solids.append(Box(x: 18...18.4, y: 15...15.4, height: 0.4))
            _ = try ShellMesh(model: columns)
        }
    }

    // MARK: Beams

    @Test("Frames mesh with beams on their columns, sharing nodes with the slabs")
    func frameMesh() throws {
        var model = try #require(ScenarioPreset.threeStorey.scenario.structure)
        model.elementKind = .shell
        model.elementSize = 0.25
        let mesh = try ShellMesh(model: model)
        // Twelve columns, each from the ground to the roof slab's midsurface.
        let columnCentres = Set(
            mesh.beams.map { beam -> SIMD2<Float> in
                let p = mesh.positions[Int(beam.nodes.x)]
                return SIMD2(p.x, p.y)
            })
        #expect(columnCentres.count == 12)
        #expect(mesh.beams.allSatisfy { $0.axis == 2 && $0.bars.count == 4 && $0.tieRatio > 0 })
        // Every column node at a slab's midsurface is also a node of that slab.
        let slabNodes = Set(
            mesh.elements.filter { $0.axis == 2 }.flatMap { e in (0..<4).map { Int(e.nodes[$0]) } })
        let levels: [Float] = [3.375, 6.875, 10.375]
        for beam in mesh.beams {
            for end in 0..<2 {
                let n = Int(beam.nodes[end])
                if levels.contains(where: { abs(mesh.positions[n].z - $0) < 1e-4 }) {
                    #expect(slabNodes.contains(n))
                }
            }
        }
        let top = mesh.beams.map { max(mesh.positions[Int($0.nodes.x)].z, mesh.positions[Int($0.nodes.y)].z) }
            .max()
        #expect(abs((top ?? 0) - 10.375) < 1e-4)
    }
}
