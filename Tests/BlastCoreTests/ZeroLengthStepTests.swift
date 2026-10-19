import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// A batch that would pass its time limit stops short, and its remaining steps are of zero length;
/// the step after it is shortened to land on the limit. Steps of zero length change nothing.
@Suite("Steps of zero length")
struct ZeroLengthStepTests {
    /// Hupfauf's SN144 slab with crushed bare concrete removed, unfused, ending at 0.5 ms (the
    /// nightly suite's `contact-sn144`), went NaN in its last batch: one step, then steps of zero
    /// length in which the structure's outline freed cells removed in the step before. A refined
    /// level's ghost cells beside a freed cell read the level's halo, saved at the last real step
    /// while the cell was solid, and zero times the fine sweep's fluxes, not finite, was NaN. Here
    /// a coarse cell beside a patch is solid through a real step, holding NaN (a solid cell's state
    /// is never read); freed, it has air in it, but the halo does not.
    @Test("A cell freed beside a patch before steps of zero length changes nothing", arguments: [1, 2])
    func freedBesidePatch(levels: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementLevels = levels
        configuration.refinementMemory = 64 << 20
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.5), configuration: configuration)
        let air = Primitive(density: 1.225, pressure: 101_325)
        solver.fill { i, j, k in
            let r = SIMD3<Float>(Float(i), Float(j), Float(k)) - 3.5
            return (r * r).sum() < 6 ? Primitive(density: 5, pressure: 1e6) : air
        }
        _ = solver.advance(steps: 4)
        let level = try #require(solver.refinement)
        let tiles = level.patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: level.tileDims.x * level.tileDims.y * level.tileDims.z)
        func refined(_ t: SIMD3<Int>) -> Bool {
            tiles[t.x + level.tileDims.x * (t.y + level.tileDims.y * t.z)] >= 0
        }
        // A refined tile with an unrefined one beyond it along x, and the coarse cell beyond the
        // middle of its face.
        let tile = try #require(
            (0..<level.tileDims.z).lazy.flatMap { z in
                (0..<level.tileDims.y).lazy.flatMap { y in
                    (0..<level.tileDims.x - 1).lazy.map { SIMD3(Int($0), y, z) }
                }
            }.first { refined($0) && !refined($0 &+ SIMD3(1, 0, 0)) })
        let cell = solver.grid.index(tile.x * 4 + 4, tile.y * 4 + 1, tile.z * 4 + 1)
        solver.mutateMask { $0[cell] = 1 }
        solver.mutateState { $0[cell] = CellState(Primitive(density: .nan, pressure: .nan), gamma: 1.4) }
        _ = solver.advance(steps: 1)
        try #require(refined(tile) && !refined(tile &+ SIMD3(1, 0, 0)))
        solver.mutateMask { $0[cell] = 0 }
        solver.mutateState { $0[cell] = CellState(air, gamma: configuration.gamma) }

        func states() -> [[Float]] {
            let coarse = solver.withState { $0.flatMap { [$0.density, $0.momentumX, $0.energy] } }
            return [coarse]
                + solver.refinementLevels.map { level in
                    let count = level.maxPatches * level.side * level.side * level.side
                    let cells = (level.fine[0].contents() + level.cellOffset * MemoryLayout<CellState>.stride)
                        .bindMemory(to: CellState.self, capacity: count)
                    return (0..<count).flatMap { [cells[$0].density, cells[$0].momentumX, cells[$0].energy] }
                }
        }
        let before = states()
        // A solid cell's state is never read: only the halo holds the NaN.
        #expect(before.allSatisfy { $0.allSatisfy(\.isFinite) })
        let time = solver.time
        let steps = solver.batchSteps(4)
        let commands = try #require(
            solver.encodeBatchPart(
                steps: steps, range: 0..<steps, timeLimit: time, updateVisualization: false))
        commands.commit()
        commands.waitUntilCompleted()
        let result = solver.completeBatch()
        #expect(result.steps == 0 && solver.time == time)
        let after = states()
        for (n, (a, b)) in zip(before, after).enumerated() {
            let changed = zip(a, b).filter { $0.bitPattern != $1.bitPattern }.count
            #expect(
                changed == 0,
                "level \(n): \(changed) values changed, \(b.filter { !$0.isFinite }.count) not finite")
        }
    }
}
