import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// Solvers made one after another in a loop, as sweeps, ensembles and studies make them. Every
/// `MTLBuffer.contents()` autoreleases its buffer (it returns an inner pointer), and building a
/// solver reads its buffers, so on a thread whose pool never drains (a command-line tool, a worker)
/// each solver's buffers outlived it: six of 584 MB built in turn kept 2.8–3.2 GB. Built in a pool,
/// as `ValidationEnsemble.run` and the app's runs build theirs, a solver lets them go when it is
/// dropped; the cell reads take addresses cached once.
@Suite("Solvers made in a loop", .gpuThreads)
struct SolverMemoryTests {
    @Test("A solver built in a pool and dropped lets its buffers go when the pool drains")
    func builtInPoolReleases() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(4, 4, 0)))
        weak var solver: BlastSolver?
        weak var mask: MTLBuffer?
        try autoreleasepool {
            let built = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.25, configuration: .recommended)
            built.advance(steps: 4)
            solver = built
            mask = built.maskBuffer
        }
        #expect(solver == nil)
        // Metal may let go of a buffer a little after its last command buffer finishes, and on a
        // loaded Mac a lot after: however long that takes. A buffer kept for good is a leak, which
        // the suite's hang limit reports, naming this test.
        while mask != nil { Thread.sleep(forTimeInterval: 0.01) }
        #expect(mask == nil, "the mask buffer outlived its solver and its pool")
    }

    @Test("Reading every cell's mask, peak and impulse leaves nothing in the thread's autorelease pool")
    func cellReadsDoNotAutorelease() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(4, 4, 0)))
        let solver = try autoreleasepool {
            try BlastSolver(device: device, scenario: scenario, cellSize: 0.25, configuration: .recommended)
        }
        let grid = solver.grid
        // An autoreleased buffer keeps the retain the pool holds until it drains: through
        // `MTLBuffer.contents()` every read added one.
        autoreleasepool {
            let before = CFGetRetainCount(solver.maskBuffer)
            var sum: Float = 0
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        sum += solver.peakOverpressure(i, j, k) + solver.impulse(i, j, k)
                        if solver.isSolid(i, j, k) { sum += 1 }
                    }
                }
            }
            #expect(sum.isFinite)
            #expect(CFGetRetainCount(solver.maskBuffer) == before)
        }
    }
}
