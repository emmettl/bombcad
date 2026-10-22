import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Experimental compensated conserved sweeps", .serialized, .gpuThreads)
struct CompensatedSweepTests {
    @Test("Every component mode preserves observation parity and replays actual residual updates")
    func parityAndReplay() throws {
        for rounding in [KernelRounding.standard, .unfused] {
            try KernelRounding.$current.withValue(rounding) {
                for components in CompensatedSweepComponents.allCases {
                    for retain in [false, true] {
                        for tiled in [false, true] {
                            let plain = try SweepUpdateDiagnosticsTests().solver(tiled: tiled)
                            let observed = try SweepUpdateDiagnosticsTests().solver(tiled: tiled)
                            try plain.configureCompensatedSweep(components, retainResiduals: retain)
                            try observed.configureCompensatedSweep(components, retainResiduals: retain)
                            try observed.configureSweepUpdateDiagnostics([30, 32, 34])
                            #expect(
                                plain.firstPhaseDiagnosticStateHashes()
                                    == observed.firstPhaseDiagnosticStateHashes())
                            #expect(plain.advance(steps: 6).isStable)
                            #expect(observed.advance(steps: 6).isStable)
                            #expect(
                                plain.firstPhaseDiagnosticStateHashes()
                                    == observed.firstPhaseDiagnosticStateHashes())
                            let trace = try observed.sweepUpdateTrace()
                            #expect(trace.capturedFields == SweepUpdateTrace.compensatedFields)
                            #expect(trace.samples.count == 6)
                            for sample in trace.samples {
                                for q in trace.indices.indices where sample.executed[q] {
                                    let v = sample.values[q]
                                    #expect(
                                        v[28] == components.mask + (retain ? 0 : 4) && v[29] == 0
                                            && v[30] == 0)
                                    for (bit, old, new, low, high, oldError, newError, increment) in [
                                        (1, 0, 5, 10, 15, 24, 26, 31), (2, 4, 9, 14, 19, 25, 27, 32),
                                    ] where Int(components.mask) & bit != 0 {
                                        let difference: Float = v[high] - v[low]
                                        let delta: Float = -v[20] * difference
                                        let corrected: Float = delta - v[oldError]
                                        let next: Float = v[old] + corrected
                                        let error: Float = (next - v[old]) - corrected
                                        #expect(v[increment].bitPattern == delta.bitPattern)
                                        #expect(v[new].bitPattern == next.bitPattern)
                                        #expect(
                                            v[newError].bitPattern == (retain ? error : Float(0)).bitPattern)
                                    }
                                }
                            }
                            let final = try #require(observed.compensatedSweepState())
                            for q in trace.indices.indices {
                                let sample = try #require(trace.samples.last)
                                #expect(
                                    final[trace.indices[q]].x.bitPattern == sample.values[q][26].bitPattern)
                                #expect(
                                    final[trace.indices[q]].y.bitPattern == sample.values[q][27].bitPattern)
                            }
                            observed.restart()
                            #expect(
                                observed.compensatedSweep == nil && observed.compensatedSweepState() == nil)
                            try observed.configureCompensatedSweep(components, retainResiduals: retain)
                            #expect(
                                try #require(observed.compensatedSweepState()).allSatisfy {
                                    $0 == SIMD4(0, 0, components.mask + (retain ? 0 : 4), 0)
                                })
                        }
                    }
                }

            }

        }
    }

    @Test("Sleeping tiles retain residuals and floors clear the overridden component")
    func skippedAndFloors() throws {
        var sleeping = SolverConfiguration()
        sleeping.skipStillAir = true
        let still = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.25), configuration: sleeping)
        still.fill(uniform: Primitive(density: 1.225, pressure: 101325))
        try still.configureCompensatedSweep(.both)
        let held = SIMD4<Float>(0.00000001, -0.001, 3, 0)
        let residual = try #require(still.compensatedSweep).residuals.contents()
            .bindMemory(to: SIMD4<Float>.self, capacity: 64)
        residual[32] = held
        try still.configureSweepUpdateDiagnostics([32])
        #expect(still.advance(steps: 1).isStable)
        #expect(try still.sweepUpdateTrace().samples[0].executed == [false])
        #expect(try #require(still.compensatedSweepState())[32] == held)

        var floors = SolverConfiguration()
        floors.skipStillAir = false
        floors.reflectiveFaces = [.xMin, .xMax, .yMin, .yMax, .zMin, .zMax]
        floors.densityFloor = 2
        floors.pressureFloor = 200000
        let clamped = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.25), configuration: floors)
        clamped.fill(uniform: Primitive(density: 1.225, pressure: 101325))
        try clamped.configureCompensatedSweep(.both)
        let buffer = try #require(clamped.compensatedSweep).residuals.contents()
            .bindMemory(to: SIMD4<Float>.self, capacity: 64)
        buffer[32] = SIMD4(0.03125, 0.00390625, 3, 0)
        try clamped.configureSweepUpdateDiagnostics([32])
        #expect(clamped.advance(steps: 1).isStable)
        let sample = try #require(clamped.sweepUpdateTrace().samples.first).values[0]
        #expect(sample[24] == 0.03125 && sample[25] == 0.00390625)
        #expect(sample[26] == 0 && sample[27] == 0 && sample[30] == 2)
        #expect(try #require(clamped.compensatedSweepState())[32] == SIMD4(0, 0, 3, 2))
    }

    @Test("Unsupported scope and configuring after observation are refused")
    func refusal() throws {
        let observed = try SweepUpdateDiagnosticsTests().solver(tiled: false)
        try observed.configureSweepUpdateDiagnostics([32])
        #expect(throws: BlastError.self) { try observed.configureCompensatedSweep(.both) }
        let bounded = try SweepUpdateDiagnosticsTests().solver(tiled: false)
        try bounded.configureCompensatedSweep(.both)
        try bounded.configureSweepUpdateDiagnostics([32], maxSamples: 1)
        _ = bounded.advance(steps: 2)
        #expect(throws: BlastError.self) { try bounded.sweepUpdateTrace() }
        let charged = try SweepUpdateDiagnosticsTests().solver(tiled: false)
        charged.largestCharge = 1
        #expect(throws: BlastError.self) { try charged.configureCompensatedSweep(.both) }
        let threeD = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            grid: Grid(nx: 8, ny: 8, nz: 8, cellSize: 0.25))
        #expect(throws: BlastError.self) { try threeD.configureCompensatedSweep(.both) }
    }
}
