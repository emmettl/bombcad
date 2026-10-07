import Foundation
import simd

/// Validation is independent of grid resolution: even sub-cell intersections are unsafe.
/// A closed, orientable surface may have nested shells, but surfaces must not cross or touch
/// except at the shared vertices/edges of their own triangulation.
enum MeshValidation {
    struct Edge: Hashable {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
    }
    struct Use {
        var face: Int
        var direction: Int
    }
    static func orientations(_ triangles: [ImportedMesh.Triangle]) throws -> [Int] {
        func less(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            for k in 0..<3 where a[k] != b[k] { return a[k] < b[k] }
            return false
        }
        var edges: [Edge: [Use]] = [:]
        var vertices: [SIMD3<Float>: [Int]] = [:]
        for (index, t) in triangles.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            for v in [t.a, t.b, t.c] { vertices[v, default: []].append(index) }
            for (a, b) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                let forward = less(a, b)
                let edge = forward ? Edge(a: a, b: b) : Edge(a: b, b: a)
                edges[edge, default: []].append(Use(face: index, direction: forward ? 1 : -1))
            }
        }
        let badEdges = edges.filter { $0.value.count != 2 }
        if !badEdges.isEmpty {
            let indices = Array(Set(badEdges.values.flatMap { $0.map(\.face) })).sorted()
            let points = badEdges.keys.flatMap { [$0.a, $0.b] }
            let bounds = Box(
                min: points.reduce(SIMD3(repeating: .infinity), simd_min),
                max: points.reduce(SIMD3(repeating: -.infinity), simd_max))
            throw ImportedMesh.ImportError.geometry(
                message:
                    "The mesh has \(badEdges.count) open or non-manifold edges. Stitch open edges, remove duplicate faces, or Boolean-union touching solids in your CAD tool, then export a watertight, triangulated solid. Open surfaces cannot reliably block the blast.",
                triangleIndices: indices, bounds: bounds)
        }
        var neighbours = Array(repeating: [(face: Int, factor: Int)](), count: triangles.count)
        for uses in edges.values {
            let a = uses[0]
            let b = uses[1]
            let factor = -a.direction * b.direction
            neighbours[a.face].append((b.face, factor))
            neighbours[b.face].append((a.face, factor))
        }
        // Two otherwise closed shells meeting at a vertex are not a manifold surface.
        for (vertex, incident) in vertices {
            try Task.checkCancellation()
            var seen: Set<Int> = [incident[0]]
            var stack = [incident[0]]
            while let face = stack.popLast() {
                for neighbour in neighbours[face] {
                    let next = neighbour.face
                    let t = triangles[next]
                    if (t.a == vertex || t.b == vertex || t.c == vertex) && seen.insert(next).inserted {
                        stack.append(next)
                    }
                }
            }
            guard seen.count == incident.count else {
                throw ImportedMesh.ImportError.geometry(
                    message:
                        "The mesh has a non-manifold vertex where separate surfaces touch. Separate the solids or Boolean-union them in your CAD tool, then export a watertight mesh.",
                    triangleIndices: incident.sorted(), bounds: Box(min: vertex, max: vertex))
            }
        }
        var orientation = Array(repeating: 0, count: triangles.count)
        for start in triangles.indices where orientation[start] == 0 {
            orientation[start] = 1
            var stack = [start]
            while let face = stack.popLast() {
                if face % 256 == 0 { try Task.checkCancellation() }
                for next in neighbours[face] {
                    let expected = orientation[face] * next.factor
                    if orientation[next.face] == 0 {
                        orientation[next.face] = expected
                        stack.append(next.face)
                    } else if orientation[next.face] != expected {
                        throw ImportedMesh.ImportError.invalid(
                            "The mesh cannot be consistently oriented. Repair the surface topology and export a watertight solid."
                        )
                    }
                }
            }
        }
        return orientation
    }

    private struct Face {
        var points: [SIMD3<Double>]
        var low: SIMD3<Double>
        var high: SIMD3<Double>
        init(_ t: ImportedMesh.Triangle) {
            points = [SIMD3<Double>(t.a), SIMD3<Double>(t.b), SIMD3<Double>(t.c)]
            low = simd_min(points[0], simd_min(points[1], points[2]))
            high = simd_max(points[0], simd_max(points[1], points[2]))
        }
    }
    private struct Node {
        var low: SIMD3<Double>
        var high: SIMD3<Double>
        var start: Int
        var count: Int
        var left = -1
        var right = -1
    }
    static func validate(
        _ triangles: [ImportedMesh.Triangle], pairLimit: Int = 2_000_000,
        nodeLimit: Int = 20_000_000, coordinateUnits: String = "source units"
    ) throws {
        try Task.checkCancellation()
        guard
            triangles.allSatisfy({ t in
                let points = [SIMD3<Double>(t.a), SIMD3<Double>(t.b), SIMD3<Double>(t.c)]
                return points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    && simd_length_squared(simd_cross(points[1] - points[0], points[2] - points[0])) > 0
            })
        else {
            throw ImportedMesh.ImportError.invalid(
                "Mesh coordinates contain a collapsed or invalid triangle. Check source units and placement precision, then repair or re-export the model."
            )
        }
        _ = try orientations(triangles)
        let faces = triangles.map(Face.init)
        var indices = Array(triangles.indices)
        var nodes: [Node] = []
        func build(_ start: Int, _ end: Int) throws -> Int {
            try Task.checkCancellation()
            var low = SIMD3<Double>(repeating: .infinity)
            var high = SIMD3<Double>(repeating: -.infinity)
            for i in start..<end {
                low = simd_min(low, faces[indices[i]].low)
                high = simd_max(high, faces[indices[i]].high)
            }
            let index = nodes.count
            nodes.append(Node(low: low, high: high, start: start, count: end - start))
            if end - start > 8 {
                let extent = high - low
                let axis = (0..<3).max(by: { extent[$0] < extent[$1] })!
                indices.replaceSubrange(
                    start..<end,
                    with: indices[start..<end].sorted {
                        let a = faces[$0]
                        let b = faces[$1]
                        return a.low[axis] + a.high[axis] < b.low[axis] + b.high[axis]
                    })
                let mid = (start + end) / 2
                let left = try build(start, mid)
                let right = try build(mid, end)
                nodes[index].left = left
                nodes[index].right = right
            }
            return index
        }
        guard !triangles.isEmpty else { return }
        _ = try build(0, triangles.count)
        var pairs = 0
        var visits = 0
        func exceededLimit() -> ImportedMesh.ImportError {
            .invalid(
                "Mesh intersection checking exceeds its work limit. Simplify the mesh before importing; validation must finish before the geometry can be used."
            )
        }
        for i in faces.indices {
            try Task.checkCancellation()
            let face = faces[i]
            var stack = [0]
            while let index = stack.popLast() {
                visits += 1
                if visits % 256 == 0 { try Task.checkCancellation() }
                guard visits <= nodeLimit else { throw exceededLimit() }
                let node = nodes[index]
                guard all(face.low .<= node.high), all(node.low .<= face.high) else { continue }
                if node.left >= 0 {
                    stack.append(node.left)
                    stack.append(node.right)
                    continue
                }
                for position in node.start..<(node.start + node.count) {
                    let j = indices[position]
                    guard j > i, all(face.low .<= faces[j].high), all(faces[j].low .<= face.high) else {
                        continue
                    }
                    pairs += 1
                    if pairs % 256 == 0 { try Task.checkCancellation() }
                    guard pairs <= pairLimit else { throw exceededLimit() }
                    if intersectsIllegally(face, faces[j]) {
                        let low = simd_min(face.low, faces[j].low)
                        let high = simd_max(face.high, faces[j].high)
                        let region = String(
                            format: "(%.4g, %.4g, %.4g)–(%.4g, %.4g, %.4g)",
                            low.x, low.y, low.z, high.x, high.y, high.z)
                        throw ImportedMesh.ImportError.geometry(
                            message:
                                "Source triangles \(i + 1) and \(j + 1) intersect or touch ambiguously near \(region) in \(coordinateUnits). Boolean-union overlapping solids or repair self-intersections in your CAD tool, then export again. Separate nested shells are supported as cavities.",
                            triangleIndices: [i, j],
                            bounds: Box(min: SIMD3<Float>(low), max: SIMD3<Float>(high)))
                    }
                }
            }
        }
    }

    private static func intersectsIllegally(_ a: Face, _ b: Face) -> Bool {
        let shared = a.points.filter { b.points.contains($0) }
        if shared.count == 3 { return true }
        let scale = max(simd_length(a.high - a.low), simd_length(b.high - b.low))
        let epsilon = max(scale * 1e-9, 1e-12)
        func legal(_ point: SIMD3<Double>) -> Bool {
            if shared.count == 1 { return simd_distance(point, shared[0]) <= epsilon * 4 }
            if shared.count == 2 {
                let edge = shared[1] - shared[0]
                let t = simd_dot(point - shared[0], edge) / simd_length_squared(edge)
                let closest = shared[0] + min(1, max(0, t)) * edge
                return simd_distance(point, closest) <= epsilon * 4
            }
            return false
        }
        for (first, second) in [(a, b), (b, a)] {
            for k in 0..<3 {
                for p in segmentHits(first.points[k], first.points[(k + 1) % 3], second.points, epsilon) {
                    if !legal(p) { return true }
                }
            }
        }
        return false
    }

    private static func segmentHits(
        _ a: SIMD3<Double>, _ b: SIMD3<Double>,
        _ triangle: [SIMD3<Double>], _ epsilon: Double
    ) -> [SIMD3<Double>] {
        let normal = simd_normalize(simd_cross(triangle[1] - triangle[0], triangle[2] - triangle[0]))
        let da = simd_dot(a - triangle[0], normal)
        let db = simd_dot(b - triangle[0], normal)
        if (da > epsilon && db > epsilon) || (da < -epsilon && db < -epsilon) { return [] }
        let drop = (0..<3).max(by: { abs(normal[$0]) < abs(normal[$1]) })!
        let j = (drop + 1) % 3
        let k = (drop + 2) % 3
        func project(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(p[j], p[k]) }
        func cross(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { u.x * v.y - u.y * v.x }
        let projected = triangle.map(project)
        let winding = cross(projected[1] - projected[0], projected[2] - projected[0]) > 0 ? 1.0 : -1.0
        func inside(_ p: SIMD3<Double>) -> Bool {
            let point = project(p)
            return (0..<3).allSatisfy { n in
                let edge = projected[(n + 1) % 3] - projected[n]
                return winding * cross(edge, point - projected[n]) >= -epsilon * simd_length(edge)
            }
        }
        if abs(da) <= epsilon && abs(db) <= epsilon {
            // Clip a coplanar segment to the triangle, including collinear contacts.
            let pa = project(a)
            let delta = project(b) - pa
            var first = 0.0
            var end = 1.0
            for n in 0..<3 {
                let edge = projected[(n + 1) % 3] - projected[n]
                let value = winding * cross(edge, pa - projected[n])
                let slope = winding * cross(edge, delta)
                let tolerance = epsilon * simd_length(edge)
                if abs(slope) <= tolerance {
                    if value < -tolerance { return [] }
                } else {
                    let t = -value / slope
                    if slope > 0 { first = max(first, t) } else { end = min(end, t) }
                }
            }
            guard first <= end + epsilon / max(simd_length(b - a), epsilon),
                first <= 1, end >= 0
            else { return [] }
            return [a + min(1, max(0, first)) * (b - a), a + min(1, max(0, end)) * (b - a)]
        }
        let t = da / (da - db)
        guard t >= 0, t <= 1 else { return [] }
        let point = a + t * (b - a)
        return inside(point) ? [point] : []
    }
}
