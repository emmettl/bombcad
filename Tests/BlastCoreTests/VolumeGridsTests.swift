import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("The air as volume grids")
struct VolumeGridsTests {
    @Test("Peak and impulse come from the solver's fields, in kPa and Pa·s, and follow the blast")
    func peakAndImpulse() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Grids", domainSize: SIMD3(repeating: 4),
            boxes: [Box(min: SIMD3(3, 0, 0), max: SIMD3(4, 4, 2))],
            charge: Charge(mass: 0.05, position: SIMD3(1.5, 2, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        _ = solver.advance(until: 0.002)
        let grids = solver.volumeGrids(fields: BlastSolver.volumeFields)
        #expect(grids.map(\.name) == ["overpressure", "shock", "peak", "impulse"])
        #expect(solver.volumeGrids().map(\.name) == BlastSolver.defaultVolumeFields)
        let (overpressure, peak, impulse) = (grids[0].values, grids[2].values, grids[3].values)
        var stored: (peak: [Float], impulse: [Float]) = ([], [])
        solver.setFields { peak, impulse in stored = (Array(peak), Array(impulse)) }
        let cells = solver.grid.cellCount
        var solid = 0
        for n in 0..<cells {
            let (i, j, k) = (
                n % solver.grid.nx, n / solver.grid.nx % solver.grid.ny, n / solver.grid.nx / solver.grid.ny
            )
            if solver.isSolid(i, j, k) {
                solid += 1
                #expect(peak[n] == 0 && impulse[n] == 0)
                continue
            }
            #expect(peak[n] == stored.peak[n] / 1000 && impulse[n] == stored.impulse[n])
            // The peak so far is at least the overpressure now, within the 16-bit visualisation's
            // rounding.
            #expect(overpressure[n] <= peak[n] * 1.002 + 0.01, "cell \(n)")
            #expect(impulse[n] >= 0)
        }
        #expect(solid > 0)
        // The blast has been through the charge's cell: a high peak and some impulse there.
        let charge = solver.grid.index(6, 8, 4)
        #expect(peak[charge] > 100 && impulse[charge] > 1)
        #expect(peak.max()! > overpressure.max()!)
    }
}
