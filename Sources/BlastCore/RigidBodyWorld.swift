import simd

/// CPU reference mechanics for several freestanding rigid objects: boxes and simplified cars on
/// the ground, among static blocks, with contact between them. Each member is a `RigidBoxBody`;
/// a car adds its four tyres as contact points that touch only the ground. Contacts follow the
/// single-body steps (`RigidBoxBody.advanceWithGround`, `RigidCarBody.advanceWithGround`):
/// speculative, inelastic (no rebound), Coulomb friction with static tried before sliding, no
/// warm start, sequential impulses, first order in time. Between bodies, impulses are equal and
/// opposite, so contact conserves linear and angular momentum and, being inelastic, cannot add
/// kinetic energy. Small positional corrections remove the penetration rotation leaves; they move
/// positions only, never velocities.
///
/// Contact between boxes is found from corners: each box's corners against the other box and
/// against static blocks, and each block's corners against the boxes. Edge-on-edge contact (two
/// boxes crossed at an angle meeting along edges, with no corner inside the other) is not found.
/// Candidate pairs come from a sweep along x over bounds grown by each body's travel in the step.
///
/// Over a terrain (`terrain`) the ground is its surface: each corner and support is held off it
/// along the surface's normal under the point, and each node of the terrain under a member is held
/// out of the member's faces, as a block's corners are, so that a box resting across a step's edge
/// turns about the edge. Between nodes the surface's own edges are not found against the member's
/// edges, as between boxes.
///
/// A deformable structure's nodes can be handed in for a step (`nodes`): each is a point mass, or
/// a sphere of half a shell's thickness, struck by the members' faces with the same impulses,
/// equal and opposite between the member and the node. A member's corner pressed into a
/// structure's face between its nodes is not found, so its elements should be smaller than the
/// members' faces.
struct RigidBodyWorld {
    struct Member {
        var body: RigidBoxBody
        /// Contact points that touch only the ground (a car's tyres), from the box's geometric
        /// centre in body axes.
        let supports: [SIMD3<Double>]
        /// Friction against the ground, static blocks and other members (the pair takes the
        /// smaller coefficients).
        let friction: RigidBoxBody.Ground
    }

    enum Party: Equatable {
        case ground
        case block(Int)
        case member(Int)
        case node(Int)
    }

    /// A node of a deformable structure: a point, or a sphere of `radius`, of mass
    /// `1 / inverseMass` (immovable where that is zero).
    struct Node {
        var position: SIMD3<Double>
        var velocity: SIMD3<Double>
        let inverseMass: Double
        let radius: Double
    }

    struct Contact {
        /// The member pushed along `normal`; `other` is pushed the opposite way.
        let member: Int
        let other: Party
        /// World contact point: one of the member's corners or supports, or a corner of the other
        /// body or block.
        let point: SIMD3<Double>
        let normal: SIMD3<Double>
        /// Impulses over the step (N s).
        var normalImpulse = 0.0
        var tangentImpulse = SIMD3<Double>.zero
        let isSupport: Bool
        fileprivate let gap: Double
        fileprivate let tangents: (SIMD3<Double>, SIMD3<Double>)
    }

    private(set) var members: [Member]
    let blocks: [Box]
    /// The ground's shape; nil for the floor, z = 0 (a flat terrain is the floor).
    var terrain: Terrain? {
        didSet { if terrain?.isFlat == true { terrain = nil } }
    }
    /// The structure's nodes for the next step; contact changes their velocities.
    var nodes: [Node] = []
    /// Friction between members and the structure's nodes (a pair takes the smaller coefficients).
    var nodeFriction = RigidBoxBody.Ground()
    /// Kinetic energy that contact changed over the last step, of the members and of the nodes
    /// (J): the members' loss can only exceed the nodes' gain.
    private(set) var lastContactWork = (members: 0.0, nodes: 0.0)
    /// Pairs tested in the last step after the sweep, for checking the spatial filter.
    private(set) var lastCandidatePairs = 0

