import Foundation
import simd

/// A cased charge's fragments and a puff of passive tracers, flown through the blast one way: the
/// air pushes them, they do not push back. Masses from Mott's distribution (with a casing's
/// thickness and diameter, Mott's own scaling for their size and number), launch speeds from the
/// Gurney equation, drag on a tumbling chunk from measured drag curves; the impacts it records are
/// where they hit the ground, a rigid block or the structure's starting outline, which they do
/// not load. See docs/fragments.md.
public struct FragmentSpec: Codable, Sendable, Equatable {
    public enum Casing: String, Codable, Sendable {
        /// Fragments sprayed out round the axis, within `spread` of square to it.
        case cylinder
        /// Fragments sprayed out evenly in every direction.
        case sphere
    }

    /// Fragments from the casing round the primary charge.
    public var casingMass: Float = 0
    public var count = 0
    public var casing = Casing.cylinder
    public var axis = SIMD3<Float>(0, 0, 1)
    /// Half the angle of the cylinder's spray, in radians.
    public var spread: Float = 0.25
    /// √(2E), the Gurney velocity of the explosive: 2,440 m/s for TNT. Taken from `explosive`'s
    /// entry in Cooper's Table 27.1 when a description names one and leaves this out.
    public var gurneyVelocity: Float = 2440
    public var fragmentDensity: Float = 7850
    /// The casing's wall thickness and inside diameter, in metres. With both, the fragments' sizes
    /// and number follow Mott's scaling, Cooper's Eq. 27.13, and `count` is how many are flown,
    /// each standing for as many real fragments as that takes; without, `count` is the number of
    /// fragments and they share the casing's mass.
    public var wallThickness: Float?
    public var innerDiameter: Float?
    /// The explosive by name, for Mott's coefficient B (Cooper's Table 27.2, mild steel cylinders)
    /// and √(2E) (his Table 27.1): one of `FragmentExplosive.names`. TNT's when not given.
    public var explosive: String?
    /// Mott's coefficient B, in lb^½ in^(−7/6), instead of the explosive's.
    public var mottCoefficient: Float?
    /// The exponent β of the masses' distribution, P(mass > m) = exp(−(m/μ)^β): ½ is Mott's
    /// (two-dimensional break-up), 1 Grady's exponential (one-dimensional), which fits Cooper's
    /// cast-iron bomb better (docs/fragments.md).
    public var massExponent: Float = 0.5
    /// Massless tracers released evenly through a box, following the air.
    public var tracers = 0
    public var tracerRegion: Box?
    public var seed: UInt64 = 1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case casingMass, count, casing, axis, spread, gurneyVelocity, fragmentDensity, tracers, tracerRegion,
            seed, wallThickness, innerDiameter, explosive, mottCoefficient, massExponent
    }

    /// Any field left out takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FragmentSpec()
        casingMass = try c.decodeIfPresent(Float.self, forKey: .casingMass) ?? d.casingMass
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? d.count
        casing = try c.decodeIfPresent(Casing.self, forKey: .casing) ?? d.casing
        axis = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .axis) ?? d.axis
        spread = try c.decodeIfPresent(Float.self, forKey: .spread) ?? d.spread
        explosive = try c.decodeIfPresent(String.self, forKey: .explosive)
        gurneyVelocity =
            try c.decodeIfPresent(Float.self, forKey: .gurneyVelocity)
            ?? explosive.flatMap { FragmentExplosive.named($0)?.gurneyVelocity } ?? d.gurneyVelocity
        fragmentDensity = try c.decodeIfPresent(Float.self, forKey: .fragmentDensity) ?? d.fragmentDensity
        tracers = try c.decodeIfPresent(Int.self, forKey: .tracers) ?? d.tracers
        tracerRegion = try c.decodeIfPresent(Box.self, forKey: .tracerRegion)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? d.seed
        wallThickness = try c.decodeIfPresent(Float.self, forKey: .wallThickness)
        innerDiameter = try c.decodeIfPresent(Float.self, forKey: .innerDiameter)
        mottCoefficient = try c.decodeIfPresent(Float.self, forKey: .mottCoefficient)
        massExponent = try c.decodeIfPresent(Float.self, forKey: .massExponent) ?? d.massExponent
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(casingMass, forKey: .casingMass)
        try c.encode(count, forKey: .count)
        try c.encode(casing, forKey: .casing)
        try c.encode(axis, forKey: .axis)
        try c.encode(spread, forKey: .spread)
        try c.encode(gurneyVelocity, forKey: .gurneyVelocity)
        try c.encode(fragmentDensity, forKey: .fragmentDensity)
        try c.encode(tracers, forKey: .tracers)
        try c.encodeIfPresent(tracerRegion, forKey: .tracerRegion)
        try c.encode(seed, forKey: .seed)
        try c.encodeIfPresent(wallThickness, forKey: .wallThickness)
        try c.encodeIfPresent(innerDiameter, forKey: .innerDiameter)
        try c.encodeIfPresent(explosive, forKey: .explosive)
        try c.encodeIfPresent(mottCoefficient, forKey: .mottCoefficient)
        // Left out at Mott's, so that descriptions saved before it read and compare the same.
        if massExponent != 0.5 { try c.encode(massExponent, forKey: .massExponent) }
    }

    /// Mott's distribution factor M_K, in lb^½, from the casing's thickness and inside diameter
    /// (Cooper's Eq. 27.13 with t^(5/6), as his Example 27.7 and B's units have it; the equation
    /// prints 5/16); nil without both.
    public var mottFactor: Double? {
        guard let t = wallThickness, let d = innerDiameter, t > 0, d > 0 else { return nil }
        let b = Double(
            mottCoefficient ?? FragmentExplosive.named(explosive ?? "TNT")?.mottCoefficient ?? 0.0779)
        let inches = (t: Double(t) / 0.0254, d: Double(d) / 0.0254)
        return b * pow(inches.t, 5.0 / 6) * cbrt(inches.d) * (1 + inches.t / inches.d)
    }

    /// The fragments' mean mass by Mott's scaling, 2 M_K², in kilograms; nil without a casing's
    /// dimensions.
    public var mottMeanMass: Float? {
        mottFactor.map { Float(2 * $0 * $0 * 0.453_592_37) }
    }

    /// How many fragments the casing breaks into: by Mott's scaling with a casing's dimensions,
    /// else `count`.
    public var realFragmentCount: Double {
        mottMeanMass.map { Double(casingMass / $0) } ?? Double(count)
    }

    /// Fragment counts and masses a run can handle.
    public func validate() throws {
        guard (0...200_000).contains(count), (0...200_000).contains(tracers), casingMass >= 0,
            casingMass.isFinite, count == 0 || casingMass > 0, gurneyVelocity > 0, fragmentDensity > 0,
            spread >= 0, spread <= .pi / 2, simd_length(axis) > 0, tracers == 0 || tracerRegion != nil,
            (wallThickness == nil) == (innerDiameter == nil), (wallThickness ?? 1) > 0,
            (innerDiameter ?? 1) > 0,
            (0.2...2).contains(massExponent), (mottCoefficient ?? 1) > 0,
            explosive.map({ FragmentExplosive.named($0) != nil }) ?? true
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "The fragment description is out of range or incomplete."
                ])
        }
    }

    /// The fragments' launch speed for a charge of `chargeMass`, by the Gurney equation for the
    /// casing's shape.
    public func launchSpeed(chargeMass: Float) -> Float {
        guard chargeMass > 0, casingMass > 0 else { return 0 }
        let ratio = casingMass / chargeMass
        return gurneyVelocity / sqrt(ratio + (casing == .sphere ? 0.6 : 0.5))
    }
}

