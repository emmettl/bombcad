import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Step selector arithmetic diagnostics", .serialized, .gpuThreads)
struct StepSelectorDiagnosticsTests {
    func make() throws -> BlastSolver {
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 16, ny: 4, nz: 4, cellSize: 0.25))
        solver.fill { i, _, _ in Primitive(density: 1.225, pressure: i < 4 ? 200_000 : 101_325) }
        return solver
    }

    @Test("Opt-in is confined to a sibling prepare pipeline; disabling preserves full fields")
    func isolationAndDisabledParity() throws {
        let plain = try make()
        let disabled = try make()
        #expect(plain.stepSelectorDiagnosticInfo == nil)
        let library = ObjectIdentifier(disabled.library)
        let measure = ObjectIdentifier(disabled.measurePipeline)
        let prepare = ObjectIdentifier(disabled.preparePipeline)
        try disabled.configureStepSelectorDiagnostics()
        let info = try #require(disabled.stepSelectorDiagnosticInfo)
        #expect(info.entryPoint == "prepareStep" && info.mathMode == "safe")
        #expect(info.mathFloatingPointFunctions == "precise" && info.sourceSHA256.count == 64)
        #expect(ObjectIdentifier(disabled.library) == library)
        #expect(ObjectIdentifier(disabled.measurePipeline) == measure)
        #expect(ObjectIdentifier(disabled.preparePipeline) == prepare)
        try disabled.configureStepSelectorDiagnostics(enabled: false)
        #expect(disabled.stepSelectorDiagnosticInfo == nil)
        let a = plain.advance(steps: 8)
        let b = disabled.advance(steps: 8)
        #expect(a.isStable && b.isStable && a.steps == b.steps)
        #expect(plain.firstPhaseDiagnosticStateHashes() == disabled.firstPhaseDiagnosticStateHashes())
    }

    @Test("Both selectors preserve clipping, inactive clocks, step budgets and nonphysical stops")
    func originalGuards() throws {
        for precise in [false, true] {
            let clipped = try make()
            if precise { try clipped.configureStepSelectorDiagnostics() }
            try clipped.configureClockInputDiagnostics(maxSamples: 16)
            let result = clipped.advance(steps: 8, timeLimit: 0.000001)
            #expect(result.steps == 1 && result.isStable)
            let control = clipped.controlBuffer.contents().load(as: StepControl.self)
            #expect(control.stopped == 2 && control.activeSteps == 1 && control.dt == 0)
            let trace = try clipped.clockInputTrace()
            #expect(trace.encodedSteps.count == 8)

            let limited = try make()
            if precise { try limited.configureStepSelectorDiagnostics() }
            let one = limited.advance(steps: 1, timeLimit: 1)
            #expect(one.steps == 1 && one.isStable && limited.time < 1)

            let invalid = try make()
            if precise { try invalid.configureStepSelectorDiagnostics() }
            invalid.maxSpeedBuffer.contents().storeBytes(of: UInt32(0x7FC0_0000), as: UInt32.self)
            let bad = invalid.advance(steps: 8)
            let stopped = invalid.controlBuffer.contents().load(as: StepControl.self)
            #expect(!bad.isStable && bad.steps == 0 && stopped.stopped == 3 && stopped.dt == 0)
        }
    }

    @Test("Restart disables the diagnostic and late or unsupported configurations refuse")
    func lifecycleAndSupport() throws {
        let solver = try make()
        try solver.configureStepSelectorDiagnostics()
        #expect(solver.advance(steps: 1).isStable)
        #expect(throws: BlastError.self) { try solver.configureStepSelectorDiagnostics() }
        solver.restart()
        #expect(solver.stepSelectorDiagnosticInfo == nil)
        solver.configuration.gravity = AirGravity()
        #expect(throws: BlastError.self) { try solver.configureStepSelectorDiagnostics() }
        solver.configuration.gravity = nil
        solver.setGauges(cells: [(i: 1, j: 1, k: 1)])
        #expect(throws: BlastError.self) { try solver.configureStepSelectorDiagnostics() }
        solver.setGauges(cells: [])
        try solver.configureStepSelectorDiagnostics()
        solver.setGauges(cells: [(i: 1, j: 1, k: 1)])
        #expect(solver.encodeBatch(steps: 1) == nil)
    }
}
