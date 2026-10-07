import Foundation
import simd

/// Experimental alternatives for whole-cell boundary updates; neither is a cut-cell scheme.
public enum ExperimentalBoxRemap: String, Codable, Sendable {
    case redistribution, connectedTransport
}

/// Local conservative reference redistribution of density, momentum and total energy.
/// It preserves these sums, but not angular momentum or a sharp pressure field; it is not a
/// cut-cell scheme. The caller supplies adjacent cells, including across patch boundaries.
enum ConservativeCellRemap {
    enum Failure: Error, LocalizedError {
        case enclosedClosingCell(Int), disconnectedOpening(Int)
        var errorDescription: String? {
            switch self {
            case .enclosedClosingCell(let index):
                "Conservative remap: closing cell \(index) has no adjacent new air."
            case .disconnectedOpening(let count):
                "Conservative remap: \(count) newly exposed cells are disconnected from existing air."
            }
        }
    }
    static func apply(
        _ original: [CellState], oldSolid: [Bool], newSolid: [Bool],
        mode: ExperimentalBoxRemap = .redistribution,
        closingTransit: Set<Int> = [],
        neighbours: (Int) -> [Int]
    ) throws -> [CellState] {
        let opening = original.indices.filter { oldSolid[$0] && !newSolid[$0] }
        let closing = original.indices.filter { !oldSolid[$0] && newSolid[$0] }
        guard !opening.isEmpty || !closing.isEmpty else { return original }
        if mode == .connectedTransport && !opening.isEmpty && !closing.isEmpty {
            var cells = original
            var adjustedOld = oldSolid
            var available = Set(opening)
            // Shift complete conserved states along adjacent air cells. A balanced occupancy
            // change therefore preserves a constant field exactly, without teleporting gas
            // through the body. Greedy shortest paths are a diagnostic, not an ALE solution;
            // they can transport gradients anisotropically and do not preserve angular momentum.
            for start in closing {
                guard !available.isEmpty else { break }
                var queue = [start]
                var parents = [start: start]
                var head = 0
                var end: Int?
                while head < queue.count && end == nil {
                    let n = queue[head]
                    head += 1
                    for adjacent in neighbours(n) where !newSolid[adjacent] && parents[adjacent] == nil {
                        parents[adjacent] = n
                        if available.contains(adjacent) { end = adjacent; break }
                        queue.append(adjacent)
                    }
                }
                guard let end else { continue }
                var path = [end]
                while path.last! != start { path.append(parents[path.last!]!) }
                // Back-to-front copy keeps each original parcel intact, including gradients.
                for slot in 0..<(path.count - 1) { cells[path[slot]] = cells[path[slot + 1]] }
                available.remove(end)
                adjustedOld[end] = false
                adjustedOld[start] = true
            }
            // Unequal voxel volumes or disconnected surfaces still use conservative local
            // redistribution. This fallback cannot preserve a uniform field when volume changes.
            return try apply(cells, oldSolid: adjustedOld, newSolid: newSolid,
                closingTransit: Set(closing), neighbours: neighbours)
        }
        var cells = original
        func vector(_ c: CellState) -> SIMD8<Double> {
            SIMD8(
                Double(c.density), Double(c.momentumX), Double(c.momentumY), Double(c.momentumZ),
                Double(c.energy), 0, 0, 0)
        }
        func state(_ v: SIMD8<Double>) -> CellState {
            var c = original[0]
            c.density = Float(v[0])
            c.momentumX = Float(v[1])
            c.momentumY = Float(v[2])
            c.momentumZ = Float(v[3])
            c.energy = Float(v[4])
            return c
        }
        for n in opening { cells[n] = state(.zero) }
        // Already matched closing cells still provide the same escape routes for residual
        // gas in a collapsing sheet. Their state is excluded from the residual source sum.
        let closingSet = Set(closing).union(closingTransit)
        for n in closing {
            // A collapsing ground gap can swallow a whole sheet at once. Interior cells
            // expel gas through other closing cells to the nearest remaining air, rather than
            // losing it or trying to pass it through previously solid material.
            var frontier = [n]
            var visited: Set<Int> = [n]
            var targets: [Int] = []
            while targets.isEmpty && !frontier.isEmpty {
                let adjacent = frontier.flatMap(neighbours)
                targets = Array(Set(adjacent.filter { !newSolid[$0] })).sorted()
                if targets.isEmpty {
                    frontier = adjacent.filter { closingSet.contains($0) && visited.insert($0).inserted }
                }
            }
            guard !targets.isEmpty else { throw Failure.enclosedClosingCell(n) }
            let share = vector(cells[n]) / Double(targets.count)
            for target in targets { cells[target] = state(vector(cells[target]) + share) }
        }
        // Lift-off can expose a connected sheet of air whose interior initially has only
        // other empty new cells as neighbours. Fill from existing gas, then progress inward;
        // rejecting the first empty donor list would make a legitimate lift-off fail.
        var pending = opening
        while !pending.isEmpty {
            var remaining: [Int] = []
            for n in pending {
                let donors = neighbours(n).filter { !newSolid[$0] && cells[$0].density > 0 }
                guard !donors.isEmpty else {
                    remaining.append(n)
                    continue
                }
                let fraction = 1 / Double(donors.count + 1)
                let sum = donors.reduce(SIMD8<Double>.zero) { $0 + vector(cells[$1]) }
                cells[n] = state(vector(cells[n]) + sum * fraction)
                for donor in donors { cells[donor] = state(vector(cells[donor]) * (1 - fraction)) }
            }
            guard remaining.count < pending.count else { throw Failure.disconnectedOpening(remaining.count) }
            pending = remaining
        }
        return cells
    }
}

/// Float geometry shared with the Metal box predicates. Small inclusion tolerance prevents
/// roundoff at a face from giving the CPU remapper a different mask from patch initialisation.
struct ExperimentalBoxGeometry {
    let centre: SIMD3<Float>
    let vectors: [SIMD4<Float>]
    init(_ body: RigidBoxBody) {
        centre = SIMD3<Float>(body.position)
        vectors = [
            SIMD4<Float>(body.orientation.vector), SIMD4(SIMD3<Float>(body.size / 2), 0),
            SIMD4(SIMD3<Float>(body.centreOfMass), 0), SIMD4(SIMD3<Float>(body.linearVelocity), 0),
            SIMD4(SIMD3<Float>(body.angularVelocity), 0),
        ]
    }
    func contains(_ point: SIMD3<Float>, cellSize: Float) -> Bool {
        let q = vectors[0]
        let imaginary = -SIMD3(q.x, q.y, q.z)
        let v = point - centre
        let local =
            v + 2 * simd_cross(imaginary, simd_cross(imaginary, v) + q.w * v)
            + SIMD3(vectors[2].x, vectors[2].y, vectors[2].z)
        return all(abs(local) .<= SIMD3(vectors[1].x, vectors[1].y, vectors[1].z) + cellSize * 1e-5)
    }
    func velocity(at point: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(vectors[3].x, vectors[3].y, vectors[3].z)
            + simd_cross(SIMD3(vectors[4].x, vectors[4].y, vectors[4].z), point - centre)
    }
}
