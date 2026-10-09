import Foundation
import Metal
import simd

/// One crack sheared along the path a real crack took: Walraven and Reinhardt's push-off tests
/// with external restraint bars, J. C. Walraven and H. W. Reinhardt, "Theory and experiments on
/// the mechanical behaviour of cracks in plain and reinforced concrete subjected to shear
/// loading", HERON 26(1A), 1981 (open access from the TU Delft repository).
///
/// Each specimen was cracked through its 300 by 120 mm shear plane by splitting, to an initial
/// width, then sheared along the crack while bars outside the concrete, bolted to plates on its
/// ends, held the crack's faces together. So the crack opened as it slid, and the bars, stretched
/// by the opening, pressed it shut: the paper records, for each specimen, the slip and the
/// opening (its Fig. 16a), the shear against the slip (16b) and the stress across the crack
/// against the opening (16c). The external bars carry no dowel action. The data here are the
/// seven specimens of its mix 1 (gravel to 16 mm, cube strength 36.7 and 38.5 N/mm²), read by hand
/// off those figures to about 0.02 mm and 0.2 N/mm².
///
/// The model is one cubic element of plain concrete. Its crack is opened to the specimen's
/// initial width, then its faces are moved along the measured path, opening and slip together,
/// and the shear along the crack and the stress across it are read from the element.
public enum PushOffTest {
    public struct Specimen: Sendable {
        /// The paper's code: mix / initial width (mm) / stress across the crack at 0.6 mm (N/mm²).
        public var name: String
        /// Cube strength (Pa); the model's cylinder strength is 0.8 of it.
        public var cubeStrength: Float
        /// Opening (m) against slip (m), from the initial width at no slip.
        public var path: [SIMD2<Float>]
        /// Shear along the crack (Pa) against slip (m).
        public var shear: [SIMD2<Float>]
        /// Stress across the crack (Pa, compressive positive) against opening (m).
        public var normal: [SIMD2<Float>]

        public var initialWidth: Float { path[0].y }
        public var finalSlip: Float { path[path.count - 1].x }

        /// The measured opening at a slip.
        public func width(at slip: Float) -> Float { SlabBenchmark.interpolate(path, at: slip) }

        /// The measured shear at a slip, or nil outside what was read off the figure.
        public func measuredShear(at slip: Float) -> Float? {
            guard let first = shear.first, let last = shear.last, slip >= first.x - 1e-6,
                slip <= last.x + 1e-6
            else { return nil }
            return SlabBenchmark.interpolate(shear, at: slip)
        }

        /// The measured stress across the crack at a slip, or nil outside what was read off.
        public func measuredNormal(at slip: Float) -> Float? {
            let opening = width(at: slip)
            guard let first = normal.first, let last = normal.last, opening >= first.x - 1e-6,
                opening <= last.x + 1e-6
            else { return nil }
            return SlabBenchmark.interpolate(normal, at: opening)
        }
    }

    /// Builds a specimen from millimetres and N/mm².
    static func specimen(
        _ name: String, cube: Float, path: [(Float, Float)], shear: [(Float, Float)], normal: [(Float, Float)]
    ) -> Specimen {
        Specimen(
            name: name, cubeStrength: cube * 1e6, path: path.map { SIMD2($0.0, $0.1) * 1e-3 },
            shear: shear.map { SIMD2($0.0 * 1e-3, $0.1 * 1e6) },
            normal: normal.map { SIMD2($0.0 * 1e-3, $0.1 * 1e6) })
    }

