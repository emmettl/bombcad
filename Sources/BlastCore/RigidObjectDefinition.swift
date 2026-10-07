import Foundation
import simd

/// Experimental saved input for an independent rigid object, separate from static boxes.
/// Ordinary scene loading leaves it inert; the standalone experimental driver opts into coupling.
/// Lengths are metres, mass kg, inertia kg m², with z up and an initially stationary body.
public struct RigidObjectDefinition: Sendable, Hashable, Codable, Identifiable {
    public enum Shape: Sendable, Hashable, Codable {
        /// Box centred on its local origin, with full dimensions along its local axes.
        case box(size: SIMD3<Double>)
    }

    public enum InvalidDefinition: Error, LocalizedError {
        case name, friction, geometry, groundPenetration

        public var errorDescription: String? {
            switch self {
            case .name: "A rigid object needs a nonempty name."
            case .friction: "Friction coefficients must be finite, with static ≥ sliding ≥ 0."
            case .geometry: "Rigid-object mass, dimensions, pose, centre of mass or inertia are invalid."
            case .groundPenetration: "A rigid object must start at or above the ground."
            }
        }
    }

    public let id: UUID
    public let name: String
    public let shape: Shape
    /// World position of the geometric centre (not the centre of mass).
    public let position: SIMD3<Double>
    /// Body-to-world unit quaternion, encoded as [x, y, z, w].
    public let orientation: SIMD4<Double>
    public let mass: Double
    /// Local offset from the geometric centre; must lie inside the box.
    public let centreOfMass: SIMD3<Double>
    /// Moments about the centre of mass; principal axes must align with the box axes.
    /// Nil means a uniform box. A nonzero centre-of-mass offset requires explicit moments.
    public let inertia: SIMD3<Double>?
    public let staticFriction: Double
    public let slidingFriction: Double

    public init(
        id: UUID = UUID(), name: String, shape: Shape, position: SIMD3<Double>, mass: Double,
        orientation: SIMD4<Double> = SIMD4(0, 0, 0, 1),
        centreOfMass: SIMD3<Double> = .zero, inertia: SIMD3<Double>? = nil,
        staticFriction: Double = 0.6, slidingFriction: Double = 0.5
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
        let pose = simd_quatd(vector: unit)
        let size: SIMD3<Double>
        switch shape {
        case .box(let dimensions): size = dimensions
        }
        let body: RigidBoxBody
        do {
            body = try RigidBoxBody(
                mass: mass, size: size, position: position + pose.act(centreOfMass),
                orientation: pose, centreOfMass: centreOfMass, inertia: inertia)
        } catch { throw InvalidDefinition.geometry }
        let tolerance = 1e-6 * min(size.x, min(size.y, size.z))
        guard body.corners.allSatisfy({ $0.z >= -tolerance }) else {
            throw InvalidDefinition.groundPenetration
        }
        self.id = id
        self.name = name
        self.shape = shape
        self.position = position
        self.orientation = unit
        self.mass = mass
        self.centreOfMass = centreOfMass
        self.inertia = inertia
        self.staticFriction = staticFriction
        self.slidingFriction = slidingFriction
    }

    /// Runtime state always starts from saved inputs, without carrying a previous run's motion.
    func makeBody() throws -> RigidBoxBody {
        let size: SIMD3<Double>
        switch shape {
        case .box(let dimensions): size = dimensions
        }
        let pose = simd_quatd(vector: orientation)
        return try RigidBoxBody(
            mass: mass, size: size, position: position + pose.act(centreOfMass),
            orientation: pose, centreOfMass: centreOfMass, inertia: inertia)
    }

    var ground: RigidBoxBody.Ground {
        RigidBoxBody.Ground(staticFriction: staticFriction, slidingFriction: slidingFriction)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shape, position, orientation, mass, centreOfMass, inertia
        case staticFriction, slidingFriction
    }

    /// Decode through the same validation as programmatic construction; malformed saved input
    /// must throw rather than reach the mechanics component's contact preconditions.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                shape: c.decode(Shape.self, forKey: .shape),
                position: c.decode(SIMD3<Double>.self, forKey: .position),
                mass: c.decode(Double.self, forKey: .mass),
                orientation: c.decode(SIMD4<Double>.self, forKey: .orientation),
                centreOfMass: c.decode(SIMD3<Double>.self, forKey: .centreOfMass),
                inertia: c.decodeIfPresent(SIMD3<Double>.self, forKey: .inertia),
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
