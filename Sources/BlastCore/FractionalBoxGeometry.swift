import simd

/// Double-precision convex clipping reference. This does not change air masks or fluxes.
/// Cell volumes and face areas are geometric measures, not yet a cut-cell solver.
struct FractionalBoxGeometry {
    private struct Plane {
        let normal: SIMD3<Double>
        let offset: Double
        func distance(_ point: SIMD3<Double>) -> Double { simd_dot(normal, point) - offset }
    }
    private let planes: [Plane]
    private let centre: SIMD3<Double>
    private let wallPolygons: [[SIMD3<Double>]]

    struct SurfacePatch {
        let area: Double
        let centroid: SIMD3<Double>
        let normal: SIMD3<Double>
    }
    struct SurfaceNode {
        let point: SIMD3<Double>
        let weight: Double  // Area in square metres.
    }
    struct WallPatch {
        let area: Double
        let centroid: SIMD3<Double>
        let normal: SIMD3<Double>
        fileprivate let vertices: [SIMD3<Double>]

        /// Solid volume swept into a fixed cell per second. Positive means gas volume shrinks.
        /// Centroid evaluation is exact for the affine velocity field of rigid motion.
        func sweptVolumeRate(velocity: (SIMD3<Double>) -> SIMD3<Double>) -> Double {
            area * simd_dot(velocity(centroid), normal)
        }

        /// Positive degree-two triangle rule, exact for quadratic surface polynomials.
        var quadrature: [SurfaceNode] {
            var nodes: [SurfaceNode] = []
            for n in 1..<(vertices.count - 1) {
                let a = vertices[0]
                let b = vertices[n]
                let c = vertices[n + 1]
                let weight = simd_length(simd_cross(b - a, c - a)) / 6
                if weight > 0 {
                    for point in [(4 * a + b + c) / 6, (a + 4 * b + c) / 6, (a + b + 4 * c) / 6] {
                        nodes.append(.init(point: point, weight: weight))
                    }
                }
            }
            return nodes
        }

        /// Work rate delivered to gas. Body pressure work has the opposite sign.
        func gasPressurePower(
            velocity: (SIMD3<Double>) -> SIMD3<Double>, pressure: (SIMD3<Double>) -> Double
        ) -> Double {
            quadrature.reduce(0) {
                $0 + $1.weight * pressure($1.point) * simd_dot(velocity($1.point), normal)
            }
        }

        /// Degree-two triangle quadrature integrates linear pressure force and torque exactly.
        /// For general pressure fields this remains a geometric reference quadrature.
        func pressureLoad(
            about origin: SIMD3<Double>, pressure: (SIMD3<Double>) -> Double
        ) -> (force: SIMD3<Double>, torque: SIMD3<Double>) {
            var force = SIMD3<Double>.zero
            var torque = SIMD3<Double>.zero
            for node in quadrature {
                let applied = -node.weight * pressure(node.point) * normal
                force += applied
                torque += simd_cross(node.point - origin, applied)
            }
            return (force, torque)
        }
    }

    init(_ body: RigidBoxBody) {
        centre = body.worldPoint(.zero)
        var planes: [Plane] = []
        var polygons: [[SIMD3<Double>]] = []
        for axis in 0..<3 {
            var direction = SIMD3<Double>.zero
            direction[axis] = 1
            let normal = body.orientation.act(direction)
            for sign in [-1.0, 1.0] {
                // Points are translated to the box centre before clipping to avoid
                // cancellation when geometry is far from the coordinate origin.
                planes.append(Plane(normal: sign * normal, offset: body.size[axis] / 2))
                var a = SIMD3<Double>.zero
                var b = SIMD3<Double>.zero
                a[(axis + 1) % 3] = body.size[(axis + 1) % 3] / 2
                b[(axis + 2) % 3] = body.size[(axis + 2) % 3] / 2
                a = body.orientation.act(a)
                b = body.orientation.act(b)
                let origin = sign * normal * body.size[axis] / 2
                polygons.append([origin - a - b, origin + a - b, origin + a + b, origin - a + b])
            }
        }
        self.planes = planes
        self.wallPolygons = polygons
    }