    /// Mix 1 of the tests with external restraint bars (the paper's Fig. 16 and Appendix 12.5).
    /// Slip and opening in mm; stresses in N/mm². The appendix lists 1/.0/7.8 where the figure
    /// labels the same curve 1/.0/6.8, which its stress across the crack at 0.6 mm supports.
    public static let specimens: [Specimen] = [
        specimen(
            "1/.0/6.8", cube: 38.5,
            path: [
                (0, 0.01), (0.1, 0.098), (0.2, 0.158), (0.3, 0.216), (0.4, 0.267), (0.6, 0.363), (0.8, 0.443),
                (1.0, 0.51), (1.2, 0.572), (1.4, 0.625), (1.6, 0.677), (1.9, 0.745), (2.24, 0.81),
            ],
            shear: [
                (0.1, 5.6), (0.2, 6.9), (0.3, 7.7), (0.4, 8.4), (0.6, 9.3), (0.8, 9.8), (1.2, 10.2),
                (1.6, 10.2), (2.0, 9.9),
            ],
            normal: [
                (0.05, 1.16), (0.15, 2.13), (0.25, 3.15), (0.35, 4.19), (0.45, 5.24), (0.55, 6.22),
                (0.65, 7.09), (0.78, 8.08),
            ]),
        specimen(
            "1/.0/3.6", cube: 36.7,
            path: [
                (0, 0.03), (0.1, 0.098), (0.2, 0.191), (0.3, 0.264), (0.4, 0.329), (0.6, 0.435), (0.8, 0.509),
                (1.0, 0.575), (1.2, 0.634), (1.4, 0.685), (1.6, 0.724), (1.9, 0.779), (2.12, 0.811),
            ],
            shear: [
                (0.05, 5.7), (0.1, 6.1), (0.2, 6.4), (0.3, 6.6), (0.4, 6.8), (0.6, 7.0), (0.8, 7.05),
                (1.2, 7.1), (1.6, 7.05), (2.1, 7.0),
            ],
            normal: [(0.05, 0.84), (0.15, 1.39), (0.35, 2.49), (0.45, 3.01), (0.55, 3.5), (0.78, 4.6)]),
        specimen(
            "1/.2/1.6", cube: 38.5,
            path: [
                (0, 0.18), (0.1, 0.22), (0.2, 0.31), (0.3, 0.40), (0.4, 0.467), (0.6, 0.575), (0.8, 0.641),
                (1.0, 0.70), (1.2, 0.737), (1.4, 0.781), (1.6, 0.817), (1.9, 0.866), (2.15, 0.90),
            ],
            shear: [(0.4, 2.3), (0.6, 2.95), (0.8, 3.5), (1.2, 4.4), (1.6, 5.0), (2.0, 5.45)],
            normal: [(0.75, 2.76), (0.78, 3.14), (0.8, 3.4)]),
        specimen(
            "1/.2/.4", cube: 36.7,
            path: [
                (0, 0.23), (0.1, 0.255), (0.2, 0.357), (0.3, 0.401), (0.4, 0.467), (0.6, 0.575), (0.8, 0.673),
                (1.0, 0.75), (1.2, 0.829), (1.4, 0.889), (1.6, 0.947), (2.0, 1.045), (2.28, 1.12),
            ],
            shear: [
                (0.4, 1.75), (0.6, 2.15), (0.8, 2.85), (1.2, 3.45), (1.6, 3.85), (2.0, 3.97), (2.2, 4.0),
            ],
            normal: [(0.85, 1.4), (0.95, 1.86), (1.05, 2.37), (1.15, 2.89)]),
        specimen(
            "1/.4/1.0", cube: 38.5,
            path: [
                (0, 0.40), (0.1, 0.42), (0.2, 0.456), (0.3, 0.515), (0.4, 0.572), (0.6, 0.682), (0.8, 0.751),
                (1.0, 0.814), (1.2, 0.871), (1.4, 0.92), (1.6, 0.964), (2.0, 1.04), (2.22, 1.07),
            ],
            shear: [(0.4, 2.6), (0.6, 3.6), (0.8, 4.4), (1.2, 5.55), (1.6, 6.05), (2.0, 6.4), (2.2, 6.5)],
            normal: [(0.85, 2.69), (0.95, 3.82), (1.0, 4.4)]),
        specimen(
            "1/.2/1.4", cube: 36.7,
            path: [
                (0, 0.19), (0.1, 0.221), (0.15, 0.27), (0.3, 0.48), (0.4, 0.572), (0.6, 0.682), (0.8, 0.77),
                (1.0, 0.848), (1.2, 0.919), (1.4, 0.976), (1.6, 1.032), (1.9, 1.101), (2.22, 1.158),
            ],
            shear: [(0.4, 2.15), (0.6, 2.35), (0.8, 3.4), (1.2, 3.95), (1.6, 4.3), (2.0, 4.6), (2.2, 4.75)],
            normal: [(0.85, 2.17), (0.95, 2.66), (1.05, 3.18), (1.15, 3.72)]),
        specimen(
            "1/.4/.3", cube: 38.5,
            path: [
                (0, 0.41), (0.1, 0.452), (0.2, 0.50), (0.3, 0.56), (0.4, 0.623), (0.6, 0.733), (0.8, 0.824),
                (1.0, 0.90), (1.2, 0.973), (1.4, 1.033), (1.6, 1.089), (1.9, 1.165), (2.13, 1.21),
            ],
            shear: [(0.4, 1.45), (0.6, 1.75), (0.8, 1.95), (1.2, 2.27), (1.6, 2.5), (2.0, 2.55)],
            normal: [(0.85, 0.94), (0.95, 1.28), (1.05, 1.59), (1.15, 1.92), (1.19, 2.01)]),
    ]

    /// The paper's fit to all its tests (eqs. 1a and 1b, w and slip in mm, stresses in N/mm²,
    /// f_cc the cube strength): the shear along a crack w wide slid by d, and the stress across it,
    /// both in Pa, neither below zero.
    public static func fittedShear(width: Float, slip: Float, cubeStrength: Float) -> Float {
        let (w, d, cube) = (width * 1000, slip * 1000, cubeStrength / 1e6)
        let tau = -cube / 30 + (1.8 * pow(w, -0.8) + (0.234 * pow(w, -0.707) - 0.20) * cube) * d
        return max(tau, 0) * 1e6
    }