/// Explosives whose casing fragments Cooper tabulates both ways: √(2E), the Gurney velocity (his
/// Table 27.1, measured: Composition B's seven the mean, TNT's three the middle one, which
/// BombCAD has always used), and Mott's B for mild steel cylinders
/// (Table 27.2). P. W. Cooper, *Explosives Engineering*, Wiley-VCH, 1996, pp. 388 and 397.
public struct FragmentExplosive: Sendable, Equatable {
    public var name: String
    /// m/s.
    public var gurneyVelocity: Float
    /// lb^½ in^(−7/6).
    public var mottCoefficient: Float

    public static let all: [FragmentExplosive] = [
        FragmentExplosive(name: "TNT", gurneyVelocity: 2440, mottCoefficient: 0.0779),
        FragmentExplosive(name: "Composition B", gurneyVelocity: 2720, mottCoefficient: 0.0554),
        FragmentExplosive(name: "Composition A-3", gurneyVelocity: 2630, mottCoefficient: 0.0549),
        FragmentExplosive(name: "Cyclotol (75/25)", gurneyVelocity: 2790, mottCoefficient: 0.0493),
        FragmentExplosive(name: "H-6", gurneyVelocity: 2580, mottCoefficient: 0.0690),
        FragmentExplosive(name: "Tetryl", gurneyVelocity: 2500, mottCoefficient: 0.0681),
    ]

