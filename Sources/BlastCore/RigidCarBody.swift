import simd

/// CPU reference mechanics for a simplified car: one rigid body on four tyre contact points,
/// with all wheels locked and rigid suspension. Each tyre carries its own normal force and
/// Coulomb friction, which vanish when that tyre lifts off. The body shell is a box whose
/// corners are further contacts, so a car that has tipped rests on its shell rather than
/// falling through the ground; on its wheels the shell stays clear of the ground.
/// Built on `RigidBoxBody`, whose box is the shell. Not coupled to the air.
struct RigidCarBody {
    /// Rigid state; its box is the shell, and its geometric centre is the origin for `tyres`.
    private(set) var body: RigidBoxBody
    /// Tyre contact points from the shell's geometric centre, in body coordinates (x forward,
    /// y left, z up): front left, front right, rear left, rear right.
    let tyres: [SIMD3<Double>]

    init(body: RigidBoxBody, tyres: [SIMD3<Double>]) {
        precondition(tyres.count == 4)
        self.body = body
        self.tyres = tyres
    }

    struct Contact {
        enum Location: Equatable {
            case tyre(Int)
            case shell(Int)
        }
        let location: Location
        let point: SIMD3<Double>
        /// Impulses over the step (N s); divide by the step for forces.
        var normal: Double = 0
        var tangent = SIMD2<Double>.zero
        fileprivate let targetSpeed: Double
    }

    var tyrePoints: [SIMD3<Double>] { tyres.map(body.worldPoint) }

    var mass: Double { body.mass }
    /// World position of the centre of mass.
    var position: SIMD3<Double> { body.position }
    var linearVelocity: SIMD3<Double> { body.linearVelocity }
    var angularVelocity: SIMD3<Double> { body.angularVelocity }
    var kineticEnergy: Double { body.kineticEnergy }

    mutating func applyImpulse(_ impulse: SIMD3<Double>, at point: SIMD3<Double>? = nil) {
        body.applyImpulse(impulse, at: point)
    }

    mutating func applyAngularImpulse(_ impulse: SIMD3<Double>) {
        body.applyAngularImpulse(impulse)
    }

    /// Kinetic plus gravitational potential energy, with zero potential at the ground.
    func mechanicalEnergy(gravity: Double = 9.81) -> Double {
        body.kineticEnergy + body.mass * gravity * body.position.z
    }

