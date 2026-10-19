import Foundation
import simd

extension RigidCarDefinition {
    /// The same car with some inputs changed, validated as on construction. A new mass scales the
    /// moments of inertia with it; `id` gives a duplicate its own identity.
    public func edited(
        id: UUID? = nil, name: String? = nil, position: SIMD3<Double>? = nil,
        orientation: SIMD4<Double>? = nil,
        mass: Double? = nil, staticFriction: Double? = nil, slidingFriction: Double? = nil
    ) throws -> RigidCarDefinition {
        let newMass = mass ?? self.mass
        return try RigidCarDefinition(
            id: id ?? self.id, name: name ?? self.name, position: position ?? self.position, mass: newMass,
            wheelbase: wheelbase, track: track, centreOfMass: centreOfMass,
            inertia: inertia * (newMass / self.mass),
            shellSize: shellSize, groundClearance: groundClearance,
            orientation: orientation ?? self.orientation,
            wheels: wheels, suspension: suspension, staticFriction: staticFriction ?? self.staticFriction,
            slidingFriction: slidingFriction ?? self.slidingFriction)
    }

    /// The same car with its footprint centre moved.
    public func moved(to position: SIMD3<Double>) throws -> RigidCarDefinition {
        try edited(position: position)
    }
}

extension RigidObjectDefinition {
    /// The same object with some inputs changed, validated as on construction. Explicit moments
    /// of inertia scale with a new mass and are kept otherwise; a uniform box's follow its size.
    public func edited(
        id: UUID? = nil, name: String? = nil, position: SIMD3<Double>? = nil,
        orientation: SIMD4<Double>? = nil,
        mass: Double? = nil, size: SIMD3<Double>? = nil, staticFriction: Double? = nil,
        slidingFriction: Double? = nil
    ) throws -> RigidObjectDefinition {
        let newMass = mass ?? self.mass
        let shape = size.map { Shape.box(size: $0) } ?? self.shape
        return try RigidObjectDefinition(
            id: id ?? self.id, name: name ?? self.name, shape: shape, position: position ?? self.position,
            mass: newMass, orientation: orientation ?? self.orientation, centreOfMass: centreOfMass,
            inertia: inertia.map { $0 * (newMass / self.mass) },
            staticFriction: staticFriction ?? self.staticFriction,
            slidingFriction: slidingFriction ?? self.slidingFriction)
    }
}
