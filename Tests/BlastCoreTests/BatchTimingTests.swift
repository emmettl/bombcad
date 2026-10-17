import Foundation
import Metal
import Testing

@testable import BlastCore

/// What a run reports of when things happened is the same to the bit however its steps are cut
/// into batches, as the air is: the batches' boundaries move with the GPU's speed (the command
/// buffers are cut by time), so times worked out from them would move too.
@Suite("Times the same however a run is batched", .gpuThreads)
struct BatchTimingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Runs `solver` to `end` in one call, a step a call, or in calls of seven steps.
    static func run(_ solver: BlastSolver, to end: Double, batch: Int?) {
        if let batch {
            while solver.time < end { _ = solver.advance(steps: batch, timeLimit: end) }
        } else {
            _ = solver.advance(until: end)
        }
    }

    @Test("A vent panel's opening time")
    func ventOpening() throws {
        // A charge in a closed room, its east wall a panel that releases at 20 kPa.
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(4, 2, 2), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(1, 1, 1)))
        scenario.reflectiveFaces = BoundaryFaces.all.subtracting(.xMax)
        scenario.ventPanels = [
            VentPanel(box: Box(min: SIMD3(2, 0, 0), max: SIMD3(2.2, 2, 2)), releasePressure: 20_000)
        ]
        func opened(batch: Int?) throws -> UInt64 {
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
            Self.run(solver, to: 0.01, batch: batch)
            return try #require(solver.ventPanelOpenTimes.first ?? nil).bitPattern
        }
        let whole = try opened(batch: nil)
        for batch in [1, 7] {
            #expect(try opened(batch: batch) == whole, "batches of \(batch)")
        }
    }

    @Test("The exposure plane's arrival times")
    func probeArrivals() throws {
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(2, 4, 0.5)))
        func arrivals(batch: Int?) throws -> [UInt32] {
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
            try solver.configureExposurePlane(heightM: 1, arrivalThresholdPa: 2000)
            Self.run(solver, to: 0.008, batch: batch)
            return try #require(solver.exposureSnapshot()).arrivalS.compactMap { $0?.bitPattern }
        }
        let whole = try arrivals(batch: nil)
        #expect(whole.count > 100)
        for batch in [1, 7] {
            let cut = try arrivals(batch: batch)
            #expect(cut == whole, "batches of \(batch): \(zip(cut, whole).filter { $0 != $1 }.count) differ")
        }
    }
}
