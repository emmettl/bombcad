import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Shells at a pitch (`Inclination`): planes laid through their solids' boxes, meshed in their own
/// planes, their elements taking their axes from their corners.
@Suite("Shells at a pitch", .gpuThreads)
struct InclinedShellTests {
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)

    @Test("A plane through its box: the pitch, the slope's length and its normal up out of it")
    func plane() {
        let pitch: Float = 30 * .pi / 180
        let box = Box(min: .zero, max: SIMD3(1, 2 * cos(pitch), 2 * sin(pitch)))
        for upwards in [true, false] {
            let inclination = Inclination(rise: 1, upwards: upwards, thickness: 0.1)
            let plane = inclination.plane(in: box)
            #expect(abs(inclination.pitch(in: box) - 30) < 1e-3)
            #expect(abs(plane.lengths.y - 2) < 1e-5 && abs(plane.lengths.x - 1) < 1e-6)
            #expect(plane.normal.z > 0 && abs(plane.normal.z - cos(pitch)) < 1e-5)
            let low = inclination.height(at: SIMD2(0.5, upwards ? 0 : box.max.y), in: box)
            let high = inclination.height(at: SIMD2(0.5, upwards ? box.max.y : 0), in: box)
            #expect(low == 0 && abs((high ?? 0) - box.max.z) < 1e-6)
        }
    }

    /// The tip's deflection, square to the plate, of a 2 m plate cantilevered from its low edge under
    /// its weight: laid at `pitch`, or flat under the weight's share across it (cos pitch).
    private func cantilever(pitch degrees: Float, flat: Bool) throws -> Float {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let pitch = degrees * .pi / 180
        var model: StructureModel
        if flat {
            model = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 4.95), max: SIMD3(1, 2, 5.05))], material: material,
                elementSize: 0.125, fixedBase: false)
        } else {
            model = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 5), max: SIMD3(1, 2 * cos(pitch), 5 + 2 * sin(pitch)))],
                material: material,
                elementSize: 0.125, fixedBase: false)
            model.setInclination(Inclination(rise: 1, upwards: true, thickness: 0.1), of: 0)
        }
        model.elementKind = .shell
        // Clamped along its low edge, 5 m up, clear of the floor.
        model.supports = [Box(min: SIMD3(-0.01, -0.01, 4.94), max: SIMD3(1.01, 0.01, 5.06))]
        let solver = try ShellSolver(device: device, model: model)
        if flat { solver.gravity = 9.81 * cos(pitch) }
        solver.damping = 400
        solver.advance(steps: Int((0.3 / Double(solver.criticalTimeStep)).rounded()))
        let normal = flat ? SIMD3<Float>(0, 0, 1) : SIMD3(0, -sin(pitch), cos(pitch))
        let tip = flat ? SIMD3<Float>(0.5, 2, 5) : SIMD3(0.5, 2 * cos(pitch), 5 + 2 * sin(pitch))
        var deflection: Float = 0
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            let n = positions.indices.min {
                simd_distance(positions[$0], tip) < simd_distance(positions[$1], tip)
            }!
            deflection = -simd_dot(nodes[n].displacement, normal)
        }
        return deflection
    }

    @Test(
        "Cantilevered at 30°, a plate bends square to itself as the flat one under its weight's share across it"
    )
    func cantilevered() throws {
        let pitched = try cantilever(pitch: 30, flat: false)
        let flat = try cantilever(pitch: 30, flat: true)
        // Kirchhoff's strip, q L⁴ / 8D, for scale: about 1.6 mm.
        #expect(flat > 1e-3 && flat < 3e-3, "\(flat)")
        #expect(abs(pitched / flat - 1) < 0.02, "\(pitched) against \(flat)")
    }

    @Test("Two slopes share their nodes along the ridge, and a wall under them is cut to a gable")
    func ridgeAndGable() throws {
        // A 4 m span at 40°, ridge along x at y = 2, over a wall in the plane x = 0 up to the ridge.
        let rise = 2 * tan(Float(40) * .pi / 180)
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 3), max: SIMD3(2, 2, 3 + rise)),
                Box(min: SIMD3(0, 2, 3), max: SIMD3(2, 4, 3 + rise)),
                Box(min: SIMD3(-0.05, 0, 0), max: SIMD3(0.05, 4, 3 + rise)),
            ], material: material, elementSize: 0.25, fixedBase: true)
        model.elementKind = .shell
        model.setInclination(Inclination(rise: 1, upwards: true, thickness: 0.1, trimsWalls: true), of: 0)
        model.setInclination(Inclination(rise: 1, upwards: false, thickness: 0.1, trimsWalls: true), of: 1)
        let mesh = try ShellMesh(model: model)
        let slopes = mesh.elements.filter { $0.solid < 2 }
        #expect(slopes.allSatisfy { $0.axis == 3 })
        let ridge = Set(
            slopes.flatMap { e in (0..<4).map { e.nodes[$0] } }.filter {
                abs(mesh.positions[Int($0)].y - 2) < 1e-3 && abs(mesh.positions[Int($0)].z - 3 - rise) < 1e-3
            })
        // One node a grid line along the ridge (2 m in 0.25 m elements), shared by both slopes.
        #expect(ridge.count == 9, "\(ridge.count)")
        // The gable: no element of the wall above the slopes over it.
        for element in mesh.elements where element.solid == 2 {
            let centre = (0..<4).reduce(SIMD3<Float>.zero) { $0 + mesh.positions[Int(element.nodes[$1])] } / 4
            let roof = 3 + rise * (1 - abs(centre.y - 2) / 2)
            #expect(centre.z <= roof + 1e-3, "\(centre)")
        }
        #expect(mesh.elements.contains { $0.solid == 2 && $0.axis == 0 })
    }

    @Test(
        "A roof put over four walls raises the end walls to gables, seats its slopes on the walls and hangs its tiles"
    )
    func roofOverWalls() throws {
        // A 6 m by 8 m box of 200 mm walls, 3 m high; the ridge along y.
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 0), max: SIMD3(0.2, 8, 3)),
                Box(min: SIMD3(5.8, 0, 0), max: SIMD3(6, 8, 3)),
                Box(min: SIMD3(0, 0, 0), max: SIMD3(6, 0.2, 3)),
                Box(min: SIMD3(0, 7.8, 0), max: SIMD3(6, 8, 3)),
            ], material: .masonry, elementSize: 0.25, fixedBase: true)
        model.elementKind = .shell
        let added = model.addPitchedRoof(
            PitchedRoof(pitch: 35, ridgeAlong: 1), over: Box(min: .zero, max: SIMD3(6, 8, 3)), eaves: 3)
        #expect(added == 4..<8)
        let ridge = 3 + 3 * tan(Float(35) * .pi / 180)
        // The end walls across the ridge are gables now; the eaves walls are as they were.
        #expect(abs(model.solids[2].max.z - ridge) < 1e-5 && abs(model.solids[3].max.z - ridge) < 1e-5)
        #expect(model.solids[0].max.z == 3 && model.solids[1].max.z == 3)
        #expect(abs(model.inclination(of: 4)!.pitch(in: model.solids[4]) - 35) < 1e-3)
        // Two seats a wall that reaches across the ridge, one a wall on one side; one a covering.
        let laws = model.supports.indices.compactMap { model.anchorage(ofSupport: $0) }
        #expect(laws.filter { $0.solids == [4] }.count == 3 && laws.filter { $0.solids == [5] }.count == 3)
        #expect(laws.filter { $0.solids == [6] || $0.solids == [7] }.count == 2)
        let mesh = try ShellMesh(model: model)
        #expect(mesh.elements.contains { $0.solid == 2 && $0.axis == 1 })
        // Removing a wall keeps the joints naming the slopes and tiles they did.
        model.removeSolid(at: 0)
        let after = model.supports.indices.compactMap { model.anchorage(ofSupport: $0)?.solids }
        #expect(after.allSatisfy { $0.allSatisfy { (3..<7).contains($0) } })
        // The tiles still hang on their slopes, the slopes bear on the walls left.
        let partners = model.supports.indices.compactMap { model.anchorage(ofSupport: $0)?.partners }
        #expect(partners.filter { $0 == [3] || $0 == [4] }.count == 2)
        #expect(partners.allSatisfy { $0.allSatisfy { (0..<5).contains($0) } })
    }
}
