import Foundation
import simd

extension ChargeFromDamage {
    // MARK: - Surveys

    /// One thing a survey saw, where it saw it (the scene's metres): a building's glass, its walls,
    /// and whether the survey says its walls are stone (masonry, which the network weighs as such).
    public struct SurveyEntry: Sendable, Equatable {
        public var place: SIMD2<Double>
        public var glass: GlassSeen?
        public var walls: WallsSeen?
        public var masonry: Bool

        public init(
            place: SIMD2<Double>, glass: GlassSeen? = nil, walls: WallsSeen? = nil, masonry: Bool = false
        ) {
            self.place = place
            self.glass = glass
            self.walls = walls
            self.masonry = masonry
        }
    }

    /// A survey read from its files, before it is put on the scene's buildings.
    public struct Survey: Sendable {
        public var entries: [SurveyEntry] = []
        /// Records read but not usable: no class, a class straddling the line, a structure the
        /// network does not weigh.
        public var skipped = 0
        /// What was read, in words: "1,351 GEER façades, 139 GEER buildings".
        public var parts: [String] = []

        public init() {}
    }

    /// Whether reading the survey at `url` needs the scene's corner (0, 0) in longitude and
    /// latitude: GEER's files and a CSV of `lat,lon`, not a marks CSV in the scene's metres.
    public static func surveyNeedsCorner(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "csv" else { return true }
        let head = (try? String(contentsOf: url, encoding: .utf8))?.split(whereSeparator: \.isNewline).first
        return !(head.map { isMarksHeader(String($0)) } ?? false)
    }

    static func isMarksHeader(_ line: String) -> Bool {
        let names = line.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains("east") && names.contains("north") && names.contains("glass")
    }

