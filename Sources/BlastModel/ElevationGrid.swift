import Foundation
import simd

/// A digital elevation model as read from a file: a raster of elevations at the centres of equal
/// cells, in the file's own coordinates (projected metres, or longitude and latitude in degrees),
/// before it is cropped and resampled into a scene's `Terrain`.
public struct ElevationGrid: Sendable, Equatable {
    public enum Units: String, Sendable, Codable { case metres, degrees }

    public var columns: Int
    public var rows: Int
    /// The centre of the south-west cell, and the distance between cell centres along x
    /// (east) and y (north), in `units`.
    public var southWest: SIMD2<Double>
    public var step: SIMD2<Double>
    public var units: Units
    /// Elevation of each cell in metres, south row first and west to east within a row; NaN where
    /// the file has no data.
    public var elevations: [Float]

    public init(
        columns: Int, rows: Int, southWest: SIMD2<Double>, step: SIMD2<Double>, units: Units,
        elevations: [Float]
    ) {
        self.columns = columns
        self.rows = rows
        self.southWest = southWest
        self.step = step
        self.units = units
        self.elevations = elevations
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case unsupported(String)
        case outside
        case noData

        public var description: String {
            switch self {
            case .malformed(let what): "The elevation file is malformed: \(what)."
            case .unsupported(let what): "The elevation file uses \(what), which BombCAD cannot read."
            case .outside: "The scene's crop lies outside the elevation grid."
            case .noData: "The elevation grid has no data under the scene's crop."
            }
        }
    }

    /// The grid with whatever is narrower than a square `2 radius + 1` cells across taken off: a
    /// morphological opening (the least over the square about each cell, then the greatest of
    /// those), which leaves the ground of a surface model without its roofs and trees, assuming
    /// the ground is the lowest point within the square. Slopes and plateaus wider than the square
    /// keep their heights; cells without data are left out of both and stay without.
    public func opened(radius: Int) -> ElevationGrid {
        guard radius > 0 else { return self }
        func filter(_ values: [Float], _ pick: (Float, Float) -> Float) -> [Float] {
            // Rows then columns: a square's extreme is the extreme of its rows' extremes.
            var across = values
            for j in 0..<rows {
                for i in 0..<columns {
                    var best = Float.nan
                    for n in max(i - radius, 0)...min(i + radius, columns - 1) {
                        let value = values[n + columns * j]
                        if !value.isNaN { best = best.isNaN ? value : pick(best, value) }
                    }
                    across[i + columns * j] = best
                }
            }
            var out = across
            for j in 0..<rows {
                for i in 0..<columns {
                    var best = Float.nan
                    for n in max(j - radius, 0)...min(j + radius, rows - 1) {
                        let value = across[i + columns * n]
                        if !value.isNaN { best = best.isNaN ? value : pick(best, value) }
                    }
                    out[i + columns * j] = values[i + columns * j].isNaN ? .nan : best
                }
            }
            return out
        }
        var grid = self
        grid.elevations = filter(filter(elevations, min), max)
        return grid
    }

    /// The north-east cell's centre.
    public var northEast: SIMD2<Double> { southWest + step * SIMD2(Double(columns - 1), Double(rows - 1)) }

    public func elevation(column i: Int, row j: Int) -> Float { elevations[i + columns * j] }

    /// The elevation at `point`, in the grid's coordinates, bilinear between the cell centres round
    /// it (those that have data, weighted as they would be); nil outside the centres' extent or
    /// where none of the four has data.
    public func elevation(at point: SIMD2<Double>) -> Float? {
        let position = (point - southWest) / step
        let last = SIMD2(Double(columns - 1), Double(rows - 1))
        let tolerance = 1e-6
        guard all(position .>= -tolerance), all(position .<= last + tolerance) else { return nil }
        let clamped = simd_clamp(position, .zero, last)
        let low = simd_min(SIMD2<Int>(clamped.rounded(.down)), SIMD2(max(columns - 2, 0), max(rows - 2, 0)))
        let f = clamped - SIMD2<Double>(low)
        var sum = 0.0
        var weight = 0.0
        for corner in 0..<4 {
            let offset = SIMD2(corner & 1, corner >> 1)
            let cell = simd_min(low &+ offset, SIMD2(columns - 1, rows - 1))
            let value = elevations[cell.x + columns * cell.y]
            guard !value.isNaN else { continue }
            let w = (offset.x == 1 ? f.x : 1 - f.x) * (offset.y == 1 ? f.y : 1 - f.y)
            sum += w * Double(value)
            weight += w
        }
        guard weight > 1e-9 else { return nil }
        return Float(sum / weight)
    }
}

