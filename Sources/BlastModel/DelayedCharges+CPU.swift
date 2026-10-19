import Foundation
import RadialBlast
import simd

/// How a charge fired after the main one was laid down.
public struct Firing: Sendable {
    public enum How: String, Sendable {
        /// Its energy spread over a sphere of hot gas when it fired.
        case balloon
        /// Its blast laid from a one-dimensional solution, at the time on the run's clock that
        /// solution had reached (its firing time and the time it took).
        case mapped
        /// To be mapped, but the air about it was not still, or another charge's blast would have
        /// reached it before its solution was laid: the balloon instead (`note` says why).
        case balloonInsteadOfMapped
    }

    public var charge: Charge
    /// When it was laid down on the run's clock, s.
    public var laidAt: Double
    public var how: How
    public var note: String?

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        charge: Charge,
        laidAt: Double,
        how: How,
        note: String? = nil
    ) {
        self.charge = charge
        self.laidAt = laidAt
        self.how = how
        self.note = note
    }
}
