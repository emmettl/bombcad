import Foundation

/// Reflection of a plane shock off a wedge (or a slope) in a perfect gas, pseudo-steady:
/// von Neumann's two- and three-shock theories, from the oblique-shock relations. What the terrain's
/// slope study compares the air solver with.
public enum ShockReflectionTheory {
    /// Behind an oblique shock that the flow meets at Mach `mach`, the shock at `angle` (radians) to
    /// the flow: the flow's deflection (radians), the pressure ratio and the Mach number after it.
    public static func obliqueShock(mach: Double, angle: Double, gamma: Double = 1.4) -> (
        deflection: Double, pressure: Double, mach: Double
    ) {
        let normal = mach * sin(angle)
        let n2 = normal * normal
        let pressure = 1 + 2 * gamma / (gamma + 1) * (n2 - 1)
        let deflection = atan(
            2 / tan(angle) * (n2 - 1) / (mach * mach * (gamma + cos(2 * angle)) + 2))
        let after = ((1 + 0.5 * (gamma - 1) * n2) / (gamma * n2 - 0.5 * (gamma - 1))).squareRoot()
        return (deflection, pressure, after / sin(angle - deflection))
    }

    /// The angle of the shock that gives the largest deflection at `mach`, and that deflection.
    public static func maximumDeflection(mach: Double, gamma: Double = 1.4) -> (
        angle: Double, deflection: Double
    ) {
        var low = asin(1 / mach)
        var high = Double.pi / 2
        // The deflection rises then falls with the angle: golden-section search for its top.
        let ratio = (5.0.squareRoot() - 1) / 2
        for _ in 0..<100 {
            let a = high - ratio * (high - low)
            let b = low + ratio * (high - low)
            if obliqueShock(mach: mach, angle: a, gamma: gamma).deflection
                < obliqueShock(mach: mach, angle: b, gamma: gamma).deflection
            {
                low = a
            } else {
                high = b
            }
        }
        let angle = 0.5 * (low + high)
        return (angle, obliqueShock(mach: mach, angle: angle, gamma: gamma).deflection)
    }

    /// The shock angle at `mach` that deflects the flow by `deflection`: the weak one, or the
    /// strong; nil beyond the largest deflection.
    public static func shockAngle(mach: Double, deflection: Double, strong: Bool = false, gamma: Double = 1.4)
        -> Double?
    {
        let top = maximumDeflection(mach: mach, gamma: gamma)
        guard deflection <= top.deflection else { return nil }
        var low = strong ? top.angle : asin(1 / mach)
        var high = strong ? Double.pi / 2 : top.angle
        for _ in 0..<100 {
            let middle = 0.5 * (low + high)
            let value = obliqueShock(mach: mach, angle: middle, gamma: gamma).deflection
            if (value < deflection) != strong { low = middle } else { high = middle }
        }
        return 0.5 * (low + high)
    }

    /// The state behind a regular reflection's incident shock, for a plane shock of Mach `shock`
    /// meeting a wedge of `wedge` radians, seen from the reflection point: the Mach number of
    /// the flow there and the deflection the reflected shock must undo.
    static func incident(shock: Double, wedge: Double, gamma: Double) -> (mach: Double, deflection: Double) {
        let ahead = shock / cos(wedge)
        let incident = obliqueShock(mach: ahead, angle: .pi / 2 - wedge, gamma: gamma)
        return (incident.mach, incident.deflection)
    }

    /// The wedge angle (radians) below which regular reflection cannot turn the flow back
    /// (`sonic` false, von Neumann's detachment criterion), or at which the flow behind the
    /// reflected shock becomes sonic (`sonic` true), for a plane shock of Mach `shock`.
    public static func transitionWedge(shock: Double, sonic: Bool = false, gamma: Double = 1.4) -> Double {
        func regularPossible(_ wedge: Double) -> Bool {
            let behind = incident(shock: shock, wedge: wedge, gamma: gamma)
            let top = maximumDeflection(mach: behind.mach, gamma: gamma)
            guard behind.deflection <= top.deflection else { return false }
            guard sonic else { return true }
            guard let angle = shockAngle(mach: behind.mach, deflection: behind.deflection, gamma: gamma)
            else {
                return false
            }
            return obliqueShock(mach: behind.mach, angle: angle, gamma: gamma).mach >= 1
        }
        var low = 1e-3
        var high = Double.pi / 2 - 1e-3
        for _ in 0..<80 {
            let middle = 0.5 * (low + high)
            if regularPossible(middle) { high = middle } else { low = middle }
        }
        return 0.5 * (low + high)
    }

