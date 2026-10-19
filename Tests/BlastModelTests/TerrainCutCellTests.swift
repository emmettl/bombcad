import Foundation
import Testing
import simd

@testable import BlastModel

/// The terrain's ground surface as cut cells.
@Suite("Terrain cut cells")
struct TerrainCutCellTests {
    @Test("Level ground part way up a cell: its share, apertures, wall and the cell its rest goes to")
    func level() {
        let grid = Grid(nx: 4, ny: 3, nz: 6, cellSize: 0.5)
        let domain = SIMD3<Float>(2, 1.5, 3)
        // 0.65 m: the second cell is 0.7 full.
        let high = TerrainCutGeometry(
            terrain: .sampled(domain: domain, spacing: 0.5) { _ in 0.65 }, grid: grid)
        let cell = high.record(1, 1, 1)
        #expect(
            abs(cell.x - 0.7) < 1e-5 && abs(cell.y - 0.7) < 1e-5 && abs(cell.z - 0.7) < 1e-5 && cell.w == 0)
        #expect(high.record(1, 1, 0) == .zero && high.record(1, 1, 2) == .one)
        #expect(high.column(1, 1).w == 1)
        #expect(high.cutColumns.count == grid.nx * grid.ny)
        let wall = high.walls[Int(high.column(1, 1).x)]
        #expect(
            simd_distance(SIMD3(wall.x, wall.y, wall.z), SIMD3(0, 0, -1)) < 1e-6 && abs(wall.w - 1) < 1e-6)
        // 0.9 m: the second cell is 0.2 full, and passes the rest of its difference to the one above.
        let low = TerrainCutGeometry(terrain: .sampled(domain: domain, spacing: 0.5) { _ in 0.9 }, grid: grid)
        #expect(abs(low.alpha(1, 1, 1) - 0.2) < 1e-5)
        #expect(low.column(1, 1).w == 2)
    }

    @Test("Under a slope the cut cells hold the volume above it")
    func slopeVolume() {
        let grid = Grid(nx: 24, ny: 4, nz: 16, cellSize: 0.25)
        let domain = SIMD3<Float>(6, 1, 4)
        let terrain = Terrain.slope(domain: domain, spacing: 0.25, foot: 1, angle: 25)
        let geometry = TerrainCutGeometry(terrain: terrain, grid: grid, samples: 16)
        var air = 0.0
        for k in 0..<grid.nz { for i in 0..<grid.nx { air += Double(geometry.alpha(i, 0, k)) } }
        air *= 0.25 * 0.25 * 0.25 * Double(grid.ny)
        // The ground under the slope: 5 m of rise at tan 25°, and the rest of the box's floor flat.
        let ground = 0.5 * 5 * (5 * tan(25 * Double.pi / 180)) * 1
        let expected = 6.0 * 4.0 * 1.0 - ground
        #expect(abs(air - expected) / expected < 2e-3, "\(air) against \(expected)")
    }
}
