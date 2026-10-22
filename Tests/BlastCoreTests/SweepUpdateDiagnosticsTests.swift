import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Production sweep update diagnostics", .serialized, .gpuThreads)
struct SweepUpdateDiagnosticsTests {
    func solver(tiled: Bool) throws -> BlastSolver {
        var config = SolverConfiguration()
        config.skipStillAir = tiled
        config.reflectiveFaces = [.xMin, .yMin, .yMax, .zMin, .zMax]
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.25), configuration: config)
        let wave = AcousticPhaseReference(amplitude: 100)
        solver.fill { i, _, _ in
            let x = (Double(i) + 0.5) * 0.25
            let p = wave.pressure(x: x, time: 0)
            return Primitive(
                density: Float(wave.density + p / (wave.soundSpeed * wave.soundSpeed)),
                velocity: SIMD3(Float(wave.velocity(x: x, time: 0)), 0, 0), pressure: Float(101325 + p))
        }
        return solver
    }

    func states(_ solver: BlastSolver, _ indices: [Int]) -> [[Float]] {
        solver.withState { cells in
            indices.map { n in
                let c = cells[n]
                return [c.density, c.momentumX, c.momentumY, c.momentumZ, c.energy]
            }
        }
    }

    @Test("Both sweep paths retain plain state and actual pre/post cells")
    func parity() throws {
        for tiled in [false, true] {
            let plain = try solver(tiled: tiled)
            let observed = try solver(tiled: tiled)
            let indices = [30, 32, 34]
            let before = states(observed, indices)
            try observed.configureSweepUpdateDiagnostics(indices)
            #expect(plain.firstPhaseDiagnosticStateHashes() == observed.firstPhaseDiagnosticStateHashes())
            let a = plain.advance(steps: 1)
            let b = observed.advance(steps: 1)
            #expect(a.isStable && b.isStable && a.steps == b.steps && a.elapsed == b.elapsed)
            #expect(plain.firstPhaseDiagnosticStateHashes() == observed.firstPhaseDiagnosticStateHashes())
            let trace = try observed.sweepUpdateTrace()
            #expect(trace.initialStates == before && trace.samples.count == 1)
            let sample = try #require(trace.samples.first)
            let after = states(observed, indices)
            #expect(trace.finalStates == after)
            for q in indices.indices {
                #expect(sample.executed[q])
                #expect(Array(sample.values[q][0..<5]).map(\.bitPattern) == before[q].map(\.bitPattern))
                #expect(Array(sample.values[q][5..<10]).map(\.bitPattern) == after[q].map(\.bitPattern))
                #expect(sample.values[q][21] == sample.dt && sample.values[q][22] == 0)
            }
            _ = plain.advance(steps: 5)
            _ = observed.advance(steps: 5)
            #expect(plain.firstPhaseDiagnosticStateHashes() == observed.firstPhaseDiagnosticStateHashes())
            #expect(try observed.sweepUpdateTrace().samples.count == observed.stepCount)
            observed.restart()
            #expect(observed.sweepUpdateCapture == nil)
        }
    }

    @Test("Sleeping tiled cells retain skipped opportunities instead of fabricated state")
    func skipped() throws {
        var config = SolverConfiguration()
        config.skipStillAir = true
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.25), configuration: config)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101325))
        try solver.configureSweepUpdateDiagnostics([0, 32])
        _ = solver.advance(steps: 1)
        let trace = try solver.sweepUpdateTrace()
        #expect(trace.samples.count == 1 && trace.samples[0].executed == [false, false])
        #expect(trace.samples[0].values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(trace.finalStates == trace.initialStates)
    }

    @Test("Invalid scope, cells and truncated history are refused")
    func refusal() throws {
        let observed = try solver(tiled: false)
        #expect(throws: BlastError.self) { try observed.configureSweepUpdateDiagnostics([1, 1]) }
        #expect(throws: BlastError.self) { try observed.configureSweepUpdateDiagnostics([-1]) }
        #expect(throws: BlastError.self) { try observed.configureSweepUpdateDiagnostics([64]) }
        #expect(throws: BlastError.self) { try observed.configureSweepUpdateDiagnostics([1], maxSamples: 0) }
        #expect(throws: BlastError.self) { try observed.sweepUpdateTrace() }
        try observed.configureSweepUpdateDiagnostics([32], maxSamples: 1)
        _ = observed.advance(steps: 2)
        #expect(throws: BlastError.self) { try observed.sweepUpdateTrace() }
        let threeD = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 8, ny: 8, nz: 8, cellSize: 1))
        #expect(throws: BlastError.self) { try threeD.configureSweepUpdateDiagnostics([1]) }
    }
}
