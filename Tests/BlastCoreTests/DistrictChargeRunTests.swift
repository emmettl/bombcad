import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// File ▸ New District's charge on a building (Fixtures/SyntheticDistrict, whose charge lies inside
/// its centre block), run: with the building cleared it goes off on both kinds of air.
@Suite("District charge on a building, run")
struct DistrictChargeRunTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/SyntheticDistrict")

    @Test("A charge on a building goes off on refined air as on uniform cells, the building cleared")
    func chargeOnBuilding() throws {
        let buildings = try MapBuilding.read(contentsOf: Self.folder.appending(path: "district.osm"))
        var layout = DistrictLayout(
            buildings: buildings,
            charge: SIMD2(612 / ElevationGrid.metresPerDegree, 608 / ElevationGrid.metresPerDegree),
            mass: 1_000)
        layout.heights = try ElevationGrid(contentsOf: Self.folder.appending(path: "heights.asc"))
        layout.ground = DistrictLayout.ground(
            try ElevationGrid(contentsOf: Self.folder.appending(path: "ground.asc")), openingM: 0, seaM: 1)
        let half = layout.halfSide(radius: 100, cellSize: 10)
        // Footprints on the refined air's finest cells.
        let (scene, report) = try layout.scene(halfSide: half, cellSize: 10, radius: 100, footprintCells: 5)
        #expect(report.clearedCharge)
        let device = try #require(MTLCreateSystemDefaultDevice())
        // The largest overpressure 40–60 m from the charge after 0.15 s.
        func peak(refined: Bool) throws -> Float {
            var config = SolverConfiguration.recommended
            if refined {
                config.refinement = 2
                config.refinementCeiling = layout.refinementCeiling(radius: 100, cellSize: 10)
            }
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 10, configuration: config)
            _ = solver.advance(until: 0.15)
            let grid = solver.grid
            var largest: Float = 0
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * 10
                        let d = simd_length(
                            SIMD2(centre.x, centre.y)
                                - SIMD2(scene.charge.position.x, scene.charge.position.y))
                        if d >= 40, d <= 60 { largest = max(largest, solver.peakOverpressure(i, j, k)) }
                    }
                }
            }
            return largest
        }
        let uniform = try peak(refined: false)
        let refined = try peak(refined: true)
        // Both go off: 16 kPa on the 10 m cells, 31 kPa refined to 5 m (Kingery–Bulmash about 40 kPa
        // at 50 m for 1 t on the ground).
        #expect(uniform > 10_000 && refined > uniform, "\(uniform) \(refined)")
    }
}
