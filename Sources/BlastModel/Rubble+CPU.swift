import Foundation
import simd

/// A particle of rubble (`StructureModel.rubbleParticles`): what an element that failed became.
/// Layout matches `RubbleParticle` in Structure.metal.
public struct RubbleParticle: Sendable {
    public var x: Float = 0
    public var y: Float = 0
    public var z: Float = 0
    /// kg; zero for a slot not in use.
    public var mass: Float = 0
    public var vx: Float = 0
    public var vy: Float = 0
    public var vz: Float = 0
    /// How near a node's centre it comes before touching it (m).
    public var reach: Float = 0
    /// The kinetic energy of its nodes' motion about its centre when it was made (J), which it
    /// keeps as its internal energy.
    public var internalEnergy: Float = 0
    /// The volume of material it stands for (m³).
    public var volume: Float = 0
    public var alive: UInt32 = 0
    var spare: Float = 0

    public var position: SIMD3<Float> { SIMD3(x, y, z) }
    public var velocity: SIMD3<Float> { SIMD3(vx, vy, vz) }
    public var kineticEnergy: Float { 0.5 * mass * simd_length_squared(velocity) }
}