    func contains(_ point: SIMD3<Double>) -> Bool {
        planes.allSatisfy { $0.distance(point - centre) <= 0 }
    }

    func solidVolumeFraction(lower: SIMD3<Double>, cellSize h: Double) -> Double {
        precondition(h.isFinite && h > 0)
        let low = lower - centre
        let vertices = (0..<8).map { n in
            low + h * SIMD3<Double>(n & 1 == 0 ? 0 : 1, n & 2 == 0 ? 0 : 1, n & 4 == 0 ? 0 : 1)
        }
        let epsilon = h * 1e-12
        if planes.contains(where: { plane in vertices.allSatisfy { plane.distance($0) > epsilon } }) {
            return 0
        }
        if vertices.allSatisfy({ point in planes.allSatisfy { $0.distance(point) <= 0 } }) { return 1 }
        // Outward-oriented cube faces; clipping retains their winding.
        var faces = [
            [0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6],
        ]
        .map { face in face.map { vertices[$0] } }
        for plane in planes {
            faces = clipped(faces, against: plane, epsilon: epsilon)
            if faces.isEmpty { return 0 }
        }
        let origin = low + SIMD3<Double>(repeating: h / 2)
        var volume = 0.0
        for face in faces {
            for n in 1..<(face.count - 1) {
                volume += simd_dot(face[0] - origin, simd_cross(face[n] - origin, face[n + 1] - origin)) / 6
            }
        }
        return min(1, max(0, volume / (h * h * h)))
    }

