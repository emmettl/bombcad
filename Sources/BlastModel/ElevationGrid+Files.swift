import Foundation
import simd

#if canImport(Compression)
    import Compression
#endif

extension ElevationGrid {
    /// Reads an elevation file by its extension: `.asc` as an ESRI ASCII grid, `.tif` or `.tiff`
    /// as a GeoTIFF.
    public init(contentsOf url: URL, units: Units? = nil) throws {
        switch url.pathExtension.lowercased() {
        case "asc", "txt":
            try self.init(esriASCII: String(contentsOf: url, encoding: .utf8), units: units)
        case "tif", "tiff":
            try self.init(geoTIFF: Data(contentsOf: url), units: units)
        default:
            throw Failure.unsupported("the extension .\(url.pathExtension)")
        }
    }
}

extension ElevationGrid {
    /// Reads a single-band GeoTIFF of elevations: classic TIFF or BigTIFF in either byte order,
    /// in strips or tiles, uncompressed or LZW or Deflate, with or without a horizontal or
    /// floating-point predictor; 8, 16 or 32-bit integers or 32 or 64-bit floats. It is placed by
    /// its ModelPixelScale and ModelTiepoint tags (or a ModelTransformation without rotation), its
    /// units taken from the GeoKeys' model type (geographic means degrees) unless `units` says,
    /// and GDAL's nodata tag is honoured. Map projections are not converted: a projected file's
    /// coordinates are taken as metres.
    public init(geoTIFF data: Data, units: Units? = nil) throws {
        let tiff = try TIFFReader(data)
        let raster = try tiff.raster()
        guard let scale = tiff.doubles(33550), scale.count >= 2 else {
            if let transform = tiff.doubles(34264), transform.count >= 16, transform[1] == 0,
                transform[4] == 0
            {
                try self.init(
                    raster: raster, tiff: tiff,
                    scale: SIMD2(transform[0], -transform[5]), tie: SIMD2(transform[3], transform[7]),
                    tiePixel: .zero, units: units)
                return
            }
            throw Failure.unsupported("no georeferencing (ModelPixelScale and ModelTiepoint)")
        }
        guard let tie = tiff.doubles(33922), tie.count >= 6 else {
            throw Failure.unsupported("no ModelTiepoint")
        }
        try self.init(
            raster: raster, tiff: tiff, scale: SIMD2(scale[0], scale[1]), tie: SIMD2(tie[3], tie[4]),
            tiePixel: SIMD2(tie[0], tie[1]), units: units)
    }
}

extension TIFFReader {
    /// The first band, row by row from the top, as floats.
    func raster() throws -> (width: Int, height: Int, values: [Float]) {
        guard let width = integer(256), let height = integer(257), width > 0, height > 0 else {
            throw ElevationGrid.Failure.malformed("no image size")
        }
        let bits = integer(258) ?? 1
        let samples = integer(277) ?? 1
        let format = integer(339) ?? 1
        let compression = integer(259) ?? 1
        let predictor = integer(317) ?? 1
        let planar = integer(284) ?? 1
        guard [8, 16, 32, 64].contains(bits), bits != 64 || format == 3, format != 3 || bits >= 32 else {
            throw ElevationGrid.Failure.unsupported("\(bits)-bit samples of format \(format)")
        }
        guard [1, 2, 3].contains(format) else {
            throw ElevationGrid.Failure.unsupported("sample format \(format)")
        }
        guard [1, 5, 8, 32946].contains(compression) else {
            throw ElevationGrid.Failure.unsupported("compression \(compression)")
        }
        guard [1, 2, 3].contains(predictor) else {
            throw ElevationGrid.Failure.unsupported("predictor \(predictor)")
        }
        let bytes = bits / 8
        // Planar data keeps the first band's chunks first; chunky data interleaves the samples.
        let stride = planar == 2 ? 1 : samples
        let tiled = entries[322] != nil
        let chunkWidth = tiled ? (integer(322) ?? width) : width
        let chunkHeight = tiled ? (integer(323) ?? height) : min(integer(278) ?? height, height)
        guard chunkWidth > 0, chunkHeight > 0,
            let offsets = integers(tiled ? 324 : 273), let counts = integers(tiled ? 325 : 279),
            offsets.count == counts.count
        else { throw ElevationGrid.Failure.malformed("no strips or tiles") }
        let across = tiled ? (width + chunkWidth - 1) / chunkWidth : 1
        let down = (height + chunkHeight - 1) / chunkHeight
        guard offsets.count >= across * down else {
            throw ElevationGrid.Failure.malformed("too few strips or tiles")
        }
        var values = [Float](repeating: .nan, count: width * height)
        let rowBytes = chunkWidth * stride * bytes
        for chunk in 0..<(across * down) {
            let start = offsets[chunk]
            guard start + counts[chunk] <= data.count else {
                throw ElevationGrid.Failure.malformed("a strip runs past the end")
            }
            let stored = data[(data.startIndex + start)..<(data.startIndex + start + counts[chunk])]
            let expected = rowBytes * chunkHeight
            var raw: [UInt8]
            switch compression {
            case 1: raw = Array(stored)
            case 5: raw = try Self.lzw(Array(stored), expected: expected)
            default: raw = try Self.inflate(Array(stored), expected: expected)
            }
            if raw.count < expected { raw += [UInt8](repeating: 0, count: expected - raw.count) }
            let chunkRows = tiled ? chunkHeight : min(chunkHeight, height - (chunk / across) * chunkHeight)
            for r in 0..<chunkRows {
                let row = Array(raw[(r * rowBytes)..<((r + 1) * rowBytes)])
                let samplesOfRow = try decodeRow(
                    row, count: chunkWidth * stride, bytes: bytes, format: format, predictor: predictor,
                    stride: stride)
                let y = (chunk / across) * chunkHeight + r
                guard y < height else { continue }
                for c in 0..<chunkWidth {
                    let x = (chunk % across) * chunkWidth + c
                    guard x < width else { continue }
                    values[x + width * y] = samplesOfRow[c * stride]
                }
            }
        }
        return (width, height, values)
    }

