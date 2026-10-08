import Foundation
import simd

/// The energy that reaches each receiver after at least one diffuse (scattered) reflection, or after
/// more specular reflections than the image sources cover, by tracing rays from the source.
///
/// At every reflection a ray loses `alpha` of its energy; of the rest, a fraction `s` leaves in a
/// Lambert (cosine) distribution and `1 - s` specularly. Paths that never scatter are the image
/// sources' job, so a ray deposits energy only once it has scattered, and each kind of path is counted
/// once. The reflection is chosen at random with probability `p` (the surface's mean scattering), and
/// per-band weights `s/p` or `(1 - s)/(1 - p)` keep every band's expectation exact.
///
/// Receivers are spheres, sized with the room, weighted by their microphone's squared gain towards
/// where each ray comes from. A ray crossing one deposits its energy times the chord length over the
/// sphere's volume inside the room, scaled so a free-field source gives `1/r²`: the same units as the
/// square of an image source's gain.
struct DiffuseRayTracer {
    let room: ShoeboxRoom
    let source: SIMD3<Double>
    let atmosphere: Atmosphere
    let airAbsorption: Bool
    let rayCount: Int
    let seed: UInt64
    /// Specular paths with more reflections than this are beyond the image sources, so rays carry them
    /// too; by default rays carry only scattered energy.
    var specularOrderLimit = Int.max
    /// Open areas; a ray reaching one leaves the room.
    var openings: [Opening] = []
    /// In a room with a floor plan, specular paths with more wall reflections than this are beyond the
    /// image sources too.
    var specularWallLimit = Int.max

    /// Width of the energy histogram's bins, in seconds.
    static let binWidth = 0.001
    /// Radius of the detection sphere around each receiver, in metres: a tenth of the room's cube-root
    /// volume, between 0.3 and 1.5 m. Larger rooms need larger spheres for enough rays to cross them;
    /// the blur this adds, up to 4 ms, is small beside their reverberation.
    var receiverRadius: Double { min(max(0.1 * cbrt(room.volume), 0.3), 1.5) }

    /// Detector crossings per millisecond to aim for.
    static let targetCrossings = 50.0

    /// Rays actually traced: enough that about `targetCrossings` cross each receiver per millisecond,
    /// at least 5,000 and at most `rayCount`. A ray crosses a sphere of radius R about c π R² / V
    /// times a second, so small rooms need far fewer rays than large ones.
    var tracedRays: Int {
        let crossingsPerRay =
            atmosphere.soundSpeed * Double.pi * receiverRadius * receiverRadius / room.volume
        let needed = Int((Self.targetCrossings / (crossingsPerRay * Self.binWidth)).rounded(.up))
        return min(rayCount, max(5_000, needed))
    }

    /// Scattered energy per receiver, per octave band, per bin. Empty bins are zero. Returns early with
    /// what has been traced if `stop` returns true.
    /// Rays are traced in this many chunks, in parallel.
    static let chunks = 16

