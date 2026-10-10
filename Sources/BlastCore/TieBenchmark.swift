import Foundation
import Metal
import simd

/// A reinforced tie pulled slowly, against the fib Model Code 2010's crack spacing and tension
/// stiffening (§7.6.4 and §7.6.5): 1 m long, 100 mm square, 2% of 12 mm bars of grade 500, in
/// C30 concrete, held at one end and pulled at the other.
public enum TieBenchmark {
    public static let length: Float = 1
    public static let side: Float = 0.1
    public static let ratio: Float = 0.02
    public static let diameter: Float = 0.012
    public static let material = StructureMaterial.concrete(
        name: "C30", compressiveStrength: 30e6, steel: .grade500)

    public struct Result: Sendable {
        /// The elements along the tie's middle cracked open past 0.1% strain.
        public var cracks: [Int]
        /// The pull, averaged over the last millisecond, in newtons.
        public var load: Float
        /// The mean strain the tie was pulled to.
        public var strain: Float
        /// The elements' size, in metres.
        public var elementSize: Float

        /// The distances between neighbouring cracks, in metres, counting a run of neighbouring
        /// cracked elements as one crack.
        public var spacings: [Float] {
            var centres: [Float] = []
            var run: [Int] = []
            for i in cracks {
                if let last = run.last, i != last + 1 {
                    centres.append(Float(run.reduce(0, +)) / Float(run.count))
                    run = []
                }
                run.append(i)
            }
            if !run.isEmpty { centres.append(Float(run.reduce(0, +)) / Float(run.count)) }
            return zip(centres, centres.dropFirst()).map { ($1 - $0) * elementSize }
        }
    }

    /// The tie on elements of `elementSize`, its bars bonded by `bond` (perfectly, when nil),
    /// pulled at `speed` (m/s) to a mean strain of `strain`. `adjust` changes the concrete.
    public static func run(
        device: MTLDevice, elementSize h: Float, bond: BondSlip?, strain: Float = 1.5e-3, speed: Float = 0.05,
        adjust: (inout StructureMaterial) -> Void = { _ in }
    ) throws -> Result {
        let tie = Box(min: SIMD3(0, 0, 1), max: SIMD3(length, side, 1 + side))
        var concrete = material
        adjust(&concrete)
        var model = StructureModel(solids: [tie], material: concrete, elementSize: h, fixedBase: false)
        model.reinforcement = [ReinforcementLayer(region: tie, ratio: SIMD3(ratio, 0, 0))]
        model.bondSlip = bond
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 200
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    nodes[solver.nodeIndex(0, j, k)].isFixed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].isPrescribed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].velocity = SIMD3(speed, 0, 0)
                }
            }
        }
        let end = Double(strain * length / speed)
        let window = min(0.001, end / 10)
        solver.advance(steps: Int(((end - window) / Double(solver.criticalTimeStep)).rounded()))
        var load: Float = 0
        let samples = 20
        for _ in 0..<samples {
            solver.advance(
                steps: max(1, Int((window / Double(samples) / Double(solver.criticalTimeStep)).rounded())))
            var force: Float = 0
            for k in 0...solver.ez {
                for j in 0...solver.ey { force -= solver.nodalForce(solver.ex, j, k).x }
            }
            load += force / Float(samples)
        }
        let cracks = (0..<solver.ex).filter { solver.crackStrain($0, solver.ey / 2, solver.ez / 2) > 1e-3 }
        return Result(cracks: cracks, load: load, strain: strain, elementSize: h)
    }

    /// The Model Code's transfer length, l_t = f_ctm d / (4 τ_bms ρ) with the mean bond stress
    /// while cracks form τ_bms = 1.8 f_ctm (§7.6.4): cracks lie l_t to 2 l_t apart. With the
    /// tensile strength raised by `raised` and the bond not, as the model's bond law has it at
    /// blast rates, it grows in proportion.
    public static func transferLength(raised: Float = 1) -> Float { raised * diameter / (4 * 1.8 * ratio) }

    /// The Model Code's pull at a mean strain `strain` with tension stiffening factor `beta` (0.6
    /// short-term, 0.4 long-term or repeated; §7.6.5): the bars at the cracks carry
    /// E_s ε + β f_ctm (1 + α_e ρ) / ρ, with `strength` the concrete's tensile strength.
    public static func expectedLoad(strain: Float, beta: Float, strength: Float) -> Float {
        let modularRatio = 200e9 / material.youngsModulus
        let barStress = 200e9 * strain + beta * strength * (1 + modularRatio * ratio) / ratio
        return barStress * ratio * side * side
    }
}
