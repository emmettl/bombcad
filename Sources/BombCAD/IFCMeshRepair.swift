import Foundation
import simd

/// Takes an element's mesh apart into the closed solids it is made of, where the converter has
/// welded several of them together: a wall's layers, a window's frame and sash, items of one
/// representation that touch. Their shared faces leave edges used by four triangles, or the same
/// face twice, so the whole is not a closed surface, though each piece is.
///
/// Coincident faces of opposite sense (two pieces pressed together over the same triangle) cancel.
/// Then the triangles are paired across each edge: where two meet, with each other; where more
/// meet, each with the next one round the edge on its inner side, the face that bounds the same
/// solid. Each set of triangles so paired is a piece; a piece whose every edge is used once each
/// way is a closed solid.
enum IFCMeshRepair {
    struct Result {
        /// Each closed piece, as triangles of indices into `points`.
        var shells: [[SIMD3<Int>]]
        var points: [SIMD3<Double>]
        /// Pieces left open, and their triangles.
        var openPieces: Int
        var openTriangles: Int
    }

    /// `triangles` of `vertices`, welded where they coincide to `tolerance` metres.
    static func shells(_ triangles: [[Int]], vertices: [SIMD3<Double>], tolerance: Double = 1e-7) -> Result {
        var index: [SIMD3<Int64>: Int] = [:]
        var points: [SIMD3<Double>] = []
        func weld(_ n: Int) -> Int {
            let p = vertices[n]
            let key = SIMD3<Int64>(
                Int64((p.x / tolerance).rounded()), Int64((p.y / tolerance).rounded()),
                Int64((p.z / tolerance).rounded()))
            if let found = index[key] { return found }
            index[key] = points.count
            points.append(p)
            return points.count - 1
        }
        var faces: [SIMD3<Int>] = []
        for t in triangles where t.count == 3 {
            let f = SIMD3(weld(t[0]), weld(t[1]), weld(t[2]))
            if f.x != f.y && f.y != f.z && f.x != f.z { faces.append(f) }
        }
        // Coincident faces: opposite senses cancel in pairs; repeats of one sense go.
        func rotated(_ f: SIMD3<Int>) -> SIMD3<Int> {
            f.x <= f.y && f.x <= f.z ? f : f.y <= f.z ? SIMD3(f.y, f.z, f.x) : SIMD3(f.z, f.x, f.y)
        }
        var bySet: [SIMD3<Int>: [Int]] = [:]
        for (n, f) in faces.enumerated() {
            let sorted = [f.x, f.y, f.z].sorted()
            bySet[SIMD3(sorted[0], sorted[1], sorted[2]), default: []].append(n)
        }
        var dropped = Set<Int>()
        for group in bySet.values where group.count > 1 {
            let first = rotated(faces[group[0]])
            let same = group.filter { rotated(faces[$0]) == first }
            let opposite = group.filter { rotated(faces[$0]) != first }
            let pairs = min(same.count, opposite.count)
            dropped.formUnion(same.prefix(pairs))
            dropped.formUnion(opposite.prefix(pairs))
            dropped.formUnion((same.dropFirst(pairs) + opposite.dropFirst(pairs)).dropFirst())
        }
        faces = faces.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)

        // Half-edges: for each directed edge, the faces using it and their third corner.
        struct Edge: Hashable {
            var a: Int
            var b: Int
        }
        var half: [Edge: [(face: Int, apex: Int)]] = [:]
        for (n, f) in faces.enumerated() {
            for (a, b, c) in [(f.x, f.y, f.z), (f.y, f.z, f.x), (f.z, f.x, f.y)] {
                half[Edge(a: a, b: b), default: []].append((n, c))
            }
        }
        var parent = Array(faces.indices)
        func root(_ n: Int) -> Int {
            var n = n
            while parent[n] != n {
                parent[n] = parent[parent[n]]
                n = parent[n]
            }
            return n
        }
        for (edge, uses) in half {
            guard let partners = half[Edge(a: edge.b, b: edge.a)], !partners.isEmpty else { continue }
            for use in uses {
                if partners.count == 1 {
                    parent[root(use.face)] = root(partners[0].face)
                    continue
                }
                // Round the edge from this face, into the solid behind it: the first face met.
                let a = points[edge.a]
                let along = simd_normalize(points[edge.b] - a)
                func across(_ apex: Int) -> SIMD3<Double> {
                    let w = points[apex] - a
                    return simd_normalize(w - simd_dot(w, along) * along)
                }
                let x = across(use.apex)
                let inward = -simd_normalize(simd_cross(points[edge.b] - a, points[use.apex] - a))
                var best: (angle: Double, face: Int)?
                for partner in partners {
                    let u = across(partner.apex)
                    var angle = atan2(simd_dot(u, inward), simd_dot(u, x))
                    if angle <= 1e-9 { angle += 2 * .pi }
                    if best == nil || angle < best!.angle { best = (angle, partner.face) }
                }
                if let best { parent[root(use.face)] = root(best.face) }
            }
        }
        var pieces: [Int: [SIMD3<Int>]] = [:]
        for (n, f) in faces.enumerated() { pieces[root(n), default: []].append(f) }
        var result = Result(shells: [], points: points, openPieces: 0, openTriangles: 0)
        for piece in pieces.keys.sorted().compactMap({ pieces[$0] }) {
            var directed: [Edge: Int] = [:]
            for f in piece {
                for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] {
                    directed[Edge(a: a, b: b), default: 0] += 1
                }
            }
            let closed = directed.allSatisfy { edge, count in
                count == 1 && directed[Edge(a: edge.b, b: edge.a)] == 1
            }
            if closed {
                result.shells.append(piece)
            } else {
                result.openPieces += 1
                result.openTriangles += piece.count
            }
        }
        return result
    }

    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")

    /// A GlobalId for the `piece`th solid of the element `id`, in the IFC's alphabet: 132 bits of
    /// two hashes of both (exporters' GlobalIds of one file often share all but their last few
    /// characters, so none of the original can be kept).
    static func pieceID(_ id: String, _ piece: Int) -> String {
        func hash(_ seed: UInt64) -> UInt64 {
            var value = seed
            for byte in Array(id.utf8) + Array("#\(piece)".utf8) {
                value = (value ^ UInt64(byte)) &* 1_099_511_628_211
            }
            return value
        }
        let a = hash(14_695_981_039_346_656_037)
        let b = hash(0x9E37_79B9_7F4A_7C15)
        var characters: [Character] = []
        for n in 0..<22 {
            let word: UInt64 = n < 11 ? a : b
            let shift = UInt64(6 * (n % 11))
            characters.append(alphabet[Int((word >> shift) & 63)])
        }
        return String(characters)
    }
}