    private func clipped(_ input: [[SIMD3<Double>]], against plane: Plane, epsilon: Double) -> [[SIMD3<
        Double
    >]] {
        var faces = input
        var cut: [SIMD3<Double>] = []
        faces = faces.compactMap { face in
            let polygon = clip(face, against: plane, epsilon: epsilon, intersections: &cut)
            return polygon.count >= 3 ? polygon : nil
        }
        guard !faces.isEmpty else { return [] }
        var unique: [SIMD3<Double>] = []
        for point in cut
        where !unique.contains(where: { simd_distance_squared($0, point) < epsilon * epsilon }) {
            unique.append(point)
        }
        if unique.count >= 3 {
            let midpoint = unique.reduce(.zero, +) / Double(unique.count)
            let seed = abs(plane.normal.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let tangent = simd_normalize(simd_cross(plane.normal, seed))
            let other = simd_cross(plane.normal, tangent)
            unique.sort {
                let a = $0 - midpoint
                let b = $1 - midpoint
                return atan2(simd_dot(a, other), simd_dot(a, tangent))
                    < atan2(simd_dot(b, other), simd_dot(b, tangent))
            }
            faces.append(unique)
        }
        return faces
    }

    struct VolumeNode {
        let point: SIMD3<Double>
        let weight: Double
    }

    /// Positive degree-two quadrature on disjoint convex gas pieces. This avoids subtracting
    /// nearly equal full/solid integrals in a thin gas sliver. Full cells use tensor Gauss nodes.
    func gasQuadrature(lower: SIMD3<Double>, cellSize h: Double) -> [VolumeNode] {
        precondition(h.isFinite && h > 0)
        let low = lower - centre
        let vertices = (0..<8).map { n in
            low + h * SIMD3<Double>(n & 1 == 0 ? 0 : 1, n & 2 == 0 ? 0 : 1, n & 4 == 0 ? 0 : 1)
        }
        let epsilon = h * 1e-12
        if vertices.allSatisfy({ point in planes.allSatisfy { $0.distance(point) <= 0 } }) { return [] }
        if planes.contains(where: { plane in vertices.allSatisfy { plane.distance($0) > epsilon } }) {
            let offset = h / (2 * sqrt(3.0))
            return (0..<8).map { n in
                VolumeNode(
                    point: lower + SIMD3(repeating: h / 2)
                        + SIMD3(
                            n & 1 == 0 ? -offset : offset, n & 2 == 0 ? -offset : offset,
                            n & 4 == 0 ? -offset : offset), weight: h * h * h / 8)
            }
        }
        var remaining = [
            [0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6],
        ]
        .map { $0.map { vertices[$0] } }
        var nodes: [VolumeNode] = []
        let small = (5 - sqrt(5.0)) / 20
        let large = (5 + 3 * sqrt(5.0)) / 20
        for plane in planes {
            let outside = clipped(
                remaining, against: Plane(normal: -plane.normal, offset: -plane.offset), epsilon: epsilon)
            let points = outside.flatMap { $0 }
            if !points.isEmpty {
                let origin = points.reduce(.zero, +) / Double(points.count)
                for face in outside where face.count >= 3 {
                    for n in 1..<(face.count - 1) {
                        let tetra = [origin, face[0], face[n], face[n + 1]]
                        let volume =
                            simd_dot(face[0] - origin, simd_cross(face[n] - origin, face[n + 1] - origin)) / 6
                        if volume > 0 {
                            let sum = tetra.reduce(SIMD3<Double>.zero, +)
                            for corner in tetra {
                                let point = centre + small * sum + (large - small) * corner
                                if !contains(point) { nodes.append(.init(point: point, weight: volume / 4)) }
                            }
                        }
                    }
                }
            }
            remaining = clipped(remaining, against: plane, epsilon: epsilon)
            if remaining.isEmpty { break }
        }
        return nodes
    }

    /// Open fractions ordered x−, x+, y−, y+, z−, z+. Adjacent cells share the same face measure.
    func openFaceFractions(lower: SIMD3<Double>, cellSize h: Double) -> [Double] {
        openFacePatches(lower: lower, cellSize: h).map { $0.area / (h * h) }
    }

    /// Outward cell normals. The centroid is the area centroid of the open portion,
    /// which may be disconnected; it need not lie within an open polygon.
    func openFacePatches(lower: SIMD3<Double>, cellSize h: Double) -> [SurfacePatch] {
        precondition(h.isFinite && h > 0)
        let low = lower - centre
        return (0..<6).map { face in
            let axis = face / 2
            let a = (axis + 1) % 3
            let b = (axis + 2) % 3
            var origin = low
            if face & 1 != 0 { origin[axis] += h }
            var da = SIMD3<Double>.zero
            var db = SIMD3<Double>.zero
            da[a] = h
            db[b] = h
            let square = [origin, origin + da, origin + da + db, origin + db]
            var polygon = square
            for plane in planes {
                var intersections: [SIMD3<Double>] = []
                polygon = clip(polygon, against: plane, epsilon: h * 1e-12, intersections: &intersections)
                if polygon.count < 3 { break }
            }
            let blocked = measure(polygon)
            var area = min(h * h, max(0, h * h - blocked.area))
            let midpoint = origin + (da + db) / 2
            var centroid = area > 0 ? (h * h * midpoint - blocked.area * blocked.centroid) / area : midpoint
            if area < h * h * 1e-6 {
                // Partition open polygons by the FIRST violated solid plane. Direct
                // positive areas/moments preserve thin triangles lost by full-minus-solid.
                var remaining = square
                area = 0
                var moment = SIMD3<Double>.zero
                for plane in planes {
                    var intersections: [SIMD3<Double>] = []
                    if remaining.contains(where: { plane.distance($0) > h * 1e-12 }) {
                        let outside = clip(
                            remaining,
                            against: Plane(normal: -plane.normal, offset: -plane.offset),
                            epsilon: h * 1e-12, intersections: &intersections)
                        let patch = measure(outside)
                        area += patch.area
                        moment += patch.area * (patch.centroid - midpoint)
                    }
                    intersections = []
                    remaining = clip(
                        remaining, against: plane, epsilon: h * 1e-12,
                        intersections: &intersections)
                    if remaining.count < 3 { break }
                }
                centroid = area > 0 ? midpoint + moment / area : midpoint
            }
            var normal = SIMD3<Double>.zero
            normal[axis] = face & 1 == 0 ? -1 : 1
            return SurfacePatch(area: area, centroid: centre + centroid, normal: normal)
        }
    }

    /// Positive tetrahedral measures avoid cancellation in an almost solid cell.
    /// Tolerance-scale geometry remains subject to the clipping predicates.
    func gasVolume(lower: SIMD3<Double>, cellSize h: Double) -> Double {
        let fraction = 1 - solidVolumeFraction(lower: lower, cellSize: h)
        if fraction < 1e-6 {
            return gasQuadrature(lower: lower, cellSize: h).reduce(0) { $0 + $1.weight }
        }
        return fraction * h * h * h
    }

    /// Normals point out of the box, so pressure on the body acts along -normal.
    /// A wall coincident with a grid face belongs to the cell on its fluid side only.
    func wallPatches(lower: SIMD3<Double>, cellSize h: Double) -> [WallPatch] {
        precondition(h.isFinite && h > 0)
        let low = lower - centre
        let epsilon = h * 1e-12
        var cellPlanes: [Plane] = []
        for axis in 0..<3 {
            var normal = SIMD3<Double>.zero
            normal[axis] = 1
            cellPlanes.append(Plane(normal: -normal, offset: -low[axis]))
            cellPlanes.append(Plane(normal: normal, offset: low[axis] + h))
        }
        return wallPolygons.indices.compactMap { wall in
            let normal = planes[wall].normal
            let original = wallPolygons[wall]
            for axis in 0..<3 where abs(normal[axis]) > 1 - 1e-12 {
                if normal[axis] < 0 && original.allSatisfy({ abs($0[axis] - low[axis]) < epsilon }) {
                    return nil
                }
                if normal[axis] > 0 && original.allSatisfy({ abs($0[axis] - low[axis] - h) < epsilon }) {
                    return nil
                }
            }
            var polygon = original
            for plane in cellPlanes {
                var intersections: [SIMD3<Double>] = []
                polygon = clip(polygon, against: plane, epsilon: epsilon, intersections: &intersections)
                if polygon.count < 3 { return nil }
            }
            let patch = measure(polygon)
            guard patch.area > h * h * 1e-14 else { return nil }
            return WallPatch(
                area: patch.area, centroid: centre + patch.centroid, normal: normal,
                vertices: polygon.map { centre + $0 })
        }
    }

    private func measure(_ polygon: [SIMD3<Double>]) -> (area: Double, centroid: SIMD3<Double>) {
        guard polygon.count >= 3 else { return (0, .zero) }
        var area = 0.0
        var moment = SIMD3<Double>.zero
        for n in 1..<(polygon.count - 1) {
            let triangle = simd_length(simd_cross(polygon[n] - polygon[0], polygon[n + 1] - polygon[0])) / 2
            area += triangle
            moment += triangle * (polygon[0] + polygon[n] + polygon[n + 1]) / 3
        }
        return (area, area > 0 ? moment / area : .zero)
    }

    private func clip(
        _ polygon: [SIMD3<Double>], against plane: Plane, epsilon: Double,
        intersections: inout [SIMD3<Double>]
    ) -> [SIMD3<Double>] {
        guard var previous = polygon.last else { return [] }
        var previousDistance = plane.distance(previous)
        var result: [SIMD3<Double>] = []
        for point in polygon {
            let distance = plane.distance(point)
            if (distance <= epsilon) != (previousDistance <= epsilon) {
                let weight = min(1, max(0, previousDistance / (previousDistance - distance)))
                let intersection = previous + weight * (point - previous)
                result.append(intersection)
                intersections.append(intersection)
            }
            if distance <= epsilon { result.append(point) }
            previous = point
            previousDistance = distance
        }
        return result
    }
}
