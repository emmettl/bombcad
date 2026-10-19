import Foundation
import simd

/// What `ChargeInference` reads: observers' arrivals and a survey of broken glass, from the files
/// `scenebench infer-charge` and the app's Infer Charge sheet take, placed in metres about a
/// reference point.
///
/// Observers: Rigby et al.'s CSV (video_ref, type, …, toa_best_s, toa_minus_err_s, lat_deg, lon_deg;
/// the fireball's rows left out), or any CSV with `name,lat,lon,earliest_s,latest_s`. Glass:
/// GEER's façade shapefile (each segment's bounding-box centre, class `Facade_num` 1–3 damaged,
/// `Azimuth_N` its normal), or a CSV `lat,lon,class[,normal_azimuth_deg]` (degrees clockwise from
/// north).
public enum ChargeInferenceInputs {
    /// A file that cannot be read as observers or a survey, in words for a person.
    public struct ReadError: LocalizedError, Sendable {
        public var errorDescription: String?
        public init(_ text: String) { errorDescription = text }
    }

    /// Longitude and latitude to metres east and north of `centre`, equirectangular.
    public struct LocalProjection: Sendable {
        public var centre: SIMD2<Double>
        public var east: Double { ElevationGrid.metresPerDegree * cos(centre.y * .pi / 180) }

        public init(centre: SIMD2<Double>) { self.centre = centre }

        public func metres(_ lonLat: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((lonLat.x - centre.x) * east, (lonLat.y - centre.y) * ElevationGrid.metresPerDegree)
        }

        public func lonLat(_ metres: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(centre.x + metres.x / east, centre.y + metres.y / ElevationGrid.metresPerDegree)
        }
    }

    public struct ObserverRow: Sendable, Hashable {
        public var name: String
        public var lonLat: SIMD2<Double>
        public var earliest: Double
        public var latest: Double

        public init(name: String, lonLat: SIMD2<Double>, earliest: Double, latest: Double) {
            self.name = name
            self.lonLat = lonLat
            self.earliest = earliest
            self.latest = latest
        }
    }

    public static func readObservers(_ url: URL) throws -> [ObserverRow] {
        try readObservers(String(contentsOf: url, encoding: .utf8), source: url.lastPathComponent)
    }

    /// Observers from a CSV's text: Rigby et al.'s table, or `name,lat,lon,earliest_s,latest_s`.
    public static func readObservers(_ text: String, source: String = "the file") throws -> [ObserverRow] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.lowercased().split(separator: ",").map({ String($0) }) else {
            return []
        }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        var rows: [ObserverRow] = []
        if let best = column("toa_best_s"), let early = column("toa_minus_err_s"),
            let lat = column("lat_deg"),
            let lon = column("lon_deg"), let type = column("type"), let ref = column("video_ref")
        {
            // Rigby et al. 2020's table.
            for line in lines.dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard f.count > max(best, early, lat, lon), f[type] != "Fireball",
                    let t = Double(f[best]), let e = Double(f[early]), let y = Double(f[lat]),
                    let x = Double(f[lon])
                else { continue }
                rows.append(
                    ObserverRow(name: "\(f[type]) \(f[ref])", lonLat: SIMD2(x, y), earliest: e, latest: t))
            }
        } else if let name = column("name"), let lat = column("lat"), let lon = column("lon"),
            let early = column("earliest_s"), let late = column("latest_s")
        {
            for line in lines.dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard f.count > max(name, lat, lon, early, late), let y = Double(f[lat]),
                    let x = Double(f[lon]),
                    let e = Double(f[early]), let l = Double(f[late])
                else { continue }
                rows.append(ObserverRow(name: f[name], lonLat: SIMD2(x, y), earliest: e, latest: l))
            }
        } else {
            throw ReadError(
                "No observer columns in \(source): Rigby et al.'s, or name,lat,lon,earliest_s,latest_s.")
        }
        return rows
    }

    /// Façades from GEER's shapefile (with its .dbf beside it) or a CSV.
    public static func readFacades(_ url: URL, projection: LocalProjection) throws -> [ChargeInference.Facade]
    {
        if url.pathExtension.lowercased() == "shp" {
            let shapes = try readShapeCentres(url)
            let records = try readDBF(url.deletingPathExtension().appendingPathExtension("dbf"))
            guard shapes.count == records.count else {
                throw ReadError(
                    "\(url.lastPathComponent) has \(shapes.count) shapes but its .dbf \(records.count) records."
                )
            }
            return zip(shapes, records).compactMap { centre, record in
                guard
                    let level = record["Facade_num"].flatMap({
                        Double($0.trimmingCharacters(in: .whitespaces))
                    })
                else { return nil }
                let place = projection.metres(centre)
                // In degrees clockwise from north (0–359 in the layer), though its README says radians.
                let normal = record["Azimuth_N"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    .map { $0 * .pi / 180 }
                return ChargeInference.Facade(
                    east: place.x, north: place.y, damaged: level >= 1, normalAzimuth: normal)
            }
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        return lines.dropFirst().compactMap { line in
            let f = line.split(separator: ",").compactMap { Double($0) }
            guard f.count >= 3 else { return nil }
            let place = projection.metres(SIMD2(f[1], f[0]))
            return ChargeInference.Facade(
                east: place.x, north: place.y, damaged: f[2] >= 1,
                normalAzimuth: f.count > 3 ? f[3] * .pi / 180 : nil)
        }
    }

    /// Each shape's bounding-box centre (longitude, latitude) from an ESRI shapefile.
    public static func readShapeCentres(_ url: URL) throws -> [SIMD2<Double>] {
        let data = try Data(contentsOf: url)
        func bigInt(_ at: Int) -> Int {
            Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
        }
        func double(_ at: Int) -> Double {
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(data[at + k]) << (8 * k) }
            return Double(bitPattern: bits)
        }
        var centres: [SIMD2<Double>] = []
        var offset = 100
        while offset + 8 <= data.count {
            let length = bigInt(offset + 4) * 2
            let content = offset + 8
            guard content + 4 <= data.count else { break }
            let type = Int(data[content]) | Int(data[content + 1]) << 8
            if type == 1 {
                centres.append(SIMD2(double(content + 4), double(content + 12)))
            } else if type != 0 {
                let low = SIMD2(double(content + 4), double(content + 12))
                let high = SIMD2(double(content + 20), double(content + 28))
                centres.append((low + high) / 2)
            } else {
                centres.append(SIMD2(.nan, .nan))
            }
            offset = content + length
        }
        return centres
    }

    /// The records of a dBASE table, as text by field name.
    public static func readDBF(_ url: URL) throws -> [[String: String]] {
        let data = try Data(contentsOf: url)
        guard data.count > 32 else { return [] }
        let count = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        let headerLength = Int(data[8]) | Int(data[9]) << 8
        let recordLength = Int(data[10]) | Int(data[11]) << 8
        var fields: [(name: String, length: Int)] = []
        var at = 32
        while at + 32 <= headerLength, data[at] != 0x0D {
            let nameBytes = data[at..<(at + 11)].prefix { $0 != 0 }
            fields.append((String(decoding: nameBytes, as: UTF8.self), Int(data[at + 16])))
            at += 32
        }
        var records: [[String: String]] = []
        for n in 0..<count {
            var position = headerLength + n * recordLength + 1
            guard position + recordLength - 1 <= data.count else { break }
            var record: [String: String] = [:]
            for field in fields {
                record[field.name] = String(
                    decoding: data[position..<(position + field.length)], as: UTF8.self)
                position += field.length
            }
            records.append(record)
        }
        return records
    }
}
