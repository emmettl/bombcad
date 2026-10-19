import Foundation

/// Diagnostic timings with additional compute-encoder boundaries. Disabled in ordinary runs.
/// Stage sums omit gaps between encoders; they are not production throughput estimates.
public struct BatchGPUProfile: Codable, Sendable {
    public var airS: Double = 0
    public var mechanicsS: Double = 0
    public var couplingS: Double = 0
    public var observationS: Double = 0
    /// With detailed profiling (`BlastSolver.enableGPUProfiling(_:detailed:)`), the GPU seconds of
    /// each stage, named "phase/stage": the coarse sweeps, and each refined level's ghosts,
    /// sweeps, refluxing, regridding and the rest, each in an encoder of its own.
    public var stages: [String: Double] = [:]
    public init() {}
}
