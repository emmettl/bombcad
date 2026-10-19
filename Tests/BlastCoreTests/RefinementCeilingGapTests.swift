import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Paths through the refinement ceiling (`SolverConfiguration.refinementCeiling`, the band's bit 2)
/// that `EnvelopeComponentHistoryTests.refinementCeiling` does not reach: the ceiling measured from
/// raised ground rather than the domain's floor, the bands held beside envelopes capped by it, a
/// solver run again without the ceiling after a run with it, and a ceiling over the domain's top
/// changing nothing in every cell (that test compares one cell in 997) with the bands held too.
@Suite("Refinement ceiling paths not otherwise reached", .gpuThreads)
struct RefinementCeilingGapTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// The open field `refinementCeiling` runs in, 12 x 12 x 8 m with half a kilogram on the
    /// ground, the ground raised to `ground` m by terrain where it is above zero.
    private func openField(ground: Float = 0) -> Scenario {
        var scene = Scenario(
            name: "Open", domainSize: SIMD3(12, 12, 8), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(6, 6, ground + 0.5)))
        if ground > 0 {
            // A plain raised flat: its surface lies on cells' faces at 0.25 m, so it is a staircase
            // with no cut cells, and every column's ground is the same.
            scene.terrain = Terrain(
                spacing: 1, columns: 13, rows: 13, heights: [Float](repeating: ground, count: 169))
        }
        return scene
    }

    private func configuration(_ ceiling: Float?, levels: Int = 2) -> SolverConfiguration {
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementLevels = levels
        config.refinementMemory = 64 << 20
        config.refinementCeiling = ceiling
        return config
    }

    /// Runs `solver` to `until` s, keeping each level's most blocks at each height
    /// (`refinedBlocksByHeight`) over the run.
    private func run(_ solver: BlastSolver, until: Double) -> [[Int]] {
        var rows: [[Int]] = []
        while solver.time < until {
            let batch = solver.advance(steps: 8, timeLimit: until)
            if batch.steps == 0 { break }
            let now = solver.refinedBlocksByHeight()
            rows = rows.isEmpty ? now : zip(rows, now).map { zip($0, $1).map { max($0, $1) } }
        }
        return rows
    }

    /// Every cell's state, peak and impulse, as bit patterns.
    private func everything(_ solver: BlastSolver) -> [UInt32] {
        let grid = solver.grid
        var bits = solver.withState { cells in
            cells.flatMap {
                [$0.density, $0.momentumX, $0.momentumY, $0.momentumZ, $0.energy].map(\.bitPattern)
            }
        }
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    bits.append(solver.peakOverpressure(i, j, k).bitPattern)
                    bits.append(solver.impulse(i, j, k).bitPattern)
                }
            }
        }
        return bits
    }

    /// The lowest block row (of `blockM` m) that must stay coarse under a ceiling at `top` m on
    /// cells `cellM` m: the highest cell whose centre is under the ceiling may be flagged, and a
    /// flagged cell refines its whole block and the blocks round it (`flagAround`; review-2's
    /// finding 8: the cap is applied in whole blocks, so it is not strict), so the first row that
    /// must stay coarse is two over the block holding that cell. On the floor with a 2 m ceiling
    /// this is row 3, as `EnvelopeComponentTests.refinementCeiling` has it.
    private func firstCoarseRow(top: Float, blockM: Float, cellM: Float) -> Int {
        let highest = ((top / cellM - 0.5).rounded(.up) - 0.5) * cellM
        return Int((highest / blockM).rounded(.down)) + 2
    }

    /// The ceiling is "more than this many metres above the ground beneath it" (`applyFacadeBand`
    /// takes the terrain's height under each column). With the ground raised 1.5 m and the
    /// ceiling 2 m over it, the highest cell allowed is centred at 3.375 m, in the first level's
    /// block row 3-4 m, so none may be refined from 5 m (the block round it reaches 4-5 m); and, so
    /// that a ceiling taken from the domain's floor would fail, some block must be refined above
    /// 3 m (the first row a 2 m ceiling from the floor forbids). Measured on the Studio on
    /// 19 October 2026: the first level's most blocks by row [92, 92, 96, 81, 56, 0, 0, 0], the
    /// second's none below 1 m or from 4 m. The existing test runs on the
    /// floor only, where the two readings agree.
    @Test("The ceiling is measured from the ground beneath, not the domain's floor")
    func measuredFromLocalGround() throws {
        let ground: Float = 1.5
        let ceiling: Float = 2
        let cell: Float = 0.25
        let solver = try BlastSolver(
            device: device, scenario: openField(ground: ground), cellSize: cell,
            configuration: configuration(ceiling))
        let rows = run(solver, until: 0.01)
        try #require(rows.count == 2)
        // Blocks are 4 coarse cells (1 m) high at the first level, 4 of its cells (0.5 m) at the second.
        let top = ground + ceiling
        let first = firstCoarseRow(top: top, blockM: 1, cellM: cell)
        // The second level's blocks are flagged from the first level's cells, and the existing
        // test allows one block more there; so does this.
        let second = firstCoarseRow(top: top, blockM: 0.5, cellM: cell) + 1
        #expect(rows[0].dropFirst(first).allSatisfy { $0 == 0 }, "\(rows[0])")
        #expect(rows[1].dropFirst(second).allSatisfy { $0 == 0 }, "\(rows[1])")
        // The shock refines the 3-5 m rows within 10 ms from a charge at 2 m (measured 81 and 56
        // blocks).
        #expect(
            rows[0].dropFirst(3).prefix(first - 3).reduce(0, +) > 0, "nothing refined above 3 m: \(rows[0])")
        // And nothing in the ground: no refined block wholly below 1.5 m at the second level.
        #expect(rows[1].prefix(2).allSatisfy { $0 == 0 }, "\(rows[1])")
    }

    /// The ceiling "caps the bands held beside envelopes and structures too". A wall 6 m tall
    /// held fine while its air is loaded (`refinementHoldsEnvelopes`) must keep no block above the
    /// ceiling after the shock has passed, though without the ceiling it keeps blocks to its top.
    /// `heldBand` and `refinementCeiling` in `EnvelopeComponentHistoryTests` never run together.
    @Test("Bands held beside an envelope stop at the ceiling")
    func heldBandsCapped() throws {
        var scene = Scenario(
            name: "Tall wall", domainSize: SIMD3(10, 10, 8), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(3, 5, 0.5)))
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(6, 2, 0), max: SIMD3(6.5, 8, 6))]), name: "Wall")
        let cell: Float = 0.25
        func held(_ ceiling: Float?) throws -> [[Int]] {
            var config = configuration(ceiling, levels: 1)
            config.refinementHoldsEnvelopes = 100
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: cell, configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.02))
            return run(solver, until: 0.02)
        }
        let free = try held(nil)
        let capped = try held(2)
        let first = firstCoarseRow(top: 2, blockM: 1, cellM: cell)
        // Without the ceiling the held band reaches the wall's top (measured [58, 54, 56, 50, 34,
        // 24, 24, 0] blocks by row); with it, none from 3 m ([58, 54, 50, 0, ...]).
        #expect(
            free[0].dropFirst(first).reduce(0, +) > 0, "the band never held above the ceiling: \(free[0])")
        #expect(capped[0].dropFirst(first).allSatisfy { $0 == 0 }, "\(capped[0])")
        #expect(capped[0].prefix(2).reduce(0, +) > 0)
    }

    /// A ceiling higher than the domain sets the ceiling's flag but marks no cell above it, so the
    /// run must be the run with none, in every cell's state, peak and impulse; and the same with
    /// the bands held beside an envelope, where `applyFacadeBand` builds the band with both bits.
    /// The existing test compares a digest of one cell in 997 and holds no band.
    @Test(
        "A ceiling over the domain's top changes no bit, with or without held bands",
        arguments: [false, true])
    func ceilingAboveDomainBitIdentical(holding: Bool) throws {
        var scene = openField()
        if holding {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(8, 3, 0), max: SIMD3(8.5, 9, 3))]), name: "Wall")
        }
        func bits(_ ceiling: Float?) throws -> (bits: [UInt32], rows: [[Int]]) {
            var config = configuration(ceiling)
            if holding { config.refinementHoldsEnvelopes = 100 }
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: 0.25, configuration: config)
            if holding {
                try solver.configureEnvelopeComponents(
                    objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.01))
            }
            let rows = run(solver, until: 0.01)
            return (everything(solver), rows)
        }
        let none = try bits(nil)
        let high = try bits(100)
        #expect(high.rows == none.rows)
        let differing = zip(high.bits, none.bits).filter { $0 != $1 }.count
        #expect(differing == 0, "\(differing) words differ")
    }

    /// `SimulationModel` keeps the solver when the grid is unchanged and loads the next scene
    /// into it. Run with a ceiling and then again without, `applyFacadeBand` takes its early
    /// return, which clears the band but not `FacadeBandParameters.ceiling`, so the flag kernels
    /// go on testing bit 2 in whatever buffer is bound in the band's place (review-2, finding 3,
    /// from 7b6261c6). The second run must be a fresh solver's without a ceiling, block for block
    /// and bit for bit. Run first with the ceiling kept, as a control: a solver reused with the
    /// same settings must match a fresh one, or the comparison means nothing.
    ///
    /// It failed until the early return reset the whole `FacadeBandParameters` (review 2, #3): run
    /// again without the ceiling, 176,381 words of state, peak and impulse differed from a fresh
    /// solver's.
    @Test("A solver run again without its ceiling refines as a fresh one without a ceiling")
    func ceilingClearedOnReuse() throws {
        let scene = openField()
        let fresh = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.25, configuration: configuration(nil))
        let freshRows = run(fresh, until: 0.01)
        let freshCapped = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.25, configuration: configuration(2))
        let freshCappedRows = run(freshCapped, until: 0.01)

        let reused = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.25, configuration: configuration(2))
        _ = run(reused, until: 0.01)
        // The control: the same ceiling again.
        try reused.load(scene)
        let againRows = run(reused, until: 0.01)
        #expect(againRows == freshCappedRows, "reused \(againRows) against fresh \(freshCappedRows)")
        #expect(everything(reused) == everything(freshCapped))

        reused.configuration.refinementCeiling = nil
        try reused.load(scene)
        let rows = run(reused, until: 0.01)
        #expect(rows == freshRows, "reused \(rows) against fresh \(freshRows)")
        let differing = zip(everything(reused), everything(fresh)).filter { $0 != $1 }.count
        #expect(differing == 0, "\(differing) words differ from a fresh solver's")
    }
}
