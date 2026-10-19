import BlastModel
import Foundation
import Metal
import simd

extension ColumnRemovalTest {
    public static func run(
        device: MTLDevice, specimen s: Specimen, connection: SteelConnection?, speed: Float = 0.1,
        drop: Float = 1.1, elementSize: Float = 0.15
    ) throws -> Result {
        let (beam, column, beamSteel, columnSteel, _) = specimen(s)
        func steel(_ strength: SIMD2<Float>) -> StructureMaterial {
            var material = StructureMaterial.structuralSteel
            material.yieldStress = strength.x
            // To the ultimate at 15% strain, and no strain-rate law: the test was slow.
            material.hardeningModulus = (strength.y - strength.x) / 0.15
            material.rateLaw = nil
            return material
        }
        let span = s.span
        let storey: Float = 4.19
        let level = storey / 2
        let stub: Float = 0.75
        let beamWidth = beam.rectangleWidth
        let columnWidth = column.rectangleWidth
        var solids: [Box] = []
        var materials: [StructureMaterial] = []
        // Beams along x, their depth up; columns up, their depth along x.
        solids.append(
            Box(
                min: SIMD3(0, -beamWidth / 2, level - beam.depth / 2),
                max: SIMD3(2 * span, beamWidth / 2, level + beam.depth / 2)))
        materials.append(beam.equivalent(of: steel(beamSteel), width: beamWidth))
        for x in [Float(0), 2 * span] {
            solids.append(
                Box(
                    min: SIMD3(x - column.depth / 2, -columnWidth / 2, 0),
                    max: SIMD3(x + column.depth / 2, columnWidth / 2, storey)))
            materials.append(column.equivalent(of: steel(columnSteel), width: columnWidth))
        }
        solids.append(
            Box(
                min: SIMD3(span - column.depth / 2, -columnWidth / 2, level - stub),
                max: SIMD3(span + column.depth / 2, columnWidth / 2, level + stub)))
        materials.append(column.equivalent(of: steel(columnSteel), width: columnWidth))
        // The two spans as two beams, each ending at the stub, so that each has its connection there.
        solids[0].max.x = span
        solids.insert(
            Box(
                min: SIMD3(span, -beamWidth / 2, level - beam.depth / 2),
                max: SIMD3(2 * span, beamWidth / 2, level + beam.depth / 2)), at: 1)
        materials.insert(materials[0], at: 1)
        var model = StructureModel(
            solids: solids, material: materials[0], elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        for (index, material) in materials.enumerated() where material != model.material {
            model.setMaterial(material, of: index)
        }
        model.steelConnection = connection
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 5
        let positions = solver.referencePositions
        let feet = solver.nodes { $0.z < 1e-4 }
        let tops = solver.nodes { $0.z > storey - 1e-4 }
        let pushed = solver.nodes { abs($0.x - span) < 1e-3 && $0.z > level + stub - 1e-4 }
        solver.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].restrain(y: true) }
            for n in feet { nodes[n].restrain(x: true, y: true, z: true, rotation: true) }
            for n in tops { nodes[n].restrain(x: true, y: true) }
            for n in pushed {
                nodes[n].restrain(x: true, y: true)
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(0, 0, -speed)
            }
        }
        _ = positions
        // The stub starts at full speed, a jolt the load rings with at first; peak and failure are
        // read past the first tenth of the test's drop.
        let settled = 0.1 * Self.measured(s).drop
        var curve: [SIMD2<Float>] = []
        var peak: Float = 0
        var atPeak: Float = 0
        var failedAt: Float?
        let chunk = max(1, Int(0.005 / solver.criticalTimeStep))
        // The load read every 5 ms rings with the stub's mass; it is judged on its mean over the
        // last 10 mm of drop.
        let window = max(1, Int(0.01 / (speed * 0.005)))
        while Float(solver.time) * speed < drop {
            solver.advance(steps: chunk)
            let down = Float(solver.time) * speed
            curve.append(SIMD2(down, abs(pushed.reduce(Float(0)) { $0 + solver.nodalForce($1).z })))
            let recent = curve.suffix(window)
            let load = recent.reduce(0) { $0 + $1.y } / Float(recent.count)
            guard down > settled else { continue }
            if load > peak {
                peak = load
                atPeak = down
            }
            if failedAt == nil, peak > 0.5 * Self.measured(s).load, load < 0.5 * peak {
                failedAt = down
                break
            }
        }
        return Result(
            peakLoad: peak, dropAtPeak: atPeak, failedAt: failedAt, hingesReleased: solver.hingesReleased,
            curve: curve)
    }
}
