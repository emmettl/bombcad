import simd

/// Reuses validated per-product solid intervals along grid-centre rays. Union intervals before
/// measuring clearances, so an intervening product, overlap, or touching face cannot create a gap.
package struct BuildingGapScan {
    package struct Span {
        package var lower: Float
        package var upper: Float
        package var owner: Int
    }
    var intervalLimit = 500_000
    private var rays: [SIMD3<Int>: [Span]] = [:]
    private var intervals = 0
    private(set) var incomplete = false
    package mutating func record(axis: Int, j: Int, k: Int, spans: [SIMD2<Float>], owner: Int) {
        guard !incomplete else { return }
        let solidSpans = spans.filter { $0.x.isFinite && $0.y.isFinite && $0.x < $0.y }
        guard !solidSpans.isEmpty else { return }
        guard intervals + solidSpans.count <= intervalLimit else {
            // A partially collected ray could miss an intervening solid and invent a clearance.
            incomplete = true
            rays.removeAll()
            return
        }
        intervals += solidSpans.count
        rays[SIMD3(axis, j, k), default: []].append(
            contentsOf: solidSpans.map {
                Span(lower: $0.x, upper: $0.y, owner: owner)
            })
    }
    func diagnostics(cellSize h: Float) throws -> (
        issues: [ImportedMesh.Diagnostic], samples: Int, truncated: Bool
    ) {
        try Task.checkCancellation()
        guard !incomplete else { return ([], 0, false) }
        var issues: [ImportedMesh.Diagnostic] = []
        var samples = 0
        var truncated = false
        func add(_ issue: ImportedMesh.Diagnostic) {
            var merged = issue
            var n = 0
            while n < issues.count {
                let old = issues[n]
                let pad = SIMD3<Float>(repeating: h * 0.01)
                if old.axis == merged.axis && all(old.bounds.min .<= merged.bounds.max + pad)
                    && all(merged.bounds.min .<= old.bounds.max + pad)
                {
                    merged.bounds = Box(
                        min: simd_min(old.bounds.min, merged.bounds.min),
                        max: simd_max(old.bounds.max, merged.bounds.max))
                    merged.minimumSize = min(old.minimumSize ?? .infinity, merged.minimumSize ?? .infinity)
                    merged.partIDs = Array(Set((old.partIDs ?? []) + (merged.partIDs ?? []))).sorted()
                    issues.remove(at: n)
                    n = 0
                } else {
                    n += 1
                }
            }
            if issues.count < 128 { issues.append(merged) } else { truncated = true }
        }
        let keys = rays.keys.sorted { a, b in
            for i in 0..<3 where a[i] != b[i] { return a[i] < b[i] }
            return false
        }
        for (index, key) in keys.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            let spans = rays[key]!.sorted {
                if $0.lower != $1.lower { return $0.lower < $1.lower }
                if $0.upper != $1.upper { return $0.upper < $1.upper }
                return $0.owner < $1.owner
            }
            guard let first = spans.first else { continue }
            var end = first.upper
            var endOwners: Set<Int> = [first.owner]
            var n = 1
            while n < spans.count {
                if n % 256 == 0 { try Task.checkCancellation() }
                let next = spans[n]
                let contactTolerance = max(h * 1e-6, max(abs(end).ulp, abs(next.lower).ulp) * 4)
                if next.lower - end <= contactTolerance {
                    if next.upper > end {
                        end = next.upper
                        endOwners = [next.owner]
                    } else if next.upper == end {
                        endOwners.insert(next.owner)
                    }
                    n += 1
                    continue
                }
                let gap = next.lower - end
                var startOwners: Set<Int> = [next.owner]
                var q = n + 1
                while q < spans.count && spans[q].lower == next.lower {
                    startOwners.insert(spans[q].owner)
                    q += 1
                }
                // Same-product cavities already have their own feature diagnostics.
                if gap < 2 * h && endOwners.contains(where: { a in startOwners.contains { $0 != a } }) {
                    samples += 1
                    let axis = key.x
                    let j = (axis + 1) % 3
                    let k = (axis + 2) % 3
                    var low = SIMD3<Float>.zero
                    var high = SIMD3<Float>.zero
                    low[axis] = end
                    high[axis] = next.lower
                    low[j] = Float(key.y) * h
                    high[j] = Float(key.y + 1) * h
                    low[k] = Float(key.z) * h
                    high[k] = Float(key.z + 1) * h
                    add(
                        .init(
                            kind: .gap, bounds: Box(min: low, max: high), axis: axis,
                            minimumSize: gap, partIDs: Array(endOwners.union(startOwners)).sorted(),
                            betweenElements: true))
                }
                end = next.upper
                endOwners = [next.owner]
                n += 1
            }
        }
        return (issues, samples, truncated)
    }
}
