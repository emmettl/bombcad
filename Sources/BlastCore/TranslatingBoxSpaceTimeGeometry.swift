import simd

/// Fixed-orientation, constant-translation clipping reference. All feasible intersections
/// of three cell/solid planes supply topology events, including edge/edge crossings.
/// Between events areas are quadratic and first moments/volumes cubic in time, so two
/// Gauss nodes suffice. This supplies geometry, not wet-cell states or a gas integrator.
struct TranslatingBoxSpaceTimeGeometry {
    enum Failure: Error { case illConditionedOrientation }
    struct PatchIntegral {
        let normal: SIMD3<Double>  // Outward from gas, for both open and wall patches.
        var areaTime = 0.0
        /// Integral of (x - fixed cell centre) dA dt, in m³ s.
        var firstMomentTime = SIMD3<Double>.zero
        var timeWeightedArea = 0.0  // Integral of t dA dt, in m² s².
    }
    struct Result {
        let initialGasVolume: Double
        let finalGasVolume: Double
        let gasVolumeTime: Double
        let openFaces: [PatchIntegral]  // -x,+x,-y,+y,-z,+z.
        let walls: [PatchIntegral]  // Body-axis -x,+x,-y,+y,-z,+z, gas normals.
        let eventTimes: [Double]
        let evaluations: Int

        var wallAreaVector: SIMD3<Double> {
            walls.reduce(.zero) { $0 + $1.areaTime * $1.normal }
        }
        var openAreaVector: SIMD3<Double> {
            openFaces.reduce(.zero) { $0 + $1.areaTime * $1.normal }
        }
        /// Pressure impulse per pascal; torque follows the translating centre of mass.
        func pressureAngularImpulse(
            cellCentre: SIMD3<Double>, initialCentreOfMass: SIMD3<Double>, velocity: SIMD3<Double>
        ) -> SIMD3<Double> {
            walls.reduce(.zero) {
                $0
                    + simd_cross(
                        $1.firstMomentTime + (cellCentre - initialCentreOfMass) * $1.areaTime
                            - velocity * $1.timeWeightedArea, $1.normal)
            }
        }
    }
    private struct Basis {
        let indices: [Int]
        let inverse: simd_double3x3
    }
    private let body: RigidBoxBody
    private let velocity: SIMD3<Double>
    private let normals: [SIMD3<Double>]
    private let bases: [Basis]
    private let speeds: [Double]

    init(body: RigidBoxBody, velocity: SIMD3<Double>) throws {
        precondition((0..<3).allSatisfy { velocity[$0].isFinite })
        self.body = body
        self.velocity = velocity
        var normals: [SIMD3<Double>] = []
        for solid in [false, true] {
            for axis in 0..<3 {
                var unit = SIMD3<Double>.zero
                unit[axis] = 1
                if solid { unit = body.orientation.act(unit) }
                normals += [-unit, unit]
            }
        }
        self.normals = normals
        speeds = normals.enumerated().map { $0.offset < 6 ? 0 : simd_dot($0.element, velocity) }
        var bases: [Basis] = []
        for a in 0..<10 {
            for b in (a + 1)..<11 {
                for c in (b + 1)..<12 {
                    let matrix = simd_double3x3(columns: (normals[a], normals[b], normals[c])).transpose
                    let determinant = abs(simd_determinant(matrix))
                    // Exact parallel planes have no isolated intersection. Nearly parallel
                    // triples require a more robust predicate/inverse than this reference.
                    if determinant <= 1e-14 { continue }
                    guard determinant >= 1e-8 else { throw Failure.illConditionedOrientation }
                    bases.append(Basis(indices: [a, b, c], inverse: simd_inverse(matrix)))
                }
            }
        }
        self.bases = bases
    }

