import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Native clock input diagnostics", .serialized, .gpuThreads)
struct ClockInputDiagnosticsTests {
    func make(mapped: Bool = false) throws -> BlastSolver {
        let scenario = Scenario(
            name: "Clock trace", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0)))
        return try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scenario, cellSize: 0.5,
            configuration: mapped ? .recommended : .recommended.balloonStart)
    }

    func control(_ trace: ClockInputTrace, _ index: Int, after: Bool) -> StepControl {
        let offset = index * trace.recordWords + 6 + (after ? trace.controlWords + trace.uniformWords : 0)
        return trace.words.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset * 4, as: StepControl.self)
        }
    }

    @Test("Clock copies preserve full fields, native pressure and actual control/clock words")
    func parityAndConsumedWords() throws {
        for mapped in [false, true] {
            let plain = try make(mapped: mapped)
            let observed = try make(mapped: mapped)
            for solver in [plain, observed] {
                try solver.configureFirstPhaseColumns(
                    Array(
                        repeating: SIMD4<Float>(1, 2, 0.25, 1), count: solver.grid.nx * solver.grid.ny))
                try solver.configureFirstPhaseDiagnostics(
                    [17, 100], capturePressure: true, captureInputs: true)
            }
            let initialSpeed = Array(
                UnsafeBufferPointer(
                    start: observed.maxSpeedBuffer.contents().bindMemory(to: UInt32.self, capacity: 2),
                    count: 2))
            let initialClock = observed.clockTicks
            try observed.configureClockInputDiagnostics(maxSamples: 4096)
            let until = observed.time + 0.003
            let a = plain.advance(until: until)
            let b = observed.advance(until: until)
            #expect(a.isStable && b.isStable && a.steps == b.steps)
            #expect(plain.firstPhaseDiagnosticStateHashes() == observed.firstPhaseDiagnosticStateHashes())
            let native = try plain.firstPhasePressureTrace()
            let copied = try observed.firstPhasePressureTrace()
            #expect(native.samples.map(\.time) == copied.samples.map(\.time))
            #expect(
                native.samples.map { $0.values.map { $0.map(\.bitPattern) } }
                    == copied.samples.map { $0.values.map { $0.map(\.bitPattern) } })
            let trace = try observed.clockInputTrace()
            #expect(Array(trace.words.prefix(2)) == initialSpeed)
            #expect(control(trace, 0, after: false).clock == initialClock)
            var active = 0
            var dts: [UInt32] = []
            for index in trace.encodedSteps.indices {
                let pre = control(trace, index, after: false)
                let post = control(trace, index, after: true)
                #expect(trace.batchBaseSteps[index] + Int(pre.activeSteps) == active)
                #expect(post.stepIndex == pre.stepIndex + 1)
                #expect(post.activeSteps == pre.activeSteps + (post.dt > 0 ? 1 : 0))
                #expect(post.clock == pre.clock + UInt64(max(post.dt, 0) * Float(1 / StepControl.tick)))
                let base = index * trace.recordWords
                let uniforms = trace.words.withUnsafeBytes {
                    $0.loadUnaligned(
                        fromByteOffset: (base + 6 + trace.controlWords) * 4, as: SolverUniforms.self)
                }
                let tileAfter = base + 8 + 2 * trace.controlWords + trace.uniformWords
                if uniforms.tileNx != 0 {
                    #expect(post.activeTiles == trace.words[base + 2])
                    #expect(
                        Array(trace.words[tileAfter..<(tileAfter + 4)]) == [0, trace.words[base + 2], 1, 1])
                    #expect(post.tileSweeps == pre.tileSweeps + (post.dt > 0 ? trace.words[base + 2] : 0))
                } else {
                    #expect(
                        Array(trace.words[tileAfter..<(tileAfter + 4)])
                            == Array(trace.words[(base + 2)..<(base + 6)]))
                }
                if post.dt > 0 {
                    active += 1
                    dts.append(post.dt.bitPattern)
                    let start = index * trace.recordWords + 6 + 2 * trace.controlWords + trace.uniformWords
                    #expect(Array(trace.words[start..<(start + 2)]) == [0, 0])
                }
            }
            #expect(active == observed.stepCount)
            #expect(dts == copied.samples.dropFirst().map { $0.values[0][6].bitPattern })
            let last = try #require(trace.encodedSteps.indices.last)
            let current = observed.controlBuffer.contents().bindMemory(
                to: UInt32.self, capacity: trace.controlWords)
            let start = last * trace.recordWords + 6 + trace.controlWords + trace.uniformWords
            #expect(
                Array(trace.words[start..<(start + trace.controlWords)])
                    == Array(UnsafeBufferPointer(start: current, count: trace.controlWords)))
        }
    }

    @Test("Clipped and inactive dispatches remain present without changing batching")
    func inactiveDispatches() throws {
        let solver = try make()
        try solver.configureClockInputDiagnostics(maxSamples: 16)
        let result = solver.advance(steps: 8, timeLimit: 0.000001)
        #expect(result.steps == 1 && result.isStable)
        let trace = try solver.clockInputTrace()
        #expect(trace.encodedSteps == Array(0..<8))
        #expect(control(trace, 0, after: true).dt == Float(0.000001))
        #expect(control(trace, 7, after: true).stopped == 2)
        for index in 1..<8 {
            let pre = control(trace, index, after: false)
            let post = control(trace, index, after: true)
            #expect(pre.stopped == 2 && post.dt == 0 && post.activeSteps == 1)
            #expect(pre.clock == post.clock)
        }
    }

    @Test("Budget overflow refuses readback and does not stop or alter the solver")
    func boundsAndOverflow() throws {
        let plain = try make()
        let observed = try make()
        #expect(throws: BlastError.self) { try observed.clockInputTrace() }
        for count in [1, 32769, Int.max] {
            #expect(throws: BlastError.self) {
                try observed.configureClockInputDiagnostics(maxSamples: count)
            }
        }
        try observed.configureClockInputDiagnostics(maxSamples: 2)
        #expect(throws: BlastError.self) { try observed.clockInputTrace() }
        let a = plain.advance(steps: 8)
        let b = observed.advance(steps: 8)
        #expect(a.steps == 8 && b.steps == 8 && a.isStable && b.isStable)
        #expect(plain.firstPhaseDiagnosticStateHashes() == observed.firstPhaseDiagnosticStateHashes())
        #expect(throws: BlastError.self) { try observed.clockInputTrace() }
    }

    @Test("Restart drops the old trace and late configuration refuses")
    func lifecycle() throws {
        let solver = try make()
        try solver.configureClockInputDiagnostics()
        #expect(solver.advance(steps: 1).isStable)
        #expect(try solver.clockInputTrace().encodedSteps.count == 1)
        #expect(throws: BlastError.self) { try solver.configureClockInputDiagnostics() }
        solver.restart()
        #expect(solver.clockInputCapture == nil)
        #expect(throws: BlastError.self) { try solver.clockInputTrace() }
    }
}
