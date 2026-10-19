import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The cell reads through the buffers' addresses cached once (eb60092e, and 2da843b2 after a merge
/// had left them assigned to themselves): reads after the state's two buffers swap, after an edit
/// and a restart, after the mask is replaced, and under a refined pool that has grown must return
/// what the GPU wrote and what it will read, not another buffer's contents. `SolverMemoryTests`
/// checks only that the reads leave nothing in the autorelease pool, on a solver that has taken
/// no step since it was built.
@Suite("Cached buffer addresses after the state moves on", .gpuThreads)
struct CachedAddressGapTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A closed room of 16 x 16 x 16 cells of 1 m, still air with a cube of 2 x 2 x 2 cells at
    /// three times the energy off its middle.
    private func closedRoom() throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = .all
        configuration.skipStillAir = false
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 1), configuration: configuration)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        solver.mutateState { cells in
            for k in 5...6 {
                for j in 6...7 {
                    for i in 4...5 { cells[solver.grid.index(i, j, k)].energy *= 3 }
                }
            }
        }
        solver.restart()
        return solver
    }

    private func stateBits(_ solver: BlastSolver) -> [UInt32] {
        solver.withState { cells in
            cells.flatMap {
                [$0.density, $0.momentumX, $0.momentumY, $0.momentumZ, $0.energy].map(\.bitPattern)
            }
        }
    }

    private func fieldBits(_ solver: BlastSolver) -> [UInt32] {
        let grid = solver.grid
        var bits: [UInt32] = []
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    bits += [
                        solver.peakOverpressure(i, j, k).bitPattern, solver.impulse(i, j, k).bitPattern,
                        solver.isSolid(i, j, k) ? 1 : 0,
                    ]
                }
            }
        }
        return bits
    }

    /// 2da843b2: a merge left `maskContents = maskContents`, the address never taken from the
    /// buffer. The cached mask address must be the buffer's own (the state's, peak's and
    /// impulse's are private, so the reads below stand for them), and every cell's `isSolid` must
    /// read the buffer's byte.
    @Test("The cached mask address is the mask buffer's, and isSolid reads its bytes")
    func maskAddressIsTheBuffers() throws {
        let solver = try closedRoom()
        #expect(solver.maskContents == solver.maskBuffer.contents())
        solver.mutateMask { mask in
            for n in stride(from: 0, to: mask.count, by: 7) { mask[n] = 1 }
        }
        solver.restart()
        let grid = solver.grid
        let bytes = solver.maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var differing = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where solver.isSolid(i, j, k) != (bytes[grid.index(i, j, k)] != 0) {
                    differing += 1
                }
            }
        }
        #expect(differing == 0)
    }

    /// The state lives in two buffers that the steps swap between (`current`), and each has its
    /// own cached address. After one step a read must show that step, not the buffer the step
    /// read from: one step then another must read as two steps taken together, and differ from
    /// one step alone, in every cell's state and every peak and impulse.
    @Test("After the state's buffers swap, reads show the latest step")
    func readsFollowTheSwap() throws {
        let one = try closedRoom()
        let two = try closedRoom()
        #expect(one.advance(steps: 1).isStable)
        #expect(two.advance(steps: 2).isStable)
        try #require(stateBits(one) != stateBits(two), "a step changed nothing")
        #expect(one.advance(steps: 1).isStable)
        #expect(stateBits(one) == stateBits(two))
        #expect(fieldBits(one) == fieldBits(two))
    }

    /// An edit through `mutateState` writes through the cached address of the current buffer; the
    /// GPU must then step from what was written. In a closed room the step conserves energy, so
    /// the energy one step after doubling a cell's must be the energy after the edit, not before
    /// it, whether the edit falls after an odd or an even number of steps and whether or not a
    /// `restart()` (which copies the current buffer to the other) comes between.
    @Test(
        "An edit after some steps is what the next step starts from, with or without a restart",
        arguments: [(1, false), (2, false), (3, true), (4, true)])
    func editIsWhatTheGPUReads(steps: Int, restarting: Bool) throws {
        let solver = try closedRoom()
        #expect(solver.advance(steps: steps).isStable)
        let before = solver.totals().energy
        let grid = solver.grid
        var added = 0.0
        solver.mutateState { cells in
            let n = grid.index(10, 10, 10)
            added = Double(cells[n].energy)
            cells[n].energy *= 2
        }
        let edited = solver.totals().energy
        // The CPU's read of the edit: one cubic metre's energy added.
        // Measured exact on the Studio on 19 October 2026 (the sum is in Double).
        #expect(abs(edited - before - added) < 1e-12 * before, "\(before) -> \(edited), added \(added)")
        if restarting { solver.restart() }
        #expect(solver.advance(steps: 1).isStable)
        let after = solver.totals().energy
        // A closed room's step conserves energy to rounding: measured 1e-10 to 4.2e-10 of the
        // total, far under the edit's share (2.4e-4).
        #expect(abs(after - edited) < 2e-9 * edited, "\(edited) -> \(after); without the edit \(before)")
        #expect(abs(after - before) > 0.5 * added)
    }

    /// Loading another scene into the same solver rewrites the mask and the state in place, and a
    /// restart clears the peak and impulse fields through their cached addresses. A reused solver
    /// (as `SimulationModel` keeps one when the grid is unchanged) must then read as one built for
    /// the second scene, in state, peak, impulse and mask, after both have run the same steps.
    @Test("A solver loaded with another scene reads as one built for it")
    func reloadReadsTheNewScene() throws {
        func scene(_ boxes: [Box]) -> Scenario {
            var s = Scenario(
                name: "Room", domainSize: SIMD3(12, 12, 8), boxes: boxes,
                charge: Charge(mass: 0.5, position: SIMD3(4, 6, 0.5)))
            s.reflectiveFaces = .all
            return s
        }
        let first = scene([])
        let second = scene([Box(x: 7...9, y: 3...9, height: 4)])
        let reused = try BlastSolver(device: device, scenario: first, cellSize: 0.5)
        #expect(reused.advance(steps: 7).isStable)
        try reused.load(second)
        let built = try BlastSolver(device: device, scenario: second, cellSize: 0.5)
        #expect(stateBits(reused) == stateBits(built))
        #expect(fieldBits(reused) == fieldBits(built))
        #expect(reused.advance(steps: 9).isStable && built.advance(steps: 9).isStable)
        #expect(stateBits(reused) == stateBits(built))
        #expect(fieldBits(reused) == fieldBits(built))
    }

    /// A refined pool that grows replaces the fine buffers while the coarse ones stay; the coarse
    /// reads (peak, impulse, mask) under the grown pool must match a run whose pool was full size
    /// from the start. `RefinementLevelsTests.growingPool` compares the state and the fine cells,
    /// not the peak and impulse fields.
    @Test("Under a refined pool that grew, peak, impulse and mask read as at full size", arguments: [1, 2])
    func readsAfterPoolGrowth(levels: Int) throws {
        func closedBox(start: Int?) throws -> BlastSolver {
            var configuration = SolverConfiguration()
            configuration.refinement = 2
            configuration.refinementLevels = levels
            configuration.refinementThreshold = 0.05
            configuration.refinementMemory = 256 << 20
            configuration.refinementStartMemory = start
            var scenario = Scenario(
                name: "Closed box", domainSize: SIMD3(24, 20, 16),
                boxes: [Box(min: SIMD3(13, 6, 0), max: SIMD3(18, 14, 9))],
                charge: Charge(mass: 5, position: SIMD3(8, 10, 1)))
            scenario.reflectiveFaces = .all
            return try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        }
        let full = try closedBox(start: nil)
        let grown = try closedBox(start: 1 << 20)
        let start = grown.refinementPools.map(\.held)
        for _ in 0..<6 {
            full.advance(steps: 10)
            grown.advance(steps: 10)
        }
        try #require(
            zip(grown.refinementPools, start).contains { $0.held > $1 },
            "no pool grew: \(grown.refinementPools)")
        #expect(fieldBits(grown) == fieldBits(full))
        #expect(stateBits(grown) == stateBits(full))
    }
}
