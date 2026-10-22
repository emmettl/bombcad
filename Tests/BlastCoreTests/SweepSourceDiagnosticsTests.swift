import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Host source-stencil diagnostics", .serialized, .gpuThreads)
struct SweepSourceDiagnosticsTests {
    @Test("Host source reads preserve all four modes and every existing GPU word")
    func parity() throws {
        for rounding in [KernelRounding.standard, .unfused] {
            try KernelRounding.$current.withValue(rounding) {
                for components in CompensatedSweepComponents.allCases {
                    for retain in [false, true] {
                        var full: BlastSolver?
                        for tiled in [false, true] {
                            let solvers = try (0..<4).map { mode in
                                let solver = try SweepUpdateDiagnosticsTests().solver(tiled: tiled)
                                try solver.configureCompensatedSweep(components, retainResiduals: retain)
                                try solver.configureFirstPhaseColumns(
                                    Array(repeating: SIMD4(0, 0, 0, 1), count: 64))
                                if mode > 0 {
                                    try solver.configureFirstPhaseDiagnostics([16, 0], capturePressure: true)
                                }
                                if mode > 1 {
                                    try solver.configureSweepUpdateDiagnostics(
                                        [0, 16, 31, 32, 33, 63], captureHostSources: mode == 3)
                                }
                                return solver
                            }
                            let initial = solvers[0].firstPhaseDiagnosticStateHashes()
                            #expect(solvers.allSatisfy { $0.firstPhaseDiagnosticStateHashes() == initial })
                            for solver in solvers { #expect(solver.advance(steps: 8).isStable) }
                            let final = solvers[0].firstPhaseDiagnosticStateHashes()
                            #expect(
                                solvers.allSatisfy {
                                    $0.firstPhaseDiagnosticStateHashes() == final
                                        && $0.time == solvers[0].time
                                })
                            if tiled {
                                #expect(try #require(full).firstPhaseDiagnosticStateHashes() == final)
                            } else {
                                full = solvers[3]
                            }
                            let pressure = try solvers[1].firstPhasePressureTrace()
                            for solver in solvers.dropFirst(2) {
                                let observed = try solver.firstPhasePressureTrace()
                                #expect(observed.samples.map(\.time) == pressure.samples.map(\.time))
                                #expect(observed.samples.count == pressure.samples.count)
                                for (a, b) in zip(observed.samples, pressure.samples) {
                                    #expect(
                                        a.values.map { $0.map(\.bitPattern) }
                                            == b.values.map { $0.map(\.bitPattern) })
                                }
                            }
                            let old = try solvers[2].sweepUpdateTrace()
                            let observed = try solvers[3].sweepUpdateTrace()
                            let sources = try solvers[3].sweepSourceStencilTrace()
                            #expect(
                                sources.samples.count == 8
                                    && observed.capturedFields == SweepUpdateTrace.compensatedFields)
                            for (a, b) in zip(observed.samples, old.samples) {
                                #expect(a.executed == b.executed && a.time == b.time && a.dt == b.dt)
                                #expect(
                                    a.values.map { $0.map(\.bitPattern) }
                                        == b.values.map { $0.map(\.bitPattern) })
                            }
                            for (host, gpu) in zip(sources.samples, observed.samples) {
                                #expect(host.step == gpu.step && host.time == gpu.time && host.dt == gpu.dt)
                                for q in gpu.executed.indices where gpu.executed[q] {
                                    #expect(
                                        host.conservedBits[q][2]
                                            == Array(gpu.values[q].prefix(5)).map(\.bitPattern))
                                    #expect(
                                        host.residualBits[q][2]
                                            == [
                                                gpu.values[q][24], gpu.values[q][25], gpu.values[q][28],
                                                gpu.values[q][29],
                                            ].map(\.bitPattern))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Physical source indices preserve real neighbor words and explicit ghost mappings")
    func sourceWords() throws {
        for highWall in [false, true] {
            var config = SolverConfiguration()
            config.skipStillAir = false
            config.reflectiveFaces =
                highWall ? [.xMin, .xMax, .yMin, .yMax, .zMin, .zMax] : [.xMin, .yMin, .yMax, .zMin, .zMax]
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()),
                grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.25), configuration: config)
            solver.fill { i, _, _ in
                Primitive(
                    density: 1.1 + Float(i) * 0.001, velocity: SIMD3(0.01 + Float(i) * 0.001, 0, 0),
                    pressure: 101325 + Float(i) * 10)
            }
            let before = SweepUpdateDiagnosticsTests().states(solver, Array(0..<64))
            try solver.configureCompensatedSweep(.both)
            let initialResiduals = try #require(solver.compensatedSweepState())
            try solver.configureSweepUpdateDiagnostics([0, 1, 2, 31, 62, 63], captureHostSources: true)
            #expect(solver.advance(steps: 1).isStable)
            let trace = try solver.sweepSourceStencilTrace()
            #expect(trace.physicalIndices[0] == [1, 0, 0, 1, 2])
            #expect(trace.ghostVelocitySigns[0] == [-1, -1, 1, 1, 1])
            #expect(trace.physicalIndices[5] == (highWall ? [61, 62, 63, 63, 62] : [61, 62, 63, 63, 63]))
            #expect(trace.ghostVelocitySigns[5] == (highWall ? [1, 1, 1, -1, -1] : [1, 1, 1, 1, 1]))
            let sample = try #require(trace.samples.first)
            for q in trace.physicalIndices.indices {
                for slot in 0..<5 {
                    let index = trace.physicalIndices[q][slot]
                    #expect(sample.conservedBits[q][slot] == before[index].map(\.bitPattern))
                    let e = initialResiduals[index]
                    #expect(sample.residualBits[q][slot] == [e.x, e.y, e.z, e.w].map(\.bitPattern))
                }
            }
        }
    }

