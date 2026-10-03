import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Skipping still air must not change the answer at all.
@Suite("Still air")
struct StillAirTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func run(_ preset: ScenarioPreset, cellSize: Float, until time: Double, skip: Bool) throws
        -> BlastSolver
    {
        let scenario = preset.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.skipStillAir = skip
        try solver.load(scenario)
        solver.advance(until: time)
        return solver
    }

    private func expectIdentical(_ a: BlastSolver, _ b: BlastSolver) {
        #expect(a.time == b.time)
        #expect(a.stepCount == b.stepCount)
        let differing = a.withState { first in
            b.withState { second in
                zip(first, second).filter { $0.0 != $0.1 }.count
            }
        }
        #expect(differing == 0, "\(differing) cells differ")
        #expect(a.gaugeHistories == b.gaugeHistories)
        var worstPeak: Float = 0
        var worstImpulse: Float = 0
        for k in 0..<a.grid.nz {
            for j in 0..<a.grid.ny {
                for i in 0..<a.grid.nx {
                    worstPeak = max(worstPeak, abs(a.peakOverpressure(i, j, k) - b.peakOverpressure(i, j, k)))
                    worstImpulse = max(worstImpulse, abs(a.impulse(i, j, k) - b.impulse(i, j, k)))
                }
            }
        }
        // Still air reads an overpressure of a rounding error, which only the full sweep records.
        #expect(worstPeak < 0.1 && worstImpulse < 1e-3, "peak \(worstPeak) Pa, impulse \(worstImpulse) Pa s")
    }

    @Test("A blast among buildings is the same, cell for cell, with still air skipped")
    func streetCanyonIsIdentical() throws {
        let skipped = try run(.streetCanyon, cellSize: 1, until: 0.06, skip: true)
        let full = try run(.streetCanyon, cellSize: 1, until: 0.06, skip: false)
        expectIdentical(skipped, full)
    }

    @Test("A wall broken by the blast is the same with still air skipped")
    func coupledWallIsIdentical() throws {
        let skipped = try run(.blastWall, cellSize: 0.5, until: 0.03, skip: true)
        let full = try run(.blastWall, cellSize: 0.5, until: 0.03, skip: false)
        expectIdentical(skipped, full)
        let structures = try [#require(skipped.structure), #require(full.structure)]
        #expect(structures[0].summary() == structures[1].summary())
    }

    @Test("Early on, only the air the blast has reached is swept")
    func onlyReachedAirIsSwept() throws {
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 1)
        let early = solver.advance(until: 0.01)
        #expect(early.sweptFraction > 0 && early.sweptFraction < 0.5, "swept \(early.sweptFraction)")
        // Once the blast fills the domain, every tile is swept.
        let late = solver.advance(until: 0.4)
        #expect(late.sweptFraction > early.sweptFraction)
    }
}
