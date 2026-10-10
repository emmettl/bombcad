import Foundation
import Testing
import simd

@testable import BlastCore

/// Reading DEMs and cropping them into a scene's terrain. The fixtures in Samples/Terrain are
/// synthetic (a hill on a gentle slope, one cell missing), written by numpy and tifffile; the
/// LZW and Deflate copies were recompressed by libtiff's tiffcp, which drops the geotags.
@Suite("Elevation grids")
struct ElevationGridTests {
    private static let samples = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Samples/Terrain")

    private func read(_ name: String) throws -> ElevationGrid {
        try ElevationGrid(contentsOf: Self.samples.appending(path: name))
    }

    private func raster(_ name: String) throws -> [Float] {
        try TIFFReader(Data(contentsOf: Self.samples.appending(path: name))).raster().values
    }

    @Test("An ESRI ASCII grid is placed by its corner, south row first, with no data as NaN")
    func ascii() throws {
        let grid = try read("synthetic-hill.asc")
        #expect(grid.columns == 24 && grid.rows == 18)
        #expect(grid.units == .metres)
        #expect(grid.southWest == SIMD2(500_002.5, 4_100_002.5))
        #expect(grid.step == SIMD2(5, 5))
        // The file's third row from the top, fourth column, has no data.
        #expect(grid.elevation(column: 3, row: 15).isNaN)
        #expect(grid.elevations.filter(\.isNaN).count == 1)
        // South-west cell: 100 + 20 exp(-((2.5 - 60)² + (2.5 - 45)²) / 30²) + 0.25.
        let expected = 100 + 20 * exp(-((57.5 * 57.5 + 42.5 * 42.5) / 900)) + 0.25
        #expect(abs(Double(grid.elevation(column: 0, row: 0)) - expected) < 1e-3)
    }

    @Test("A GeoTIFF reads as the same grid, placed by its tie point and scale")
    func geoTIFF() throws {
        let ascii = try read("synthetic-hill.asc")
        let tiff = try read("synthetic-hill.tif")
        #expect(tiff.southWest == ascii.southWest)
        #expect(tiff.step == ascii.step)
        #expect(tiff.units == .metres)
        for (a, b) in zip(ascii.elevations, tiff.elevations) {
            #expect(a.isNaN ? b.isNaN : abs(a - b) < 1e-3)
        }
        let integers = try read("synthetic-hill-int16.tif")
        #expect(integers.elevations.filter(\.isNaN).count == 1)
        #expect(abs(integers.elevation(column: 5, row: 7) / 10 - tiff.elevation(column: 5, row: 7)) < 0.06)
    }

    @Test("LZW and Deflate, with predictors, strips or tiles and either byte order, decode exactly")
    func compression() throws {
        let plain = try raster("synthetic-hill.tif")
        for name in ["synthetic-hill-lzw-fp.tif", "synthetic-hill-be-zip-fp.tif"] {
            #expect(try raster(name) == plain, "\(name)")
        }
        #expect(try raster("synthetic-hill-int16-zip-tiled.tif") == raster("synthetic-hill-int16.tif"))
    }

    @Test("A crop becomes terrain above its lowest point, with missing nodes filled")
    func crop() throws {
        let grid = try read("synthetic-hill.asc")
        let origin = SIMD2(500_010.0, 4_100_010.0)
        let (terrain, report) = try grid.terrain(origin: origin, size: SIMD2(80, 60), spacing: 2.5)
        #expect(terrain.columns == 33 && terrain.rows == 25)
        #expect(terrain.heights.min() == 0)
        #expect(abs(terrain.highest - (report.highest - report.lowest)) < 1e-4)
        // A node on a cell centre takes that cell's elevation.
        let node = try #require(grid.elevation(at: origin + SIMD2(12.5, 7.5)))
        #expect(abs(terrain.height(column: 5, row: 3) - (node - report.lowest)) < 1e-4)
        #expect(abs(node - grid.elevation(column: 4, row: 3)) < 1e-4)
        // The missing cell, (3, 15), is at (17.5, 77.5) m: beyond the crop's top, so none filled.
        #expect(report.filled == 0)
        #expect(throws: ElevationGrid.Failure.outside) {
            try grid.terrain(origin: SIMD2(0, 0), size: SIMD2(10, 10), spacing: 1)
        }
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
