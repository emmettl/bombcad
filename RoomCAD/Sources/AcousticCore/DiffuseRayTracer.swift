import Foundation
import simd

/// The energy that reaches each receiver after at least one diffuse (scattered) reflection, by tracing
/// rays from the source.
///
/// At every reflection a ray loses `alpha` of its energy; of the rest, a fraction `s` leaves in a
/// Lambert (cosine) distribution and `1 - s` specularly. Paths that never scatter are the image
/// sources' job, so a ray deposits energy only once it has scattered, and each kind of path is counted
/// once. The reflection is chosen at random with probability `p` (the surface's mean scattering), and
/// per-band weights `s/p` or `(1 - s)/(1 - p)` keep every band's expectation exact.
///
/// Receivers are spheres. A ray crossing one deposits its energy times the chord length over the
/// sphere's volume inside the room, scaled so a free-field source gives `1/r²`: the same units as the
/// square of an image source's gain.
struct DiffuseRayTracer {
    let room: ShoeboxRoom
    let source: SIMD3<Double>
    let atmosphere: Atmosphere
    let airAbsorption: Bool
    let rayCount: Int
    let seed: UInt64

    /// Width of the energy histogram's bins, in seconds.
    static let binWidth = 0.001
    /// Radius of the detection sphere around each receiver, in metres.
    static let receiverRadius = 0.4

    /// Scattered energy per receiver, per octave band, per bin. Empty bins are zero. Returns early with
    /// what has been traced if `stop` returns true.
    func trace(receivers: [SIMD3<Double>], duration: Double, stop: () -> Bool = { false }) -> [[[Double]]] {
        let bands = OctaveBands.count
        let bins = Int((duration / Self.binWidth).rounded(.up))
        var energy = Array(
            repeating: Array(repeating: [Double](repeating: 0, count: bins), count: bands),
            count: receivers.count)
        guard rayCount > 0, room.scatters else { return energy }

        let c = atmosphere.soundSpeed
        let reach = duration * c
        let radius = Self.receiverRadius
        let volumes = receivers.map { insideVolume(of: $0, radius: radius) }
        // Energy decay by air per metre, for intensity.
        let air =
            airAbsorption
            ? OctaveBands.centres.map { 2 * atmosphere.amplitudeAttenuationPerMetre(frequency: $0) }
            : Array(repeating: 0, count: bands)
        let materials = Surface.allCases.map { room[$0] }
        var random = SplitMix(seed: seed)
        let rotation = randomRotation(&random)
        let golden = Double.pi * (3 - 5.0.squareRoot())
        var weights = [Double](repeating: 0, count: bands)

        for ray in 0..<rayCount {
            if ray % 256 == 0, stop() { break }
            // Evenly spread directions (a spherical Fibonacci lattice), randomly rotated.
            let z = 1 - 2 * (Double(ray) + 0.5) / Double(rayCount)
            let ring = (1 - z * z).squareRoot()
            var direction =
                rotation * SIMD3(ring * cos(golden * Double(ray)), ring * sin(golden * Double(ray)), z)
            var position = source
            var travelled = 0.0
            var scattered = false
            for b in 0..<bands { weights[b] = 1 / Double(rayCount) }

            while travelled < reach {
                // The nearest wall along the ray.
                var hit = Double.infinity
                var axis = 0
                for a in 0..<3 where direction[a] != 0 {
                    let wall = direction[a] > 0 ? room.size[a] : 0
                    let t = (wall - position[a]) / direction[a]
                    if t < hit {
                        hit = max(0, t)
                        axis = a
                    }
                }
                let segment = min(hit, reach - travelled)
                if scattered {
                    for (r, receiver) in receivers.enumerated() {
                        // Chord of the segment through the receiver's sphere.
                        let offset = position - receiver
                        let b = simd_dot(offset, direction)
                        let disc = b * b - (simd_length_squared(offset) - radius * radius)
                        guard disc > 0 else { continue }
                        let root = disc.squareRoot()
                        let enter = max(0, -b - root)
                        let leave = min(segment, -b + root)
                        guard leave > enter else { continue }
                        let distance = travelled + (enter + leave) / 2
                        let bin = Int(distance / c / Self.binWidth)
                        guard bin < bins else { continue }
                        let scale = 4 * Double.pi * (leave - enter) / volumes[r]
                        for band in 0..<bands {
                            energy[r][band][bin] += weights[band] * scale * exp(-air[band] * distance)
                        }
                    }
                }
                travelled += segment
                guard segment == hit else { break }
                position += direction * hit
                // Keep exactly on the wall so the next step starts inside the room.
                position[axis] = direction[axis] > 0 ? room.size[axis] : 0

                let surface = 2 * axis + (direction[axis] > 0 ? 1 : 0)
                let material = materials[surface]
                var mean = 0.0
                for b in 0..<bands {
                    weights[b] *= 1 - material.absorption[b]
                    mean += material.scattering[b]
                }
                mean /= Double(bands)
                let diffuse: Bool
                if mean <= 0 {
                    diffuse = false
                } else if mean >= 1 {
                    diffuse = true
                } else {
                    let p = min(max(mean, 0.05), 0.95)
                    diffuse = random.nextUnit() < p
                    for b in 0..<bands {
                        weights[b] *=
                            diffuse ? material.scattering[b] / p : (1 - material.scattering[b]) / (1 - p)
                    }
                }
                var normal = SIMD3<Double>(0, 0, 0)
                normal[axis] = direction[axis] > 0 ? -1 : 1
                if diffuse {
                    scattered = true
                    direction = lambert(around: normal, &random)
                } else {
                    direction[axis] = -direction[axis]
                }
                // Stop once the ray can no longer matter, about 150 dB down.
                if (weights.max() ?? 0) * Double(rayCount) < 1e-15 { break }
            }
        }
        return energy
    }

