import BlastModel
import Foundation
import Metal
import simd

extension NassrSteelTest {
    /// One member of `shot`: a beam, or a column under its axial load. `rateFactor` raises the steel's
    /// yield (a study of the strain-rate effect the model's steel lacks).
    public static func run(
        device: MTLDevice, shot: Shot, column: Bool, rateFactor: Float = 1, duration: Double = 0.06,
        elements: Int = 24
    ) throws -> Result {
        let (section, yield, kgPerM) = Self.section(shot.section, axis: shot.axis)
        var steel = StructureMaterial.structuralSteel
        steel.yieldStress = yield * rateFactor
        // To the ultimate at 15% strain (537 and 474 MPa).
        steel.hardeningModulus = ((shot.section == "W150X24" ? 537e6 : 474e6) - yield) / 0.15
        let width = section.rectangleWidth
        let material = section.equivalent(of: steel, width: width)
        // Upright, along z, bent along x; the foot 0.5 m up.
        let base: Float = 0.5
        var model = StructureModel(
            solids: [
                Box(
                    min: SIMD3(-section.depth / 2, -width / 2, base),
                    max: SIMD3(section.depth / 2, width / 2, base + span))
            ], material: material, elementSize: span / Float(elements), fixedBase: false)
        model.elementKind = .shell
        // Rolled I-sections: about the strong axis curve a (h/b > 1.2) or b, about the weak b or c.
        model.bucklingCurve =
            shot.section == "W150X24" ? (shot.axis == .strong ? .a : .b) : (shot.axis == .strong ? .b : .c)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        let positions = solver.mesh.positions
        let foot = solver.nodes { $0.z < base + 1e-4 }
        let head = solver.nodes { $0.z > base + span - 1e-4 }
        let middle = solver.nearestNode(to: SIMD3(0, 0, base + span / 2))
        // The column's load: a head mass far heavier than the member, under gravity raised slowly.
        let headMass: Float = column ? 1000 * kgPerM * span : 0
        solver.mutateNodes { nodes in
            for n in foot { nodes[n].restrain(x: true, y: true, z: true) }
            for n in head {
                nodes[n].restrain(x: true, y: true, z: !column)
                if column { nodes[n].mass += headMass / Float(head.count) }
            }
            // The curtain moves with the member: its mass over the nodes between the ends.
            let inner = nodes.indices.filter { !foot.contains($0) && !head.contains($0) }
            for n in inner { nodes[n].mass += shot.addedMass / Float(inner.count) }
        }
        if column {
            solver.damping = 60
            let gravity = shot.axialLoad / headMass
            let settle = 0.3
            let chunk = max(1, Int(0.005 / Double(solver.criticalTimeStep)))
            while solver.time < settle {
                solver.gravity = gravity * Float(min(1, solver.time / (0.6 * settle)))
                solver.advance(steps: chunk)
            }
            solver.gravity = gravity
            solver.damping = 0
        } else {
            solver.gravity = 0
        }
        // The blast on the face towards -x: each node a share of the width over its length.
        var shares = [Float](repeating: 0, count: positions.count)
        let nodesAlong = positions.indices.filter { !head.contains($0) && !foot.contains($0) }
        let spacing = span / Float(elements)
        for n in nodesAlong { shares[n] = shot.width * spacing }
        for n in foot + head { shares[n] = 0.5 * shot.width * spacing / Float(max(foot.count, 1)) }
        let start = Float(solver.time)
        let fall = 2 * shot.impulse / shot.pressure
        var load = PressureLoad(
            axis: 0, positiveSide: true,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 1e-6, shot.pressure), SIMD2(start + fall, 0),
                SIMD2(start + fall + 10, 0),
            ])
        load.nodeShares = shares
        solver.appliedLoad = load
        let rest = solver.node(middle).displacement.x
        var peak: Float = 0
        let chunk = max(1, Int(0.0002 / Double(solver.criticalTimeStep)))
        while solver.time < Double(start) + duration {
            solver.advance(steps: chunk)
            peak = max(peak, rest - solver.node(middle).displacement.x)
        }
        let final = rest - solver.node(middle).displacement.x
        return Result(
            shot: shot.number, column: column, peak: peak, final: final,
            measured: column ? shot.column : shot.beam)
    }
}
