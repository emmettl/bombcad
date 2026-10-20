import BlastModel
import Foundation
import RadialBlast
import simd

extension BlastSolver {
    /// The air on the ground under the rectangle from `low` to `high` at each of `times` before
    /// the grid's clock starts, from the mapped start's one-dimensional solutions (solved again
    /// from the start, kept at those times), as `groundSlice` reads the grid's: in each open cell
    /// within a laid solution's radius (and nearer its charge than any other), the solution's
    /// overpressure then and its peak and positive impulse so far at the cell's centre; still air
    /// elsewhere, and where its charge has yet to fire. Empty where the run did not start mapped,
    /// or for times from its start on. A ground-shock point inside the mapped radius takes these
    /// before the grid's own frames, so that its soil feels the front the grid never carried.
    public func earlyGroundSlices(low: SIMD2<Float>, high: SIMD2<Float>, at times: [Double]) -> [GroundSlice]
    {
        guard let start = mappedStart.map({ $0.blast.time + $0.charge.firingTime }).min() else { return [] }
        let wanted = times.filter { $0 >= 0 && $0 < start - 1e-9 }.sorted()
        guard !wanted.isEmpty else { return [] }
        let solutions = mappedStart.map { entry -> (blast: SphericalBlast, times: [Double]) in
            let delay = entry.charge.firingTime
            var blast = Self.mappedSolution(
                entry.charge, radius: entry.radius, mirrors: entry.mirrors, configuration: configuration,
                ambientDensity: ambientDensity, products: configuration.mappedChargeProducts ? .tnt : nil)
            let own = wanted.filter { $0 > delay }
            blast.snapshotTimes = own.map { $0 - delay }
            return (blast.solved(toShockRadius: Double(entry.radius), until: start - delay), own)
        }
        // The grid's slice now, for its cells and which of them are solid.
        let template = groundSlice(low: low, high: high)
        let (nx, ny) = (Int(template.counts.x), Int(template.counts.y))
        let terrain = terrainSurface
        let positions = firingCharges.map(\.position)
        // Each open cell's centre and, for each laid solution, its distance from the charge, or nil
        // where the cell lies beyond its radius or nearer another charge.
        var cells: [(n: Int, distances: [Double?])] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let n = 3 * (i + nx * j)
                guard !template.values[n].isNaN else { continue }
                let (ci, cj) = (Int(template.first.x) + i, Int(template.first.y) + j)
                let surface = min(Int(terrain?[ci + grid.nx * cj] ?? 0), grid.nz - 1)
                let centre = grid.cellCentre(ci, cj, surface)
                let distances = mappedStart.map { entry -> Double? in
                    let r = simd_distance(centre, entry.centre)
                    guard r < entry.radius else { return nil }
                    if positions.count > 1, !nearest(centre, to: entry.centre, among: positions) {
                        return nil
                    }
                    return Double(r)
                }
                if distances.contains(where: { $0 != nil }) { cells.append((n, distances)) }
            }
        }
        return wanted.map { time in
            var values = template.values.map { $0.isNaN ? Float.nan : 0 }
            let snapshots = solutions.map { solution -> SphericalBlast.Snapshot? in
                guard let n = solution.times.firstIndex(of: time), n < solution.blast.snapshots.count else {
                    return nil
                }
                return solution.blast.snapshots[n]
            }
            for cell in cells {
                for (k, distance) in cell.distances.enumerated() {
                    guard let distance, let snapshot = snapshots[k] else { continue }
                    let load = snapshot.load(at: distance, cellSize: solutions[k].blast.cellSize)
                    values[cell.n] = load.x
                    values[cell.n + 1] = load.y
                    values[cell.n + 2] = load.z
                }
            }
            var slice = template
            slice.time = time
            slice.values = values
            return slice
        }
    }
}