    public static var names: [String] { all.map(\.name) }

    /// The explosive of that name, ignoring case.
    public static func named(_ name: String) -> FragmentExplosive? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct FragmentImpact: Codable, Sendable, Equatable {
    public var fragment: Int
    public var time: Double
    public var position: SIMD3<Float>
    public var speed: Float
    public var energy: Float
    /// `ground`, `block <n>` or `structure`.
    public var surface: String
    /// Owner of an impacted structure in a multiple-body scene, or the envelope building struck;
    /// absent in legacy results.
    public var objectID: UUID? = nil
    /// How many real fragments it stands for, when not one (see `FragmentSpec.wallThickness`).
    public var weight: Float? = nil
    /// What it did to what it struck, where the scene says what that is (`FragmentTarget`).
    public var penetration: PenetrationResult? = nil
    /// The pane struck, by its index among its envelope's panes.
    public var pane: Int? = nil

    /// One unless it stands for several.
    public var count: Float { weight ?? 1 }
}

/// What fragments need of a scene: the charge, the domain, and what they can hit.
public struct FragmentScene: Codable, Sendable, Equatable {
    public var charge: Charge
    public var domain: SIMD3<Float>
    public var blocks: [Box]
    /// The structure's outline as it starts; fragments do not see it move.
    public var structure: [Box]
    /// One owner per starting structural region. Absent for legacy and single-body scenes.
    public var structureOwners: [UUID]?
    /// The material's name of each starting structural region, for the surfaces' heating.
    public var structureMaterials: [String]?
    /// The ground's shape; nil for flat ground (and for scenes saved before terrain).
    public var terrain: Terrain?
    /// What each block and structural region is, for fragments striking it; nil entries (and
    /// scenes saved before) are rigid, unjudged.
    public var blockTargets: [FragmentTarget?]?
    public var structureTargets: [FragmentTarget?]?

    public init(_ scenario: Scenario) {
        charge = scenario.charge
        domain = scenario.domainSize
        blocks = scenario.rigidBoxes
        let bodies = scenario.structuralObjects.sorted { $0.id.uuidString < $1.id.uuidString }
        structure = bodies.flatMap { $0.structure!.solids }
        structureMaterials = bodies.flatMap { body in
            body.structure!.solids.indices.map { body.structure!.material(of: $0).name }
        }
        structureOwners =
            bodies.count > 1
            ? bodies.flatMap { body in body.structure!.solids.map { _ in body.id } } : nil
        terrain = scenario.terrain
        structureTargets = bodies.flatMap { body in
            body.structure!.solids.indices.map { FragmentTarget(body.structure!.material(of: $0)) }
        }
        // The scenario's rigid boxes are its own, then each envelope's blocks, then imports'.
        var targets: [FragmentTarget?] = Array(repeating: nil, count: scenario.boxes.count)
        for object in scenario.envelopeObjects {
            let envelope = object.envelope!
            let construction = scenario.envelopeConstruction(for: object.id)
            for (block, source) in zip(envelope.blocks, envelope.blockSources) {
                switch source {
                case .pane(let index):
                    targets.append(
                        FragmentTarget(
                            material: .glass, thickness: construction.glassThicknessM, owner: object.id,
                            pane: index))
                case .solid:
                    let roof = block.size.z < min(block.size.x, block.size.y)
                    let kind = roof ? construction.roof : construction.walls
                    targets.append(
                        FragmentTarget(
                            material: kind == .reinforcedConcrete ? .concrete : .masonry,
                            thickness: roof ? construction.roofThicknessM : construction.wallThicknessM,
                            strength: kind == .reinforcedConcrete
                                ? StructureMaterial.reinforcedConcrete.compressiveStrength
                                : StructureMaterial.masonry.compressiveStrength, owner: object.id))
                }
            }
        }
        blockTargets = targets.contains { $0 != nil } ? targets : nil
    }