    /// One row of a strip or tile, undoing its predictor, as floats.
    private func decodeRow(
        _ row: [UInt8], count: Int, bytes: Int, format: Int, predictor: Int, stride: Int
    ) throws -> [Float] {
        var row = row
        var host: [UInt8]
        if predictor == 3 {
            // The floating-point predictor: bytes differenced along the row, then split into planes
            // by significance, the most significant first, whatever the file's byte order.
            guard format == 3 else { throw ElevationGrid.Failure.unsupported("predictor 3 on integers") }
            for n in stride..<row.count { row[n] = row[n] &+ row[n - stride] }
            host = [UInt8](repeating: 0, count: row.count)
            for sample in 0..<count {
                for byte in 0..<bytes {
                    host[bytes * sample + byte] = row[(bytes - byte - 1) * count + sample]
                }
            }
            return (0..<count).map { sample in
                let value = (0..<bytes).reduce(UInt64(0)) {
                    $0 | UInt64(host[bytes * sample + $1]) << (8 * UInt64($1))
                }
                return bytes == 4 ? Float(bitPattern: UInt32(value)) : Float(Double(bitPattern: value))
            }
        }
        var integers = (0..<count).map { Self.read(Data(row), bytes * $0, bytes, littleEndian) }
        if predictor == 2 {
            let mask: UInt64 = bytes == 8 ? .max : (1 << (8 * UInt64(bytes))) - 1
            for n in stride..<count { integers[n] = (integers[n] &+ integers[n - stride]) & mask }
        }
        return integers.map { value in
            switch (format, bytes) {
            case (3, 4): Float(bitPattern: UInt32(value))
            case (3, 8): Float(Double(bitPattern: value))
            case (2, 1): Float(Int8(truncatingIfNeeded: value))
            case (2, 2): Float(Int16(truncatingIfNeeded: value))
            case (2, 4): Float(Int32(truncatingIfNeeded: value))
            default: Float(value)
            }
        }
    }

    /// Deflate, inside zlib's two-byte header and four-byte check.
    static func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        guard input.count > 2 else { throw ElevationGrid.Failure.malformed("an empty Deflate strip") }
        let body = Array(input.dropFirst(2))
        #if canImport(Compression)
            var output = [UInt8](repeating: 0, count: max(expected, 1))
            let written = output.withUnsafeMutableBufferPointer { out in
                body.withUnsafeBufferPointer { source in
                    compression_decode_buffer(
                        out.baseAddress!, out.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else {
                throw ElevationGrid.Failure.malformed("a Deflate strip would not inflate")
            }
            return Array(output.prefix(written))
        #else
            // Without Apple's Compression framework (Linux), Deflate decoded in Swift.
            do {
                let output = try Inflate.decode(body, limit: max(expected, 1))
                guard !output.isEmpty else {
                    throw ElevationGrid.Failure.malformed("a Deflate strip would not inflate")
                }
                return output
            } catch let failure as Inflate.Failure {
                throw ElevationGrid.Failure.malformed(failure.description)
            }
        #endif
    }
}
