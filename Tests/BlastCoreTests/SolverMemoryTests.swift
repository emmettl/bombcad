import Darwin
import Foundation
import Metal
import Testing

@testable import BlastCore

/// Solvers made one after another in a loop, as sweeps, ensembles and studies make them. Building a
/// solver autoreleases something that keeps it, and all its buffers, alive until an autorelease
/// pool drains, which on a command-line or worker thread is never: six solvers of 584 MB built in
/// turn kept 2.8–3.2 GB. Built in a pool, as `ValidationEnsemble.run` and the app's runs build
/// theirs, each lets its memory go when it is dropped.
@Suite("Solvers made in a loop", .gpuThreads)
struct SolverMemoryTests {
    /// The process's physical footprint, bytes (what the system counts against it).
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test("Six solvers each built in a pool and run in turn hold no more than about two solvers' memory")
    func loopReleases() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(32, 32, 16), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(16, 16, 0)))
        func run() throws -> Int {
            let solver = try autoreleasepool {
                try BlastSolver(
                    device: device, scenario: scenario, cellSize: 0.125, configuration: .recommended)
            }
            _ = solver.advance(steps: 6)
            return solver.memoryFootprint
        }
        // One first, so the libraries and pipelines are loaded before the count starts.
        let one = try run()
        let before = footprint()
        for _ in 0..<6 { _ = try run() }
        // Metal lets go of a buffer a little after its last command buffer finishes.
        Thread.sleep(forTimeInterval: 2)
        let grown = footprint() - before
        #expect(one > 100 << 20, "\(one >> 20) MB a solver")
        #expect(grown < 2 * one, "grew \(grown >> 20) MB over six solvers of \(one >> 20) MB")
    }
}
