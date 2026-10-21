import Foundation

/// A compact, left-going, linear acoustic pulse and its pressure reflection at x = 0.
/// This is a small-amplitude reference, not an exact finite-amplitude Euler solution.
public struct AcousticPhaseReference: Sendable {
    public let amplitude: Double
    public let density = 1.225
    public let ambientPressure = 101_325.0
    public let gamma = 1.4
    public var soundSpeed: Double { sqrt(gamma * ambientPressure / density) }
    public var stopTime: Double { 14 / soundSpeed }

    public init(amplitude: Double) { self.amplitude = amplitude }

    /// Support [-1, 1] m; its positive lobe arrives before its negative lobe.
    public func pulse(_ offset: Double) -> Double {
        abs(offset) < 1 ? -amplitude * sin(.pi * offset) : 0
    }

    public func pressure(x: Double, time: Double) -> Double {
        pulse(x + soundSpeed * time - 8) + pulse(soundSpeed * time - x - 8)
    }

    public func velocity(x: Double, time: Double) -> Double {
        (-pulse(x + soundSpeed * time - 8) + pulse(soundSpeed * time - x - 8))
            / (density * soundSpeed)
    }

    /// For a separated direct pulse, or the overlapping reflection within a quarter metre of the wall.
    /// The diagnostic uses only these regimes; other positions have a different overlap pattern.
    public func firstImpulse(x: Double) -> Double? {
        if x >= 1 && x < 7 { return 2 * amplitude / (.pi * soundSpeed) }
        if x >= 0 && x <= 0.25 { return 2 * amplitude * (1 + cos(.pi * x)) / (.pi * soundSpeed) }
        return nil
    }

    public func peak(x: Double) -> Double? {
        if x >= 1 && x < 7 { return amplitude }
        if x >= 0 && x <= 0.25 { return 2 * amplitude * cos(.pi * x) }
        return nil
    }
}