// MARK: - Cropping into a scene

extension ElevationGrid {
    /// Metres per degree of latitude, and of longitude at the equator, on a sphere of the Earth's
    /// mean radius (6,371,008.8 m). A local, equirectangular mapping, good to a part in a thousand
    /// over a few kilometres.
    public static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    /// The grid's coordinates of a scene point (x east, y north, in metres) for a scene whose
    /// (0, 0) is at `origin` in the grid's coordinates.
    public func coordinates(of scenePoint: SIMD2<Double>, origin: SIMD2<Double>) -> SIMD2<Double> {
        switch units {
        case .metres: return origin + scenePoint
        case .degrees:
            let east = Self.metresPerDegree * cos(origin.y * .pi / 180)
            return origin + SIMD2(scenePoint.x / east, scenePoint.y / Self.metresPerDegree)
        }
    }

    /// The cell spacing in metres, near `origin`.
    public func spacingInMetres(near origin: SIMD2<Double>) -> SIMD2<Double> {
        switch units {
        case .metres: return step
        case .degrees:
            return step * SIMD2(Self.metresPerDegree * cos(origin.y * .pi / 180), Self.metresPerDegree)
        }
    }

    /// What became of a crop: where its heights came from and what was filled in.
    public struct CropReport: Sendable, Equatable {
        /// The lowest and highest elevation under the crop, metres in the file's datum.
        public var lowest: Float
        public var highest: Float
        /// Nodes with no data in the file under them, given the lowest elevation.
        public var filled: Int
        public var nodes: Int
    }

    /// The scene's terrain from this grid: nodes `spacing` apart covering `size` (the scene's x and
    /// y extent) from `origin`, the grid coordinates of the scene's (0, 0); each the bilinear
    /// elevation there, less `datum` (the crop's lowest elevation unless given), times
    /// `verticalScale`, plus `base`. Nodes with no data are given the crop's lowest elevation.
    public func terrain(
        origin: SIMD2<Double>, size: SIMD2<Float>, spacing: Float, datum: Float? = nil, base: Float = 0,
        verticalScale: Float = 1, name: String? = nil
    ) throws -> (terrain: Terrain, report: CropReport) {
        guard spacing.isFinite, spacing > 0, size.x > 0, size.y > 0 else {
            throw Failure.malformed("the crop needs a positive size and spacing")
        }
        let columns = max(2, Int((size.x / spacing).rounded(.up)) + 1)
        let rows = max(2, Int((size.y / spacing).rounded(.up)) + 1)
        var raw = [Float](repeating: .nan, count: columns * rows)
        let last = SIMD2(Double(self.columns - 1), Double(self.rows - 1))
        var inside = false
        for j in 0..<rows {
            for i in 0..<columns {
                let point = coordinates(
                    of: SIMD2(Double(i), Double(j)) * Double(spacing), origin: origin)
                let position = (point - southWest) / step
                if all(position .>= -1e-6), all(position .<= last + 1e-6) { inside = true }
                raw[i + columns * j] = elevation(at: point) ?? .nan
            }
        }
        guard inside else { throw Failure.outside }
        let valid = raw.filter { !$0.isNaN }
        guard let lowest = valid.min(), let highest = valid.max() else { throw Failure.noData }
        let zero = datum ?? lowest
        let filled = raw.count - valid.count
        let heights = raw.map { max(0, (($0.isNaN ? lowest : $0) - zero) * verticalScale + base) }
        let description =
            (name.map { "\($0), " } ?? "")
            + "from (\(origin.x), \(origin.y)) \(units.rawValue), \(size.x) × \(size.y) m at \(spacing) m"
        let terrain = Terrain(
            spacing: spacing, columns: columns, rows: rows, heights: heights, source: description)
        return (terrain, CropReport(lowest: lowest, highest: highest, filled: filled, nodes: raw.count))
    }
}

