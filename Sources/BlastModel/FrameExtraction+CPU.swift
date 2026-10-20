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

/// A recorder's standing request for the view field (`BlastSolver.viewFieldCapture`): cut out at
/// `stride` on the GPU at the end of any batch whose clock ends at or past `from`, the next
/// frame's time, so that the frame due then reads it without waiting. Batches are not cut to it:
/// each is the batch it would have been, and the field is the one worked out after it.
public struct ViewFieldCapture: Sendable, Equatable {
    public var stride: Int
    public var from: Double

    public init(stride: Int, from: Double) {
        self.stride = stride
        self.from = from
    }

    /// The run's clock, in its ticks of 2^-40 s, from which a batch's end cuts the field out: a
    /// nanosecond before `from`, so that every batch whose time reaches `from`, as the host
    /// adds the steps up, is one.
    public var fromTicks: UInt64 {
        let seconds = from - 1e-9
        guard seconds > 0 else { return 0 }
        return UInt64(min((seconds / StepControl.tick).rounded(.down), 0x1p62))
    }
}
