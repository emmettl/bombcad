import Foundation
import simd

/// Experimental saved input for a simplified car, stored beside `RigidObjectDefinition`.
/// A rigid body on four tyre contacts at the corners of a wheelbase × track rectangle, with
/// all wheels locked and rigid suspension, both recorded explicitly so that rolling wheels or
/// a sprung body can be added later without changing what older files mean. The shell is a
/// box between the axles' ends, used for contact once the car is off its wheels and for
/// drawing. Ordinary scene loading leaves it inert, and nothing couples it to the air yet.
/// Body axes: x forward, y left, z up. Lengths m, mass kg, inertia kg m²; initially at rest.
public struct RigidCarDefinition: Sendable, Hashable, Codable, Identifiable {
    /// How the wheels turn. Only locked wheels are modelled: each tyre slides as a block.
    public enum Wheels: String, Sendable, Hashable, Codable { case allLocked }
    /// How the body is carried. Only a rigid connection is modelled.
    public enum Suspension: String, Sendable, Hashable, Codable { case rigid }

    public enum InvalidDefinition: Error, LocalizedError {
        case name, friction, geometry, groundPenetration

        public var errorDescription: String? {
            switch self {
            case .name: "A car needs a nonempty name."
            case .friction: "Friction coefficients must be finite, with static ≥ sliding ≥ 0."
            case .geometry:
                "Car mass, wheelbase, track, shell, pose, centre of mass or inertia are invalid."
            case .groundPenetration: "A car must start at or above the ground."
            }
        }
    }

    public let id: UUID
    public let name: String
    /// World position of the footprint centre: the point midway between the four tyre contacts.
    public let position: SIMD3<Double>
    /// Body-to-world unit quaternion, encoded as [x, y, z, w].
    public let orientation: SIMD4<Double>
    public let mass: Double
    /// Distance between the front and rear tyre contacts.
    public let wheelbase: Double
    /// Distance between the left and right tyre contacts.
    public let track: Double
    /// From the footprint centre, in body axes; z is the height h of the centre of mass.
    public let centreOfMass: SIMD3<Double>
    /// Principal moments about the centre of mass along the body axes: roll, pitch, yaw.
    public let inertia: SIMD3<Double>
    /// Shell length, width and height, centred over the footprint.
    public let shellSize: SIMD3<Double>
    /// Height of the shell's underside above the tyre contacts.
    public let groundClearance: Double
    public let wheels: Wheels
    public let suspension: Suspension
    /// Tyre and shell friction on the ground; locked tyres slide at the sliding coefficient.
    public let staticFriction: Double
    public let slidingFriction: Double