    init(members: [Member], blocks: [Box] = [], terrain: Terrain? = nil) {
        self.members = members
        self.blocks = blocks
        self.terrain = terrain?.isFlat == true ? nil : terrain
    }

    /// The scenario's freestanding objects and cars, in that order, among its rigid blocks.
    init(scenario: Scenario) throws {
        var members: [Member] = []
        for object in scenario.rigidObjects ?? [] {
            members.append(Member(body: try object.makeBody(), supports: [], friction: object.ground))
        }
        for car in scenario.rigidCars ?? [] {
            let made = try car.makeBody()
            members.append(Member(body: made.body, supports: made.tyres, friction: car.ground))
        }
        self.init(members: members, blocks: scenario.boxes, terrain: scenario.terrain)
    }

    var kineticEnergy: Double { members.reduce(0) { $0 + $1.body.kineticEnergy } }
    private var nodeKineticEnergy: Double {
        nodes.reduce(0) {
            $1.inverseMass > 0 ? $0 + 0.5 * simd_length_squared($1.velocity) / $1.inverseMass : $0
        }
    }
    var linearMomentum: SIMD3<Double> {
        members.reduce(.zero) { $0 + $1.body.mass * $1.body.linearVelocity }
    }
    /// About the world origin.
    var angularMomentum: SIMD3<Double> {
        members.reduce(.zero) {
            $0 + $1.body.angularMomentum + simd_cross($1.body.position, $1.body.mass * $1.body.linearVelocity)
        }
    }

    mutating func applyImpulse(_ impulse: SIMD3<Double>, to member: Int, at point: SIMD3<Double>? = nil) {
        members[member].body.applyImpulse(impulse, at: point)
    }

    mutating func applyAngularImpulse(_ impulse: SIMD3<Double>, to member: Int) {
        members[member].body.applyAngularImpulse(impulse)
    }