    /// Reads a survey (emmettl/bombcad-work#116, stage 3): any of
    /// - a marks CSV as `charge-from-damage infer` reads it (`building,east,north,height,footprint,
    ///   built,walls,glass,seen`), east and north about `charge` (the scene's charge: the reference a
    ///   table's `--marks-out` writes them about);
    /// - GEER's façade shapefile (`Facade_damage.shp`, its .dbf beside it): a building's glass
    ///   broken where any of its façades is W1 or worse, whole otherwise;
    /// - a CSV of façades `lat,lon,class[,…]`, as the Infer Charge sheet reads one;
    /// - GEER's structural assessment (.dbf, `Latitude`, `Longitude`, `Damage_Cla`, `Str_Type`):
    ///   walls read as `geerStructure` reads them;
    /// - a folder holding any of these, searched through.
    ///
    /// Places in longitude and latitude are put on the scene by its corner (0, 0), `corner`.
    public static func readSurvey(_ url: URL, corner: SIMD2<Double>?, charge: SIMD2<Double>) throws -> Survey
    {
        var survey = Survey()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw ChargeInferenceInputs.ReadError("No file at \(url.path).")
        }
        var files: [URL] = []
        if isFolder.boolValue {
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let next = found?.nextObject() as? URL { files.append(next) }
            files.sort { $0.path < $1.path }
        } else {
            files = [url]
        }
        if !isFolder.boolValue, ["shp", "dbf"].contains(url.pathExtension.lowercased()) {
            // A table's shapes beside it, or a shapefile's table.
            let other = url.deletingPathExtension().appendingPathExtension(
                url.pathExtension.lowercased() == "shp" ? "dbf" : "shp")
            if FileManager.default.fileExists(atPath: other.path) { files.append(other) }
        }
        let shapeFiles = Set(
            files.filter { $0.pathExtension.lowercased() == "shp" }.map { $0.deletingPathExtension().path })
        let paths = Set(files.map(\.path))
        func placed(_ lonLat: SIMD2<Double>) throws -> SIMD2<Double> {
            guard let corner else {
                throw ChargeInferenceInputs.ReadError(
                    "Give the longitude and latitude of the scene's corner, to put the survey on its buildings."
                )
            }
            return MapBuildingPlacement(origin: corner, resolution: 1).position(lonLat)
        }
        for file in files {
            switch file.pathExtension.lowercased() {
            case "shp", "dbf":
                // A table's kind by its fields: GEER's façades (`Facade_num`, read with their shapes'
                // places) or its buildings (`Damage_Cla`, read by their own longitude and latitude).
                let table = file.deletingPathExtension().appendingPathExtension("dbf")
                let shape = file.deletingPathExtension().appendingPathExtension("shp")
                if file.pathExtension.lowercased() == "shp" && paths.contains(table.path) { continue }
                let records = try ChargeInferenceInputs.readDBF(table)
                let fields = Set(records.first?.keys.map { String($0) } ?? [])
                var used = 0
                if fields.contains("Facade_num") {
                    guard shapeFiles.contains(shape.deletingPathExtension().path) else {
                        throw ChargeInferenceInputs.ReadError(
                            "\(table.lastPathComponent) is GEER's façades: give its .shp beside it.")
                    }
                    let centres = try ChargeInferenceInputs.readShapeCentres(shape)
                    guard centres.count == records.count else {
                        throw ChargeInferenceInputs.ReadError(
                            "\(shape.lastPathComponent) has \(centres.count) shapes but its .dbf \(records.count) records."
                        )
                    }
                    for (centre, record) in zip(centres, records) {
                        guard centre.x.isFinite,
                            let level = record["Facade_num"].flatMap({
                                Double($0.trimmingCharacters(in: .whitespaces))
                            })
                        else {
                            survey.skipped += 1
                            continue
                        }
                        survey.entries.append(
                            SurveyEntry(place: try placed(centre), glass: level >= 1 ? .broken : .whole))
                        used += 1
                    }
                    if used > 0 {
                        survey.parts.append(
                            "\(used) façade\(used == 1 ? "" : "s") from \(table.deletingPathExtension().lastPathComponent)"
                        )
                    }
                } else if fields.contains("Damage_Cla") {
                    for record in records {
                        func field(_ name: String) -> String? {
                            record[name]?.trimmingCharacters(in: .whitespaces)
                        }
                        guard let lat = field("Latitude").flatMap(Double.init),
                            let lon = field("Longitude").flatMap(Double.init)
                        else {
                            survey.skipped += 1
                            continue
                        }
                        if let visit = field("VID"), visit != "0" { continue }
                        guard
                            let (seen, stone) = geerStructure(
                                damage: field("Damage_Cla"), type: field("Str_Type"))
                        else {
                            survey.skipped += 1
                            continue
                        }
                        survey.entries.append(
                            SurveyEntry(place: try placed(SIMD2(lon, lat)), walls: seen, masonry: stone))
                        used += 1
                    }
                    if used > 0 {
                        survey.parts.append(
                            "\(used) building\(used == 1 ? "" : "s") from \(table.deletingPathExtension().lastPathComponent)"
                        )
                    }
                }
            case "csv":
                let text = try String(contentsOf: file, encoding: .utf8)
                if let head = text.split(whereSeparator: \.isNewline).first, isMarksHeader(String(head)) {
                    let marks = readMarks(text: text)
                    for (_, mark) in marks {
                        survey.entries.append(
                            SurveyEntry(
                                place: charge + SIMD2(mark.building.east, mark.building.north),
                                glass: mark.glass,
                                walls: mark.walls, masonry: mark.building.walls == .masonry))
                    }
                    survey.parts.append(
                        "\(marks.count) mark\(marks.count == 1 ? "" : "s") from \(file.lastPathComponent)")
                } else {
                    var used = 0
                    for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                        let f = line.split(separator: ",").compactMap {
                            Double($0.trimmingCharacters(in: .whitespaces))
                        }
                        guard f.count >= 3 else {
                            survey.skipped += 1
                            continue
                        }
                        survey.entries.append(
                            SurveyEntry(
                                place: try placed(SIMD2(f[1], f[0])), glass: f[2] >= 1 ? .broken : .whole))
                        used += 1
                    }
                    if used > 0 {
                        survey.parts.append(
                            "\(used) façade\(used == 1 ? "" : "s") from \(file.lastPathComponent)")
                    }
                }
            default: continue
            }
        }
        guard !survey.entries.isEmpty || survey.skipped > 0 else {
            throw ChargeInferenceInputs.ReadError(
                "Nothing in \(url.lastPathComponent) reads as a survey: a marks CSV, GEER's façade shapefile or structural .dbf, or a CSV of lat,lon,class."
            )
        }
        return survey
    }

    /// What GEER's structural class says of a building's walls, if anything, and whether it is stone
    /// (`charge-from-damage table --structure` reads it so): stone bearing walls at the line they were
    /// calibrated at, D3 or worse heavy and D0–D2 undamaged, a class straddling D3 left out (the
    /// model's masonry goes from undamaged to heavy at once); concrete frames and walls D0–D1
    /// undamaged, D2 damaged, D3 or worse heavy, a straddling class left out; any other structure
    /// left out.
    public static func geerStructure(damage: String?, type: String?) -> (WallsSeen, stone: Bool)? {
        guard let damage, !damage.isEmpty else { return nil }
        let kind = (type ?? "").lowercased()
        let stone = kind.hasPrefix("stone masonry bearing") || kind.hasPrefix("sandstone bearing")
        let concrete =
            kind.hasPrefix("reinforced concrete frame") || kind.hasPrefix("reinforced concrete walls")
            || kind == "rc frame"
        guard stone || concrete else { return nil }
        let classes = damage.uppercased().split(separator: "-").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces).dropFirst())
        }
        guard let low = classes.min(), let high = classes.max() else { return nil }
        if stone {
            guard low >= 3 || high < 3 else { return nil }
            return (low >= 3 ? .heavy : .undamaged, true)
        }
        if high <= 1 { return (.undamaged, false) }
        if low >= 3 { return (.heavy, false) }
        if low >= 2 { return (.damaged, false) }
        return nil
    }

    /// A survey put on buildings.
    public struct SurveyMatch: Sendable {
        /// Each building's mark, by its index among those given: its glass broken where any entry
        /// on it is, its walls the first entry's that has them, stone where that entry says so.
        public var marks: [Int: (glass: GlassSeen?, walls: WallsSeen?, masonry: Bool)] = [:]
        /// Entries put on a building, and those that found none within reach.
        public var matched = 0
        public var unmatched = 0
        /// Entries whose walls were left out because their building had walls from another already.
        public var repeated = 0
    }

    /// Puts `survey` on the buildings whose blocks' plans are `footprints` (each a list of
    /// rectangles, the scene's metres): each entry on the building it stands in, or the nearest
    /// within `within` m, as `charge-from-damage table --structure` matches GEER's buildings.
    public static func match(
        _ survey: Survey, footprints: [[(low: SIMD2<Double>, high: SIMD2<Double>)]], within: Double = 15
    ) -> SurveyMatch {
        var result = SurveyMatch()
        // Bucketed by 100 m squares.
        let size = 100.0
        var buckets: [SIMD2<Int>: [Int]] = [:]
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> {
            SIMD2(Int((p.x / size).rounded(.down)), Int((p.y / size).rounded(.down)))
        }
        for (n, rects) in footprints.enumerated() {
            var keys = Set<SIMD2<Int>>()
            for r in rects {
                let a = key(r.low)
                let b = key(r.high)
                for i in a.x...b.x { for j in a.y...b.y { keys.insert(SIMD2(i, j)) } }
            }
            for k in keys { buckets[k, default: []].append(n) }
        }
        for entry in survey.entries {
            let k = key(entry.place)
            var best: (Int, Double)?
            for dx in -1...1 {
                for dy in -1...1 {
                    for n in buckets[k &+ SIMD2(dx, dy)] ?? [] {
                        for r in footprints[n] {
                            let d = simd_length(
                                simd_max(simd_max(r.low - entry.place, entry.place - r.high), .zero))
                            if d <= within, best.map({ d < $0.1 }) ?? true { best = (n, d) }
                        }
                    }
                }
            }
            guard let (n, _) = best else {
                result.unmatched += 1
                continue
            }
            result.matched += 1
            var mark = result.marks[n] ?? (nil, nil, false)
            if let glass = entry.glass {
                mark.glass = mark.glass == .broken || glass == .broken ? .broken : .whole
            }
            if let walls = entry.walls {
                if mark.walls == nil {
                    mark.walls = walls
                    mark.masonry = entry.masonry
                } else {
                    result.repeated += 1
                }
            }
            result.marks[n] = mark
        }
        return result
    }

    /// The marks of a marks CSV's text (`building,east,north,height,footprint,built,walls,glass,seen`,
    /// a header line first): the table's building index (−1 for none) and the mark, its place as
    /// given.
    public static func readMarks(text: String) -> [(index: Int, mark: Mark)] {
        var marks: [(Int, Mark)] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard f.count >= 9, let index = Int(f[0]), let east = Double(f[1]), let north = Double(f[2]),
                let height = Double(f[3]), let footprint = Double(f[4]), let built = Double(f[5])
            else { continue }
            let walls: Walls = f[6] == "masonry" ? .masonry : f[6] == "other" ? .other : .concrete
            let glass: GlassSeen? = f[7] == "whole" ? .whole : f[7] == "broken" ? .broken : nil
            let seen: WallsSeen? =
                f[8] == "undamaged"
                ? .undamaged : f[8] == "damaged" ? .damaged : f[8] == "heavy" ? .heavy : nil
            marks.append(
                (
                    index,
                    Mark(
                        building: Building(
                            east: east, north: north, heightM: height, footprintM2: footprint,
                            builtShare: built,
                            walls: walls, glazed: glass != nil),
                        glass: glass, walls: seen)
                ))
        }
        return marks
    }

    // MARK: - Marks kept with a project

    /// The marks kept with a project (`chargeMarks.json`; emmettl/bombcad-work#116, stage 3): each
    /// building's by its id, the place searched about if it was moved, the weighing, and the
    /// scene's corner a survey was put on by. A project saved before has none.
    public struct SavedMarks: Codable, Sendable, Equatable {
        public struct Saved: Codable, Sendable, Equatable {
            public var id: UUID
            public var glass: GlassSeen?
            public var walls: WallsSeen?
            /// The walls taken as this kind, not the scene's (a survey's stone, as masonry).
            public var wallsAs: Walls?

            public init(id: UUID, glass: GlassSeen?, walls: WallsSeen?, wallsAs: Walls? = nil) {
                self.id = id
                self.glass = glass
                self.walls = walls
                self.wallsAs = wallsAs
            }
        }

        public var marks: [Saved]
        /// The middle of the square searched, the scene's metres; nil for the scene's charge.
        public var reference: [Double]?
        /// The weighing's name (`Weighing.named`); nil for the default.
        public var weighing: String?
        /// The scene's corner (0, 0) as longitude and latitude, for surveys placed by it.
        public var corner: [Double]?

        public init(
            marks: [Saved], reference: [Double]? = nil, weighing: String? = nil, corner: [Double]? = nil
        ) {
            self.marks = marks
            self.reference = reference
            self.weighing = weighing
            self.corner = corner
        }
    }
}