    public init(
        id: UUID = UUID(), name: String, position: SIMD3<Double>, mass: Double,
        wheelbase: Double, track: Double, centreOfMass: SIMD3<Double>, inertia: SIMD3<Double>,
        shellSize: SIMD3<Double>, groundClearance: Double,
        orientation: SIMD4<Double> = SIMD4(0, 0, 0, 1),
        wheels: Wheels = .allLocked, suspension: Suspension = .rigid,
        staticFriction: Double = 0.8, slidingFriction: Double = 0.7
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidDefinition.name
        }
        guard staticFriction.isFinite, slidingFriction.isFinite,
            staticFriction >= slidingFriction, slidingFriction >= 0
        else { throw InvalidDefinition.friction }
        let length = simd_length(orientation)
        guard length.isFinite, length > 0 else { throw InvalidDefinition.geometry }
        // Preserve an already unit quaternion exactly so repeated save/load does not dirty a scene.
        let unit = abs(length - 1) <= 1e-12 ? orientation : orientation / length
        // The tyres sit within the shell's plan, below its underside.
        guard wheelbase.isFinite, track.isFinite, groundClearance.isFinite, wheelbase > 0, track > 0,
            groundClearance >= 0, wheelbase <= shellSize.x, track <= shellSize.y
        else { throw InvalidDefinition.geometry }
        self.id = id
        self.name = name
        self.position = position
        self.orientation = unit
        self.mass = mass
        self.wheelbase = wheelbase
        self.track = track
        self.centreOfMass = centreOfMass
        self.inertia = inertia
        self.shellSize = shellSize
        self.groundClearance = groundClearance
        self.wheels = wheels
        self.suspension = suspension
        self.staticFriction = staticFriction
        self.slidingFriction = slidingFriction
        let car: RigidCarBody
        do { car = try makeBody() } catch { throw InvalidDefinition.geometry }
        let tolerance = 1e-6 * min(shellSize.x, min(shellSize.y, shellSize.z))
        guard (car.tyrePoints + car.body.corners).allSatisfy({ $0.z >= -tolerance }) else {
            throw InvalidDefinition.groundPenetration
        }
    }

    /// An illustrative mid-size saloon: 1500 kg, 2.7 m wheelbase, 1.55 m track, centre of mass
    /// 1.2 m behind the front axle and 0.55 m up, so a static stability factor of 1.41. Typical
    /// published magnitudes, not a measured vehicle. The shell is as wide as the track, so the
    /// tyre lines alone set the tipping angle.
    public static func saloon(
        id: UUID = UUID(), name: String = "Saloon", position: SIMD3<Double> = .zero,
        orientation: SIMD4<Double> = SIMD4(0, 0, 0, 1),
        staticFriction: Double = 0.8, slidingFriction: Double = 0.7
    ) throws -> RigidCarDefinition {
        try RigidCarDefinition(
            id: id, name: name, position: position, mass: 1500, wheelbase: 2.7, track: 1.55,
            centreOfMass: SIMD3(0.15, 0, 0.55), inertia: SIMD3(550, 2500, 2700),
            shellSize: SIMD3(4.6, 1.55, 1.3), groundClearance: 0.15, orientation: orientation,
            staticFriction: staticFriction, slidingFriction: slidingFriction)
    }

    /// Track over twice the height of the centre of mass: the steady sideways acceleration,
    /// in g, at which the inner tyres unload, and the tangent of the tilt at which it balances.
    public var staticStabilityFactor: Double { track / (2 * centreOfMass.z) }

    /// Tyre contacts from the footprint centre in body axes: FL, FR, RL, RR.
    public var tyreContacts: [SIMD3<Double>] {
        [SIMD3(1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, 1, 0), SIMD3(-1, -1, 0)].map {
            $0 * SIMD3(wheelbase / 2, track / 2, 0)
        }
    }

    /// Runtime state always starts from saved inputs, without carrying a previous run's motion.
    func makeBody() throws -> RigidCarBody {
        let pose = simd_quatd(vector: orientation)
        let shellCentre = SIMD3(0, 0, groundClearance + shellSize.z / 2)
        let body = try RigidBoxBody(
            mass: mass, size: shellSize, position: position + pose.act(centreOfMass),
            orientation: pose, centreOfMass: centreOfMass - shellCentre, inertia: inertia)
        return RigidCarBody(body: body, tyres: tyreContacts.map { $0 - shellCentre })
    }

    var ground: RigidBoxBody.Ground {
        RigidBoxBody.Ground(staticFriction: staticFriction, slidingFriction: slidingFriction)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, position, orientation, mass, wheelbase, track, centreOfMass, inertia
        case shellSize, groundClearance, wheels, suspension, staticFriction, slidingFriction
    }

    /// Decode through the same validation as programmatic construction.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                position: c.decode(SIMD3<Double>.self, forKey: .position),
                mass: c.decode(Double.self, forKey: .mass),
                wheelbase: c.decode(Double.self, forKey: .wheelbase),
                track: c.decode(Double.self, forKey: .track),
                centreOfMass: c.decode(SIMD3<Double>.self, forKey: .centreOfMass),
                inertia: c.decode(SIMD3<Double>.self, forKey: .inertia),
                shellSize: c.decode(SIMD3<Double>.self, forKey: .shellSize),
                groundClearance: c.decode(Double.self, forKey: .groundClearance),
                orientation: c.decode(SIMD4<Double>.self, forKey: .orientation),
                wheels: c.decode(Wheels.self, forKey: .wheels),
                suspension: c.decode(Suspension.self, forKey: .suspension),
                staticFriction: c.decode(Double.self, forKey: .staticFriction),
                slidingFriction: c.decode(Double.self, forKey: .slidingFriction))
        } catch let error as InvalidDefinition {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: error.localizedDescription, underlyingError: error))
        }
    }
}
