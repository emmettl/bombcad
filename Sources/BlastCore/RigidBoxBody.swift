import simd

/// CPU reference mechanics for a rigid box, independent of the blast/structural solvers.
/// SI units; position is the centre of mass, orientation maps body coordinates into world space.
/// Ground contact is optional; blast coupling is not yet implemented.
struct RigidBoxBody {
    enum InvalidDefinition: Error { case mass, dimensions, pose, centreOfMass, inertia }

    let mass: Double
    let size: SIMD3<Double>
    /// Centre of mass relative to the geometric centre, in body coordinates.
    let centreOfMass: SIMD3<Double>
    /// Principal moments about the centre of mass in body coordinates (kg m²).
    let inertia: SIMD3<Double>
    private(set) var position: SIMD3<Double>
    private(set) var orientation: simd_quatd
    private(set) var linearVelocity = SIMD3<Double>.zero
    /// World-space angular momentum. Keeping this as the state preserves it in free flight.
    private(set) var angularMomentum = SIMD3<Double>.zero

    init(
        mass: Double, size: SIMD3<Double>, position: SIMD3<Double> = .zero,
        orientation: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)),
        centreOfMass: SIMD3<Double> = .zero, inertia: SIMD3<Double>? = nil
    ) throws {
        guard mass.isFinite, mass > 0 else { throw InvalidDefinition.mass }
        guard Self.finite(size), all(size .> 0) else { throw InvalidDefinition.dimensions }
        guard Self.finite(centreOfMass), all(abs(centreOfMass) .<= size / 2) else {
            throw InvalidDefinition.centreOfMass
        }
        // Uniform-box inertia is valid only for a centred, uniform mass distribution.
        guard centreOfMass == .zero || inertia != nil else { throw InvalidDefinition.inertia }
        let squared = size * size
        let moments =
            inertia
            ?? (mass / 12
                * SIMD3(
                    squared.y + squared.z, squared.x + squared.z, squared.x + squared.y))
        guard Self.finite(moments), all(moments .> 0),
            moments.x <= moments.y + moments.z,
            moments.y <= moments.x + moments.z,
            moments.z <= moments.x + moments.y
        else { throw InvalidDefinition.inertia }
        let q = orientation.vector
        guard Self.finite(position), Self.finite(SIMD3(q.x, q.y, q.z)), q.w.isFinite,
            simd_length(q).isFinite, simd_length(q) > 0
        else { throw InvalidDefinition.pose }
        self.mass = mass
        self.size = size
        self.centreOfMass = centreOfMass
        self.inertia = moments
        self.position = position
        self.orientation = orientation.normalized
    }

    var angularVelocity: SIMD3<Double> {
        angularVelocity(at: orientation, momentum: angularMomentum)
    }

    var kineticEnergy: Double {
        0.5 * mass * simd_length_squared(linearVelocity)
            + 0.5 * simd_dot(angularMomentum, angularVelocity)
    }

    /// Transform a point measured from the box's geometric centre.
    func worldPoint(_ bodyPoint: SIMD3<Double>) -> SIMD3<Double> {
        position + orientation.act(bodyPoint - centreOfMass)
    }

    /// An instantaneous world-space impulse (N s), optionally applied away from the centre.
    mutating func applyImpulse(_ impulse: SIMD3<Double>, at point: SIMD3<Double>? = nil) {
        precondition(Self.finite(impulse) && Self.finite(point ?? position))
        linearVelocity += impulse / mass
        angularMomentum += simd_cross((point ?? position) - position, impulse)
    }

    mutating func applyAngularImpulse(_ impulse: SIMD3<Double>) {
        precondition(Self.finite(impulse))
        angularMomentum += impulse
    }

    /// Advance under constant world-space force, torque about the centre, and gravity.
    /// Translation is exact for constant acceleration. Rotation uses an explicit midpoint
    /// orientation update; callers must resolve angular motion with sufficiently small steps.
    mutating func advance(
        by dt: Double, gravity: SIMD3<Double> = SIMD3(0, 0, -9.81),
        force: SIMD3<Double> = .zero, torque: SIMD3<Double> = .zero
    ) {
        precondition(dt.isFinite && dt >= 0)
        precondition(Self.finite(gravity) && Self.finite(force) && Self.finite(torque))
        guard dt > 0 else { return }
        let acceleration = gravity + force / mass
        position += dt * linearVelocity + 0.5 * dt * dt * acceleration
        linearVelocity += dt * acceleration

        let midpointMomentum = angularMomentum + 0.5 * dt * torque
        let midpointOrientation = (Self.rotation(angularVelocity, duration: 0.5 * dt) * orientation)
            .normalized
        let midpointVelocity = angularVelocity(at: midpointOrientation, momentum: midpointMomentum)
        orientation = (Self.rotation(midpointVelocity, duration: dt) * orientation).normalized
        angularMomentum += dt * torque
    }

    private func angularVelocity(at pose: simd_quatd, momentum: SIMD3<Double>) -> SIMD3<Double> {
        pose.act(pose.inverse.act(momentum) / inertia)
    }

    private static func rotation(_ velocity: SIMD3<Double>, duration: Double) -> simd_quatd {
        let speed = simd_length(velocity)
        return speed > 0
            ? simd_quatd(angle: speed * duration, axis: velocity / speed)
            : simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
    }

    private static func finite(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}

