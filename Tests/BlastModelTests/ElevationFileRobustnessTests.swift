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

    // MARK: GeoTIFF rasters (fuzzed on a Mac, 28 October 2026)

    /// A little-endian TIFF (a BigTIFF if `big`) of `tags`, each a type and its values (doubles
    /// as their bit patterns), then `body`: offsets in tags 273 and 324 count from the body's
    /// start. Georeferenced at 10 m cells from (500000, 4000000) unless `tags` says otherwise.
    static func tiff(_ tags: [UInt16: (type: UInt16, values: [UInt64])], body: [UInt8], big: Bool = false)
        -> Data
    {
        var tags = tags
        let georeference: [UInt16: (type: UInt16, values: [UInt64])] = [
            33550: (12, [10.0, 10.0, 0.0].map(\.bitPattern)),
            33922: (12, [0.0, 0.0, 0.0, 500_000.0, 4_000_000.0, 0.0].map(\.bitPattern)),
        ]
        tags.merge(georeference) { mine, _ in mine }
        let word = big ? 8 : 4
        let header = big ? 16 : 8
        let directory = (big ? 8 : 2) + (big ? 20 : 12) * tags.count + word
        func size(_ type: UInt16) -> Int { type == 2 ? 1 : type == 3 ? 2 : type == 4 ? 4 : 8 }
        let extraSize = tags.values.map { size($0.type) * $0.values.count }.filter { $0 > word }.reduce(0, +)
        let bodyStart = UInt64(header + directory + extraSize)
        var entries: [UInt8] = little(UInt64(tags.count), big ? 8 : 2)
        var extra: [UInt8] = []
        for tag in tags.keys.sorted() {
            let (type, raw) = tags[tag]!
            let values = tag == 273 || tag == 324 ? raw.map { $0 &+ bodyStart } : raw
            let payload = values.flatMap { little($0, size(type)) }
            entries += little(UInt64(tag), 2) + little(UInt64(type), 2) + little(UInt64(values.count), word)
            if payload.count <= word {
                entries += payload + [UInt8](repeating: 0, count: word - payload.count)
            } else {
                entries += little(UInt64(header + directory + extra.count), word)
                extra += payload
            }
        }
        entries += little(0, word)
        let start: [UInt8] =
            big ? [0x49, 0x49, 43, 0, 8, 0, 0, 0] + little(16, 8) : [0x49, 0x49, 42, 0] + little(8, 4)
        return Data(start + entries + extra + body)
    }

    /// A 4 × 3 raster of 32-bit floats in one uncompressed strip, `samples` given (as a Float's
    /// bit pattern) or 1…12, with `change` made to its tags.
    static func floats(
        _ samples: [Float] = (1...12).map(Float.init), big: Bool = false,
        _ change: (inout [UInt16: (type: UInt16, values: [UInt64])]) -> Void = { _ in }
    ) -> Data {
        let body = samples.flatMap { little(UInt64($0.bitPattern), 4) }
        var tags: [UInt16: (type: UInt16, values: [UInt64])] = [
            256: (3, [4]), 257: (3, [3]), 258: (3, [32]), 259: (3, [1]), 277: (3, [1]), 278: (3, [3]),
            339: (3, [3]), 273: (4, [0]), 279: (4, [UInt64(body.count)]),
        ]
        change(&tags)
        return tiff(tags, body: body, big: big)
    }

    @Test("A plain float GeoTIFF built here reads as written, north row first")
    func geoTIFFBuilt() throws {
        let grid = try ElevationGrid(geoTIFF: Self.floats())
        #expect(grid.columns == 4 && grid.rows == 3)
        // The file's first row is the north one: the grid's last.
        #expect(grid.elevation(column: 0, row: 2) == 1 && grid.elevation(column: 3, row: 0) == 12)
    }

    @Test(
        "A BigTIFF's raster tag past Int's range is refused by name, not trapped on",
        arguments: [UInt16(273), 279, 256, 277])
    func geoTIFFLong8PastInt(tag: UInt16) {
        // A LONG8 of 2⁶³ or more trapped converting to Int, in a strip's offset or count first.
        let data = Self.floats(big: true) { $0[tag] = (16, [UInt64(Int.max) + 1]) }
        #expect(throws: ElevationGrid.Failure.malformed("tag \(tag) is not an unsigned integer an Int holds"))
        {
            try ElevationGrid(geoTIFF: data)
        }
    }

    @Test("A GeoTIFF of no samples per pixel, or of thousands, is refused")
    func geoTIFFSamples() {
        // No samples left each row empty and its first sample out of range; 32,767 of them, each
        // row's bytes copied for each sample, held the reader for minutes.
        for samples: UInt64 in [0, 32_767] {
            #expect(throws: ElevationGrid.Failure.self) {
                try ElevationGrid(geoTIFF: Self.floats { $0[277] = (3, [samples]) })
            }
        }
    }

    @Test("A GeoTIFF claiming more samples than its strips could hold is refused before it is allocated")
    func geoTIFFTooLarge() {
        // 2³² − 1 columns of 18 rows ran the reader out of memory (a raster of 77 billion floats
        // for 48 bytes of strip); 2³² by 2³² trapped multiplying; compressed strips can hold at
        // most 1,032 bytes (Deflate) or 3,000 (LZW) of each they store.
        let wide = Self.floats { $0[256] = (4, [UInt64(UInt32.max)]) }
        let square = Self.floats(big: true) {
            $0[256] = (16, [1 << 32])
            $0[257] = (16, [1 << 32])
            $0[278] = (16, [1 << 32])
        }
        let deflate = Self.floats {
            $0[256] = (4, [1_000_000])
            $0[259] = (3, [8])
        }
        for data in [wide, square, deflate] {
            #expect(throws: ElevationGrid.Failure.self) { try ElevationGrid(geoTIFF: data) }
        }
    }

    @Test("A strip that holds fewer bytes than its rows is refused; a last strip of only its own rows reads")
    func geoTIFFShortStrip() throws {
        // Cut short, the rows missing read as elevations of 0: uncompressed, and a Deflate strip
        // (zlib's header, then one stored block) that inflates to 40 bytes of the 48.
        let short = Self.floats { $0[279] = (4, [40]) }
        #expect(throws: ElevationGrid.Failure.self) { try ElevationGrid(geoTIFF: short) }
        let stored: [UInt8] = [0x78, 0x01, 0x01] + Self.little(40, 2) + Self.little(0xFFFF - 40, 2)
        let compressed = Self.tiff(
            [
                256: (3, [4]), 257: (3, [3]), 258: (3, [32]), 259: (3, [8]), 277: (3, [1]), 278: (3, [3]),
                339: (3, [3]), 273: (4, [0]), 279: (4, [UInt64(stored.count + 40)]),
            ], body: stored + (0..<10).flatMap { _ in Self.little(UInt64(Float(7).bitPattern), 4) })
        #expect(throws: ElevationGrid.Failure.malformed("strip 1 holds 40 bytes of its rows' 48")) {
            try ElevationGrid(geoTIFF: compressed)
        }
        // Two rows a strip: the second strip has one row (16 bytes), as a writer leaves it.
        let strips = Self.floats {
            $0[278] = (3, [2])
            $0[273] = (4, [0, 32])
            $0[279] = (4, [32, 16])
        }
        let grid = try ElevationGrid(geoTIFF: strips)
        #expect(grid.elevations == [9, 10, 11, 12, 5, 6, 7, 8, 1, 2, 3, 4])
    }

    @Test("A GeoTIFF's infinite sample is refused; a NaN one and its nodata value read as no data")
    func geoTIFFInfinite() throws {
        for value in [Float.infinity, -.infinity] {
            var samples = (1...12).map(Float.init)
            samples[5] = value
            #expect(throws: ElevationGrid.Failure.malformed("sample 6 is out of range")) {
                try ElevationGrid(geoTIFF: Self.floats(samples))
            }
        }
        var samples = (1...12).map(Float.init)
        samples[5] = .nan
        samples[6] = -.infinity
        let nodata = Array("-inf\0".utf8).map(UInt64.init)
        let grid = try ElevationGrid(geoTIFF: Self.floats(samples) { $0[42113] = (2, nodata) })
        #expect(grid.elevation(column: 1, row: 1).isNaN && grid.elevation(column: 2, row: 1).isNaN)
    }

    @Test(
        "A GeoTIFF's infinite or NaN cell size or tie point, or corners past a double, is refused",
        arguments: [
            ([Double.infinity, 10, 0], [0, 0, 0, 500_000, 4_000_000, 0]),
            ([10, 10, 0], [0, 0, 0, Double.nan, 4_000_000, 0]),
            ([10, 10, 0], [Double.infinity, 0, 0, 500_000, 4_000_000, 0]),
            ([1e308, 1e308, 0], [0, 0, 0, 1e308, 0, 0]),
        ])
    func geoTIFFPlacement(scale: [Double], tie: [Double]) {
        let data = Self.floats {
            $0[33550] = (12, scale.map(\.bitPattern))
            $0[33922] = (12, tie.map(\.bitPattern))
        }
        #expect(throws: ElevationGrid.Failure.self) { try ElevationGrid(geoTIFF: data) }
    }

    /// A raw Deflate stream of one fixed-Huffman block: a literal 0, `copies` copies of 258
    /// bytes from one back, then the block's end, or (`farBack`) a copy from before the start.
    static func zeros(copies: Int, farBack: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = 0
        var count = 0
        func put(_ value: Int, _ bits: Int, reversed: Bool = false) {
            for n in 0..<bits {
                let bit = reversed ? (value >> (bits - 1 - n)) & 1 : (value >> n) & 1
                buffer |= bit << count
                count += 1
                if count == 8 {
                    bytes.append(UInt8(buffer))
                    buffer = 0
                    count = 0
                }
            }
        }
        put(1, 1)  // the last block
        put(1, 2)  // fixed Huffman codes
        put(0b0011_0000, 8, reversed: true)  // literal 0
        for _ in 0..<copies {
            put(0b1100_0101, 8, reversed: true)  // length 258
            put(0, 5, reversed: true)  // distance 1
        }
        if farBack {
            put(0b1100_0101, 8, reversed: true)
            put(29, 5, reversed: true)  // distance code 29 with its 13 extra bits: 32,768 back
            put(0x1FFF, 13)
        } else {
            put(0, 7, reversed: true)  // end of block
        }
        put(0, 7)
        return bytes
    }

    @Test("Inflate stops a block at its limit, as Apple's decoder stops at its buffer")
    func inflateLimit() throws {
        // A block decoded to its end before its limit was looked at: 1,032 bytes of output a
        // byte of input, and a corrupt code past the limit refused what the Mac reads.
        let whole = try Inflate.decode(Self.zeros(copies: 100, farBack: false))
        #expect(whole.count == 1 + 100 * 258 && whole.allSatisfy { $0 == 0 })
        let limited = try Inflate.decode(Self.zeros(copies: 100, farBack: true), limit: 5_000)
        #expect(limited.count == 5_000 && limited.allSatisfy { $0 == 0 })
        #expect(throws: Inflate.Failure.self) { try Inflate.decode(Self.zeros(copies: 100, farBack: true)) }
    }
}
