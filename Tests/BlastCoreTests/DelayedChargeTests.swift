import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Charges fired after the main one (`Charge.delay`): laid down when the run's clock reaches them,
/// as the balloon or, where the air about them is still, from their one-dimensional solution.
@Suite("Delayed charges", .gpuThreads)
struct DelayedChargeTests {
    /// Open rigid ground 60 by 20 m, the main charge at x = 10 m and a second at x = 10 + `apart`;
    /// a gauge `gauge` m beyond the second, 0.75 m up.
    static func scene(main: Float, second: Float, apart: Float, delay: Float?, gauge: Float) -> Scenario {
        let first = SIMD3<Float>(10, 10, 0)
        let other = first + SIMD3(apart, 0, 0)
        var scenario = Scenario(
            name: "Delayed", domainSize: SIMD3(60, 20, 10), boxes: [],
            charge: Charge(mass: main, position: first),
            gauges: [Gauge("Beyond the second", at: other + SIMD3(gauge, 0, 0.75))])
        scenario.additionalCharges = [Charge(mass: second, position: other, delay: delay)]
        scenario.reflectiveFaces = .ground
        return scenario
    }

    static func solver(_ scenario: Scenario, mapped: Bool) throws -> BlastSolver {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var configuration = SolverConfiguration()
        configuration.mappedCharge = mapped
        // Mapped 2 m/kg^(1/3) out: 4.3 m for 10 kg, a few milliseconds.
        configuration.mappedChargeScaledReach = 2
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
    }

    /// A gauge's peak overpressure and the time it first reached a tenth of it.
    static func reading(_ samples: [GaugeSample], ambient: Float) -> (peak: Float, arrival: Double) {
        let peak = (samples.map(\.pressure).max() ?? ambient) - ambient
        return (peak, samples.first { $0.pressure - ambient > 0.1 * peak }?.time ?? .nan)
    }

    @Test("A delayed charge fires when the clock reaches it, as the balloon, and adds its energy then")
    func balloonAtItsTime() throws {
        let scenario = Self.scene(main: 10, second: 10, apart: 20, delay: 0.003, gauge: 4)
        let solver = try Self.solver(scenario, mapped: false)
        let one = solver.totals().energy
        #expect(solver.pendingFirings.count == 1)
        solver.advance(until: 0.0029)
        #expect(solver.firings.isEmpty && abs(solver.totals().energy - one) < 1e-3 * one)
        solver.advance(until: 0.004)
        let firing = try #require(solver.firings.first)
        #expect(firing.how == .balloon && abs(firing.laidAt - 0.003) < 1e-6, "\(firing)")
        let added = solver.totals().energy - one
        #expect(
            abs(added / Double(scenario.charge.energy) - 1) < 0.03,
            "added \(added) J for a charge of \(scenario.charge.energy) J")
    }

    @Test(
        "A delayed charge reads as the same charge undelayed, later by its delay, as the balloon and mapped",
        arguments: [false, true])
    func readsAsUndelayed(mapped: Bool) throws {
        // The main charge far off and light, so that its blast is weak where the second fires; the
        // gauge 6 m beyond the second, past its mapped radius, read by the grid.
        let delay: Float = 0.010
        let delayed = try Self.solver(
            Self.scene(main: 0.5, second: 10, apart: 30, delay: delay, gauge: 6), mapped: mapped)
        let undelayed = try Self.solver(
            Self.scene(main: 0.5, second: 10, apart: 30, delay: nil, gauge: 6), mapped: mapped)
        delayed.advance(until: 0.035 + Double(delay))
        undelayed.advance(until: 0.035)
        if mapped {
            let firing = try #require(delayed.firings.first)
            #expect(firing.how == .mapped && firing.laidAt > Double(delay), "\(firing)")
        }
        let ambient = Float(101_325)
        let a = Self.reading(delayed.gaugeHistories[0], ambient: ambient)
        let b = Self.reading(undelayed.gaugeHistories[0], ambient: ambient)
        #expect(abs(a.peak / b.peak - 1) < 0.05, "peaks \(a.peak) and \(b.peak) Pa")
        #expect(abs(a.arrival - b.arrival - Double(delay)) < 2e-4, "arrivals \(a.arrival) and \(b.arrival) s")
    }

    @Test("A delayed charge to be mapped in another's wake is laid as the balloon, saying why")
    func wakeFallsBack() throws {
        // 6 m from the main charge, fired after its shock has passed.
        let solver = try Self.solver(
            Self.scene(main: 10, second: 10, apart: 6, delay: 0.010, gauge: 4), mapped: true)
        solver.advance(until: 0.012)
        let firing = try #require(solver.firings.first)
        #expect(firing.how == .balloonInsteadOfMapped && firing.note?.isEmpty == false, "\(firing)")
        #expect(abs(firing.laidAt - 0.010) < 1e-6)
    }

    @Test("A delayed charge's run is the same however it is batched")
    func batchingIndependent() throws {
        let scenario = Self.scene(main: 10, second: 10, apart: 20, delay: 0.003, gauge: 4)
        var histories: [[GaugeSample]] = []
        for steps in [5, 64] {
            let solver = try Self.solver(scenario, mapped: true)
            while solver.time < 0.012 { _ = solver.advance(steps: steps, timeLimit: 0.012) }
            histories.append(solver.gaugeHistories[0])
        }
        #expect(histories[0] == histories[1], "\(histories[0].count) and \(histories[1].count) samples")
    }
}
