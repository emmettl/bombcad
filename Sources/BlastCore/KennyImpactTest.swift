import Foundation
import Metal
import simd

/// Kenny's drop-hammer tests on slender strips (D. Kenny, *Dynamic pulse buckling of slender beams
/// with geometric imperfections subjected to an axial impact*, PhD thesis, Dalhousie, 2001,
/// hdl:10222/55746; a scan, read from its pages): a 10 kg hammer dropped at about 6.2 m/s onto
/// strips 50.8 mm wide standing upright, clamped at the foot over 75 mm, held at the head by a
/// lubricated slide bearing that stops it moving or turning sideways but lets it shorten. The
/// strips buckled plastically, their largest buckle near the clamped foot; Table 6-4 gives each
/// series' mean final deflection of that buckle and how far up it lay, Table 6-6 the materials as
/// bilinear laws. Strips that buckled at the head, where the bearing had lifted out of its collar,
/// were set aside by Kenny; so are his series AIIe and AIIf here, the slenderest.
///
/// Here each strip is a line of the shell solver's beams, its weaker side the strip's thickness.
/// A strip 3.175 mm thick and 50.8 mm wide meshes as a plate, so it is drawn 6 mm wide, of a
/// material stiffer, denser and stronger by 50.8 / 6: its axial stiffness and mass, its bending
/// about its weak axis, its plastic moment and both its wave speeds are the strip's. The hammer
/// drives the head at its own speed, slowed by the strip's push, until the strip stops pushing and
/// they part. Bowed by Eurocode 3's rule for the length (curve c, a solid section's) or, with
/// `measuredBow`, to Kenny's mean measured initial imperfection β = A₀ / L.
public enum KennyImpactTest {
    public struct Series: Sendable {
        public var name: String
        public var steel: Bool
        /// Thickness (m) and unsupported length (m).
        public var thickness: Float
        public var length: Float
        public var speed: Float
        /// Mean initial imperfection over the length.
        public var beta: Float
        /// Measured: mean final deflection of the peak buckle and its height above the clamp (m).
        public var deflection: Float
        public var position: Float
    }

    /// Table 6-1 to 6-4: steel CR1018 (SI) and aluminium 6061-T6 (AI, 3.175 mm; AII, 4.7625 mm).
    public static let series: [Series] = {
        let t1: Float = 0.003175
        let t2: Float = 0.0047625
        func s(
            _ n: String, _ steel: Bool, _ t: Float, _ l: Float, _ v: Float, _ b: Float, _ w: Float, _ x: Float
        )
            -> Series
        {
            Series(
                name: n, steel: steel, thickness: t, length: l / 1000, speed: v, beta: b,
                deflection: w / 1000,
                position: x / 1000)
        }
        return [
            s("SIa", true, t1, 137, 6.22, 0.0027, 10.8, 54.2),
            s("SIb", true, t1, 183, 6.22, 0.0017, 12.7, 52.5),
            s("SIc", true, t1, 275, 6.24, 0.0020, 8.0, 63.7),
            s("SId", true, t1, 367, 6.14, 0.0021, 7.3, 130.0),
            s("SIe", true, t1, 458, 6.31, 0.0023, 5.4, 92.6),
            s("SIf", true, t1, 550, 6.18, 0.0025, 5.0, 125.6),
            s("AIa", false, t1, 137, 6.20, 0.0029, 14.1, 51.3),
            s("AIb", false, t1, 183, 6.20, 0.0023, 19.4, 57.8),
            s("AIc", false, t1, 275, 6.24, 0.0020, 21.3, 60.0),
            s("AId", false, t1, 367, 6.14, 0.0019, 18.3, 59.5),
            s("AIe", false, t1, 458, 6.19, 0.0021, 22.0, 68.8),
            s("AIf", false, t1, 550, 6.22, 0.0024, 20.8, 71.9),
            s("AIIa", false, t2, 206, 6.28, 0.0019, 17.6, 75.0),
            s("AIIb", false, t2, 275, 6.21, 0.0019, 18.0, 80.4),
            s("AIIc", false, t2, 412, 6.21, 0.0019, 17.6, 84.0),
            s("AIId", false, t2, 550, 6.23, 0.0020, 17.0, 97.5),
        ]
    }()

    public struct Result: Sendable {
        /// The largest final sideways deflection (m) and its height above the clamp (m).
        public var deflection: Float
        public var position: Float
        /// When the hammer stopped, and when it first left the strip (s).
        public var stopped: Float
        public var parted: Float
    }

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
