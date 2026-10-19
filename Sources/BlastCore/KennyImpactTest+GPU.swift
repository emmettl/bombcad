import BlastModel
import Foundation
import Metal
import simd

extension KennyImpactTest {
    /// `rateLaw`: the steel's yield rising with strain rate, Jones's mild-steel constants (Kenny's
    /// CR1018 yields at 300 MPa); aluminium 6061-T6 is taken as rate-independent.
    public static func run(
        device: MTLDevice, series s: Series, measuredBow: Bool = false, rateLaw: Bool = true,
        elementSize: Float = 0.004, stroke: Float = 0.010
    ) throws -> Result {
        let width: Float = 0.0508
        let drawn: Float = 0.006
        let k = width / drawn
        // Table 6-6: E, the tangent modulus, yield and density.
        let (modulus, tangent, yield, rho): (Float, Float, Float, Float) =
            s.steel ? (200e9, 1.75e9, 300e6, 7200) : (69e9, 0.9e9, 285e6, 2700)
        var material = StructureMaterial(
            name: s.steel ? "CR1018 steel" : "6061-T6 aluminium", density: rho * k,
            youngsModulus: modulus * k,
            poissonRatio: 0.3, yieldStress: yield * k,
            hardeningModulus: modulus * tangent / (modulus - tangent) * k, failureStrain: 1e30)
        material.rateLaw = s.steel && rateLaw ? .cowperSymonds(d: 40.4, q: 5) : nil
        let t = s.thickness
        let base: Float = 0.5
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(-t / 2, -drawn / 2, base), max: SIMD3(t / 2, drawn / 2, base + s.length))
            ],
            material: material, elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        model.memberImperfections = true
        model.bucklingCurve = .c
        let solver = try MemberImperfection.$divisorOverride.withValue(measuredBow ? 1 / s.beta : nil) {
            try ShellSolver(device: device, model: model)
        }
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 0
        let foot = solver.nodes { $0.z < base + 1e-5 }
        let head = solver.nodes { $0.z > base + s.length - 1e-5 }
        let hammer: Float = 10
        solver.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].restrain(y: true) }
            for n in foot { nodes[n].restrain(x: true, y: true, z: true, rotation: true) }
            for n in head {
                nodes[n].restrain(x: true, y: true, rotation: true)
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(0, 0, -s.speed)
            }
        }
        // The hammer drives the head while the strip pushes back on it, slowed by that push, and
        // leaves it once the strip no longer pushes (the returning tensile wave or the strip's
        // rebound part them, as Kenny observed); it strikes again whenever it catches the head
        // up, until it has pushed the head down `stroke`, when it meets the bearing disc the top
        // of the strip stood above (scribed 35 mm from the top, the disc 25 mm thick: Kenny's
        // Appendix B.3; he measured about 5 mm of shortening) and the drop tube stops it. Gravity is left out: the hammer's fall over a few milliseconds is a few tenths of a
        // millimetre.
        var down = s.speed
        var hammerZ = base + s.length
        var touching = true
        var caught = false
        var stopped: Float?
        var parted: Float?
        var receded: Float?
        func headState() -> (z: Float, down: Float) {
            var z: Float = 0
            var v: Float = 0
            solver.mutateNodes { nodes in
                for n in head {
                    z += nodes[n].displacement.z
                    v -= nodes[n].velocity.z
                }
            }
            return (base + s.length + z / Float(head.count), v / Float(head.count))
        }
        let chunk = max(1, Int(1e-5 / solver.criticalTimeStep))
        while Float(solver.time) < 0.1 {
            let before = Float(solver.time)
            solver.advance(steps: chunk)
            let dt = Float(solver.time) - before
            if touching, headState().z <= base + s.length - stroke {
                // The hammer's head has reached the bearing disc: the drop tube stops it.
                touching = false
                caught = true
                down = 0
                parted = parted ?? Float(solver.time)
                receded = Float(solver.time)
                solver.mutateNodes { nodes in for n in head { nodes[n].isPrescribed = false } }
            } else if touching {
                let push = head.reduce(Float(0)) { $0 + solver.nodalForce($1).z }
                if push < 0, Float(solver.time) > 1e-4 {
                    touching = false
                    parted = parted ?? Float(solver.time)
                    hammerZ = headState().z
                    solver.mutateNodes { nodes in for n in head { nodes[n].isPrescribed = false } }
                } else {
                    down -= push / hammer * dt
                    if stopped == nil, down <= 0 { stopped = Float(solver.time) }
                    hammerZ = headState().z
                    solver.mutateNodes { nodes in for n in head { nodes[n].velocity = SIMD3(0, 0, -down) } }
                }
            } else if !caught {
                hammerZ -= down * dt
                let h = headState()
                if hammerZ <= h.z, down > h.down {
                    // Caught up: it strikes again.
                    touching = true
                    solver.mutateNodes { nodes in
                        for n in head {
                            nodes[n].isPrescribed = true
                            nodes[n].velocity = SIMD3(0, 0, -down)
                        }
                    }
                } else if down <= 0, receded == nil {
                    receded = Float(solver.time)
                }
            }
            // Twenty milliseconds after the hammer has turned back for good, the buckling is done.
            if let receded, Float(solver.time) > receded + 0.02 { break }
        }
        let positions = solver.referencePositions
        var deflection: Float = 0
        var position: Float = 0
        solver.mutateNodes { nodes in
            for n in nodes.indices where abs(nodes[n].displacement.x) > deflection {
                deflection = abs(nodes[n].displacement.x)
                position = positions[n].z - base
            }
        }
        return Result(
            deflection: deflection, position: position, stopped: stopped ?? Float(solver.time),
            parted: parted ?? Float(solver.time))
    }
}