    /// Semi-implicit reference step with sequential contact impulses, following
    /// `RigidBoxBody.advanceWithGround`: speculative contacts, no rebound, static friction
    /// tried before sliding, no warm start so lift-off releases at once, and first order in
    /// time. Rigid suspension makes four coplanar tyre loads statically indeterminate; the
    /// split is chosen as equal tyre stiffness would set it (see `equaliseLoads`).
    @discardableResult
    mutating func advanceWithGround(
        by dt: Double, ground: RigidBoxBody.Ground = RigidBoxBody.Ground(),
        gravity: SIMD3<Double> = SIMD3(0, 0, -9.81),
        force: SIMD3<Double> = .zero, torque: SIMD3<Double> = .zero
    ) -> [Contact] {
        precondition(dt.isFinite && dt >= 0)
        precondition(Self.finite(gravity) && Self.finite(force) && Self.finite(torque))
        guard dt > 0 else { return [] }
        let initialVelocity = body.linearVelocity
        let initialSpin = body.angularVelocity
        let initialCentre = body.position
        let size = body.size
        let contactTolerance = 1e-6 * min(size.x, min(size.y, size.z))
        let candidates =
            tyrePoints.enumerated().map { (Contact.Location.tyre($0.offset), $0.element) }
            + body.corners.enumerated().map { (Contact.Location.shell($0.offset), $0.element) }
        precondition(
            candidates.allSatisfy { $0.1.z >= -contactTolerance },
            "Ground contact requires an initially nonpenetrating car")
        body.applyImpulse(dt * (body.mass * gravity + force))
        body.applyAngularImpulse(dt * torque)
        let unconstrained = body
        var contacts = candidates.compactMap { location, point -> Contact? in
            let speed = pointVelocity(point).z
            guard point.z <= contactTolerance || point.z + dt * speed <= 0 else { return nil }
            return Contact(
                location: location, point: point,
                targetSpeed: -max(point.z - contactTolerance, 0) / dt)
        }
        let normal = SIMD3<Double>(0, 0, 1)
        let responses = contacts.map { contact in
            let arm = contact.point - body.position
            return (
                normal: impulseResponse(normal, arm: arm).z,
                tangent: impulseResponse(SIMD3(1, 0, 0), arm: arm).x
                    + impulseResponse(SIMD3(0, 1, 0), arm: arm).y
            )
        }
        let slipTolerance = 1e-6  // m/s, as for the box
        var coefficients = contacts.map { contact in
            let velocity = initialVelocity + simd_cross(initialSpin, contact.point - initialCentre)
            return simd_length(SIMD2(velocity.x, velocity.y)) > slipTolerance
                ? ground.slidingFriction : ground.staticFriction
        }
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
                    body.applyImpulse((contacts[n].normal - oldNormal) * normal, at: point)

                    let velocity = pointVelocity(point)
                    let correction = -SIMD2(velocity.x, velocity.y) / responses[n].tangent
                    let oldTangent = contacts[n].tangent
                    var candidate = oldTangent + correction
                    let magnitude = simd_length(candidate)
                    if magnitude > coefficients[n] * contacts[n].normal {
                        candidate *= coefficients[n] * contacts[n].normal / magnitude
                    }
                    contacts[n].tangent = candidate
                    let change = candidate - oldTangent
                    body.applyImpulse(SIMD3(change.x, change.y, 0), at: point)
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
            body = unconstrained
            for n in contacts.indices {
                contacts[n].normal = 0
                contacts[n].tangent = .zero
            }
        }
        equaliseLoads(&contacts, coefficients: coefficients, slipTolerance: slipTolerance)
        body.advance(by: dt, gravity: .zero)
        let lowest = (tyrePoints + body.corners).map(\.z).min()!
        if lowest < 0 { body = body.translated(by: SIMD3(0, 0, -lowest)) }
        return contacts
    }

    /// Several coplanar contacts on the ground share load in a way the rigid body's motion does
    /// not fix: shifting load around a "warp" pattern (more on one diagonal, less on the other)
    /// leaves the net force and moment unchanged. Equal, stiff springs at the contacts would
    /// choose the smallest load vector with the same resultant, so the reported impulses are
    /// moved towards it, as far as each contact's friction cone allows. The body's motion was
    /// set by the solve and does not change. Sliding contacts keep friction equal to μN; that
    /// keeps the resultant only if they all slide the same way, so otherwise nothing is moved.
    private func equaliseLoads(
        _ contacts: inout [Contact], coefficients: [Double], slipTolerance: Double
    ) {
        var members: [(index: Int, sliding: Bool)] = []
        var slip: SIMD2<Double>?
        for n in contacts.indices {
            let velocity = pointVelocity(contacts[n].point)
            let closed = abs(velocity.z - contacts[n].targetSpeed) <= 1e-9
            guard contacts[n].normal > 0 || closed else { continue }
            let tangential = SIMD2(velocity.x, velocity.y)
            let sliding = simd_length(tangential) > slipTolerance
            if sliding {
                let direction = simd_normalize(tangential)
                if let slip, simd_dot(slip, direction) < 1 - 1e-9 { return }
                slip = direction
            }
            members.append((n, sliding))
        }
        guard members.count > 3 else { return }
        // Rows of the resultant map: total load and its first moments in the ground plane.
        let centre =
            members.reduce(SIMD2<Double>.zero) {
                $0 + SIMD2(contacts[$1.index].point.x, contacts[$1.index].point.y)
            } / Double(members.count)
        let rows = members.map { member -> SIMD3<Double> in
            let point = contacts[member.index].point
            return SIMD3(1, point.x - centre.x, point.y - centre.y)
        }
        var gram = simd_double3x3()
        var resultant = SIMD3<Double>.zero
        for (row, member) in zip(rows, members) {
            gram += simd_double3x3(rows: [row.x * row, row.y * row, row.z * row])
            resultant += contacts[member.index].normal * row
        }
        let scale = gram[0, 0] * gram[1, 1] * gram[2, 2]
        guard scale > 0, abs(gram.determinant) > 1e-9 * scale else { return }
        let multipliers = gram.inverse * resultant
        let change = zip(rows, members).map { row, member in
            simd_dot(multipliers, row) - contacts[member.index].normal
        }
        var step = 1.0
        for (k, member) in members.enumerated() where change[k] < 0 {
            let contact = contacts[member.index]
            let coefficient = coefficients[member.index]
            let floor =
                member.sliding || coefficient == 0 ? 0 : simd_length(contact.tangent) / coefficient
            step = min(step, max(0, contact.normal - floor) / -change[k])
        }
        for (k, member) in members.enumerated() {
            let n = member.index
            let old = contacts[n].normal
            contacts[n].normal = max(0, old + step * change[k])
            if member.sliding, let slip {
                contacts[n].tangent =
                    old > 0
                    ? contacts[n].tangent * (contacts[n].normal / old)
                    : -coefficients[n] * contacts[n].normal * slip
            }
        }
    }

    private func pointVelocity(_ point: SIMD3<Double>) -> SIMD3<Double> {
        body.linearVelocity + simd_cross(body.angularVelocity, point - body.position)
    }

    /// Change in a contact point's velocity per unit world-space impulse at that point.
    private func impulseResponse(_ direction: SIMD3<Double>, arm: SIMD3<Double>) -> SIMD3<Double> {
        let pose = body.orientation
        let spin = pose.act(pose.inverse.act(simd_cross(arm, direction)) / body.inertia)
        return direction / body.mass + simd_cross(spin, arm)
    }

    private static func finite(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
