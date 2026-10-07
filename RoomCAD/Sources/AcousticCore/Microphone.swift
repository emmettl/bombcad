import Foundation
import simd

/// A first-order microphone: gain `a + (1 - a) cos θ` at angle θ from its axis, the same at every
/// frequency. Omni microphones have `a = 1`; a figure of eight, `a = 0`, picks up its rear lobe in
/// inverted polarity.
public struct Microphone: Codable, Equatable, Sendable {
    public enum Pattern: String, Codable, CaseIterable, Sendable {
        case omni, subcardioid, cardioid, supercardioid, hypercardioid, figureOfEight

        /// The omnidirectional share `a`.
        public var omniShare: Double {
            switch self {
            case .omni: 1
            case .subcardioid: 0.7
            case .cardioid: 0.5
            case .supercardioid: 0.37
            case .hypercardioid: 0.25
            case .figureOfEight: 0
            }
        }

        public var title: String {
            switch self {
            case .omni: "Omni"
            case .subcardioid: "Subcardioid"
            case .cardioid: "Cardioid"
            case .supercardioid: "Supercardioid"
            case .hypercardioid: "Hypercardioid"
            case .figureOfEight: "Figure of eight"
            }
        }

        /// Average of the squared gain over all directions: the share of a diffuse field's energy picked up.
        public var diffuseEnergy: Double {
            let a = omniShare
            return a * a + (1 - a) * (1 - a) / 3
        }
    }

    public var pattern: Pattern
    /// Aim in the horizontal plane, in degrees: 0 points along +x (east), 90 along +y (north).
    public var azimuth: Double
    /// Aim above the horizontal, in degrees.
    public var elevation: Double

    public init(pattern: Pattern, azimuth: Double = 0, elevation: Double = 0) {
        self.pattern = pattern
        self.azimuth = azimuth
        self.elevation = elevation
    }

    public static let omni = Microphone(pattern: .omni)

    /// Unit vector along the axis.
    public var axis: SIMD3<Double> {
        let az = azimuth * .pi / 180
        let el = elevation * .pi / 180
        return [cos(el) * cos(az), cos(el) * sin(az), sin(el)]
    }

    /// Gain for sound arriving from `direction`, a unit vector from the microphone towards the sound.
    public func gain(from direction: SIMD3<Double>) -> Double {
        let a = pattern.omniShare
        return a + (1 - a) * simd_dot(axis, direction)
    }

    var isOmni: Bool { pattern == .omni }

    public var summary: String {
        isOmni
            ? "Omni" : String(format: "%@, azimuth %.0f°, elevation %.0f°", pattern.title, azimuth, elevation)
    }

    func validate() throws {
        guard azimuth.isFinite, elevation.isFinite, (-90...90).contains(elevation) else {
            throw AcousticError.invalid("A microphone's elevation must be between -90° and 90°.")
        }
    }
}

/// Standard two-microphone stereo arrangements.
public enum StereoPair: String, CaseIterable, Identifiable, Sendable {
    case spacedOmnis, xy, ortf, nos, blumlein

    public var id: Self { self }

    public var title: String {
        switch self {
        case .spacedOmnis: "Spaced omnis (A–B), 60 cm"
        case .xy: "XY: coincident cardioids at ±45°"
        case .ortf: "ORTF: cardioids at ±55°, 17 cm"
        case .nos: "NOS: cardioids at ±45°, 30 cm"
        case .blumlein: "Blumlein: coincident figures of eight at ±45°"
        }
    }

    /// Spacing between the capsules in metres, half-angle between their axes in degrees, and pattern.
    var layout: (spacing: Double, halfAngle: Double, pattern: Microphone.Pattern) {
        switch self {
        case .spacedOmnis: (0.6, 0, .omni)
        case .xy: (0, 45, .cardioid)
        case .ortf: (0.17, 55, .cardioid)
        case .nos: (0.3, 45, .cardioid)
        case .blumlein: (0, 45, .figureOfEight)
        }
    }

    /// The first two receivers of `settings` arranged as this pair around their midpoint, facing the
    /// source horizontally; the first is the left channel. Other receivers are kept.
    public func arranged(in settings: RoomResponseSettings) -> RoomResponseSettings {
        var result = settings
        guard settings.receivers.count >= 2 else { return result }
        let centre = (settings.receivers[0].position + settings.receivers[1].position) / 2
        let toSource = settings.source.position - centre
        let facing = atan2(toSource.y, toSource.x) * 180 / .pi
        let layout = layout
        // Left is anticlockwise of the facing direction, seen from above.
        let leftward = SIMD3(-sin(facing * .pi / 180), cos(facing * .pi / 180), 0)
        for (index, side) in [(0, 1.0), (1, -1.0)] {
            var position = centre + leftward * (side * layout.spacing / 2)
            for axis in 0..<3 {
                position[axis] = min(max(position[axis], 0.05), settings.room.size[axis] - 0.05)
            }
            result.receivers[index].position = position
            result.receivers[index].microphone = Microphone(
                pattern: layout.pattern, azimuth: facing + side * layout.halfAngle, elevation: 0)
        }
        return result
    }
}