    @Test("Skipped source reads remain host evidence; incomplete and unsupported capture refuses")
    func refusalAndSkips() throws {
        let ordinary = try SweepUpdateDiagnosticsTests().solver(tiled: false)
        #expect(throws: BlastError.self) {
            try ordinary.configureSweepUpdateDiagnostics([32], captureHostSources: true)
        }
        for periodic in [false, true] {
            var config = SolverConfiguration()
            config.periodicSides = periodic
            config.openFaces = periodic ? .copy : .farField
            let unsupported = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()),
                grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.25), configuration: config)
            try unsupported.configureCompensatedSweep(.both)
            #expect(throws: BlastError.self) {
                try unsupported.configureSweepUpdateDiagnostics([32], captureHostSources: true)
            }
        }
        let sleeping = try SweepUpdateDiagnosticsTests().solver(tiled: true)
        sleeping.fill(uniform: Primitive(density: 1.225, pressure: 101325))
        try sleeping.configureCompensatedSweep(.both)
        try sleeping.configureSweepUpdateDiagnostics([0, 32, 63], maxSamples: 1, captureHostSources: true)
        #expect(sleeping.advance(steps: 1).isStable)
        let gpu = try sleeping.sweepUpdateTrace().samples[0]
        let host = try sleeping.sweepSourceStencilTrace().samples[0]
        #expect(gpu.executed == [false, false, false] && gpu.values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(
            host.conservedBits.allSatisfy {
                $0.count == 5 && $0.allSatisfy { $0[0] == Float(1.225).bitPattern }
            })
        _ = sleeping.advance(steps: 1)
        #expect(throws: BlastError.self) { try sleeping.sweepSourceStencilTrace() }
        sleeping.restart()
        #expect(sleeping.sweepUpdateCapture == nil)
        let async = try SweepUpdateDiagnosticsTests().solver(tiled: false)
        try async.configureCompensatedSweep(.both)
        try async.configureSweepUpdateDiagnostics([32], captureHostSources: true)
        let command = try #require(async.encodeBatch(steps: 1))
        #expect(async.advance(steps: 0).steps == 0 && async.batchInFlight)
        command.commit()
        command.waitUntilCompleted()
        #expect(async.completeBatch().isStable)
        #expect(throws: BlastError.self) { try async.sweepSourceStencilTrace() }
    }
}
