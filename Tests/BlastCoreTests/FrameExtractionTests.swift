import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Cutting the air out on the GPU at a frame")
struct FrameExtractionTests {
    private let region = Box(min: SIMD3(1, 1, 0), max: SIMD3(7, 7, 4))

    /// A kilogram's blast in an 8 m box with a wall in it, run to 2 ms with the GPU asked for the
    /// fragments' air and the fireball.
    private func blast(request: Bool = true) throws -> BlastSolver {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Frame", domainSize: SIMD3(8, 8, 8), boxes: [Box(min: SIMD3(5, 2, 0), max: SIMD3(6, 6, 3))],
            charge: Charge(mass: 1, position: SIMD3(3, 4, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.125)
        if request {
            solver.frameRequest = FrameRequest(
                airSlice: AirSliceRequest(region: region, stride: 2), fireball: 1500)
        }
        solver.advance(until: 0.002)
        return solver
    }

    @Test("The GPU's slice of the air and fireball agree with the CPU's")
    func agreement() throws {
        let solver = try blast()
        #expect(solver.frameExtractor?.ready != nil)
        let layout = AirSlice.layout(region: region, stride: 2, grid: solver.grid)
        // The GPU's own, not the CPU's in its place.
        let cut = solver.frameExtractor?.airValues(layout, time: solver.time, steps: solver.stepCount)
        #expect(cut != nil)
        #expect(
            solver.frameExtractor?.fireballRows(
                luminous: 1500, grid: solver.grid, time: solver.time, steps: solver.stepCount) != nil)
        let gpu = solver.airSlice(region: region, stride: 2)
        #expect(gpu.values == cut)
        let cpu = solver.cpuAirValues(layout)
        #expect(gpu.values.count == cpu.count && gpu.counts == layout.counts)
        // Half floats: at most one unit in the last place apart, and nearly all the same.
        var same = 0
        for (a, b) in zip(gpu.values, cpu) {
            #expect(abs(Float(a) - Float(b)) <= Float(max(a.ulp, b.ulp)), "\(a) against \(b)")
            if a == b { same += 1 }
        }
        #expect(Double(same) / Double(cpu.count) > 0.99, "\(same) of \(cpu.count)")

        let fireball = solver.fireball(luminousTemperature: 1500)
        #expect(fireball.volume > 0)
        solver.frameExtractor?.invalidate()
        let reference = solver.fireball(luminousTemperature: 1500)
        #expect(abs(fireball.volume - reference.volume) <= 0.01 * reference.volume)
        #expect(simd_distance(fireball.centre, reference.centre) < 0.01)
        #expect(abs(fireball.temperature - reference.temperature) < 1)
        #expect(abs(fireball.hottest - reference.hottest) < 1)
    }

    @Test("The same run cuts out the same air, and asking makes no difference to the blast")
    func repeatable() throws {
        let first = try blast()
        let second = try blast()
        let unasked = try blast(request: false)
        #expect(first.airSlice(region: region, stride: 2) == second.airSlice(region: region, stride: 2))
        #expect(first.fireball(luminousTemperature: 1500) == second.fireball(luminousTemperature: 1500))
        #expect(first.stepCount == unasked.stepCount && first.time == unasked.time)
        #expect(first.withState { Array($0) } == unasked.withState { Array($0) })
    }

    @Test("Nothing is kept from a batch that ends short of its limit, or once the state changes")
    func staleness() throws {
        let solver = try blast()
        let other = Box(min: SIMD3(0, 0, 0), max: SIMD3(4, 4, 4))
        // Asked for another region, the slice is read on the CPU, as it was before.
        let layout = AirSlice.layout(region: other, stride: 1, grid: solver.grid)
        #expect(solver.airSlice(region: other, stride: 1).values == solver.cpuAirValues(layout))
        #expect(
            solver.frameExtractor?.fireballRows(
                luminous: 2000, grid: solver.grid, time: solver.time, steps: solver.stepCount) == nil)
        // A batch without a time limit does not reach one.
        solver.advance(steps: 3)
        #expect(solver.frameExtractor?.ready == nil)
        solver.advance(until: 0.003)
        #expect(solver.frameExtractor?.ready != nil)
        solver.mutateState { _ in }
        #expect(solver.frameExtractor?.ready == nil)
    }
}