// MARK: - ESRI ASCII grid

extension ElevationGrid {
    /// Reads an ESRI ASCII grid (`.asc`): a header of `ncols`, `nrows`, `xllcorner` or
    /// `xllcenter`, `yllcorner` or `yllcenter`, `cellsize` (or `dx` and `dy`) and optionally
    /// `NODATA_value`, then the rows from north to south. The format says nothing of its
    /// coordinates' units: `units` says, or, left nil, degrees are assumed when the cell size is
    /// under a thousandth and the corner lies within longitude and latitude's range.
    public init(esriASCII text: String, units: Units? = nil) throws {
        var header: [String: Double] = [:]
        var centred = (x: false, y: false)
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })[...]
        // A key starts with a letter and is not a number: `nan` or `inf` as the first value is the
        // grid's, not a key (taken as one, it shifted every value by two).
        while let key = tokens.first, let first = key.unicodeScalars.first,
            CharacterSet.letters.contains(first), Double(key) == nil
        {
            tokens = tokens.dropFirst()
            guard let token = tokens.first, let value = Double(token) else {
                throw Failure.malformed("the header's \(key) has no number")
            }
            tokens = tokens.dropFirst()
            let name = key.lowercased()
            if name == "xllcenter" { centred.x = true }
            if name == "yllcenter" { centred.y = true }
            header[name.replacingOccurrences(of: "center", with: "corner")] = value
        }
        // A count that is a whole number no larger than a billion, so that it converts to an Int
        // and two of them multiply without overflow; nil for a fraction, NaN or infinity.
        func count(_ value: Double?) -> Int? {
            guard let value, value.rounded() == value, value >= 2, value <= 1e9 else { return nil }
            return Int(value)
        }
        guard let ncols = count(header["ncols"]), let nrows = count(header["nrows"]),
            let x = header["xllcorner"], let y = header["yllcorner"]
        else { throw Failure.malformed("the header needs ncols, nrows (two or more), xll and yll") }
        guard x.isFinite, y.isFinite else { throw Failure.malformed("the corner is not a finite number") }
        let cell: SIMD2<Double>
        if let size = header["cellsize"] {
            cell = SIMD2(size, size)
        } else if let dx = header["dx"], let dy = header["dy"] {
            cell = SIMD2(dx, dy)
        } else {
            throw Failure.malformed("the header has no cellsize")
        }
        guard cell.x > 0, cell.y > 0, cell.x.isFinite, cell.y.isFinite else {
            throw Failure.malformed("the cell size is not a positive, finite number")
        }
        let noData = header["nodata_value"]
        guard tokens.count >= ncols * nrows else {
            throw Failure.malformed("\(tokens.count) values for \(ncols) × \(nrows) cells")
        }
        var values = [Float](repeating: .nan, count: ncols * nrows)
        var index = tokens.startIndex
        for row in 0..<nrows {
            // The file's first row is the north one.
            let j = nrows - 1 - row
            for i in 0..<ncols {
                guard let value = Double(tokens[index]) else {
                    throw Failure.malformed("value \(row * ncols + i + 1) is not a number")
                }
                index = tokens.index(after: index)
                // NaN reads as no data, as the nodata value does; an elevation beyond a Float's
                // range would read as infinite.
                guard value == noData || !Float(value).isInfinite else {
                    throw Failure.malformed("value \(row * ncols + i + 1) is out of range")
                }
                values[i + ncols * j] = value == noData ? .nan : Float(value)
            }
        }
        let corner = SIMD2(x, y)
        let southWest = corner + SIMD2(centred.x ? 0 : 0.5 * cell.x, centred.y ? 0 : 0.5 * cell.y)
        let guessed: Units =
            cell.x < 1e-3 && abs(corner.x) <= 360 && abs(corner.y) <= 90 ? .degrees : .metres
        self.init(
            columns: ncols, rows: nrows, southWest: southWest, step: cell, units: units ?? guessed,
            elevations: values)
    }
}