    /// One step under gravity and optional per-member world forces and torques about each centre
    /// of mass; `ground: false` removes the ground (for free-flight checks).
    @discardableResult
    mutating func advance(
        by dt: Double, gravity: SIMD3<Double> = SIMD3(0, 0, -9.81), ground: Bool = true,
        forces: [SIMD3<Double>]? = nil, torques: [SIMD3<Double>]? = nil
    ) -> [Contact] {
        precondition(dt.isFinite && dt >= 0)
        lastContactWork = (0, 0)
        guard dt > 0, !members.isEmpty else { return [] }
        let initial = members.map(\.body)
        let initialNodes = nodes
        for n in members.indices {
            members[n].body.applyImpulse(dt * (members[n].body.mass * gravity + (forces?[n] ?? .zero)))
            members[n].body.applyAngularImpulse(dt * (torques?[n] ?? .zero))
        }
        let unconstrained = members.map(\.body)
        let energies = (members: kineticEnergy, nodes: nodeKineticEnergy)
        var contacts = findContacts(dt: dt, ground: ground)
        let responses = contacts.map(response)
        let slipTolerance = 1e-6  // m/s, as for the single bodies
        var coefficients = contacts.map { contact in
            let slip = relativeVelocity(contact, bodies: initial, nodes: initialNodes)
            let tangential = slip - simd_dot(slip, contact.normal) * contact.normal
            let pair = friction(contact)
            return simd_length(tangential) > slipTolerance ? pair.slidingFriction : pair.staticFriction
        }
        let scale = members.reduce(0) { max($0, $1.body.mass) } * max(simd_length(gravity), 1) * dt
        let tolerance = contactTolerance
        let targets = contacts.map { -max($0.gap - tolerance, 0) / dt }
        for pass in 0..<2 {
            for iteration in 0..<400 {
                var largest = 0.0
                for slot in contacts.indices {
                    let n = iteration & 1 == 0 ? slot : contacts.count - 1 - slot
                    let normal = contacts[n].normal
                    let old = contacts[n].normalImpulse
                    contacts[n].normalImpulse = max(
                        0,
                        old + (targets[n] - simd_dot(relativeVelocity(contacts[n]), normal))
                            / responses[n].normal)
                    apply((contacts[n].normalImpulse - old) * normal, contacts[n])
                    largest = max(largest, abs(contacts[n].normalImpulse - old))

                    let velocity = relativeVelocity(contacts[n])
                    let (t1, t2) = contacts[n].tangents
                    let correction =
                        -SIMD2(simd_dot(velocity, t1), simd_dot(velocity, t2)) / responses[n].tangent
                    let oldTangent = SIMD2(
                        simd_dot(contacts[n].tangentImpulse, t1), simd_dot(contacts[n].tangentImpulse, t2))
                    var candidate = oldTangent + correction
                    let limit = coefficients[n] * contacts[n].normalImpulse
                    let magnitude = simd_length(candidate)
                    if magnitude > limit { candidate *= limit / magnitude }
                    let change = candidate - oldTangent
                    contacts[n].tangentImpulse = candidate.x * t1 + candidate.y * t2
                    apply(change.x * t1 + change.y * t2, contacts[n])
                    largest = max(largest, simd_length(change))
                }
                if largest <= 1e-10 * scale { break }
            }
            guard pass == 0 else { break }
            var changed = false
            for n in contacts.indices {
                let velocity = relativeVelocity(contacts[n])
                let tangential = velocity - simd_dot(velocity, contacts[n].normal) * contacts[n].normal
                let sliding = friction(contacts[n]).slidingFriction
                if coefficients[n] > sliding, simd_length(tangential) > slipTolerance {
                    coefficients[n] = sliding
                    changed = true
                }
            }
            guard changed else { break }
            for n in members.indices { members[n].body = unconstrained[n] }
            nodes = initialNodes
            for n in contacts.indices {
                contacts[n].normalImpulse = 0
                contacts[n].tangentImpulse = .zero
            }
        }
        lastContactWork = (kineticEnergy - energies.members, nodeKineticEnergy - energies.nodes)
        for n in members.indices { members[n].body.advance(by: dt, gravity: .zero) }
        separate(ground: ground)
        return contacts
    }

    // MARK: Contact search

    private var contactTolerance: Double {
        1e-6 * members.reduce(Double.infinity) { min($0, $1.body.size.min()) }
    }

    /// World bounds of a member grown by how far any of its points can travel in `dt`.
    private func bounds(_ n: Int, dt: Double) -> (low: SIMD3<Double>, high: SIMD3<Double>) {
        let body = members[n].body
        let points = body.corners + members[n].supports.map(body.worldPoint)
        var low = points.reduce(SIMD3(repeating: Double.infinity)) { simd_min($0, $1) }
        var high = points.reduce(SIMD3(repeating: -Double.infinity)) { simd_max($0, $1) }
        let reach =
            dt
            * (simd_length(body.linearVelocity) + simd_length(body.angularVelocity) * simd_length(body.size))
            + 1e-6 * simd_length(body.size)
        low -= reach
        high += reach
        return (low, high)
    }