    func trace(
        receivers: [(position: SIMD3<Double>, microphone: Microphone)], duration: Double,
        stop: @Sendable () -> Bool = { false }, progress: GenerationProgress? = nil
    ) -> [[[Double]]] {
        let bands = OctaveBands.count
        let bins = Int((duration / Self.binWidth).rounded(.up))
        var energy = Array(
            repeating: Array(repeating: [Double](repeating: 0, count: bins), count: bands),
            count: receivers.count)
        guard
            rayCount > 0,
            room.scatters || specularOrderLimit < Int.max || specularWallLimit < Int.max || !openings.isEmpty,
            !stop()
        else {
            return energy
        }
        let rayCount = tracedRays

        let c = atmosphere.soundSpeed
        let reach = duration * c
        let radius = receiverRadius
        let volumes = receivers.map { insideVolume(of: $0.position, radius: radius) }
        // Energy decay by air per metre, for intensity.
        let air =
            airAbsorption
            ? OctaveBands.centres.map { 2 * atmosphere.amplitudeAttenuationPerMetre(frequency: $0) }
            : Array(repeating: 0, count: bands)
        let materials = Surface.allCases.map { room[$0] }
        let openingsBySurface = Surface.allCases.map { surface in
            openings.filter { $0.surface == surface && $0.wall == nil }
        }
        let plan = room.plan
        let mesh = room.mesh.map(MeshGeometry.of)
        let meshMaterials = room.mesh.map { mesh in mesh.faces.indices.map { mesh.material(of: $0) } }
        let openingsByWall = plan.map { plan in
            plan.corners.indices.map { wall in openings.filter { $0.wall == wall } }
        }
        var random = SplitMix(seed: seed)
        let rotation = randomRotation(&random)
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let chunks = Self.chunks

        // A fixed number of chunks, each with its own random stream, merged in order: the result does not
        // depend on how many cores share the work.
        func traceChunk(_ chunk: Int) -> [[[Double]]] {
            var energy = Array(
                repeating: Array(repeating: [Double](repeating: 0, count: bins), count: bands),
                count: receivers.count)
            var random = SplitMix(seed: seed &+ UInt64(chunk + 1) &* 0x9E37_79B9_7F4A_7C15)
            var weights = [Double](repeating: 0, count: bands)
            let range = (chunk * rayCount / chunks)..<((chunk + 1) * rayCount / chunks)
            for ray in range {
                if ray % 256 == 0, stop() { break }
                // Evenly spread directions (a spherical Fibonacci lattice), randomly rotated.
                let z = 1 - 2 * (Double(ray) + 0.5) / Double(rayCount)
                let ring = (1 - z * z).squareRoot()
                var direction =
                    rotation * SIMD3(ring * cos(golden * Double(ray)), ring * sin(golden * Double(ray)), z)
                var position = source
                var travelled = 0.0
                var scattered = false
                var reflections = 0
                var wallReflections = 0
                // The plan wall or mesh face last reflected from, which the ray cannot meet again straight
                // away.
                var lastWall = -1
                for b in 0..<bands { weights[b] = 1 / Double(rayCount) }

                while travelled < reach {
                    // The nearest boundary along the ray: a box face, or a plan wall, floor or ceiling.
                    var hit = Double.infinity
                    var axis = 0
                    var planWall = -1
                    var meshFace = -1
                    if let mesh {
                        // A ray that slips through a seam between faces has left the room.
                        guard
                            let found = mesh.nearestHit(
                                origin: position, direction: direction, excluding: lastWall)
                        else { break }
                        hit = found.t
                        meshFace = found.face
                    } else if let plan {
                        if direction.z != 0 {
                            hit = max(0, ((direction.z > 0 ? room.size.z : 0) - position.z) / direction.z)
                            axis = 2
                        }
                        let flat = SIMD2(position.x, position.y)
                        let heading = SIMD2(direction.x, direction.y)
                        if heading != .zero {
                            for wall in plan.corners.indices where wall != lastWall {
                                if let t = raySegment(flat, heading, plan.start(wall), plan.end(wall)),
                                    t < hit
                                {
                                    hit = t
                                    planWall = wall
                                }
                            }
                        }
                    } else {
                        for a in 0..<3 where direction[a] != 0 {
                            let wall = direction[a] > 0 ? room.size[a] : 0
                            let t = (wall - position[a]) / direction[a]
                            if t < hit {
                                hit = max(0, t)
                                axis = a
                            }
                        }
                    }
                    let segment = min(hit, reach - travelled)
                    if scattered || reflections > specularOrderLimit || wallReflections > specularWallLimit {
                        for (r, (receiver, microphone)) in receivers.enumerated() {
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
                            var scale = 4 * Double.pi * (leave - enter) / volumes[r]
                            if !microphone.isOmni {
                                // Squared gain towards where the ray comes from.
                                let gain = microphone.gain(from: -direction)
                                scale *= gain * gain
                            }
                            for band in 0..<bands {
                                energy[r][band][bin] += weights[band] * scale * exp(-air[band] * distance)
                            }
                        }
                    }
                    travelled += segment
                    guard segment == hit else { break }
                    position += direction * hit
                    reflections += 1
                    if let mesh, meshFace >= 0 {
                        // A mesh face: out if it is open, otherwise reflected about its normal.
                        if mesh.faces[meshFace].open { break }
                        let normal = mesh.faces[meshFace].normal
                        let diffuse = reflect(
                            material: meshMaterials![meshFace], weights: &weights, random: &random)
                        if diffuse {
                            scattered = true
                            direction = lambert(aroundAny: normal, &random)
                        } else {
                            direction -= 2 * simd_dot(direction, normal) * normal
                        }
                        lastWall = meshFace
                        if (weights.max() ?? 0) * Double(rayCount) < 1e-15 { break }
                        continue
                    }
                    if let plan, planWall >= 0 {
                        // A plan wall: out through an opening, or reflected about the wall's normal.
                        let start = plan.start(planWall)
                        let along = simd_dot(
                            SIMD2(position.x, position.y) - start, simd_normalize(plan.end(planWall) - start))
                        if openingsByWall![planWall].contains(where: { $0.contains([along, position.z]) }) {
                            break
                        }
                        let material = plan.walls[planWall]
                        let flatNormal = plan.inwardNormal(planWall)
                        let normal = SIMD3(flatNormal.x, flatNormal.y, 0)
                        let diffuse = reflect(material: material, weights: &weights, random: &random)
                        if diffuse {
                            scattered = true
                            direction = lambert(aroundAny: normal, &random)
                        } else {
                            direction -= 2 * simd_dot(direction, normal) * normal
                        }
                        wallReflections += 1
                        lastWall = planWall
                        if (weights.max() ?? 0) * Double(rayCount) < 1e-15 { break }
                        continue
                    }
                    lastWall = -1
                    // Keep exactly on the wall so the next step starts inside the room.
                    position[axis] = direction[axis] > 0 ? room.size[axis] : 0

                    let surface = 2 * axis + (direction[axis] > 0 ? 1 : 0)
                    if !openingsBySurface[surface].isEmpty {
                        let (a, b) = Surface.allCases[surface].planeAxes
                        let point = SIMD2(position[a], position[b])
                        // Out through the opening.
                        if openingsBySurface[surface].contains(where: { $0.contains(point) }) { break }
                    }
                    let diffuse = reflect(material: materials[surface], weights: &weights, random: &random)
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

        let results = ChunkResults<[[[Double]]]>(count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            results.store(traceChunk(chunk), at: chunk)
            progress?.advance(by: 1 / Double(chunks))
        }
        for part in results.values {
            for r in part.indices {
                for b in part[r].indices {
                    for i in part[r][b].indices { energy[r][b][i] += part[r][b][i] }
                }
            }
        }
        return energy
    }

    /// Absorbs at a reflection and chooses, with importance weights, whether it scatters.
    private func reflect(material: SurfaceMaterial, weights: inout [Double], random: inout SplitMix) -> Bool {
        var mean = 0.0
        for b in weights.indices {
            weights[b] *= 1 - material.absorption[b]
            mean += material.scattering[b]
        }
        mean /= Double(weights.count)
        if mean <= 0 { return false }
        if mean >= 1 { return true }
        let p = min(max(mean, 0.05), 0.95)
        let diffuse = random.nextUnit() < p
        for b in weights.indices {
            weights[b] *= diffuse ? material.scattering[b] / p : (1 - material.scattering[b]) / (1 - p)
        }
        return diffuse
    }

    /// A cosine-weighted direction around any unit normal.
    private func lambert(aroundAny normal: SIMD3<Double>, _ random: inout SplitMix) -> SIMD3<Double> {
        let u = random.nextUnit()
        let angle = 2 * Double.pi * random.nextUnit()
        let sine = u.squareRoot()
        let cosine = (1 - u).squareRoot()
        let helper: SIMD3<Double> = abs(normal.z) < 0.9 ? [0, 0, 1] : [1, 0, 0]
        let t1 = simd_normalize(simd_cross(normal, helper))
        let t2 = simd_cross(normal, t1)
        return t1 * (sine * cos(angle)) + t2 * (sine * sin(angle)) + normal * cosine
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

    /// Volume of the part of a sphere inside the room: exact when the sphere is wholly inside, otherwise
    /// by counting points on a grid.
    func insideVolume(of centre: SIMD3<Double>, radius: Double) -> Double {
        if room.contains(centre) && room.clearance(centre) >= radius {
            return 4 / 3 * Double.pi * radius * radius * radius
        }
        let steps = 48
        var inside = 0
        for i in 0..<steps {
            for j in 0..<steps {
                for k in 0..<steps {
                    let offset = (SIMD3(Double(i), Double(j), Double(k)) + 0.5) / Double(steps) * 2 - 1
                    guard simd_length_squared(offset) <= 1 else { continue }
                    let point = centre + offset * radius
                    if room.contains(point) { inside += 1 }
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

/// Results written by parallel workers, one slot each.
final class ChunkResults<Value>: @unchecked Sendable {
    private var slots: [Value?]
    private let lock = NSLock()

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func store(_ value: Value, at index: Int) {
        lock.withLock { slots[index] = value }
    }

    /// The stored values in slot order.
    var values: [Value] { lock.withLock { slots.compactMap { $0 } } }
}

extension DiffuseRayTracer {
    /// Scattered energy at omni receivers.
    func trace(receivers: [SIMD3<Double>], duration: Double) -> [[[Double]]] {
        trace(receivers: receivers.map { ($0, .omni) }, duration: duration)
    }
}
