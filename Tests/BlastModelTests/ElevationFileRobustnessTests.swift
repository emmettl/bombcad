import Foundation
import Testing

@testable import BlastModel

/// Elevation files that trapped or misread the ESRI ASCII and TIFF readers, found by
/// Scripts/fuzz/fuzz-importers.py and by reading the readers for what it pointed at
/// (docs/linux.md#sanitizers-and-importer-fuzzing-20-october-2026 has the runs). Before its fix, each trapped or read as nonsense.
@Suite("Elevation readers refuse corrupt files")
struct ElevationFileRobustnessTests {
    static func asc(
        ncols: String = "3", nrows: String = "2", corner: String = "0", cell: String = "10",
        values: String = "1 2 3\n4 5 6\n"
    ) -> String {
        "ncols \(ncols)\nnrows \(nrows)\nxllcorner \(corner)\nyllcorner 0\ncellsize \(cell)\nNODATA_value -9999\n"
            + values
    }

    @Test(
        "An elevation grid's counts that are not whole numbers an Int holds are refused",
        arguments: ["1e300", "nan", "inf", "2.5", "-3", "9223372036854775807", "4294967296"])
    func gridCounts(ncols: String) {
        // 1e300, NaN and Int.max trapped converting to Int; 2³² by 2³² overflowed multiplying;
        // 2.5 read as 2 columns.
        #expect(throws: ElevationGrid.Failure.self) {
            try ElevationGrid(esriASCII: Self.asc(ncols: ncols, nrows: ncols == "4294967296" ? ncols : "2"))
        }
    }

    @Test(
        "An elevation grid's infinite cell size, NaN corner or elevation past a Float's range is refused",
        arguments: [
            ElevationFileRobustnessTests.asc(cell: "inf"), ElevationFileRobustnessTests.asc(corner: "nan"),
            ElevationFileRobustnessTests.asc(corner: "inf"),
            ElevationFileRobustnessTests.asc(values: "1 2 3\n4 1e39 6\n"),
            ElevationFileRobustnessTests.asc(values: "1 2 3\n4 -inf 6\n"),
        ])
    func gridValues(text: String) {
        #expect(throws: ElevationGrid.Failure.self) { try ElevationGrid(esriASCII: text) }
    }

    @Test("An elevation grid's NaN and nodata cells still read as no data")
    func gridNoData() throws {
        let grid = try ElevationGrid(esriASCII: Self.asc(values: "1 nan 3\n4 -9999 6\n"))
        #expect(grid.elevation(column: 1, row: 1).isNaN && grid.elevation(column: 1, row: 0).isNaN)
        #expect(grid.elevation(column: 0, row: 0) == 4)
    }

    @Test("A grid whose first value is nan reads it as no data, not as a header key")
    func gridLeadingNaN() throws {
        // Taken as a key, `nan` swallowed the value after it and shifted the rest by two.
        let grid = try ElevationGrid(esriASCII: Self.asc(values: "nan 2 3\n4 5 6\n"))
        #expect(grid.elevation(column: 0, row: 1).isNaN)
        #expect(grid.elevation(column: 1, row: 1) == 2 && grid.elevation(column: 2, row: 0) == 6)
    }

    /// A little-endian BigTIFF header pointing at a directory at `ifd`, followed by `rest`.
    static func bigTIFF(ifd: UInt64, _ rest: [UInt8] = []) -> Data {
        var bytes: [UInt8] = [0x49, 0x49, 43, 0, 8, 0, 0, 0]
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: ifd >> (8 * $0)) }
        return Data(bytes + rest)
    }

    static func little(_ value: UInt64, _ size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// A directory of one entry (tag 256, SHORT) of `count` values at `offset`, and no next one.
    static func directory(count: UInt64, offset: UInt64) -> [UInt8] {
        little(1, 8) + little(256, 2) + little(3, 2) + little(count, 8) + little(offset, 8) + little(0, 8)
    }

    @Test(
        "A BigTIFF's 64-bit offsets and counts past Int's range are refused, not trapped on",
        arguments: [
            ElevationFileRobustnessTests.bigTIFF(ifd: .max),
            ElevationFileRobustnessTests.bigTIFF(ifd: UInt64(Int.max)),
            ElevationFileRobustnessTests.bigTIFF(ifd: 16, ElevationFileRobustnessTests.little(.max, 8)),
            ElevationFileRobustnessTests.bigTIFF(
                ifd: 16, ElevationFileRobustnessTests.directory(count: UInt64(Int.max), offset: 0)),
            ElevationFileRobustnessTests.bigTIFF(
                ifd: 16, ElevationFileRobustnessTests.directory(count: 100, offset: UInt64(Int.max) - 15)),
        ])
    func bigTIFFOverflow(data: Data) {
        #expect(throws: ElevationGrid.Failure.self) { try TIFFReader(data) }
    }

    @Test("A BigTIFF directory within its file still reads")
    func bigTIFFWithin() throws {
        // One SHORT value, held in the entry itself.
        let tiff = try TIFFReader(Self.bigTIFF(ifd: 16, Self.directory(count: 1, offset: 7)))
        #expect(tiff.integer(256) == 7)
    }
}
