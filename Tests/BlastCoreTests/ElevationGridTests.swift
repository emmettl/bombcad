import Foundation
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Reading DEMs and cropping them into a scene's terrain. The fixtures in Samples/Terrain are
/// synthetic (a hill on a gentle slope, one cell missing), written by numpy and tifffile; the
/// LZW and Deflate copies were recompressed by libtiff's tiffcp, which drops the geotags.
@Suite("Elevation grids", .timeLimit(.minutes(120)))
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

    @Test("A BigTIFF reads as the classic TIFF it was made from")
    func bigTIFF() throws {
        for name in ["synthetic-hill-lzw-fp.tif", "synthetic-hill-int16-zip-tiled.tif", "synthetic-hill.tif"]
        {
            let classic = try Data(contentsOf: Self.samples.appending(path: name))
            let big = try Self.bigTIFF(from: classic)
            #expect(try TIFFReader(big).raster().values == TIFFReader(classic).raster().values, "\(name)")
        }
        // The fixture with georeferencing.
        let classic = try Data(contentsOf: Self.samples.appending(path: "synthetic-hill.tif"))
        let grid = try ElevationGrid(geoTIFF: Self.bigTIFF(from: classic))
        let original = try ElevationGrid(geoTIFF: classic)
        #expect(grid.southWest == original.southWest && grid.step == original.step)
        #expect(grid.elevations.map(\.bitPattern) == original.elevations.map(\.bitPattern))
    }

    /// The same file as a BigTIFF: the classic file's bytes moved 16 on, behind a BigTIFF header,
    /// and its directory written again at the end with 8-byte counts and offsets (the strips' and
    /// tiles' offsets as LONG8).
    static func bigTIFF(from classic: Data) throws -> Data {
        let reader = try TIFFReader(classic)
        let shift = 16
        func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
        guard reader.littleEndian else { throw ElevationGrid.Failure.malformed("the fixture is big-endian") }
        var out = [UInt8]([0x49, 0x49]) + bytes(UInt16(43)) + bytes(UInt16(8)) + bytes(UInt16(0))
        let directory = shift + classic.count
        out += bytes(UInt64(directory))
        out += [UInt8](classic)
        let tags = reader.entries.keys.sorted()
        // Where the directory's out-of-line values go: after it.
        var extra = [UInt8]()
        let extraStart = directory + 8 + 20 * tags.count + 8
        var entries = [UInt8]()
        for tag in tags {
            let entry = reader.entries[tag]!
            var type = entry.type
            var payload = [UInt8](
                classic[entry.offset..<(entry.offset + entry.count * TIFFReader.typeSize(entry.type))])
            if tag == 273 || tag == 324 {
                // Strip or tile offsets: moved by the shift, and as LONG8.
                type = 16
                payload = reader.integers(tag)!.flatMap { bytes(UInt64($0 + shift)) }
            }
            entries += bytes(tag) + bytes(type) + bytes(UInt64(entry.count))
            if payload.count <= 8 {
                entries += payload + [UInt8](repeating: 0, count: 8 - payload.count)
            } else {
                entries += bytes(UInt64(extraStart + extra.count))
                extra += payload
            }
        }
        out += bytes(UInt64(tags.count)) + entries + bytes(UInt64(0)) + extra
        return Data(out)
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
}