    /// Sweep and prune along x: pairs of members, and of members and blocks, whose grown bounds
    /// overlap. Sorted, so the contact order never depends on the sweep.
    func candidatePairs(dt: Double) -> [(Int, Party)] {
        struct Entry {
            let party: Party
            let low: SIMD3<Double>
            let high: SIMD3<Double>
        }
        var entries = members.indices.map { n -> Entry in
            let b = bounds(n, dt: dt)
            return Entry(party: .member(n), low: b.low, high: b.high)
        }
        entries += blocks.indices.map {
            Entry(party: .block($0), low: SIMD3<Double>(blocks[$0].min), high: SIMD3<Double>(blocks[$0].max))
        }
        let order = entries.indices.sorted {
            entries[$0].low.x < entries[$1].low.x || (entries[$0].low.x == entries[$1].low.x && $0 < $1)
        }
        var active: [Int] = []
        var pairs: [(Int, Party)] = []
        for e in order {
            let entry = entries[e]
            active.removeAll { entries[$0].high.x < entry.low.x }
            for a in active {
                let other = entries[a]
                guard all(other.low .<= entry.high), all(entry.low .<= other.high) else { continue }
                switch (entry.party, other.party) {
                case (.member(let i), .member(let j)): pairs.append((min(i, j), .member(max(i, j))))
                case (.member(let i), .block(let k)), (.block(let k), .member(let i)):
                    pairs.append((i, .block(k)))
                default: break
                }
            }
            active.append(e)
        }
        func key(_ p: (Int, Party)) -> (Int, Int) {
            switch p.1 {
            case .member(let j): (p.0, j)
            case .block(let k): (p.0, members.count + k)
            case .ground, .node: (p.0, -1)
            }
        }
        return pairs.sorted { key($0) < key($1) }
    }