    func integrate(lower: SIMD3<Double>, cellSize h: Double, duration: Double) throws -> Result {
        precondition(h.isFinite && h > 0 && duration.isFinite && duration > 0)
        precondition((0..<3).allSatisfy { lower[$0].isFinite })
        let volume = h * h * h
        let reference = lower + SIMD3(repeating: h / 2)
        var faces = normals.prefix(6).map { PatchIntegral(normal: $0) }
        var walls = normals.suffix(6).map { PatchIntegral(normal: -$0) }
        let low = body.corners.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
        let high = body.corners.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
        let sweptLow = simd_min(low, low + duration * velocity)
        let sweptHigh = simd_max(high, high + duration * velocity)
        if (0..<3).contains(where: { sweptHigh[$0] < lower[$0] || sweptLow[$0] > lower[$0] + h }) {
            for side in 0..<6 {
                faces[side].areaTime = h * h * duration
                faces[side].firstMomentTime = faces[side].normal * (h / 2) * faces[side].areaTime
                faces[side].timeWeightedArea = duration / 2 * faces[side].areaTime
            }
            return Result(
                initialGasVolume: volume, finalGasVolume: volume, gasVolumeTime: volume * duration,
                openFaces: faces, walls: walls, eventTimes: [0, duration], evaluations: 0)
        }
        var offsets = [0.0, h, 0, h, 0, h]
        for side in 0..<6 {
            offsets.append(
                simd_dot(normals[side + 6], body.worldPoint(.zero) - lower) + body.size[side / 2] / 2)
        }
        let corners = (0..<8).map { n in
            h * SIMD3<Double>(n & 1 == 0 ? 0 : 1, n & 2 == 0 ? 0 : 1, n & 4 == 0 ? 0 : 1)
        }
        if corners.allSatisfy({ point in
            (6..<12).allSatisfy {
                simd_dot(normals[$0], point) <= min(offsets[$0], offsets[$0] + duration * speeds[$0])
            }
        }) {
            return Result(
                initialGasVolume: 0, finalGasVolume: 0, gasVolumeTime: 0,
                openFaces: faces, walls: walls, eventTimes: [0, duration], evaluations: 0)
        }
        // Local coordinates keep the predicates independent of the world's origin.
        // Events closer than duration * 1e-12 are coalesced; tolerance-scale grazing
        // intervals and near-parallel configurations are not certified by this reference.
        let lengthTolerance = h * 1e-12
        let rateTolerance = max(simd_length(velocity), h / duration) * 1e-12
        var times = [0.0, duration]
        for basis in bases {
            let indices = basis.indices
            let point = basis.inverse * SIMD3(offsets[indices[0]], offsets[indices[1]], offsets[indices[2]])
            let rate = basis.inverse * SIMD3(speeds[indices[0]], speeds[indices[1]], speeds[indices[2]])
            var start = 0.0
            var end = duration
            for side in 0..<12 where !indices.contains(side) {
                let residual = simd_dot(normals[side], point) - offsets[side]
                let derivative = simd_dot(normals[side], rate) - speeds[side]
                if abs(derivative) <= rateTolerance {
                    if residual > lengthTolerance {
                        end = -1
                        break
                    }
                } else {
                    let crossing = -residual / derivative
                    if derivative > 0 { end = min(end, crossing) } else { start = max(start, crossing) }
                }
            }
            if start <= end && end >= 0 && start <= duration {
                times += [max(0, start), min(duration, end)]
            }
        }
        times.sort()
        var events = [0.0]
        for time in times where time > events.last! + duration * 1e-12 && time < duration {
            events.append(time)
        }
        if duration - events.last! <= duration * 1e-12 && events.count > 1 { events.removeLast() }
        events.append(duration)
        func geometry(_ time: Double) -> FractionalBoxGeometry {
            FractionalBoxGeometry(body.translated(by: time * velocity))
        }
        let initial = geometry(0).gasVolume(lower: lower, cellSize: h)
        let final = geometry(duration).gasVolume(lower: lower, cellSize: h)
        var volumeTime = 0.0
        for interval in 0..<(events.count - 1) {
            let midpoint = (events[interval] + events[interval + 1]) / 2
            let weight = (events[interval + 1] - events[interval]) / 2
            for time in [midpoint - weight / sqrt(3.0), midpoint + weight / sqrt(3.0)] {
                let current = geometry(time)
                volumeTime += weight * current.gasVolume(lower: lower, cellSize: h)
                let open = current.openFacePatches(lower: lower, cellSize: h)
                for side in 0..<6 {
                    let area = weight * open[side].area
                    faces[side].areaTime += area
                    faces[side].firstMomentTime += area * (open[side].centroid - reference)
                    faces[side].timeWeightedArea += time * area
                }
                for wall in current.wallPatches(lower: lower, cellSize: h) {
                    let side = (0..<6).max {
                        simd_dot(normals[$0 + 6], wall.normal) < simd_dot(normals[$1 + 6], wall.normal)
                    }!
                    let area = weight * wall.area
                    walls[side].areaTime += area
                    walls[side].firstMomentTime += area * (wall.centroid - reference)
                    walls[side].timeWeightedArea += time * area
                }
            }
        }
        return Result(
            initialGasVolume: initial, finalGasVolume: final, gasVolumeTime: volumeTime,
            openFaces: faces, walls: walls, eventTimes: events, evaluations: 2 * (events.count - 1))
    }
}
