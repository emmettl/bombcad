import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Structure surface and USD export", .gpuThreads)
struct StructureSurfaceTests {
    let device: MTLDevice

    private static let concrete = StructureMaterial.concrete(name: "Concrete", compressiveStrength: 30e6)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func solver(_ structure: StructureModel) throws -> BlastSolver {
        let scenario = Scenario(
            name: "Surface", domainSize: SIMD3(4, 4, 4),
            boxes: [Box(min: SIMD3(3, 3, 0), max: SIMD3(3.5, 3.5, 1))],
            charge: Charge(mass: 0, position: SIMD3(0.5, 0.5, 0.5)), structure: structure)
        return try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
    }

    /// Volume enclosed by outward faces, by the divergence theorem; negative if they face inward.
    private func volume(_ surface: StructureSurface) -> Float {
        stride(from: 0, to: surface.quads.count, by: 4).reduce(Float(0)) { total, start in
            let p = surface.quads[start..<start + 4].map { surface.points[Int($0)] }
            return total + (dot(p[0], cross(p[1], p[2])) + dot(p[0], cross(p[2], p[3]))) / 6
        }
    }

    /// Every edge of a closed surface belongs to exactly two faces, once each way round.
    private func isClosed(_ surface: StructureSurface) -> Bool {
        var edges: [SIMD2<Int32>: Int] = [:]
        for start in stride(from: 0, to: surface.quads.count, by: 4) {
            for n in 0..<4 {
                edges[SIMD2(surface.quads[start + n], surface.quads[start + (n + 1) % 4]), default: 0] += 1
            }
        }
        return edges.allSatisfy { edge, count in count == 1 && edges[SIMD2(edge.y, edge.x)] == 1 }
    }

    @Test("A solid block's surface is its outer faces, closed, outward and enclosing its volume")
    func solidBlock() throws {
        let solver = try solver(
            StructureModel(
                solids: [Box(min: SIMD3(1, 1, 1), max: SIMD3(2, 1.5, 1.5))], material: Self.concrete,
                elementSize: 0.125,
                fixedBase: false))
        let structure = try #require(solver.structure)
        let surface = try #require(solver.structureSurface())
        let faces = 2 * (8 * 4 + 8 * 4 + 4 * 4)
        let points = 9 * 5 * 5 - 7 * 3 * 3
        #expect(surface.faceCount == faces)
        #expect(surface.points.count == points)
        #expect(abs(volume(surface) - 0.25) < 1e-4)
        #expect(isClosed(surface))
        #expect(surface.damage.count == surface.faceCount && surface.material.allSatisfy { $0 == 0 })
        #expect(surface.materials.map(\.name) == [Self.concrete.name])

        // A failed corner element leaves its neighbours' faces showing, and becomes rubble.
        let h = structure.model.elementSize
        let corner = structure.elementIndex(0, 0, 0)
        structure.flagBuffer.contents().storeBytes(
            of: ElementFlag.eroded.rawValue, toByteOffset: corner, as: UInt8.self)
        let broken = try #require(solver.structureSurface())
        #expect(broken.faceCount == surface.faceCount + 6)
        let rubble = 0.6 * h
        #expect(abs(volume(broken) - (0.25 - h * h * h + rubble * rubble * rubble)) < 1e-4)
        #expect(broken.damage.filter { $0 == 1 }.count == 6)
        #expect(broken.rubble.filter { $0 }.count == 6 && !surface.rubble.contains(true))
    }

    @Test("Shells become closed boxes their thickness through")
    func shellWall() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(1, 1, 0), max: SIMD3(3, 1.2, 1))], material: Self.concrete,
            elementSize: 0.25,
            fixedBase: true)
        model.elementKind = ElementKind.shell
        let solver = try solver(model)
        let shells = try #require(solver.shells)
        let surface = try #require(solver.structureSurface())
        #expect(surface.faceCount == 6 * (shells.elementCount + shells.beamCount))
        #expect(abs(volume(surface) - 2 * 0.2 * 1) < 0.01)
        #expect(isClosed(surface))
    }
}
