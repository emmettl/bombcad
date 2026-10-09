import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Spatial exposure and diagnostic profiling", .serialized)
struct ExposurePlaneTests {
    func solver() throws -> BlastSolver {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var config = SolverConfiguration()
        config.skipStillAir = false
        config.reflectiveFaces = .all
        return try BlastSolver(
            device: device, grid: Grid(nx: 12, ny: 4, nz: 4, cellSize: 0.5), configuration: config)
    }

    @Test("Endpoint maps match an independent CPU accumulation and retain null semantics")
    func accumulation() throws {
        let solver = try solver()
        // Pressure varies across x and z, so this also checks vertical interpolation.
        solver.mutateState { cells in
            for k in 0..<solver.grid.nz {
                for j in 0..<solver.grid.ny {
                    for i in 0..<solver.grid.nx {
                        let pressure: Float = 101_325 + (i < 3 ? 12_000 : 0) + Float(k) * 500
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: 1.225, pressure: pressure), gamma: 1.4)
                    }
                }
            }
        }
        solver.mutateMask { $0[solver.grid.index(5, 1, 2)] = 1 }
        solver.restart()
        try solver.configureExposurePlane(heightM: 1, arrivalThresholdPa: 3000)
        let count = solver.grid.nx * solver.grid.ny
        var peaks = Array(repeating: Float(0), count: count)
        var impulses = peaks
        var arrivals = [Float?](repeating: nil, count: count)
        func pressure(_ i: Int, _ j: Int) -> Float {
            max(0, 0.5 * (solver.primitive(i, j, 1).pressure + solver.primitive(i, j, 2).pressure) - 101_325)
        }
        for j in 0..<solver.grid.ny {
            for i in 0..<solver.grid.nx {
                let index = i + solver.grid.nx * j
                peaks[index] = pressure(i, j)
                if peaks[index] >= 3000 { arrivals[index] = 0 }
            }
        }
        for _ in 0..<12 {
            let result = solver.advance(steps: 1)
            #expect(result.isStable && result.steps == 1)
            for j in 0..<solver.grid.ny {
                for i in 0..<solver.grid.nx {
                    let index = i + solver.grid.nx * j
                    let p = pressure(i, j)
                    peaks[index] = max(peaks[index], p)
                    impulses[index] += p * Float(result.elapsed)
                    if arrivals[index] == nil && p >= 3000 { arrivals[index] = Float(solver.time) }
                }
            }
        }
        let map = try #require(solver.exposureSnapshot())
        #expect(map.heightM == 1 && map.nx == 12 && map.ny == 4)
        for index in 0..<count {
            if index == 5 + solver.grid.nx {
                #expect(map.everSolid[index])
                #expect(
                    map.peakPa[index] == nil && map.positiveImpulsePaS[index] == nil
                        && map.arrivalS[index] == nil)
            } else {
                #expect(abs(try #require(map.peakPa[index]) - peaks[index]) < 0.02)
                #expect(abs(try #require(map.positiveImpulsePaS[index]) - impulses[index]) < 0.0001)
                #expect(map.arrivalS[index] == arrivals[index])
            }
        }
        #expect(map.arrivalS.last! == nil)
        let reopened = try JSONDecoder().decode(ExposurePlaneSnapshot.self, from: JSONEncoder().encode(map))
        #expect(reopened.arrivalS == map.arrivalS && reopened.everSolid == map.everSolid)
    }

    @Test(
        "Recording and profiled encoder boundaries preserve coarse/refined multi-body results",
        arguments: [1, 2])
    func parity(refinement: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = try MultiBodyTests().scene()
        let config = MultiBodyTests().configuration(refinement: refinement)
        let plain = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        let observed = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        try observed.configureExposurePlane(heightM: 1, arrivalThresholdPa: 1000)
        try observed.enableGPUProfiling(true)
        let a = plain.advance(steps: 12)
        let b = observed.advance(steps: 12)
        #expect(a.steps == b.steps && a.isStable && b.isStable)
        TiledCouplingTests().compare(plain, observed)
        let profile = try #require(observed.lastBatchGPUProfile)
        #expect(
            profile.airS > 0 && profile.mechanicsS > 0 && profile.couplingS > 0 && profile.observationS >= 0)
        #expect(observed.exposureSnapshot()?.elapsedS == observed.time)
    }

    @Test("Batching, time-limit no-ops and restart preserve exposure histories")
    func batching() throws {
        let a = try solver()
        let b = try solver()
        for solver in [a, b] {
            solver.deposit(Charge(mass: 0.001, position: SIMD3(1, 1, 1)))
            solver.restart()
            try solver.configureExposurePlane(heightM: 1, arrivalThresholdPa: 1000)
        }
        _ = a.advance(until: 0.002)
        while b.time < 0.002 - 1e-10 { _ = b.advance(steps: 1, timeLimit: 0.002) }
        let first = try #require(a.exposureSnapshot())
        let second = try #require(b.exposureSnapshot())
        #expect(first.peakPa == second.peakPa && first.positiveImpulsePaS == second.positiveImpulsePaS)
        for (left, right) in zip(first.arrivalS, second.arrivalS) {
            if let left, let right { #expect(abs(left - right) < 1e-8) } else { #expect(left == right) }
        }
        let command = try #require(a.encodeBatch(steps: 8, timeLimit: a.time))
        command.commit()
        command.waitUntilCompleted()
        #expect(a.completeBatch().steps == 0)
        #expect(a.exposureSnapshot()?.positiveImpulsePaS == first.positiveImpulsePaS)
        a.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        _ = a.advance(steps: 2)
        let reset = try #require(a.exposureSnapshot())
        #expect(reset.peakPa.allSatisfy { $0 == 0 } && reset.arrivalS.allSatisfy { $0 == nil })
    }

    @Test("Street fixtures retain common owners and reject overlapping bodies")
    func fixtures() throws {
        let isolated = try StreetInteractionStudy.make(.isolated)
        let pair = try StreetInteractionStudy.make(.pair)
        let street = try StreetInteractionStudy.make(.street)
        #expect(
            isolated.structuralObjects.count == 1 && pair.structuralObjects.count == 2
                && street.structuralObjects.count == 4)
        #expect(isolated.structuralObjects[0].id == pair.structuralObjects[0].id)
        #expect(pair.structuralObjects.map(\.id) == Array(street.structuralObjects.prefix(2)).map(\.id))
        for scene in [isolated, pair, street] {
            try scene.validateObjectOwnership()
            try scene.validateStructuralSeparation()
            #expect(!scene.chargeIsBlocked)
        }
    }
}
