import Foundation
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

    /// The Model Code's transfer length, l_t = f_ctm d / (4 τ_bms ρ) with the mean bond stress
    /// while cracks form τ_bms = 1.8 f_ctm (§7.6.4): cracks lie l_t to 2 l_t apart. With the
    /// tensile strength raised by `raised` and the bond not, as the model's bond law has it at
    /// blast rates, it grows in proportion.
    public static func transferLength(raised: Float = 1) -> Float { raised * diameter / (4 * 1.8 * ratio) }
}
