import Foundation
import simd

extension ImportedMesh {
    /// A stable closed shell. IDs follow source triangle order, independent of units or grid.
    public struct Part: Sendable, Hashable, Identifiable {
        public var id: Int
        public var name: String
        public var objectName: String?
        public var groupName: String?
        public var triangleIndices: [Int]
    }
    struct FaceLabel: Sendable, Hashable, Codable {
        var object: String?
        var group: String?
    }
    public func bounds(of part: Part) -> Box {
        let points = part.triangleIndices.flatMap { n in
            let t = triangles[n]
            return [t.a, t.b, t.c]
        }
        return Box(
            min: points.reduce(SIMD3(repeating: .infinity), simd_min),
            max: points.reduce(SIMD3(repeating: -.infinity), simd_max))
    }
    var trianglePartIDs: [Int] {
        var ids = Array(repeating: 0, count: triangles.count)
        for part in parts { for n in part.triangleIndices { ids[n] = part.id } }
        return ids
    }
}

enum MeshParts {
    static func make(_ triangles: [ImportedMesh.Triangle], labels: [ImportedMesh.FaceLabel]?) throws
        -> [ImportedMesh.Part]
    {
        if let labels {
            guard labels.count == triangles.count,
                labels.allSatisfy({ ($0.object?.count ?? 0) <= 200 && ($0.group?.count ?? 0) <= 200 })
            else {
                throw ImportedMesh.ImportError.invalid("Saved source part labels are invalid.")
            }
        }
        var parents = Array(triangles.indices)
        func root(_ n: Int) -> Int {
            var current = n
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
        func less(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            for k in 0..<3 where a[k] != b[k] { return a[k] < b[k] }
            return false
        }
        var edges: [MeshValidation.Edge: Int] = [:]
        for (n, t) in triangles.enumerated() {
            if n % 256 == 0 { try Task.checkCancellation() }
            for (a, b) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                let edge = less(a, b) ? MeshValidation.Edge(a: a, b: b) : MeshValidation.Edge(a: b, b: a)
                if let previous = edges[edge] {
                    let first = root(previous)
                    let second = root(n)
                    parents[max(first, second)] = min(first, second)
                } else {
                    edges[edge] = n
                }
            }
        }
        var components: [Int: [Int]] = [:]
        for n in triangles.indices { components[root(n), default: []].append(n) }
        var parts: [ImportedMesh.Part] = []
        for id in components.keys.sorted() {
            try Task.checkCancellation()
            let indices = components[id]!
            func common(_ value: (ImportedMesh.FaceLabel) -> String?) -> String? {
                guard let labels, let first = value(labels[indices[0]]), !first.isEmpty,
                    indices.allSatisfy({ value(labels[$0]) == first })
                else { return nil }
                return first
            }
            let object = common { $0.object }
            let group = common { $0.group }
            let name = [object, group].compactMap { $0 }.joined(separator: " / ")
            parts.append(
                .init(
                    id: id, name: name.isEmpty ? "Component \(parts.count + 1)" : name,
                    objectName: object, groupName: group, triangleIndices: indices))
        }
        let counts = Dictionary(grouping: parts, by: \.name).mapValues(\.count)
        var occurrences: [String: Int] = [:]
        for n in parts.indices where counts[parts[n].name, default: 0] > 1 {
            let name = parts[n].name
            occurrences[name, default: 0] += 1
            parts[n].name = "\(name) · \(occurrences[name]!)"
        }
        return parts
    }
}