    /// The ground's height under `point`: the terrain's, or the floor's.
    public func groundHeight(at point: SIMD3<Float>) -> Float { terrain?.height(at: point) ?? 0 }
}

public struct FragmentCloud: Sendable {
    public struct Particle: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var velocity: SIMD3<Float>
        /// Zero for a tracer.
        public var mass: Float
        /// Mean presented area, m².
        public var area: Float
        public var landed = false
        /// How many real fragments it stands for: one, unless a casing's dimensions set their
        /// number (`FragmentSpec.wallThickness`).
        public var weight: Float = 1

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            position: SIMD3<Float>,
            velocity: SIMD3<Float>,
            mass: Float,
            area: Float,
            landed: Bool = false,
            weight: Float = 1
        ) {
            self.position = position
            self.velocity = velocity
            self.mass = mass
            self.area = area
            self.landed = landed
            self.weight = weight
        }
    }

    public private(set) var particles: [Particle]
    public private(set) var impacts: [FragmentImpact] = []
    /// Hazardous fragments crossing spheres round `centre` near the horizontal, as they fly.
    public private(set) var crossings = FragmentCrossings()
    /// Where the spheres are centred: the charge.
    package let centre: SIMD3<Float>
    /// Each particle's next sphere to cross, by index in `crossings.radii`.
    private var nextSphere: [Int] = []
    public private(set) var time: Double = 0
    /// Samples taken inside the domain but outside the air given: the slice was too small.
    public private(set) var misses = 0
    /// Particles whose flight became non-finite, taken out of it.
    public private(set) var lost = 0
    public let launchSpeed: Float
    package let blocks: [Box]
    package let structure: [Box]
    let structureOwners: [UUID]?
    let blockTargets: [FragmentTarget?]
    let structureTargets: [FragmentTarget?]
    package let terrain: Terrain?
    package let gravity = SIMD3<Float>(0, 0, -9.81)

    public var fragmentCount: Int { particles.lazy.filter { $0.mass > 0 }.count }
    public var airborne: Int { particles.lazy.filter { !$0.landed }.count }

    public init(spec: FragmentSpec, scenario: Scenario) {
        self.init(spec: spec, scene: FragmentScene(scenario))
    }

    public init(spec: FragmentSpec, scene: FragmentScene) {
        var random = SplitMix(seed: spec.seed)
        let charge = scene.charge
        let speed = spec.launchSpeed(chargeMass: charge.mass)
        launchSpeed = speed
        centre = charge.position
        blocks = scene.blocks
        structure = scene.structure
        structureOwners = scene.structureOwners?.count == scene.structure.count ? scene.structureOwners : nil
        blockTargets = scene.blockTargets ?? []
        structureTargets = scene.structureTargets ?? []
        terrain = scene.terrain
        crossings.chargeHeight = charge.position.z - (scene.terrain?.height(at: charge.position) ?? 0)
        var particles: [Particle] = []
        // P(mass > m) = exp(-(m/μ)^β), whose mean is μ Γ(1 + 1/β): 2μ for Mott's β = ½. The mean
        // is Mott's scaling's with a casing's dimensions, and each fragment flown then stands for
        // as many as share the casing's mass; without, the fragments are `count` and share it.
        let beta = spec.massExponent
        let mean = spec.mottMeanMass ?? (spec.count > 0 ? spec.casingMass / Float(spec.count) : 0)
        // Mott's without a casing's dimensions as it always was, to the last bit.
        let mu =
            spec.mottMeanMass == nil && beta == 0.5
            ? (spec.count > 0 ? spec.casingMass / Float(2 * spec.count) : 0)
            : mean / Float(tgamma(1 + 1 / Double(beta)))
        let masses = (0..<spec.count).map { _ in
            beta == 0.5
                ? mu * pow(log(max(random.unit(), 1e-12)), 2)
                : mu * pow(-log(max(random.unit(), 1e-12)), 1 / beta)
        }
        let total = max(masses.reduce(0, +), .leastNormalMagnitude)
        let scale = spec.mottMeanMass == nil ? spec.casingMass / total : 1
        let weight = spec.mottMeanMass == nil ? 1 : spec.casingMass / total
        let radius = cbrt(3 * charge.mass / (4 * .pi * 1630))
        let axis = simd_normalize(spec.axis)
        let side = simd_normalize(
            abs(axis.z) < 0.9 ? simd_cross(axis, SIMD3(0, 0, 1)) : simd_cross(axis, SIMD3(1, 0, 0)))
        let other = simd_cross(axis, side)
        for drawn in masses {
            let mass = drawn * scale
            let direction: SIMD3<Float>
            switch spec.casing {
            case .sphere:
                let z = 2 * random.unit() - 1
                let phi = 2 * Float.pi * random.unit()
                let r = sqrt(max(0, 1 - z * z))
                direction = SIMD3(r * cos(phi), r * sin(phi), z)
            case .cylinder:
                let phi = 2 * Float.pi * random.unit()
                let elevation = spec.spread * (2 * random.unit() - 1)
                direction = cos(elevation) * (cos(phi) * side + sin(phi) * other) + sin(elevation) * axis
            }
            // A tumbling cube's mean presented area is a quarter of its surface.
            let edge = cbrt(mass / spec.fragmentDensity)
            particles.append(
                Particle(
                    position: charge.position + radius * direction, velocity: speed * direction, mass: mass,
                    area: 1.5 * edge * edge, weight: weight))
        }
        if let region = spec.tracerRegion, spec.tracers > 0 {
            for _ in 0..<spec.tracers {
                let p = region.min + SIMD3(random.unit(), random.unit(), random.unit()) * region.size
                particles.append(Particle(position: p, velocity: .zero, mass: 0, area: 0))
            }
        }
        self.particles = particles
    }

    /// Particles placed directly, for tests.
    package init(
        particles: [Particle], blocks: [Box] = [], structure: [Box] = [], structureOwners: [UUID]? = nil,
        terrain: Terrain? = nil, blockTargets: [FragmentTarget?] = [],
        structureTargets: [FragmentTarget?] = [], centre: SIMD3<Float> = .zero
    ) {
        self.centre = centre
        self.particles = particles
        launchSpeed = 0
        self.blocks = blocks
        self.structure = structure
        self.structureOwners = structureOwners?.count == structure.count ? structureOwners : nil
        self.blockTargets = blockTargets
        self.structureTargets = structureTargets
        self.terrain = terrain
        crossings.chargeHeight = centre.z - (terrain?.height(at: centre) ?? 0)
    }

    /// The box a consumer needs air over to carry every airborne particle `ahead` seconds on,
    /// and the fastest of them.
    public func region(ahead: Double, slowest: Float = 0) -> (box: Box, speed: Float)? {
        let moving = particles.filter { !$0.landed }
        guard let first = moving.first else { return nil }
        var low = first.position
        var high = first.position
        var speed = slowest
        for particle in moving {
            low = simd_min(low, particle.position)
            high = simd_max(high, particle.position)
            speed = max(speed, simd_length(particle.velocity))
        }
        let margin = speed * Float(ahead)
        return (Box(min: low - margin, max: high + margin), speed)
    }

    /// Moves every airborne particle from `a.time` to `b.time` through the air between the two.
    public mutating func advance(from a: AirSlice, to b: AirSlice) {
        let end = b.time
        for index in particles.indices where !particles[index].landed {
            var particle = particles[index]
            var t = time
            while t < end - 1e-12 {
                let air = sample(particle.position, t, a, b)
                var dt = end - t
                let speed = simd_length(particle.velocity)
                if speed > 0 { dt = min(dt, Double(0.5 * a.cellSize / speed)) }
                if particle.mass > 0 {
                    // Drag is integrated exactly for a rate held over the step, so the step need
                    // only follow the rate's own change, not its stiffness.
                    let drag = dragRate(particle, air)
                    if drag > 0 { dt = min(dt, max(Double(0.5 / drag), 1e-5)) }
                    // Nor may gravity change its speed by more than a twentieth in a step: a slow
                    // piece (debris falling off a wall) would otherwise land at the speed a step of
                    // seconds ends with.
                    dt = min(dt, Double(0.05 * max(speed, 1) / 9.81))
                }
                dt = max(dt, 1e-7)
                let start = particle.position
                if particle.mass > 0 {
                    // Half a step to find the drag at the midpoint, then the whole step with it.
                    let middle = particle.position + particle.velocity * Float(dt / 2)
                    let airMiddle = sample(middle, t + dt / 2, a, b)
                    var halfway = particle
                    halfway.position = middle
                    halfway.velocity = relax(particle.velocity, air, dragRate(particle, air), dt / 2)
                    let velocity = relax(particle.velocity, airMiddle, dragRate(halfway, airMiddle), dt)
                    particle.position += (particle.velocity + velocity) * Float(dt / 2)
                    particle.velocity = velocity
                } else {
                    // A tracer goes with the air, by the midpoint rule.
                    let middle = particle.position + air.velocity * Float(dt / 2)
                    particle.velocity = sample(middle, t + dt / 2, a, b).velocity
                    particle.position += particle.velocity * Float(dt)
                }
                t += dt
                guard particle.position.x.isFinite, particle.position.y.isFinite,
                    particle.position.z.isFinite,
                    particle.velocity.x.isFinite, particle.velocity.y.isFinite, particle.velocity.z.isFinite
                else {
                    // Lost to the numerics: left where it was, out of the flight.
                    particle.position = start
                    particle.velocity = .zero
                    particle.landed = true
                    lost += 1
                    break
                }
                let struck = hit(from: start, to: particle.position)
                if particle.mass > 0 { cross(index, to: struck?.point ?? particle.position, particle) }
                if let hit = struck {
                    particle.position = hit.point
                    particle.landed = true
                    if particle.mass > 0 {
                        let speed = simd_length(particle.velocity)
                        let struck = penetration(particle, at: hit.point, struck: hit.struck)
                        impacts.append(
                            FragmentImpact(
                                fragment: index, time: t, position: hit.point, speed: speed,
                                energy: 0.5 * particle.mass * speed * speed, surface: hit.surface,
                                objectID: hit.objectID ?? struck?.target.owner,
                                weight: particle.weight == 1 ? nil : particle.weight,
                                penetration: struck?.result,
                                pane: struck?.target.pane))
                    }
                    particle.velocity = .zero
                    break
                }
            }
            particles[index] = particle
        }
        time = end
    }

    private mutating func sample(_ point: SIMD3<Float>, _ time: Double, _ a: AirSlice, _ b: AirSlice)
        -> Primitive
    {
        if let air = AirSlice.sample(point, time: time, between: a, and: b) { return air }
        misses += 1
        return a.ambient
    }

    /// The velocity after `dt` of gravity and of drag at `rate` towards the air's velocity:
    /// exact for a rate held over the step, and stable however stiff.
    private func relax(_ velocity: SIMD3<Float>, _ air: Primitive, _ rate: Float, _ dt: Double) -> SIMD3<
        Float
    > {
        let x = Double(rate) * dt
        // (1 - e^-x) / x, without losing it as x goes to 0.
        let share = x < 1e-6 ? 1 - x / 2 : -expm1(-x) / x
        return velocity + (air.velocity - velocity) * Float(x * share) + gravity * Float(dt * share)
    }

    /// The inverse of a particle's drag time, 1/s.
    private func dragRate(_ particle: Particle, _ air: Primitive) -> Float {
        let relative = simd_length(air.velocity - particle.velocity)
        return air.density * dragCoefficient(particle, air) * particle.area * relative / (2 * particle.mass)
    }

    /// A chunk's drag coefficient by its Mach number in the air around it.
    private func dragCoefficient(_ particle: Particle, _ air: Primitive) -> Float {
        let sound = sqrt(max(1.4 * air.pressure / max(air.density, 1e-3), 1))
        return Self.dragCoefficient(mach: simd_length(air.velocity - particle.velocity) / sound)
    }

    /// The drag coefficient of a tumbling fragment, on its mean presented area, by Mach number, as
    /// Hansche and Rinehart measured tumbling cubes from Mach 0.5 to 3.5 (as Moxnes et al., Defence
    /// Technology 13, 2017, restate them): 0.82 at Mach 0.5, held below; rising to 1.25 at Mach 1.25;
    /// falling to 1.1 at Mach 3, and 1.1 beyond.
    public static func dragCoefficient(mach: Float) -> Float {
        if mach <= 0.5 { return 0.82 }
        if mach <= 1.25 { return 0.82 + (1.25 - 0.82) * (mach - 0.5) / 0.75 }
        if mach <= 3 { return 1.25 - 0.15 * (mach - 1.25) / 1.75 }
        return 1.1
    }

    /// Flies every fragment still airborne on through the still `air` until it lands or `limit`
    /// seconds have passed: after the blast's last frame, so that each fragment's range, and its
    /// energy where it lands, are its whole flight's. Tracers stay where they are.
    public mutating func land(in air: Primitive, limit: Double = 300) {
        let still = AirSlice.still(air, time: time)
        var later = still
        later.time = time + limit
        // Tracers are held where they are, then given back their own state.
        let tracers = particles.indices.filter { particles[$0].mass <= 0 }
        let held = tracers.map { particles[$0].landed }
        for index in tracers { particles[index].landed = true }
        advance(from: still, to: later)
        for (index, landed) in zip(tracers, held) { particles[index].landed = landed }
    }

    private func acceleration(_ particle: Particle, _ air: Primitive) -> SIMD3<Float> {
        guard particle.mass > 0 else { return .zero }
        let relative = air.velocity - particle.velocity
        return gravity + dragRate(particle, air) * relative
    }

    /// Where a straight step first meets the ground (the terrain's surface, where there is one), a
    /// block or the structure. A step that crosses a ridge and comes down beyond it within one step
    /// passes through it: steps are short against any hill.
    private func hit(from start: SIMD3<Float>, to end: SIMD3<Float>) -> (
        point: SIMD3<Float>, surface: String, objectID: UUID?, struck: Struck?
    )? {
        var best: (fraction: Float, surface: String, objectID: UUID?, struck: Struck?)?
        if let terrain {
            // Above the surface at the start and on or below it at the end: where between, by
            // bisection on the height above it, which the bilinear surface makes continuous.
            func clearance(_ f: Float) -> Float {
                let p = start + (end - start) * f
                return p.z - terrain.height(at: p)
            }
            if clearance(1) <= 0 {
                if clearance(0) > 0 {
                    var (low, high): (Float, Float) = (0, 1)
                    for _ in 0..<24 {
                        let middle = 0.5 * (low + high)
                        if clearance(middle) > 0 { low = middle } else { high = middle }
                    }
                    best = (high, "ground", nil, nil)
                } else {
                    best = (0, "ground", nil, nil)
                }
            }
        } else if end.z <= 0, start.z > 0 {
            best = (start.z / (start.z - end.z), "ground", nil, nil)
        } else if end.z <= 0 {
            best = (0, "ground", nil, nil)
        }
        for (n, box) in blocks.enumerated() {
            if let f = Self.entry(start, end, box), f < (best?.fraction ?? .infinity) {
                best = (f, "block \(n)", nil, .block(n))
            }
        }
        for (index, box) in structure.enumerated() {
            if let f = Self.entry(start, end, box), f < (best?.fraction ?? .infinity) {
                best = (f, "structure", structureOwners?[index], .structure(index))
            }
        }
        guard let best else { return nil }
        return (start + (end - start) * best.fraction, best.surface, best.objectID, best.struck)
    }

    /// Counts the spheres `particle` has crossed on its way to `point`, if hazardous and near the
    /// horizontal there (`FragmentCrossings`).
    private mutating func cross(_ index: Int, to point: SIMD3<Float>, _ particle: Particle) {
        if nextSphere.count != particles.count {
            nextSphere = particles.map { p in
                let r = simd_distance(p.position, centre)
                return crossings.radii.firstIndex { $0 > r } ?? crossings.radii.count
            }
        }
        let offset = point - centre
        let r = simd_length(offset)
        var next = nextSphere[index]
        guard next < crossings.radii.count, r >= crossings.radii[next] else { return }
        let speed = simd_length(particle.velocity)
        let hazardous = 0.5 * particle.mass * speed * speed >= HazardCriteria.hazardousEnergyJ
        let level = abs(asin(max(min(offset.z / max(r, 1e-6), 1), -1))) <= crossings.band
        let sector = FragmentCrossings.sector(of: SIMD2(offset.x, offset.y), sectors: crossings.sectors)
        while next < crossings.radii.count, r >= crossings.radii[next] {
            if hazardous, level {
                crossings.counts[next * crossings.sectors + sector] += particle.weight
                crossings.samples[next * crossings.sectors + sector] += 1
            }
            next += 1
        }
        nextSphere[index] = next
    }

    /// A block or structural region struck, by index.
    enum Struck {
        case block(Int)
        case structure(Int)
    }

    /// What `particle` does to what it struck at `point`, if the scene says what that is: its
    /// depth is the box's across the face struck (or the target's own thickness), the face the
    /// one `point` lies on.
    private func penetration(_ particle: Particle, at point: SIMD3<Float>, struck: Struck?) -> (
        result: PenetrationResult, target: FragmentTarget
    )? {
        let found: (FragmentTarget?, Box)? =
            switch struck {
            case .block(let n):
                n < blocks.count ? (n < blockTargets.count ? blockTargets[n] : nil, blocks[n]) : nil
            case .structure(let n):
                n < structure.count
                    ? (n < structureTargets.count ? structureTargets[n] : nil, structure[n]) : nil
            case nil: nil
            }
        guard let (target, box) = found, let target else { return nil }
        // The face struck: the one `point` is nearest.
        var axis = 0
        var nearest = Float.infinity
        for a in 0..<3 {
            let distance = min(abs(point[a] - box.min[a]), abs(point[a] - box.max[a]))
            if distance < nearest {
                nearest = distance
                axis = a
            }
        }
        let speed = simd_length(particle.velocity)
        let cosine = speed > 0 ? abs(particle.velocity[axis]) / speed : 1
        var result = target.assess(
            mass: particle.mass, area: particle.area, speed: speed,
            thickness: target.thickness ?? box.size[axis],
            obliquity: acos(min(cosine, 1)))
        if result.outcome == .perforated { result.holeAreaM2 = particle.area }
        return (result, target)
    }

    /// The fraction of the way from `start` to `end` where the segment enters `box`, if it does.
    package static func entry(_ start: SIMD3<Float>, _ end: SIMD3<Float>, _ box: Box) -> Float? {
        let direction = end - start
        // A stationary particle inside closed bounds is already touching the outline.
        // A zero direction does not define a ray in the shared geometry contract.
        if direction == .zero {
            return all(start .>= box.min) && all(start .<= box.max) ? 0 : nil
        }
        return box.intersection(
            origin: start, direction: direction, parameters: 0...1,
            parallelTolerance: Float(1e-12).nextDown)?.lowerBound
    }
}

/// A small, fast, reproducible random generator (SplitMix64).
package struct SplitMix {
    package var state: UInt64

    init(seed: UInt64) { state = seed }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1].
    package mutating func unit() -> Float { Float((next() >> 40) + 1) / Float(1 << 24) }
}
