import Foundation

/// The luminous gas losing the heat it radiates (see `Radiation.metal`): after each step, every
/// cell at least `luminousTemperature` hot absorbs and emits as the thermal radiation's volume
/// takes it to, the radiance is carried along the 26 directions of the lattice through the box of
/// luminous cells, and each cell gives up what it emits less what it absorbs. The energy given up
/// is `BlastSolver.radiatedEnergy`. Off by default (nil in `SolverConfiguration`).
public struct RadiativeCooling: Sendable, Hashable, Codable {
    /// The gas emits and absorbs at or above this, K; below it, it is transparent.
    public var luminousTemperature: Float = 1500
    /// The hot gas's own grey absorption coefficient, 1/m.
    public var absorption: Float = 0.1
    /// Soot as a share of the mass of unburnt detonation products (only with afterburning).
    public var sootYield: Float = 0.185
    /// Steps of the run's count between takings of the loss, each taking it for the time since the
    /// last, however the run is batched. An opaque fireball's outer cells at 3,000 K lose under a
    /// hundredth of their heat a step, so four steps make little difference and cost a quarter.
    public var interval = 4
    /// The most of a cell's internal energy one taking may remove: a guard, never reached in
    /// practice.
    public var largestShare: Float = 0.25

    public init(luminousTemperature: Float = 1500, absorption: Float = 0.1, sootYield: Float = 0.185) {
        self.luminousTemperature = luminousTemperature
        self.absorption = absorption
        self.sootYield = sootYield
    }

    /// The same medium as `spec`'s volume, so that the gas loses what the volume radiates.
    public init(spec: ThermalSpec) {
        self.init(
            luminousTemperature: spec.luminousTemperature, absorption: spec.absorption,
            sootYield: spec.sootYield)
    }
}

/// Mirrors `RadiationUniforms` in Radiation.metal.
package struct RadiationUniforms {
    var luminous: Float
    var absorption: Float
    var sootAbsorption: Float
    package var hasSpecies: UInt32
    var largestShare: Float
    var luminousEnergy: Float
    var capacity: UInt32

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        luminous: Float,
        absorption: Float,
        sootAbsorption: Float,
        hasSpecies: UInt32,
        largestShare: Float,
        luminousEnergy: Float,
        capacity: UInt32
    ) {
        self.luminous = luminous
        self.absorption = absorption
        self.sootAbsorption = sootAbsorption
        self.hasSpecies = hasSpecies
        self.largestShare = largestShare
        self.luminousEnergy = luminousEnergy
        self.capacity = capacity
    }
}
