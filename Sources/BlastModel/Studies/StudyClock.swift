import Foundation

/// The headless studies' stopwatch.
package enum StudyClock {
    /// Seconds since `start`.
    package static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let took = start.duration(to: .now)
        return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
    }
}