    /// A direction in the hemisphere around `normal`, cosine weighted.
    private func lambert(around normal: SIMD3<Double>, _ random: inout SplitMix) -> SIMD3<Double> {
        let u = random.nextUnit()
        let angle = 2 * Double.pi * random.nextUnit()
        let sine = u.squareRoot()
        let cosine = (1 - u).squareRoot()
        // Two tangents of the axis-aligned normal.
        let axis = normal.x != 0 ? 0 : normal.y != 0 ? 1 : 2
        var t1 = SIMD3<Double>(0, 0, 0)
        var t2 = SIMD3<Double>(0, 0, 0)
        t1[(axis + 1) % 3] = 1
        t2[(axis + 2) % 3] = 1
        return t1 * (sine * cos(angle)) + t2 * (sine * sin(angle)) + normal * cosine
    }

    /// A uniformly random rotation, from a random unit quaternion.
    private func randomRotation(_ random: inout SplitMix) -> simd_double3x3 {
        let u1 = random.nextUnit()
        let u2 = 2 * Double.pi * random.nextUnit()
        let u3 = 2 * Double.pi * random.nextUnit()
        let q = simd_quatd(
            ix: (1 - u1).squareRoot() * sin(u2), iy: (1 - u1).squareRoot() * cos(u2),
            iz: u1.squareRoot() * sin(u3), r: u1.squareRoot() * cos(u3))
        return simd_double3x3(q)
    }

    /// Volume of the part of a sphere inside the room, by counting points on a grid.
    func insideVolume(of centre: SIMD3<Double>, radius: Double) -> Double {
        let steps = 48
        var inside = 0
        for i in 0..<steps {
            for j in 0..<steps {
                for k in 0..<steps {
                    let offset = (SIMD3(Double(i), Double(j), Double(k)) + 0.5) / Double(steps) * 2 - 1
                    guard simd_length_squared(offset) <= 1 else { continue }
                    let point = centre + offset * radius
                    if all(point .>= 0) && all(point .<= room.size) { inside += 1 }
                }
            }
        }
        let cell = pow(2 * radius / Double(steps), 3)
        return max(Double(inside) * cell, 1e-9)
    }
}

/// Deterministic random numbers, so a response can be reproduced from its seed.
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

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
