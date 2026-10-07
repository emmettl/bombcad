import simd

/// Capacity-constrained displacement reference on an adjacent-face graph. Face area
/// establishes connectivity, not a physical flux or time-integrated aperture capacity.
enum FractionalVolumeRemap {
    enum Failure: Error { case invalidGeometry, volumeImbalance, unroutable }
    struct Face {
        let a: Int
        let b: Int
        let openArea: Double
    }
    struct Plan {
        let transfers: [FractionalGasTransport.Transfer]
        let maximumVolumeResidual: Double
        let maximumOutflowFraction: Double
    }
    private struct Edge {
        let to: Int
        var capacity: Double
        var flow: Double = 0
    }
    static func build(old: [Double], new: [Double], faces: [Face], relativeTolerance: Double = 1e-9) throws
        -> Plan
    {
        guard old.count == new.count, !old.isEmpty, relativeTolerance.isFinite && relativeTolerance > 0,
            old.allSatisfy({ $0.isFinite && $0 >= 0 }), new.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { throw Failure.invalidGeometry }
        let count = old.count
        let source = 2 * count
        let sink = source + 1
        var delta = zip(new, old).map(-)
        let root = old.indices.max { old[$0] < old[$1] }!
        let imbalance = delta.reduce(0, +)
        guard abs(imbalance) <= relativeTolerance * old[root] else { throw Failure.volumeImbalance }
        delta[root] -= imbalance
        let required = delta.reduce(0) { $0 + max(0, -$1) }
        var graph = Array(repeating: [Int](), count: sink + 1)
        var edges: [Edge] = []
        func add(_ from: Int, _ to: Int, _ capacity: Double) -> Int {
            let index = edges.count
            graph[from].append(index)
            graph[to].append(index + 1)
            edges.append(Edge(to: to, capacity: capacity))
            edges.append(Edge(to: from, capacity: 0))
            return index
        }
        for n in old.indices {
            // All outgoing transfers, including transit flow, share the old gas inventory.
            _ = add(n, count + n, old[n])
            if delta[n] < 0 { _ = add(source, n, -delta[n]) }
            if delta[n] > 0 { _ = add(n, sink, delta[n]) }
        }
        var physicalEdges: [(index: Int, from: Int, to: Int)] = []
        for face in faces.sorted(by: { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }) {
            guard old.indices.contains(face.a), old.indices.contains(face.b), face.a != face.b,
                face.openArea.isFinite && face.openArea >= 0
            else { throw Failure.invalidGeometry }
            if face.openArea > 0 {
                physicalEdges.append((add(count + face.a, face.b, required), face.a, face.b))
                physicalEdges.append((add(count + face.b, face.a, required), face.b, face.a))
            }
        }
        while true {
            var queue = [source]
            var parent = Array(repeating: -1, count: graph.count)
            var head = 0
            parent[source] = -2
            while head < queue.count && parent[sink] == -1 {
                let n = queue[head]
                head += 1
                for index in graph[n] where edges[index].capacity > 0 && parent[edges[index].to] == -1 {
                    parent[edges[index].to] = index
                    queue.append(edges[index].to)
                }
            }
            if parent[sink] == -1 { break }
            var amount = Double.infinity
            var n = sink
            while n != source {
                let index = parent[n]
                amount = min(amount, edges[index].capacity)
                n = edges[index ^ 1].to
            }
            guard amount.isFinite && amount > 0 else { throw Failure.unroutable }
            n = sink
            while n != source {
                let index = parent[n]
                edges[index].capacity -= amount
                edges[index ^ 1].capacity += amount
                edges[index].flow += amount
                edges[index ^ 1].flow -= amount
                n = edges[index ^ 1].to
            }
        }
        var transfers = physicalEdges.compactMap { edge -> FractionalGasTransport.Transfer? in
            edges[edge.index].flow > 0
                ? .init(from: edge.from, to: edge.to, volume: edges[edge.index].flow) : nil
        }
        var outgoing = Array(repeating: 0.0, count: count)
        for t in transfers { outgoing[t.from] += t.volume }
        // Roundoff excess at a saturated donor is adjusted on both sides of one transfer.
        // Significant capacity violations are rejected; endpoint residuals are checked below.
        for n in old.indices where outgoing[n] > old[n] {
            while outgoing[n] > old[n] {
                let excess = outgoing[n] - old[n]
                guard excess <= 64 * Double.ulpOfOne * old[n],
                    let index = transfers.indices.filter({ transfers[$0].from == n }).max(by: {
                        transfers[$0].volume < transfers[$1].volume
                    })
                else { throw Failure.unroutable }
                let t = transfers[index]
                let volume = max(0, (t.volume - excess).nextDown)
                guard volume < t.volume else { throw Failure.unroutable }
                transfers[index] = .init(from: t.from, to: t.to, volume: volume)
                outgoing[n] = transfers.filter { $0.from == n }.reduce(0) { $0 + $1.volume }
            }
        }
        var received = Array(repeating: 0.0, count: count)
        outgoing = Array(repeating: 0.0, count: count)
        for t in transfers {
            outgoing[t.from] += t.volume
            received[t.to] += t.volume
        }
        var maximumResidual = 0.0
        var maximumOutflow = 0.0
        for n in old.indices {
            let residual = old[n] + received[n] - outgoing[n] - new[n]
            guard abs(residual) <= relativeTolerance * max(old[n], new[n]) else { throw Failure.unroutable }
            maximumResidual = max(maximumResidual, abs(residual))
            if old[n] > 0 { maximumOutflow = max(maximumOutflow, outgoing[n] / old[n]) }
        }
        return Plan(
            transfers: transfers, maximumVolumeResidual: maximumResidual,
            maximumOutflowFraction: maximumOutflow)
    }
}
