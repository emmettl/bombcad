import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// The first positive phase's impulse over each plan cell (`FirstPhaseColumns`, the field export's
/// `--first-phase` target).
@Suite("First-phase columns", .serialized, .gpuThreads)
struct FirstPhaseColumnsTests {
    /// A kilogram on the ground of an 8 × 8 × 4 m box of 0.5 m cells, on the balloon.
    func solver() throws -> BlastSolver {
        let scenario = Scenario(
            name: "Burst", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0)))
        return try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scenario, cellSize: 0.5,
            configuration: SolverConfiguration.recommended.balloonStart)
    }

    /// Every column reading between its second and third cells, 1 m over the ground, a quarter of
    /// the way up.
    func columns(_ solver: BlastSolver) -> [SIMD4<Float>] {
        Array(repeating: SIMD4(1, 2, 0.25, 1), count: solver.grid.nx * solver.grid.ny)
    }

    @Test("Each column's first phase is the recorder's rule over its whole history")
    func rule() throws {
        let solver = try solver()
        try solver.configureFirstPhaseColumns(columns(solver))
        let (nx, ny) = (solver.grid.nx, solver.grid.ny)
        var histories = [[Double]](repeating: [], count: nx * ny)
        var steps: [Double] = []
        func sample(_ dt: Double) {
            solver.withState { cells in
                for j in 0..<ny {
                    for i in 0..<nx {
                        let low = solver.primitive(of: cells[solver.grid.index(i, j, 1)]).pressure
                        let high = solver.primitive(of: cells[solver.grid.index(i, j, 2)]).pressure
                        histories[i + nx * j].append(Double(0.75 * low + 0.25 * high) - 101_325)
                    }
                }
            }
            steps.append(dt)
        }
        sample(0)
        while solver.time < 0.012 {
            let result = solver.advance(steps: 1)
            #expect(result.isStable && result.steps == 1)
            sample(result.elapsed)
        }
        let records = try #require(solver.firstPhaseSnapshot())
        var phased = 0
        for (n, history) in histories.enumerated() {
            let peak = history.max() ?? 0
            guard peak > 1000 else { continue }
            // The rule as the recorder's strips take it, with each step's own length.
            var first = 0.0
            var all = 0.0
            var risen = false
            var ended = false
            for (p, dt) in zip(history, steps) {
                all += max(p, 0) * dt
                if p >= 0.5 * peak { risen = true }
                if risen, p < 0 { ended = true }
                if !ended { first += max(p, 0) * dt }
            }
            if ended { phased += 1 }
            let record = records[n]
            #expect(abs(Double(record.x) / peak - 1) < 1e-3, "peak at \(n)")
            #expect(abs(Double(record.y) / all - 1) < 1e-3, "every phase's impulse at \(n)")
            #expect(
                abs(Double(record.z) / first - 1) < 1e-3,
                "first phase's impulse at \(n): \(record) vs \(first)")
            #expect(record.z <= record.y * (1 + 1e-6))
        }
        // The positive phase has ended over much of the box, so the two impulses differ there.
        #expect(phased > nx * ny / 4, "\(phased) of \(nx * ny) columns past their first phase")
    }

    @Test("Production diagnostics preserve batches, fields and recorder values to the bit")
    func diagnosticObservation() throws {
        let plain = try solver()
        let observed = try solver()
        try plain.configureFirstPhaseColumns(columns(plain))
        try observed.configureFirstPhaseColumns(columns(observed))
        let indices = [17, 100]
        try observed.configureFirstPhaseDiagnostics(indices)
        let a = plain.advance(until: 0.006)
        let b = observed.advance(until: 0.006)
        #expect(a.steps == b.steps && a.isStable && b.isStable)
        #expect(plain.stateDigest() == observed.stateDigest())
        #expect(plain.firstPhaseSnapshot() == observed.firstPhaseSnapshot())
        let samples = observed.firstPhaseDiagnosticSamples()
        #expect(samples.count == observed.stepCount)
        #expect(samples.map(\.step) == Array(1...observed.stepCount))
        #expect(samples.allSatisfy { $0.dt > 0 && $0.values.count == indices.count })
        let last = try #require(samples.last)
        let records = try #require(observed.firstPhaseSnapshot())
        for (q, index) in indices.enumerated() {
            #expect(
                Array(last.values[q].prefix(4)) == [
                    records[index].x, records[index].y, records[index].z, records[index].w,
                ])
        }
        #expect(abs(last.time - observed.time) < Double(observed.stepCount) * 0x1p-39)
        #expect(plain.firstPhaseDiagnosticSamples().isEmpty)
    }

    @Test("Disabled columns cannot expose invalid cell indices to host diagnostics")
    func disabledDiagnosticColumn() throws {
        let observed = try solver()
        var cells = columns(observed)
        cells[17] = SIMD4(-1, -1, 0, 0)
        try observed.configureFirstPhaseColumns(cells)
        #expect(throws: BlastError.self) { try observed.configureFirstPhaseDiagnostics([17]) }
        #expect(observed.firstPhaseDiagnosticSamples().isEmpty)
    }

    @Test("All-tiles diagnostics retain the tiled kernel and sweep every tile")
    func allTilesDiagnostic() throws {
        let observed = try solver()
        #expect(observed.tilesEnabled)
        try observed.activateAllAirTilesForDiagnostics()
        let result = observed.advance(steps: 1)
        #expect(result.steps == 1 && result.isStable)
        #expect(observed.tilesEnabled)
        #expect(result.sweptFraction == 1)
    }

    @Test("Layers of columns each record as that layer alone would, and leave the run as it was")
    func layers() throws {
        let low = try solver()
        let high = try solver()
        let both = try solver()
        let upper = Array(repeating: SIMD4<Float>(3, 4, 0.5, 1), count: both.grid.nx * both.grid.ny)
        try low.configureFirstPhaseColumns(columns(low))
        try high.configureFirstPhaseColumns(upper)
        try both.configureFirstPhaseColumns(columns(both) + upper)
        for solver in [low, high, both] {
            let result = solver.advance(until: 0.006)
            #expect(result.isStable && result.steps > 0)
        }
        #expect(low.stateDigest() == both.stateDigest())
        let plan = both.grid.nx * both.grid.ny
        let records = try #require(both.firstPhaseSnapshot())
        #expect(records.count == 2 * plan)
        #expect(Array(records[..<plan]) == low.firstPhaseSnapshot())
        #expect(Array(records[plan...]) == high.firstPhaseSnapshot())
        #expect(records[plan...].contains { $0.z > 0 })
    }

    @Test("Recording the columns leaves the run as it was, to the bit")
    func unchanged() throws {
        let plain = try solver()
        let recorded = try solver()
        try recorded.configureFirstPhaseColumns(columns(recorded))
        let a = plain.advance(until: 0.006)
        let b = recorded.advance(until: 0.006)
        #expect(a.steps == b.steps && a.isStable && b.isStable)
        #expect(plain.stateDigest() == recorded.stateDigest())
        #expect(recorded.firstPhaseSnapshot()?.contains { $0.z > 0 } == true)
        #expect(plain.firstPhaseSnapshot() == nil)
    }
}