    private mutating func findContacts(dt: Double, ground: Bool) -> [Contact] {
        let tolerance = contactTolerance
        var contacts: [Contact] = []
        if ground, let terrain {
            for n in members.indices {
                let body = members[n].body
                let points =
                    body.corners.map { ($0, false) } + members[n].supports.map { (body.worldPoint($0), true) }
                for (point, support) in points {
                    let (gap, normal) = Self.clearance(point, above: terrain)
                    let speed = simd_dot(pointVelocity(body, point), normal)
                    guard gap <= tolerance || gap + dt * speed <= 0 else { continue }
                    contacts.append(
                        Contact(
                            member: n, other: .ground, point: point, normal: normal, isSupport: support,
                            gap: gap,
                            tangents: Self.tangents(normal)))
                }
                // The terrain's nodes against the member's faces, pushing it away from the face each
                // is near.
                let centre = body.worldPoint(.zero)
                let travel =
                    dt
                    * (simd_length(body.linearVelocity) + simd_length(body.angularVelocity)
                        * simd_length(body.size))
                for node in Self.nodes(of: terrain, under: bounds(n, dt: dt)) {
                    guard
                        let c = Self.pointAgainstBox(
                            node.position, centre: centre, pose: body.orientation, half: body.size / 2,
                            towards: -node.normal, reach: travel + tolerance),
                        Self.canPush(node, along: -c.normal)
                    else { continue }
                    add(
                        &contacts, member: n, other: .ground, point: node.position, gap: c.gap,
                        normal: -c.normal, dt: dt)
                }
            }
        } else if ground {
            for n in members.indices {
                let body = members[n].body
                let points =
                    body.corners.map { ($0, false) } + members[n].supports.map { (body.worldPoint($0), true) }
                for (point, support) in points {
                    let speed = pointVelocity(body, point).z
                    guard point.z <= tolerance || point.z + dt * speed <= 0 else { continue }
                    contacts.append(
                        Contact(
                            member: n, other: .ground, point: point, normal: SIMD3(0, 0, 1),
                            isSupport: support,
                            gap: point.z, tangents: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))))
                }
            }
        }
        let pairs = candidatePairs(dt: dt)
        lastCandidatePairs = pairs.count
        for (i, other) in pairs {
            let a = members[i].body
            switch other {
            case .member(let j):
                let b = members[j].body
                // A's corners against B push A; B's corners against A push B.
                let ab = a.worldPoint(.zero) - b.worldPoint(.zero)
                for corner in a.corners {
                    if let c = Self.pointAgainstBox(
                        corner, centre: b.worldPoint(.zero), pose: b.orientation, half: b.size / 2,
                        towards: ab)
                    {
                        add(
                            &contacts, member: i, other: .member(j), point: corner, gap: c.gap,
                            normal: c.normal, dt: dt)
                    }
                }
                for corner in b.corners {
                    if let c = Self.pointAgainstBox(
                        corner, centre: a.worldPoint(.zero), pose: a.orientation, half: a.size / 2,
                        towards: -ab)
                    {
                        add(
                            &contacts, member: j, other: .member(i), point: corner, gap: c.gap,
                            normal: c.normal, dt: dt)
                    }
                }
            case .block(let k):
                let low = SIMD3<Double>(blocks[k].min)
                let high = SIMD3<Double>(blocks[k].max)
                let centre = (low + high) / 2
                let identity = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
                let towards = a.worldPoint(.zero) - centre
                for corner in a.corners {
                    if let c = Self.pointAgainstBox(
                        corner, centre: centre, pose: identity, half: (high - low) / 2, towards: towards)
                    {
                        add(
                            &contacts, member: i, other: .block(k), point: corner, gap: c.gap,
                            normal: c.normal, dt: dt)
                    }
                }
                for z in [low.z, high.z] {
                    for y in [low.y, high.y] {
                        for x in [low.x, high.x] {
                            let corner = SIMD3(x, y, z)
                            if let c = Self.pointAgainstBox(
                                corner, centre: a.worldPoint(.zero), pose: a.orientation, half: a.size / 2,
                                towards: -towards)
                            {
                                // The block's corner pushes the member away from the box face it is near.
                                add(
                                    &contacts, member: i, other: .block(k), point: corner, gap: c.gap,
                                    normal: -c.normal, dt: dt)
                            }
                        }
                    }
                }
            case .ground, .node: break
            }
        }
        // Each member's faces against the structure's nodes near it: the node pushes the member
        // away from the face it is near.
        if !nodes.isEmpty {
            for n in members.indices {
                let body = members[n].body
                let box = bounds(n, dt: dt)
                let centre = body.worldPoint(.zero)
                let travel =
                    dt
                    * (simd_length(body.linearVelocity) + simd_length(body.angularVelocity)
                        * simd_length(body.size))
                for (k, node) in nodes.enumerated() {
                    let reach = node.radius + dt * simd_length(node.velocity)
                    guard all(node.position .>= box.low - reach), all(node.position .<= box.high + reach),
                        let c = Self.pointAgainstBox(
                            node.position, centre: centre, pose: body.orientation, half: body.size / 2,
                            towards: node.position - centre, reach: reach + travel + contactTolerance)
                    else { continue }
                    add(
                        &contacts, member: n, other: .node(k), point: node.position - c.gap * c.normal,
                        gap: c.gap - node.radius, normal: -c.normal, dt: dt)
                }
            }
        }
        return contacts
    }

    /// Adds a speculative contact if the gap can close within the step.
    private func add(
        _ contacts: inout [Contact], member: Int, other: Party, point: SIMD3<Double>, gap: Double,
        normal: SIMD3<Double>, dt: Double
    ) {
        var probe = Contact(
            member: member, other: other, point: point, normal: normal, isSupport: false, gap: gap,
            tangents: Self.tangents(normal))
        let closing = -simd_dot(relativeVelocity(probe), normal)
        guard gap <= contactTolerance || gap <= dt * closing else { return }
        probe.normalImpulse = 0
        contacts.append(probe)
    }

    /// Distance from a point to an oriented box (negative inside, by the shallowest face) and the
    /// box's outward normal there, if the point is within `reach` of it.
    ///
    /// Inside, faces equally shallow (a corner on an edge, as in a stack of equal boxes) are told
    /// apart by `towards`, the direction to the other body's centre: the face it lies beyond most,
    /// relative to the box's size, wins, as separating axes would choose.
    static func pointAgainstBox(
        _ point: SIMD3<Double>, centre: SIMD3<Double>, pose: simd_quatd, half: SIMD3<Double>,
        towards: SIMD3<Double> = .zero, reach: Double = .infinity
    ) -> (gap: Double, normal: SIMD3<Double>)? {
        let local = pose.inverse.act(point - centre)
        // Within a hair of the surface counts as on it: a corner resting on an edge, nudged out
        // by rounding, must keep the face's normal, not the direction of the rounding.
        let excess = abs(local) - half
        let hair = 1e-6 * half.min()
        if all(excess .<= hair) {
            let shallowest = excess.max()
            let direction = pose.inverse.act(towards) / half
            var axis = -1
            for a in 0..<3 where excess[a] >= shallowest - hair {
                if axis < 0 || abs(direction[a]) > abs(direction[axis]) { axis = a }
            }
            var n = SIMD3<Double>.zero
            n[axis] = local[axis] != 0 ? (local[axis] < 0 ? -1 : 1) : (direction[axis] < 0 ? -1 : 1)
            return (excess[axis], pose.act(n))
        }
        let closest = simd_clamp(local, -half, half)
        let offset = local - closest
        let distance = simd_length(offset)
        // Only near points are contact candidates; far ones are left to later steps.
        guard distance <= min(reach, half.max()) else { return nil }
        return (distance, pose.act(offset / distance))
    }

    private static func tangents(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let helper = abs(n.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
        let t1 = simd_normalize(simd_cross(helper, n))
        return (t1, simd_cross(n, t1))
    }

    // MARK: Impulses

    private func friction(_ contact: Contact) -> RigidBoxBody.Ground {
        let own = members[contact.member].friction
        let theirs: RigidBoxBody.Ground
        switch contact.other {
        case .member(let j): theirs = members[j].friction
        case .node: theirs = nodeFriction
        case .ground, .block: return own
        }
        return RigidBoxBody.Ground(
            staticFriction: min(own.staticFriction, theirs.staticFriction),
            slidingFriction: min(own.slidingFriction, theirs.slidingFriction))
    }

    private func pointVelocity(_ body: RigidBoxBody, _ point: SIMD3<Double>) -> SIMD3<Double> {
        body.linearVelocity + simd_cross(body.angularVelocity, point - body.position)
    }

    /// Velocity of the member's point relative to whatever it touches, for given body states.
    private func relativeVelocity(_ c: Contact, bodies: [RigidBoxBody], nodes: [Node]) -> SIMD3<Double> {
        var v = pointVelocity(bodies[c.member], c.point)
        switch c.other {
        case .member(let j): v -= pointVelocity(bodies[j], c.point)
        case .node(let k): v -= nodes[k].velocity
        case .ground, .block: break
        }
        return v
    }

    /// Velocity of the member's point relative to whatever it touches.
    private func relativeVelocity(_ c: Contact) -> SIMD3<Double> {
        var v = pointVelocity(members[c.member].body, c.point)
        switch c.other {
        case .member(let j): v -= pointVelocity(members[j].body, c.point)
        case .node(let k): v -= nodes[k].velocity
        case .ground, .block: break
        }
        return v
    }

    /// Change in a body's point velocity per unit world impulse there.
    private static func impulseResponse(_ body: RigidBoxBody, _ direction: SIMD3<Double>, arm: SIMD3<Double>)
        -> SIMD3<Double>
    {
        let pose = body.orientation
        let spin = pose.act(pose.inverse.act(simd_cross(arm, direction)) / body.inertia)
        return direction / body.mass + simd_cross(spin, arm)
    }

    private func response(_ c: Contact) -> (normal: Double, tangent: Double) {
        var bodies = [members[c.member].body]
        if case .member(let j) = c.other { bodies.append(members[j].body) }
        var normal = 0.0
        var tangent = 0.0
        for body in bodies {
            let arm = c.point - body.position
            normal += simd_dot(Self.impulseResponse(body, c.normal, arm: arm), c.normal)
            tangent +=
                simd_dot(Self.impulseResponse(body, c.tangents.0, arm: arm), c.tangents.0)
                + simd_dot(Self.impulseResponse(body, c.tangents.1, arm: arm), c.tangents.1)
        }
        if case .node(let k) = c.other {
            normal += nodes[k].inverseMass
            tangent += 2 * nodes[k].inverseMass
        }
        return (normal, tangent)
    }

    private mutating func apply(_ impulse: SIMD3<Double>, _ c: Contact) {
        members[c.member].body.applyImpulse(impulse, at: c.point)
        switch c.other {
        case .member(let j): members[j].body.applyImpulse(-impulse, at: c.point)
        case .node(let k): nodes[k].velocity -= impulse * nodes[k].inverseMass
        case .ground, .block: break
        }
    }

    // MARK: Position correction

    /// Pushes overlapping members apart, and out of blocks and the ground, without changing any
    /// velocity: the overlap rotation leaves within a step, shared by inverse mass between bodies.
    private mutating func separate(ground: Bool) {
        let tolerance = contactTolerance
        for _ in 0..<4 {
            var moved = false
            for (i, other) in candidatePairs(dt: 0) {
                let a = members[i].body
                var worst: (depth: Double, normal: SIMD3<Double>)?
                func consider(_ c: (gap: Double, normal: SIMD3<Double>)?, sign: Double) {
                    guard let c, c.gap < -tolerance, -c.gap > (worst?.depth ?? 0) else { return }
                    worst = (-c.gap, sign * c.normal)
                }
                switch other {
                case .member(let j):
                    let b = members[j].body
                    let ab = a.worldPoint(.zero) - b.worldPoint(.zero)
                    for corner in a.corners {
                        consider(
                            Self.pointAgainstBox(
                                corner, centre: b.worldPoint(.zero), pose: b.orientation, half: b.size / 2,
                                towards: ab),
                            sign: 1)
                    }
                    for corner in b.corners {
                        consider(
                            Self.pointAgainstBox(
                                corner, centre: a.worldPoint(.zero), pose: a.orientation, half: a.size / 2,
                                towards: -ab),
                            sign: -1)
                    }
                    guard let worst else { continue }
                    let share = b.mass / (a.mass + b.mass)
                    members[i].body = a.translated(by: worst.normal * (worst.depth - tolerance) * share)
                    members[j].body = b.translated(
                        by: -worst.normal * (worst.depth - tolerance) * (1 - share))
                    moved = true
                case .block(let k):
                    let low = SIMD3<Double>(blocks[k].min)
                    let high = SIMD3<Double>(blocks[k].max)
                    let identity = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
                    for corner in a.corners {
                        consider(
                            Self.pointAgainstBox(
                                corner, centre: (low + high) / 2, pose: identity, half: (high - low) / 2,
                                towards: a.worldPoint(.zero) - (low + high) / 2),
                            sign: 1)
                    }
                    guard let worst else { continue }
                    members[i].body = a.translated(by: worst.normal * (worst.depth - tolerance))
                    moved = true
                case .ground, .node: break
                }
            }
            // Out of the structure's nodes, moving the member alone.
            for i in members.indices where !nodes.isEmpty {
                let a = members[i].body
                let box = bounds(i, dt: 0)
                var worst: (depth: Double, normal: SIMD3<Double>)?
                for node in nodes {
                    guard all(node.position .>= box.low - node.radius),
                        all(node.position .<= box.high + node.radius),
                        let c = Self.pointAgainstBox(
                            node.position, centre: a.worldPoint(.zero), pose: a.orientation, half: a.size / 2,
                            towards: node.position - a.worldPoint(.zero), reach: node.radius),
                        c.gap - node.radius < -tolerance, node.radius - c.gap > (worst?.depth ?? 0)
                    else { continue }
                    worst = (node.radius - c.gap, -c.normal)
                }
                guard let worst else { continue }
                members[i].body = a.translated(by: worst.normal * (worst.depth - tolerance))
                moved = true
            }
            if !moved { break }
        }
        guard ground else { return }
        if let terrain {
            // Out of the terrain along the normal of the deepest point, a few times over.
            for n in members.indices {
                for _ in 0..<4 {
                    let body = members[n].body
                    var worst: (depth: Double, normal: SIMD3<Double>)?
                    for point in body.corners + members[n].supports.map(body.worldPoint) {
                        let (gap, normal) = Self.clearance(point, above: terrain)
                        if gap < -tolerance, -gap > (worst?.depth ?? 0) { worst = (-gap, normal) }
                    }
                    let centre = body.worldPoint(.zero)
                    for node in Self.nodes(of: terrain, under: bounds(n, dt: 0)) {
                        guard
                            let c = Self.pointAgainstBox(
                                node.position, centre: centre, pose: body.orientation, half: body.size / 2,
                                towards: -node.normal, reach: 0),
                            c.gap < -tolerance, -c.gap > (worst?.depth ?? 0),
                            Self.canPush(node, along: -c.normal)
                        else { continue }
                        worst = (-c.gap, -c.normal)
                    }
                    guard let worst else { break }
                    members[n].body = body.translated(by: worst.normal * (worst.depth - tolerance))
                }
            }
            return
        }
        for n in members.indices {
            let body = members[n].body
            let lowest = (body.corners + members[n].supports.map(body.worldPoint)).map(\.z).min()!
            if lowest < 0 { members[n].body = body.translated(by: SIMD3(0, 0, -lowest)) }
        }
    }

    // MARK: Terrain

    /// How far `point` is above the terrain, along the surface's normal under it (the distance to
    /// the tangent plane there), and that normal.
    static func clearance(_ point: SIMD3<Double>, above terrain: Terrain) -> (
        gap: Double, normal: SIMD3<Double>
    ) {
        let (height, normal) = terrain.surface(at: SIMD2(point.x, point.y))
        return ((point.z - height) * normal.z, normal)
    }

    /// A node of the terrain, with the normals of the four cells round it.
    struct TerrainNode {
        let position: SIMD3<Double>
        let normals: [SIMD3<Double>]
        /// Their mean direction.
        var normal: SIMD3<Double> { simd_normalize(normals.reduce(.zero, +)) }
    }

    /// Whether a node can push a member along `direction`: only within 60° of one of the cells'
    /// normals round it. Nodes lying in a slope's face would otherwise catch a box sliding over
    /// it on the edge of its leading face, while the node at a step's edge holds a box resting
    /// across it up, along the plateau's normal.
    static func canPush(_ node: TerrainNode, along direction: SIMD3<Double>) -> Bool {
        node.normals.contains { simd_dot($0, direction) > 0.5 }
    }

    /// The terrain's nodes within `bounds` and not below its floor.
    static func nodes(of terrain: Terrain, under bounds: (low: SIMD3<Double>, high: SIMD3<Double>))
        -> [TerrainNode]
    {
        let s = Double(terrain.spacing)
        let origin = SIMD2<Double>(terrain.origin)
        let first = SIMD2<Int>(((SIMD2(bounds.low.x, bounds.low.y) - origin) / s).rounded(.up))
        let last = SIMD2<Int>(((SIMD2(bounds.high.x, bounds.high.y) - origin) / s).rounded(.down))
        let low = simd_max(first, .zero)
        let high = simd_min(last, SIMD2(terrain.columns - 1, terrain.rows - 1))
        guard all(low .<= high) else { return [] }
        var nodes: [TerrainNode] = []
        for j in low.y...high.y {
            for i in low.x...high.x {
                let height = Double(terrain.height(column: i, row: j))
                guard height >= bounds.low.z else { continue }
                let xy = origin + s * SIMD2(Double(i), Double(j))
                let normals = [SIMD2<Double>(1, 1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, -1)].map {
                    terrain.surface(at: xy + 0.25 * s * $0).normal
                }
                nodes.append(TerrainNode(position: SIMD3(xy.x, xy.y, height), normals: normals))
            }
        }
        return nodes
    }
}
