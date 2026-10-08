import Foundation
import simd

/// A cased charge's fragments and a puff of passive tracers, flown through the blast one way: the
/// air pushes them, they do not push back. An illustrative model, not a validated one: masses
/// from Mott's distribution, launch speeds from the Gurney equation, drag on a tumbling chunk,
/// and the impacts it records are where they hit the ground, a rigid block or the structure's
/// starting outline, which they do not load.
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
    /// √(2E), the Gurney velocity of the explosive: 2,440 m/s for TNT.
    public var gurneyVelocity: Float = 2440
    public var fragmentDensity: Float = 7850
    /// Massless tracers released evenly through a box, following the air.
    public var tracers = 0
    public var tracerRegion: Box?
    public var seed: UInt64 = 1

    public init() {}

    /// The fragments' launch speed for a charge of `chargeMass`, by the Gurney equation for the
    /// casing's shape.
    public func launchSpeed(chargeMass: Float) -> Float {
        guard chargeMass > 0, casingMass > 0 else { return 0 }
        let ratio = casingMass / chargeMass
        return gurneyVelocity / sqrt(ratio + (casing == .sphere ? 0.6 : 0.5))
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
    }

    public private(set) var particles: [Particle]
    public private(set) var impacts: [FragmentImpact] = []
    public private(set) var time: Double = 0
    /// Samples taken inside the domain but outside the air given: the slice was too small.
    public private(set) var misses = 0
    public let launchSpeed: Float
    let blocks: [Box]
    let structure: [Box]
    let gravity = SIMD3<Float>(0, 0, -9.81)

    public var fragmentCount: Int { particles.lazy.filter { $0.mass > 0 }.count }
    public var airborne: Int { particles.lazy.filter { !$0.landed }.count }

    public init(spec: FragmentSpec, scenario: Scenario) {
        var random = SplitMix(seed: spec.seed)
        let charge = scenario.charge
        let speed = spec.launchSpeed(chargeMass: charge.mass)
        launchSpeed = speed
        blocks = scenario.rigidBoxes
        structure = scenario.structure?.solids ?? []
        var particles: [Particle] = []
        // Mott: P(mass > m) = exp(-√(m/μ)), whose mean is 2μ; scaled after to the casing's mass.
        let mu = spec.count > 0 ? spec.casingMass / Float(2 * spec.count) : 0
        let masses = (0..<spec.count).map { _ in mu * pow(log(max(random.unit(), 1e-12)), 2) }
        let scale = spec.casingMass / max(masses.reduce(0, +), .leastNormalMagnitude)
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
                    area: 1.5 * edge * edge))
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
    init(particles: [Particle], blocks: [Box] = [], structure: [Box] = []) {
        self.particles = particles
        launchSpeed = 0
        self.blocks = blocks
        self.structure = structure
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
                    let drag = dragRate(particle, air)
                    if drag > 0 { dt = min(dt, Double(0.2 / drag)) }
                }
                dt = max(dt, 1e-7)
                // Midpoint step.
                let a1 = acceleration(particle, air)
                let middle = particle.position + particle.velocity * Float(dt / 2)
                var halfway = particle
                halfway.position = middle
                halfway.velocity = particle.mass > 0 ? particle.velocity + a1 * Float(dt / 2) : air.velocity
                let airMiddle = sample(middle, t + dt / 2, a, b)
                if particle.mass == 0 { halfway.velocity = airMiddle.velocity }
                let a2 = acceleration(halfway, airMiddle)
                let start = particle.position
                particle.position += halfway.velocity * Float(dt)
                particle.velocity =
                    particle.mass > 0 ? particle.velocity + a2 * Float(dt) : airMiddle.velocity
                t += dt
                if let hit = hit(from: start, to: particle.position) {
                    particle.position = hit.point
                    particle.landed = true
                    if particle.mass > 0 {
                        let speed = simd_length(particle.velocity)
                        impacts.append(
                            FragmentImpact(
                                fragment: index, time: t, position: hit.point, speed: speed,
                                energy: 0.5 * particle.mass * speed * speed, surface: hit.surface))
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

    /// The inverse of a particle's drag time, 1/s.
    private func dragRate(_ particle: Particle, _ air: Primitive) -> Float {
        let relative = simd_length(air.velocity - particle.velocity)
        return air.density * dragCoefficient(particle, air) * particle.area * relative / (2 * particle.mass)
    }

    /// A chunk's drag coefficient by its Mach number in the air around it.
    private func dragCoefficient(_ particle: Particle, _ air: Primitive) -> Float {
        let sound = sqrt(max(1.4 * air.pressure / max(air.density, 1e-3), 1))
        let mach = simd_length(air.velocity - particle.velocity) / sound
        if mach < 0.8 { return 0.9 }
        if mach < 1.2 { return 0.9 + (mach - 0.8) * 1.0 }
        return max(1.1, 1.3 - 0.1 * (mach - 1.2))
    }

    private func acceleration(_ particle: Particle, _ air: Primitive) -> SIMD3<Float> {
        guard particle.mass > 0 else { return .zero }
        let relative = air.velocity - particle.velocity
        return gravity + dragRate(particle, air) * relative
    }

    /// Where a straight step first meets the ground, a block or the structure.
    private func hit(from start: SIMD3<Float>, to end: SIMD3<Float>) -> (
        point: SIMD3<Float>, surface: String
    )? {
        var best: (fraction: Float, surface: String)?
        if end.z <= 0, start.z > 0 {
            best = (start.z / (start.z - end.z), "ground")
        } else if end.z <= 0 {
            best = (0, "ground")
        }
        for (n, box) in blocks.enumerated() {
            if let f = entry(start, end, box), f < (best?.fraction ?? .infinity) { best = (f, "block \(n)") }
        }
        for box in structure {
            if let f = entry(start, end, box), f < (best?.fraction ?? .infinity) { best = (f, "structure") }
        }
        guard let best else { return nil }
        return (start + (end - start) * best.fraction, best.surface)
    }

    /// The fraction of the way from `start` to `end` where the segment enters `box`, if it does.
    private func entry(_ start: SIMD3<Float>, _ end: SIMD3<Float>, _ box: Box) -> Float? {
        let direction = end - start
        var near: Float = 0
        var far: Float = 1
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-12 {
                if start[axis] < box.min[axis] || start[axis] > box.max[axis] { return nil }
                continue
            }
            let t1 = (box.min[axis] - start[axis]) / direction[axis]
            let t2 = (box.max[axis] - start[axis]) / direction[axis]
            near = max(near, min(t1, t2))
            far = min(far, max(t1, t2))
            if near > far { return nil }
        }
        return near
    }
}

/// A small, fast, reproducible random generator (SplitMix64).
struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1].
    mutating func unit() -> Float { Float((next() >> 40) + 1) / Float(1 << 24) }
}