    public static func fittedNormal(width: Float, slip: Float, cubeStrength: Float) -> Float {
        let (w, d, cube) = (width * 1000, slip * 1000, cubeStrength / 1e6)
        let sigma = -cube / 20 + (1.35 * pow(w, -0.63) + (0.191 * pow(w, -0.552) - 0.15) * cube) * d
        return max(sigma, 0) * 1e6
    }

    /// The modified compression field theory's limit on the shear across a crack w wide pressed
    /// shut by f_ci (Vecchio and Collins, 1986, fitted to Walraven's tests): v_ci = 0.18 v_max +
    /// 1.64 f_ci - 0.82 f_ci² / v_max, v_max = sqrt(f_c) / (0.31 + 24 w / (a + 16)), MPa and mm.
    /// Its first term alone, with nothing across the crack, is the model's cap.
    public static func compressionFieldShear(
        width: Float, pressure: Float, compressiveStrength: Float, aggregate: Float = 0.016
    ) -> Float {
        let most =
            (compressiveStrength / 1e6).squareRoot() / (0.31 + 24 * width * 1000 / (aggregate * 1000 + 16))
        let f = min(pressure / 1e6, most)
        return (0.18 * most + 1.64 * f - 0.82 * f * f / most) * 1e6
    }

    public static func material(for specimen: Specimen) -> StructureMaterial {
        .concrete(name: "Walraven-Reinhardt mix 1", compressiveStrength: 0.8 * specimen.cubeStrength)
    }

    public struct Sample: Sendable {
        public var slip: Float
        public var width: Float
        /// Shear along the crack and stress across it (compressive positive), in Pa.
        public var shear: Float
        public var normal: Float
    }

    public struct Result: Sendable {
        public var specimen: Specimen
        public var samples: [Sample]

        /// The model's shear and stress across the crack at a slip along the path.
        public func modelled(at slip: Float) -> (shear: Float, normal: Float) {
            let shear = SlabBenchmark.interpolate(samples.map { SIMD2($0.slip, $0.shear) }, at: slip)
            let normal = SlabBenchmark.interpolate(samples.map { SIMD2($0.slip, $0.normal) }, at: slip)
            return (shear, normal)
        }
    }

    /// Drives one element `size` on a side along the specimen's path: its low-x face held, its
    /// high-x face opened to the initial width, then moved along the path, opening across x and
    /// sliding along z, over `stepsPerMillimetre` time steps per millimetre of the path, and then
    /// on through `beyond` (slip and width, m), if given.
    public static func run(
        device: MTLDevice, specimen: Specimen, size: Float = 0.05, crackShearStiffness: Bool = false,
        stepsPerMillimetre: Int = 4000, beyond: [SIMD2<Float>] = [],
        adjust: (inout StructureModel) -> Void = { _ in }
    ) throws -> Result {
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
        var model = StructureModel(
            solids: [cube], material: material(for: specimen), elementSize: size, fixedBase: false)
        model.crackShearStiffness = crackShearStiffness
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false

        // The crack's width is the opening past the strain at which it formed.
        let material = model.material
        let onset = material.tensileStrength / material.youngsModulus * size
        let legs = [SIMD2<Float>(0, 0)] + (specimen.path + beyond).map { SIMD2($0.x, $0.y + onset) }
        var samples: [Sample] = []
        let stepsPerSample = 10
        for (from, to) in zip(legs, legs.dropFirst()) {
            let length = simd_length(to - from)
            let count = max(
                1, Int((length * 1000 * Float(stepsPerMillimetre) / Float(stepsPerSample)).rounded()))
            let duration = Float(count * stepsPerSample) * solver.criticalTimeStep
            let velocity = (to - from) / duration
            solver.mutateNodes { nodes in
                for k in 0...1 {
                    for j in 0...1 {
                        nodes[solver.nodeIndex(0, j, k)].isFixed = true
                        nodes[solver.nodeIndex(1, j, k)].isPrescribed = true
                        nodes[solver.nodeIndex(1, j, k)].velocity = SIMD3(velocity.y, 0, velocity.x)
                    }
                }
            }
            for _ in 0..<count {
                solver.advance(steps: stepsPerSample)
                let moved = solver.displacement(1, 0, 0)
                let stress = solver.stress(0, 0, 0)
                samples.append(
                    Sample(slip: moved.z, width: moved.x - onset, shear: abs(stress[5]), normal: -stress[0]))
            }
        }
        return Result(specimen: specimen, samples: Array(samples.drop { $0.slip <= 0 }))
    }
}
