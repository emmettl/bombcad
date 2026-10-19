import Foundation
import Testing
import simd

@testable import BlastModel

/// Reading DEMs and cropping them into a scene's terrain. The fixtures in Samples/Terrain are
/// synthetic (a hill on a gentle slope, one cell missing), written by numpy and tifffile; the
/// LZW and Deflate copies were recompressed by libtiff's tiffcp, which drops the geotags.
@Suite("Elevation grids", .timeLimit(.minutes(120)))
struct ElevationGridTests {
    @Test("An opening takes off what is narrower than its square and leaves a slope as it was")
    func opening() {
        // A ramp rising 1 m a cell east, with a building 3 cells across and 20 m tall on it.
        var elevations = (0..<15).flatMap { _ in (0..<15).map { Float($0) } }
        for j in 6...8 { for i in 6...8 { elevations[i + 15 * j] += 20 } }
        elevations[0] = .nan
        let grid = ElevationGrid(
            columns: 15, rows: 15, southWest: .zero, step: SIMD2(30, 30), units: .metres,
            elevations: elevations)
        let ground = grid.opened(radius: 2)
        #expect(ground.elevations[0].isNaN)
        for j in 2..<13 {
            for i in 2..<13 { #expect(ground.elevation(column: i, row: j) == Float(i), "\(i) \(j)") }
        }
        #expect(grid.opened(radius: 0) == grid)
    }

    @Test("A grid in degrees is cropped by local metres")
    func degrees() throws {
        let text = """
            ncols 3
            nrows 2
            xllcenter -3.0
            yllcenter 51.0
            cellsize 0.0002777778
            1 2 3
            4 5 6
            """
        let grid = try ElevationGrid(esriASCII: text)
        #expect(grid.units == .degrees)
        #expect(grid.southWest == SIMD2(-3, 51))
        #expect(grid.elevation(column: 0, row: 0) == 4 && grid.elevation(column: 2, row: 1) == 3)
        let metres = grid.spacingInMetres(near: grid.southWest)
        #expect(abs(metres.y - 30.88) < 0.01)
        #expect(abs(metres.x - 30.88 * cos(51 * Double.pi / 180)) < 0.01)
        let (terrain, report) = try grid.terrain(origin: grid.southWest, size: SIMD2(20, 30), spacing: 10)
        // 10 m east of the south-west centre is 10 / 19.43 of the way to the next, 4 to 5; the
        // lowest point, 30 m north of the corner, is 30 / 30.88 of the way from 4 to 1.
        #expect(abs(report.lowest - Float(4 - 3 * 30 / metres.y)) < 1e-3)
        #expect(abs(terrain.height(column: 1, row: 0) - (4 + Float(10 / metres.x) - report.lowest)) < 1e-3)
    }
}
