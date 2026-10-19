import Foundation
import simd

/// A structure meshed as shells and beams, stood under gravity alone for a while, damped, and
/// judged: does it stand, stand but still deflect, or fall? The IFC corpus judges imported
/// buildings this way (docs/ifc-import-corpus.md, "Under gravity"), and the layouts are held to it.
public struct GravityCheck: Sendable {
    public enum Verdict: String, Sendable, Equatable {
        /// The supports carry at least 95% of the weight.
        case stands
        /// Less is carried yet, but what moves is coming to rest.
        case deflects
        /// What moves keeps moving, near the speed of a body falling against the damping.
        case falls
    }

    /// The supports' reaction (connections' and clamps') over the weight.
    public var carried: Float
    /// The share of the weight on nodes that moved under 10 mm.
    public var still: Float
    /// The mean speed (m/s) of the weight that moved over 10 mm, at five-sixths of the time and
    /// at its end.
    public var settling: (early: Float, late: Float)
    /// The largest displacement (m), and the elements that failed.
    public var peak: Float
    public var eroded: Int
    public var weight: Float

    /// Mass-proportional damping (1/s), and how long (s) the structure is stood.
    public static let damping: Float = 50
    public static let duration = 0.3
    /// g over the damping rate: the speed a body falling against the damping keeps.
    public static let fallingSpeed = 9.81 / damping

    public var verdict: Verdict {
        if carried >= 0.95 { return .stands }
        return settling.late < 0.5 * Self.fallingSpeed && settling.late <= settling.early ? .deflects : .falls
    }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        carried: Float,
        still: Float,
        settling: (early: Float, late: Float),
        peak: Float,
        eroded: Int,
        weight: Float
    ) {
        self.carried = carried
        self.still = still
        self.settling = settling
        self.peak = peak
        self.eroded = eroded
        self.weight = weight
    }
}