// MARK: - GeoTIFF

extension ElevationGrid {
    package init(
        raster: (width: Int, height: Int, values: [Float]), tiff: TIFFReader, scale: SIMD2<Double>,
        tie: SIMD2<Double>, tiePixel: SIMD2<Double>, units: Units?
    ) throws {
        guard scale.x > 0, scale.y > 0 else { throw Failure.unsupported("a rotated or flipped raster") }
        let keys = tiff.shorts(34735) ?? []
        func geoKey(_ id: UInt16) -> UInt16? {
            guard keys.count >= 4 else { return nil }
            for n in 0..<Int(keys[3]) where 4 + 4 * n + 3 < keys.count {
                let entry = keys[(4 + 4 * n)...]
                if entry[entry.startIndex] == id, entry[entry.startIndex + 1] == 0 {
                    return entry[entry.startIndex + 3]
                }
            }
            return nil
        }
        // GTRasterTypeGeoKey 2 places the tie point at a pixel's centre, 1 (the default) at its
        // corner; GTModelTypeGeoKey 2 is geographic.
        let pixelIsPoint = geoKey(1025) == 2
        let geographic = geoKey(1024) == 2
        let noData = tiff.ascii(42113).flatMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)))
        }
        let (width, height) = (raster.width, raster.height)
        var values = [Float](repeating: .nan, count: width * height)
        for row in 0..<height {
            let j = height - 1 - row
            for i in 0..<width {
                let value = raster.values[i + width * row]
                values[i + width * j] =
                    noData.map { Double(value) == $0 || Float($0) == value } == true ? .nan : value
            }
        }
        let centre = pixelIsPoint ? SIMD2<Double>.zero : SIMD2(0.5, 0.5)
        // Pixel (column, row) centre lies at tie + ((column, row) - tiePixel + centre) · (sx, -sy).
        let northWest = tie + (centre - tiePixel) * SIMD2(scale.x, -scale.y)
        let southWest = SIMD2(northWest.x, northWest.y - Double(height - 1) * scale.y)
        self.init(
            columns: width, rows: height, southWest: southWest, step: scale,
            units: units ?? (geographic ? .degrees : .metres), elevations: values)
        guard columns >= 2, rows >= 2 else { throw Failure.malformed("fewer than 2 × 2 cells") }
    }
}

