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

    @Test("Consumed-pressure capture preserves plain and recorder-only runs, including layered tail grids")
    func consumedPressure() throws {
        for mapped in [false, true] {
            func make() throws -> BlastSolver {
                let scenario = Scenario(
                    name: "Pressure trace", domainSize: SIMD3(7.5, 8.5, 4.5),
                    boxes: [], charge: Charge(mass: 1, position: SIMD3(2, 4, 0)))
                return try BlastSolver(
                    device: #require(MTLCreateSystemDefaultDevice()), scenario: scenario,
                    cellSize: 0.5,
                    configuration: mapped ? .recommended : .recommended.balloonStart)
            }
            let plain = try make()
            let legacy = try make()
            let observed = try make()
            let raw = try make()
            let plan = plain.grid.nx * plain.grid.ny
            let cells =
                Array(repeating: SIMD4<Float>(1, 2, 0.25, 1), count: plan)
                + Array(repeating: SIMD4<Float>(3, 4, 0.5, 1), count: plan)
            for solver in [plain, legacy, observed, raw] { try solver.configureFirstPhaseColumns(cells) }
            let nearCharge = 4 + plain.grid.nx * 8
            let indices = [nearCharge, plan - 1, plan + nearCharge, 2 * plan - 1]
            try legacy.configureFirstPhaseDiagnostics(Array(indices.prefix(2)))
            try observed.configureFirstPhaseDiagnostics(indices, capturePressure: true)
            try raw.configureFirstPhaseDiagnostics(indices, capturePressure: true, captureInputs: true)
            func cellWords(_ solver: BlastSolver) -> [UInt32] {
                let buffer = solver.stateBuffers[solver.current]
                return Array(
                    UnsafeBufferPointer(
                        start: buffer.contents().bindMemory(to: UInt32.self, capacity: buffer.length / 4),
                        count: buffer.length / 4))
            }
            let initialWords = cellWords(raw)
            let initialSnapshot = try raw.firstPhaseInputStateSnapshot()
            #expect(plain.firstPhaseColumns?.pressureCapture == nil)
            #expect(legacy.firstPhaseColumns?.pressureCapture == nil)
            for solver in [plain, legacy, observed, raw] {
                let result = solver.advance(until: 0.006)
                #expect(result.isStable && result.steps > 0)
            }
            #expect(plain.stateDigest() == observed.stateDigest())
            #expect(plain.firstPhaseDiagnosticStateHashes() == observed.firstPhaseDiagnosticStateHashes())
            #expect(plain.firstPhaseDiagnosticStateHashes() == legacy.firstPhaseDiagnosticStateHashes())
            #expect(plain.stateDigest() == legacy.stateDigest())
            #expect(plain.firstPhaseSnapshot() == observed.firstPhaseSnapshot())
            #expect(plain.firstPhaseSnapshot() == legacy.firstPhaseSnapshot())
            #expect(raw.firstPhaseDiagnosticStateHashes() == plain.firstPhaseDiagnosticStateHashes())
            let trace = try observed.firstPhasePressureTrace()
            let paired = try raw.firstPhasePressureTrace()
            #expect(
                paired.samples.map { $0.values.map { $0.map(\.bitPattern) } }
                    == trace.samples.map { $0.values.map { $0.map(\.bitPattern) } })
            let inputs = try raw.firstPhaseInputTrace()
            let finalSnapshot = try raw.firstPhaseInputStateSnapshot()
            #expect(
                initialSnapshot.map { $0.map(\.bitPattern) }
                    == inputs.samples.first?.values.map { $0.map(\.bitPattern) })
            #expect(
                finalSnapshot.map { $0.map(\.bitPattern) }
                    == inputs.samples.last?.values.map { $0.map(\.bitPattern) })
            #expect(inputs.columns == indices)
            #expect(inputs.samples.map(\.step) == paired.samples.map(\.step))
            #expect(inputs.samples.map(\.time) == paired.samples.map(\.time))
            for (sample, words) in [
                (try #require(inputs.samples.first), initialWords),
                (try #require(inputs.samples.last), cellWords(raw)),
            ] {
                for (q, n) in indices.enumerated() {
                    let c = cells[n]
                    let values = sample.values[q]
                    #expect(Array(values.prefix(6)) == [c.x, c.y, c.z, c.w, 1 - c.z, c.z])
                    for (side, k) in [Int(c.x), Int(c.y)].enumerated() {
                        let start = 5 * (n % plan + plan * k)
                        #expect(
                            Array(values[(6 + 5 * side)..<(11 + 5 * side)]).map(\.bitPattern)
                                == Array(words[start..<(start + 5)]))
                    }
                }
            }
            #expect(trace.columns == indices)
            if mapped { #expect(trace.seedRecords.contains { $0[1] > 0 }) }
            #expect(trace.samples.count == observed.stepCount + 1)
            #expect(trace.samples.first?.step == 0)
            #expect(trace.samples.first?.values.allSatisfy { $0[6] == 0 } == true)
            let old = legacy.firstPhaseDiagnosticSamples()
            let new = observed.firstPhaseDiagnosticSamples()
            #expect(old.map(\.step) == new.map(\.step))
            #expect(old.map(\.values) == new.map { Array($0.values.prefix(2)) })
            for (q, _) in indices.enumerated() {
                var record = trace.seedRecords[q]
                for sample in trace.samples {
                    let row = sample.values[q]
                    let pressure = row[0]
                    let dt = row[6]
                    record[1] = record[1].addingProduct(max(pressure, 0), dt)
                    record[0] = max(record[0], pressure)
                    if record[4] != 0 {
                        if pressure < 0 {
                            record[4] = 0
                        } else {
                            record[2] = record[1]
                            record[3] = max(record[3], pressure)
                        }
                    }
                    if pressure > 0 && record[3] < 0.5 * record[0] {
                        record[2] = record[1]
                        record[3] = pressure
                        record[4] = 1
                    }
                    #expect(record == Array(row[1...5]))
                }
            }
        }
    }

    @Test("Pressure capture refuses budget overflow and never exposes a truncated complete trace")
    func pressureBudget() throws {
        let observed = try solver()
        try observed.configureFirstPhaseColumns(columns(observed))
        #expect(throws: BlastError.self) {
            try observed.configureFirstPhaseDiagnostics([17], capturePressure: true, maxPressureSamples: 1)
        }
        #expect(throws: BlastError.self) {
            try observed.configureFirstPhaseDiagnostics([17], captureInputs: true)
        }
        try observed.configureFirstPhaseDiagnostics(
            [17], capturePressure: true, maxPressureSamples: 2, captureInputs: true)
        let result = observed.advance(steps: 3)
        #expect(result.isStable && result.steps == 3)
        #expect(observed.firstPhaseColumns?.pressureCapture?.samples.count == 2)
        #expect(throws: BlastError.self) { try observed.firstPhasePressureTrace() }
        #expect(throws: BlastError.self) { try observed.firstPhaseInputTrace() }
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
