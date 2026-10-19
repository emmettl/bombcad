import BlastCore
import Foundation

/// `scenebench infer-charge`: the charge (its TNT mass, place and, if asked, height and clock
/// offset) inferred from observed arrivals and, optionally, surveyed broken glass
/// (`ChargeInference`).
///
/// ```
/// scenebench infer-charge --observers rigby.csv [--centre lon,lat] [--glass Facade_damage.shp|facades.csv]
///     [--correction a.json,b.json] [--temperature 30] [--mass-range 1e4,1e7] [--radius 500]
///     [--height 0,200] [--offset -0.2,0.2] [--glass-load facing|incident|reflected]
///     [--glazing apartments|older|commercial|industrial] [--exposure 1] [--exposure-spread 0.8]
///     [--glass-concentration 30] [--steps 3000] [--walkers 48] [--seed 1]
///     [--out posterior.json] [--samples samples.csv]
/// ```
///
/// Observers: Rigby et al.'s CSV (video_ref, type, …, toa_best_s, toa_minus_err_s, lat_deg, lon_deg;
/// the fireball's rows left out), or any CSV with `name,lat,lon,earliest_s,latest_s`. Glass:
/// GEER's façade shapefile (each segment's bounding-box centre, class `Facade_num` 1–3 damaged,
/// `Azimuth_N` its normal), or a CSV `lat,lon,class[,normal_azimuth_rad]`. Corrections: BombCAD's
/// `district-compare` comparison.json files, one per yield, whose arrivals over Kingery–Bulmash's
/// become each observer's ratio (matched by name and distance).
enum InferCharge {
    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--" + name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func pair(_ name: String) throws -> ClosedRange<Double>? {
            guard let text = value(name) else { return nil }
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, parts[0] <= parts[1] else {
                throw BlastError.allocationFailed("--\(name) a,b")
            }
            return parts[0]...parts[1]
        }
        guard let observersPath = value("observers") else {
            throw BlastError.allocationFailed("--observers file.csv")
        }
        let rows = try readObservers(URL(filePath: observersPath))
        guard !rows.isEmpty else { throw BlastError.allocationFailed("observers in \(observersPath)") }
        let centre: SIMD2<Double>
        if let text = value("centre") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { throw BlastError.allocationFailed("--centre lon,lat") }
            centre = SIMD2(parts[0], parts[1])
        } else {
            centre = rows.reduce(SIMD2<Double>.zero) { $0 + $1.lonLat } / Double(rows.count)
        }
        let projection = LocalProjection(centre: centre)
        let corrections =
            try value("correction").map { list in
                try list.split(separator: ",").map { try readCorrection(URL(filePath: String($0))) }
            } ?? []
        var arrivals: [ChargeInference.Arrival] = []
        var unmatched = 0
        for row in rows {
            let place = projection.metres(row.lonLat)
            let distance = hypot(place.x, place.y)
            var ratios: [(massKg: Double, ratio: Double)] = []
            for run in corrections {
                if let match = run.arrivals.first(where: {
                    $0.name == row.name && abs($0.distance - distance) < 30
                }) {
                    ratios.append((run.massKg, match.ratio))
                }
            }
            if !corrections.isEmpty && ratios.count < corrections.count { unmatched += 1 }
            arrivals.append(
                ChargeInference.Arrival(
                    name: row.name, east: place.x, north: place.y, earliest: row.earliest, latest: row.latest,
                    ratios: ratios))
        }
        var facades: [ChargeInference.Facade] = []
        if let path = value("glass") {
            facades = try readFacades(URL(filePath: path), projection: projection)
        }

        var settings = ChargeInference.Settings()
        if let t = value("temperature").flatMap(Double.init) { settings.temperatureC = t }
        if let range = try pair("mass-range") { settings.massRange = range }
        if let radius = value("radius").flatMap(Double.init) { settings.placeRadius = radius }
        settings.heightRange = try pair("height")
        settings.offsetRange = try pair("offset")
        if let load = value("glass-load") {
            guard let parsed = ChargeInference.GlassLoad(rawValue: load) else {
                throw BlastError.allocationFailed("--glass-load facing|incident|reflected")
            }
            settings.glassLoad = parsed
        }
        if let name = value("glazing") {
            let mixes: [String: GlazingMix] = [
                "apartments": .apartments, "older": .olderLowRise, "commercial": .commercial,
                "industrial": .industrial,
            ]
            guard let mix = mixes[name] else { throw BlastError.allocationFailed("--glazing \(name)") }
            settings.glazing = mix
        }
        if let median = value("exposure").flatMap(Double.init) { settings.exposureMedian = median }
        if let spread = value("exposure-spread").flatMap(Double.init) { settings.exposureSpread = spread }
        if let kappa = value("glass-concentration").flatMap(Double.init) {
            settings.glassConcentration = kappa
        }
        if let steps = value("steps").flatMap(Int.init) { settings.steps = steps }
        if let walkers = value("walkers").flatMap(Int.init) { settings.walkers = walkers }
        if let seed = value("seed").flatMap(UInt64.init) { settings.seed = seed }

        if let kt = value("glass-curve").flatMap(Double.init) {
            print(
                String(
                    format: "The glass at %.2f kt at the reference point: band, façades, GEER damaged, model",
                    kt))
            for band in ChargeInference.glassBands(massKg: kt * 1e6, facades: facades, settings: settings) {
                print(
                    String(
                        format: "  %5.0f–%5.0f m  %5d  %.2f  %.2f", band.fromM,
                        band.fromM + settings.glassBandM,
                        band.count, band.observed, band.model))
            }
            return
        }
        print(
            "\(arrivals.count) arrivals" + (facades.isEmpty ? "" : ", \(facades.count) façades")
                + (corrections.isEmpty
                    ? ""
                    : ", BombCAD's ratios from \(corrections.count) runs (\(unmatched) observers unmatched)")
                + String(
                    format: "; reference %.6f N %.6f E, %.0f °C", centre.y, centre.x, settings.temperatureC))
        let start = ContinuousClock.now
        let posterior = ChargeInference.infer(arrivals: arrivals, facades: facades, settings: settings)
        let elapsed = ContinuousClock.now - start
        report(posterior, arrivals: arrivals, projection: projection, settings: settings)
        print(
            String(
                format: "%d samples, acceptance %.2f, R-hat %.3f, %.1f s", posterior.samples.count,
                posterior.acceptance, posterior.rHat,
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18))

        if let out = value("out") {
            let summary = Output(
                centre: [centre.x, centre.y], temperatureC: settings.temperatureC, arrivals: arrivals.count,
                facades: facades.count, corrections: corrections.map(\.massKg),
                acceptance: posterior.acceptance,
                rHat: posterior.rHat, parameters: posterior.summaries,
                yieldKt: kilotonnes(posterior),
                place: place(posterior, projection: projection))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: URL(filePath: out))
        }
        if let path = value("samples") {
            var text = posterior.names.joined(separator: ",") + ",logLikelihood\n"
            for (row, likelihood) in zip(posterior.samples, posterior.logLikelihoods) {
                text += row.map { String($0) }.joined(separator: ",") + ",\(likelihood)\n"
            }
            try text.write(to: URL(filePath: path), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Reporting

    struct Output: Codable {
        var centre: [Double]
        var temperatureC: Double
        var arrivals: Int
        var facades: Int
        var corrections: [Double]
        var acceptance: Double
        var rHat: Double
        var parameters: [ChargeInference.Summary]
        var yieldKt: [String: Double]
        var place: [String: Double]
    }

    /// The yield's median and credible bounds in kilotonnes of TNT.
    static func kilotonnes(_ posterior: ChargeInference.Posterior) -> [String: Double] {
        guard let s = posterior.summary("log10MassKg") else { return [:] }
        func kt(_ v: Double) -> Double { pow(10, v) / 1e6 }
        return [
            "median": kt(s.median), "p05": kt(s.p05), "p16": kt(s.p16), "p84": kt(s.p84), "p95": kt(s.p95),
        ]
    }

    /// The place's median (east, north, latitude, longitude, distance from the reference) and the
    /// radii holding half and 90% of the samples.
    static func place(_ posterior: ChargeInference.Posterior, projection: LocalProjection) -> [String: Double]
    {
        guard let e = posterior.summary("east"), let n = posterior.summary("north") else { return [:] }
        let lonLat = projection.lonLat(SIMD2(e.median, n.median))
        return [
            "east": e.median, "north": n.median, "latitude": lonLat.y, "longitude": lonLat.x,
            "fromReference": hypot(e.median, n.median), "radius50": posterior.placeRadius(holding: 0.5),
            "radius90": posterior.placeRadius(holding: 0.9),
        ]
    }

    static func report(
        _ posterior: ChargeInference.Posterior, arrivals: [ChargeInference.Arrival],
        projection: LocalProjection,
        settings: ChargeInference.Settings
    ) {
        let kt = kilotonnes(posterior)
        print(
            String(
                format: "Yield: %.3f kt TNT (68%%: %.3f–%.3f, 90%%: %.3f–%.3f)", kt["median"] ?? 0,
                kt["p16"] ?? 0,
                kt["p84"] ?? 0, kt["p05"] ?? 0, kt["p95"] ?? 0))
        let location = place(posterior, projection: projection)
        print(
            String(
                format:
                    "Place: %.6f N %.6f E, %.0f m E %.0f m N of the reference (%.0f m off it); half the samples within %.0f m, 90%% within %.0f m",
                location["latitude"] ?? 0, location["longitude"] ?? 0, location["east"] ?? 0,
                location["north"] ?? 0,
                location["fromReference"] ?? 0, location["radius50"] ?? 0, location["radius90"] ?? 0))
        for name in ["height", "offset"] {
            if let s = posterior.summary(name) {
                print(
                    String(
                        format: "%@: %.3f (68%%: %.3f–%.3f, 90%%: %.3f–%.3f)", name, s.median, s.p16, s.p84,
                        s.p05,
                        s.p95))
            }
        }
        if let s = posterior.summary("logSpread") {
            print(
                String(
                    format: "Observers off the model by %.1f%% (90%%: %.1f–%.1f%%)", 100 * exp(s.median),
                    100 * exp(s.p05), 100 * exp(s.p95)))
        }
        // Each observer against the median charge.
        guard let mass = posterior.summary("log10MassKg").map({ pow(10, $0.median) }),
            let east = posterior.summary("east")?.median, let north = posterior.summary("north")?.median
        else { return }
        let height = posterior.summary("height")?.median ?? 0
        let offset = posterior.summary("offset")?.median ?? 0
        let sound = ChargeInference.soundSpeedRatio(temperatureC: settings.temperatureC)
        let outliers = ChargeInference.outlierChances(posterior, arrivals: arrivals, settings: settings)
        print("observer            range (m)  observed (s)       model (s)  model/observed  outlier")
        for (observer, outlier) in zip(arrivals, outliers).sorted(by: {
            hypot($0.0.east, $0.0.north) < hypot($1.0.east, $1.0.north)
        }) {
            let range = (pow(observer.east - east, 2) + pow(observer.north - north, 2) + height * height)
                .squareRoot()
            let t =
                ChargeInference.arrival(massKg: mass, range: range, soundRatio: sound)
                * (observer.ratios.isEmpty ? 1 : ratio(observer, mass)) + offset
            let middle = 0.5 * (observer.earliest + observer.latest)
            print(
                observer.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                    + String(
                        format: " %9.0f  %.3f–%.3f  %10.3f  %14.3f  %7.2f", range, observer.earliest,
                        observer.latest,
                        t, t / middle, outlier))
        }
    }

    /// The observer's ratio at `massKg`, as `ChargeInference` interpolates it.
    static func ratio(_ observer: ChargeInference.Arrival, _ massKg: Double) -> Double {
        let ratios = observer.ratios
        guard let first = ratios.first, let last = ratios.last else { return 1 }
        if massKg <= first.massKg { return first.ratio }
        if massKg >= last.massKg { return last.ratio }
        for (a, b) in zip(ratios, ratios.dropFirst()) where massKg <= b.massKg {
            return a.ratio + log(massKg / a.massKg) / log(b.massKg / a.massKg) * (b.ratio - a.ratio)
        }
        return last.ratio
    }

    // MARK: - Inputs

    /// Longitude and latitude to metres east and north of `centre`, equirectangular.
    struct LocalProjection {
        var centre: SIMD2<Double>
        var east: Double { ElevationGrid.metresPerDegree * cos(centre.y * .pi / 180) }

        func metres(_ lonLat: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((lonLat.x - centre.x) * east, (lonLat.y - centre.y) * ElevationGrid.metresPerDegree)
        }

        func lonLat(_ metres: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(centre.x + metres.x / east, centre.y + metres.y / ElevationGrid.metresPerDegree)
        }
    }

    struct ObserverRow {
        var name: String
        var lonLat: SIMD2<Double>
        var earliest: Double
        var latest: Double
    }

    static func readObservers(_ url: URL) throws -> [ObserverRow] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(
            String.init)
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
            throw BlastError.allocationFailed(
                "observer columns (Rigby's, or name,lat,lon,earliest_s,latest_s) in \(url.path)")
        }
        return rows
    }

    struct Correction {
        var massKg: Double
        var arrivals: [(name: String, distance: Double, ratio: Double)]
    }

    /// A `district-compare` comparison.json: its charge and each observer's arrival over
    /// Kingery–Bulmash's.
    static func readCorrection(_ url: URL) throws -> Correction {
        struct Report: Decodable {
            struct Arrival: Decodable {
                var name: String
                var distanceM: Double
                var simulatedS: Double?
                var kingeryBulmashS: Double?
            }
            var massKg: Double
            var arrivals: [Arrival]
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        return Correction(
            massKg: report.massKg,
            arrivals: report.arrivals.compactMap { a in
                guard let s = a.simulatedS, let k = a.kingeryBulmashS, k > 0 else { return nil }
                return (a.name, a.distanceM, s / k)
            })
    }

    /// Façades from GEER's shapefile (with its .dbf beside it) or a CSV.
    static func readFacades(_ url: URL, projection: LocalProjection) throws -> [ChargeInference.Facade] {
        if url.pathExtension.lowercased() == "shp" {
            let shapes = try readShapeCentres(url)
            let records = try readDBF(url.deletingPathExtension().appendingPathExtension("dbf"))
            guard shapes.count == records.count else {
                throw BlastError.allocationFailed(
                    "as many records in the .dbf as shapes in \(url.lastPathComponent)")
            }
            return zip(shapes, records).compactMap { centre, record in
                guard
                    let level = record["Facade_num"].flatMap({
                        Double($0.trimmingCharacters(in: .whitespaces))
                    })
                else { return nil }
                let place = projection.metres(centre)
                let normal = record["Azimuth_N"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
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
                east: place.x, north: place.y, damaged: f[2] >= 1, normalAzimuth: f.count > 3 ? f[3] : nil)
        }
    }

    /// Each shape's bounding-box centre (longitude, latitude) from an ESRI shapefile.
    static func readShapeCentres(_ url: URL) throws -> [SIMD2<Double>] {
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
    static func readDBF(_ url: URL) throws -> [[String: String]] {
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