/// Just enough of TIFF to read one band of elevations.
package struct TIFFReader {
    package let data: Data
    package let littleEndian: Bool
    package var entries: [UInt16: (type: UInt16, count: Int, offset: Int)] = [:]

    package init(_ data: Data) throws {
        self.data = data
        guard data.count >= 8 else { throw ElevationGrid.Failure.malformed("too short for a TIFF") }
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw ElevationGrid.Failure.malformed("not a TIFF")
        }
        let magic = Self.read(data, 2, 2, littleEndian)
        // BigTIFF (43) is the classic layout with 8-byte offsets and counts: its directory's count,
        // each entry's count and value, and the header's pointer to the directory.
        guard magic == 42 || magic == 43 else { throw ElevationGrid.Failure.malformed("not a TIFF") }
        let big = magic == 43
        if big, data.count < 16 || Self.read(data, 4, 2, littleEndian) != 8 {
            throw ElevationGrid.Failure.malformed("a BigTIFF header with offsets other than 8 bytes")
        }
        let word = big ? 8 : 4
        let countSize = big ? 8 : 2
        let entrySize = big ? 20 : 12
        // BigTIFF's offsets and counts are 64-bit: one past Int's range, or a sum or product of
        // them past it, is a corrupt file, not a trap.
        guard let ifd = Int(exactly: Self.read(data, big ? 8 : 4, word, littleEndian)),
            ifd <= data.count - countSize
        else {
            throw ElevationGrid.Failure.malformed("the directory is missing")
        }
        guard let count = Int(exactly: Self.read(data, ifd, countSize, littleEndian)) else {
            throw ElevationGrid.Failure.malformed("the directory is cut short")
        }
        for n in 0..<count {
            let at = ifd + countSize + entrySize * n
            guard at + entrySize <= data.count else {
                throw ElevationGrid.Failure.malformed("the directory is cut short")
            }
            let tag = UInt16(Self.read(data, at, 2, littleEndian))
            let type = UInt16(Self.read(data, at + 2, 2, littleEndian))
            guard let values = Int(exactly: Self.read(data, at + 4, word, littleEndian)),
                case (let size, let overflow) = values.multipliedReportingOverflow(by: Self.typeSize(type)),
                !overflow,
                let offset = size <= word
                    ? at + 4 + word : Int(exactly: Self.read(data, at + 4 + word, word, littleEndian)),
                offset <= data.count, size <= data.count - offset
            else {
                throw ElevationGrid.Failure.malformed("tag \(tag) runs past the end")
            }
            entries[tag] = (type, values, offset)
        }
    }

    static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12, 16, 17, 18: 8
        default: 1
        }
    }

    package static func read(_ data: Data, _ offset: Int, _ size: Int, _ littleEndian: Bool) -> UInt64 {
        var value: UInt64 = 0
        for n in 0..<size {
            let byte = UInt64(data[data.startIndex + offset + n])
            value |= littleEndian ? byte << (8 * UInt64(n)) : byte << (8 * UInt64(size - 1 - n))
        }
        return value
    }

    package func integers(_ tag: UInt16) -> [Int]? {
        guard let entry = entries[tag] else { return nil }
        let size = Self.typeSize(entry.type)
        guard [1, 3, 4, 16].contains(entry.type) else { return nil }
        return (0..<entry.count).map { Int(Self.read(data, entry.offset + size * $0, size, littleEndian)) }
    }

    package func integer(_ tag: UInt16) -> Int? { integers(tag)?.first }

    func shorts(_ tag: UInt16) -> [UInt16]? { integers(tag)?.map { UInt16(truncatingIfNeeded: $0) } }

    package func doubles(_ tag: UInt16) -> [Double]? {
        guard let entry = entries[tag] else { return nil }
        switch entry.type {
        case 12:
            return (0..<entry.count).map {
                Double(bitPattern: Self.read(data, entry.offset + 8 * $0, 8, littleEndian))
            }
        case 11:
            return (0..<entry.count).map {
                Double(Float(bitPattern: UInt32(Self.read(data, entry.offset + 4 * $0, 4, littleEndian))))
            }
        default:
            return integers(tag)?.map(Double.init)
        }
    }

    func ascii(_ tag: UInt16) -> String? {
        guard let entry = entries[tag], entry.type == 2 else { return nil }
        let start = data.startIndex + entry.offset
        return String(decoding: data[start..<start + entry.count].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// TIFF's LZW: codes most significant bit first, starting 9 bits wide, widening a code early.
    package static func lzw(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(expected)
        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] } + [[], []]
        var width = 9
        var bitPosition = 0
        var previous: [UInt8]? = nil
        func next() -> Int? {
            guard bitPosition + width <= input.count * 8 else { return nil }
            var code = 0
            for _ in 0..<width {
                let byte = input[bitPosition >> 3]
                code = (code << 1) | Int((byte >> (7 - UInt8(bitPosition & 7))) & 1)
                bitPosition += 1
            }
            return code
        }
        while let code = next() {
            if code == 257 { break }
            if code == 256 {
                table.removeSubrange(258...)
                width = 9
                previous = nil
                continue
            }
            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if let previous, code == table.count {
                entry = previous + [previous[0]]
            } else {
                throw ElevationGrid.Failure.malformed("an LZW code out of sequence")
            }
            output += entry
            if let previous { table.append(previous + [entry[0]]) }
            previous = entry
            if table.count + 1 >= (1 << width), width < 12 { width += 1 }
            if output.count >= expected { break }
        }
        return output
    }
}