extension RigidBoxBody {
    /// Inelastic contact against the plane z = 0, with a circular Coulomb friction cone.
    struct Ground {
        let staticFriction: Double
        let slidingFriction: Double

        init(staticFriction: Double = 0.6, slidingFriction: Double = 0.5) {
            precondition(staticFriction.isFinite && slidingFriction.isFinite)
            precondition(staticFriction >= slidingFriction && slidingFriction >= 0)
            self.staticFriction = staticFriction
            self.slidingFriction = slidingFriction
        }
    }

    struct GroundImpulse {
        let point: SIMD3<Double>
        var normal: Double = 0
        var tangent = SIMD2<Double>.zero
        fileprivate let targetSpeed: Double
    }

    var corners: [SIMD3<Double>] {
        (0..<8).map { corner in
            worldPoint(
                0.5 * size
                    * SIMD3(
                        corner & 1 == 0 ? -1 : 1,
                        corner & 2 == 0 ? -1 : 1,
                        corner & 4 == 0 ? -1 : 1))
        }
    }

    /// Semi-implicit reference step with sequential contact impulses. Speculative contacts
    /// arrest corners that would cross the ground during this step; impacts have no rebound.
    /// Unlike free flight, this path is first order in time. Resolve impacts/rotation with small
    /// steps and check convergence. Small positional corrections remove rotational penetration;
    /// these are numerical corrections, not physical impulses, and must shrink with the step.
    @discardableResult
    mutating func advanceWithGround(
        by dt: Double, ground: Ground = Ground(),
        gravity: SIMD3<Double> = SIMD3(0, 0, -9.81),
        force: SIMD3<Double> = .zero, torque: SIMD3<Double> = .zero
    ) -> [GroundImpulse] {
        precondition(dt.isFinite && dt >= 0)
        precondition(Self.finite(gravity) && Self.finite(force) && Self.finite(torque))
        guard dt > 0 else { return [] }
        let initialVelocity = linearVelocity
        let initialSpin = angularVelocity
        let contactTolerance = 1e-6 * min(size.x, min(size.y, size.z))
        let startingCorners = corners
        precondition(
            startingCorners.allSatisfy { $0.z >= -contactTolerance },
            "Ground contact requires an initially nonpenetrating box")
        linearVelocity += dt * (gravity + force / mass)
        angularMomentum += dt * torque
        let unconstrainedVelocity = linearVelocity
        let unconstrainedMomentum = angularMomentum
        // A geometric tolerance keeps a nearly flat resting face in the contact manifold.
        // Without it, roundoff-sized tilts discard corners and destroy static friction.
        var contacts = startingCorners.compactMap { point -> GroundImpulse? in
            let speed = pointVelocity(point).z
            guard point.z <= contactTolerance || point.z + dt * speed <= 0 else { return nil }
            return GroundImpulse(point: point, targetSpeed: -max(point.z - contactTolerance, 0) / dt)
        }
        let normal = SIMD3<Double>(0, 0, 1)
        let x = SIMD3<Double>(1, 0, 0)
        let y = SIMD3<Double>(0, 1, 0)
        let responses = contacts.map { contact in
            let arm = contact.point - position
            return (
                normal: impulseResponse(normal, arm: arm).z,
                tangent: impulseResponse(x, arm: arm).x + impulseResponse(y, arm: arm).y
            )
        }
        let slipTolerance = 1e-6  // m/s: distinguishes numerical residual from sliding
        var coefficients = contacts.map { contact in
            let velocity = initialVelocity + simd_cross(initialSpin, contact.point - position)
            return simd_length(SIMD2(velocity.x, velocity.y)) > slipTolerance
                ? ground.slidingFriction : ground.staticFriction
        }
        // No warm start: impulses are local to this step, making lift-off release immediately.
        // Attempt static contact before selecting sliding friction. Switching coefficients on
        // each iteration would turn a temporary solver residual into irreversible sliding.
        for pass in 0..<2 {
            for iteration in 0..<200 {
                for slot in contacts.indices {
                    let n = iteration & 1 == 0 ? slot : contacts.count - 1 - slot
                    let point = contacts[n].point
                    let oldNormal = contacts[n].normal
                    contacts[n].normal = max(
                        0,
                        oldNormal
                            + (contacts[n].targetSpeed - pointVelocity(point).z)
                            / responses[n].normal)
                    applyImpulse((contacts[n].normal - oldNormal) * normal, at: point)

                    let velocity = pointVelocity(point)
                    // Projected gradient with a scalar bound on the tangential effective mass.
                    // Inverting the 2x2 response and then projecting Euclideanly would rotate
                    // sliding friction away from the slip direction on an anisotropic contact.
                    let correction = -SIMD2(velocity.x, velocity.y) / responses[n].tangent
                    let oldTangent = contacts[n].tangent
                    var candidate = oldTangent + correction
                    let magnitude = simd_length(candidate)
                    if magnitude > coefficients[n] * contacts[n].normal {
                        candidate *= coefficients[n] * contacts[n].normal / magnitude
                    }
                    contacts[n].tangent = candidate
                    let change = candidate - oldTangent
                    applyImpulse(SIMD3(change.x, change.y, 0), at: point)
                }
            }
            guard pass == 0 else { break }
            var changed = false
            for n in contacts.indices {
                let velocity = pointVelocity(contacts[n].point)
                if coefficients[n] > ground.slidingFriction,
                    simd_length(SIMD2(velocity.x, velocity.y)) > slipTolerance
                {
                    coefficients[n] = ground.slidingFriction
                    changed = true
                }
            }
            guard changed else { break }
            linearVelocity = unconstrainedVelocity
            angularMomentum = unconstrainedMomentum
            for n in contacts.indices {
                contacts[n].normal = 0
                contacts[n].tangent = .zero
            }
        }
        advance(by: dt, gravity: .zero)
        let lowest = corners.map(\.z).min()!
        if lowest < 0 { position.z -= lowest }
        return contacts
    }

    private func pointVelocity(_ point: SIMD3<Double>) -> SIMD3<Double> {
        linearVelocity + simd_cross(angularVelocity, point - position)
    }

    /// Change in a contact point's velocity per unit world-space impulse at that point.
    private func impulseResponse(_ direction: SIMD3<Double>, arm: SIMD3<Double>) -> SIMD3<Double> {
        direction / mass
            + simd_cross(
                angularVelocity(at: orientation, momentum: simd_cross(arm, direction)), arm)
    }
}