    /// The pressure behind a regular reflection, over the pressure ahead of the incident shock;
    /// nil where it is not possible.
    public static func regularReflectionPressure(shock: Double, wedge: Double, gamma: Double = 1.4) -> Double?
    {
        let ahead = shock / cos(wedge)
        let first = obliqueShock(mach: ahead, angle: .pi / 2 - wedge, gamma: gamma)
        guard let angle = shockAngle(mach: first.mach, deflection: first.deflection, gamma: gamma) else {
            return nil
        }
        return first.pressure * obliqueShock(mach: first.mach, angle: angle, gamma: gamma).pressure
    }

    /// The triple point's trajectory angle χ (radians, from the wedge's surface) of a Mach
    /// reflection, by three-shock theory closed with a straight Mach stem normal to the wedge;
    /// nil where there is none (regular reflection, or no three-shock solution).
    public static func triplePointAngle(shock: Double, wedge: Double, gamma: Double = 1.4) -> Double? {
        // Seen from the triple point, the gas ahead arrives along its trajectory, at χ to the
        // surface: Mach Ms / cos(θw + χ), meeting the incident shock at 90° − θw − χ and the stem,
        // normal to the surface, at 90° − χ. The incident shock and the stem both turn it towards
        // the surface; the reflected shock turns it back so that the flows either side of the
        // slipstream are parallel, at one pressure.
        func mismatch(_ chi: Double) -> Double? {
            let ahead = shock / cos(wedge + chi)
            let first = obliqueShock(mach: ahead, angle: .pi / 2 - wedge - chi, gamma: gamma)
            let stem = obliqueShock(mach: ahead, angle: .pi / 2 - chi, gamma: gamma)
            let turnBack = first.deflection - stem.deflection
            guard turnBack >= 0,
                let angle = shockAngle(mach: first.mach, deflection: turnBack, gamma: gamma)
            else { return nil }
            return first.pressure * obliqueShock(mach: first.mach, angle: angle, gamma: gamma).pressure
                - stem.pressure
        }
        // The pressure behind the reflected shock falls short of the stem's at small χ and passes
        // it where the three shocks balance; scan for the first change of sign.
        var previous: (chi: Double, value: Double)? = nil
        let top = Double.pi / 2 - wedge - 1e-4
        var chi = 1e-5
        while chi < top {
            if let value = mismatch(chi) {
                if let previous, (previous.value < 0) != (value < 0) {
                    var low = previous.chi
                    var high = chi
                    for _ in 0..<60 {
                        let middle = 0.5 * (low + high)
                        guard let m = mismatch(middle) else { break }
                        if (m < 0) == (previous.value < 0) { low = middle } else { high = middle }
                    }
                    return 0.5 * (low + high)
                }
                previous = (chi, value)
            }
            chi += 0.25 * .pi / 180
        }
        return nil
    }

    /// The flow behind a plane shock of Mach `shock` running into still gas of `density` and
    /// `pressure`: density, pressure and speed (along the shock's motion), and the shock's speed.
    public static func behindNormalShock(
        shock: Double, density: Double, pressure: Double, gamma: Double = 1.4
    )
        -> (density: Double, pressure: Double, speed: Double, shockSpeed: Double)
    {
        let m2 = shock * shock
        let speed = shock * (gamma * pressure / density).squareRoot()
        let ratio = (gamma + 1) * m2 / ((gamma - 1) * m2 + 2)
        let after = pressure * (1 + 2 * gamma / (gamma + 1) * (m2 - 1))
        return (density * ratio, after, speed * (1 - 1 / ratio), speed)
    }
}
