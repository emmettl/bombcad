import simd

/// What the models alongside the blast will want from the air at the next frame, cut out on the
/// GPU at the end of the batch that lands on it (see `BlastSolver.frameRequest`).
public struct FrameRequest: Sendable, Equatable {
    /// The fragments' block of air: its region and stride, as `airSlice(region:stride:)` takes them.
    public var airSlice: AirSliceRequest?
    /// The fireball's luminous temperature, as `fireball(luminousTemperature:)` takes it.
    public var fireball: Float?
    /// Whether the fireball is wanted cell by cell too, as the volume model takes it.
    public var fireballCells: Bool
    /// The visualisation field every this-many cells along each axis, as `viewField(stride:)`
    /// takes it, for a view of the run drawn elsewhere.
    public var viewField: Int?

    public init(airSlice: AirSliceRequest? = nil, fireball: Float? = nil, fireballCells: Bool = false) {
        self.airSlice = airSlice
        self.fireball = fireball
        self.fireballCells = fireballCells
    }

    /// What the thermal radiation `spec` describes needs, if any.
    public init(thermal spec: ThermalSpec?) {
        self.init(fireball: spec?.luminousTemperature, fireballCells: spec?.fireball == .volume)
    }

    public var isEmpty: Bool { airSlice == nil && fireball == nil && viewField == nil }
}

public struct AirSliceRequest: Sendable, Equatable {
    public var region: Box
    public var stride: Int

    public init(region: Box, stride: Int) {
        self.region = region
        self.stride = stride
    }
}
