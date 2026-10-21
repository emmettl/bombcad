import Foundation
import simd

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// A building from map data (OpenStreetMap, as an .osm file or GeoJSON): its footprint in
/// longitude and latitude, and what the data says of its height.
public struct MapBuilding: Sendable, Equatable {
    /// `way/123`, `relation/45` or a GeoJSON feature's id or index.
    public var id: String
    public var name: String?
    /// The `building` tag's value (`yes`, `house`, `apartments`…).
    public var kind: String
    /// Rings of (longitude, latitude), the first the outline, any others holes (courtyards).
    public var rings: [[SIMD2<Double>]]
    /// `height` and `min_height` in metres, `building:levels`, `roof:levels` and
    /// `building:min_level`, as tagged.
    public var height: Float?
    public var minHeight: Float?
    public var levels: Float?
    public var roofLevels: Float?
    public var minLevel: Float?
    /// The `building:material` tag, for its envelope's construction (`EnvelopeConstruction.fromMap`).
    public var material: String?
    /// The `building:use` tag, where it says more than `kind` of who is in it (`BuildingUse`).
    public var use: String?

    public init(
        id: String, name: String? = nil, kind: String = "yes", rings: [[SIMD2<Double>]], height: Float? = nil,
        minHeight: Float? = nil, levels: Float? = nil, roofLevels: Float? = nil, minLevel: Float? = nil,
        material: String? = nil, use: String? = nil
    ) {
        self.material = material
        self.use = use
        self.id = id
        self.name = name
        self.kind = kind
        self.rings = rings
        self.height = height
        self.minHeight = minHeight
        self.levels = levels
        self.roofLevels = roofLevels
        self.minLevel = minLevel
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            switch self {
            case .malformed(let what): "The map data is malformed: \(what)."
            }
        }
    }

    /// The attribution OpenStreetMap's licence (ODbL 1.0) asks of anything made from its data.
    public static let openStreetMapAttribution =
        "Buildings © OpenStreetMap contributors, under the Open Database Licence (ODbL 1.0): "
        + "https://www.openstreetmap.org/copyright"

    /// A length as OSM tags it: metres by default, `12`, `12.5 m`, `12m`; or feet, `40 ft`, `40'`,
    /// `40'6"`. Of several values (`12;15`), the first.
    public static func length(_ text: String) -> Float? {
        let first = text.split(separator: ";").first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.contains("'") {
            let parts = trimmed.split(separator: "'", omittingEmptySubsequences: false)
            guard let feet = Float(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let inches =
                parts.count > 1
                ? Float(
                    parts[1].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces))
                    ?? 0
                : 0
            return (feet * 12 + inches) * 0.0254
        }
        var number = trimmed
        var scale: Float = 1
        for (suffix, factor) in [("ft", Float(0.3048)), ("feet", 0.3048), ("m", 1)]
        where number.hasSuffix(suffix) {
            number = String(number.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            scale = factor
            break
        }
        guard let value = Float(number.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            return nil
        }
        return value * scale
    }

    static func building(id: String, tags: [String: String], rings: [[SIMD2<Double>]]) -> MapBuilding? {
        guard let kind = tags["building"], kind != "no" else { return nil }
        return MapBuilding(
            id: id, name: tags["name"], kind: kind, rings: rings, height: tags["height"].flatMap(length),
            minHeight: tags["min_height"].flatMap(length), levels: tags["building:levels"].flatMap(length),
            roofLevels: tags["roof:levels"].flatMap(length),
            minLevel: tags["building:min_level"].flatMap(length), material: tags["building:material"],
            use: tags["building:use"])
    }
}

// MARK: - Reading

extension MapBuilding {
    /// Reads an OpenStreetMap XML file (`.osm`): closed ways tagged `building`, and multipolygon
    /// relations tagged `building` whose outer and inner ways are joined into rings. Building parts
    /// (`building:part`) are left out: they lie within their buildings.
    public static func readOSM(_ data: Data) throws -> [MapBuilding] {
        // Invalid UTF-8 can trap Linux's XMLParser (`SVGTree.isXMLText`).
        guard SVGTree.isXMLText(data) else {
            throw Failure.malformed("not valid UTF-8 text, and no other encoding named")
        }
        let reader = OSMReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw Failure.malformed(parser.parserError.map { "\($0.localizedDescription)" } ?? "not XML")
        }
        var buildings: [MapBuilding] = []
        func ring(_ refs: [Int64]) -> [SIMD2<Double>]? {
            let points = refs.compactMap { reader.nodes[$0] }
            return points.count == refs.count ? points : nil
        }
        for way in reader.ways {
            guard let points = ring(way.refs),
                let building = building(id: "way/\(way.id)", tags: way.tags, rings: [points])
            else { continue }
            buildings.append(building)
        }
        let ways = Dictionary(reader.ways.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for relation in reader.relations where relation.tags["type"] == "multipolygon" {
            var outers: [[SIMD2<Double>]] = []
            var inners: [[SIMD2<Double>]] = []
            for role in ["outer", "inner"] {
                let segments = relation.members.filter {
                    $0.role == role || (role == "outer" && $0.role.isEmpty)
                }
                .compactMap { ways[$0.ref]?.refs }
                for joined in join(segments) {
                    guard let points = ring(joined) else { continue }
                    if role == "outer" { outers.append(points) } else { inners.append(points) }
                }
            }
            // Each outer ring is a building of its own, with the inner rings inside it.
            for (n, outer) in outers.enumerated() {
                let holes = inners.filter { inner in inner.first.map { contains(outer, $0) } ?? false }
                if let building = building(
                    id: outers.count > 1 ? "relation/\(relation.id)#\(n + 1)" : "relation/\(relation.id)",
                    tags: relation.tags, rings: [outer] + holes)
                {
                    buildings.append(building)
                }
            }
        }
        return buildings
    }

    /// Reads GeoJSON (RFC 7946, longitude and latitude in WGS 84): Polygon and MultiPolygon
    /// features whose properties have `building` (or any feature, when none has it), with OSM's
    /// height tags among their properties.
    public static func readGeoJSON(_ data: Data) throws -> [MapBuilding] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("not a GeoJSON object")
        }
        let features: [[String: Any]]
        switch root["type"] as? String {
        case "FeatureCollection": features = root["features"] as? [[String: Any]] ?? []
        case "Feature": features = [root]
        default: throw Failure.malformed("neither a Feature nor a FeatureCollection")
        }
        func strings(_ properties: [String: Any]) -> [String: String] {
            properties.compactMapValues { value in
                switch value {
                case let text as String: text
                case let number as NSNumber: number.stringValue
                default: nil
                }
            }
        }
        let anyTagged = features.contains { (($0["properties"] as? [String: Any])?["building"]) != nil }
        var buildings: [MapBuilding] = []
        for (index, feature) in features.enumerated() {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            var tags = strings(feature["properties"] as? [String: Any] ?? [:])
            if !anyTagged { tags["building"] = tags["building"] ?? "yes" }
            let id = (feature["id"].map { "\($0)" }) ?? tags["@id"] ?? tags["id"] ?? "feature/\(index + 1)"
            func rings(_ value: Any?) -> [[SIMD2<Double>]] {
                (value as? [[[Double]]] ?? []).map { ring in
                    ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
                }
            }
            switch geometry["type"] as? String {
            case "Polygon":
                if let building = building(id: id, tags: tags, rings: rings(geometry["coordinates"])) {
                    buildings.append(building)
                }
            case "MultiPolygon":
                let polygons = geometry["coordinates"] as? [Any] ?? []
                for (n, polygon) in polygons.enumerated() {
                    if let building = building(
                        id: polygons.count > 1 ? "\(id)#\(n + 1)" : id, tags: tags, rings: rings(polygon))
                    {
                        buildings.append(building)
                    }
                }
            default: continue
            }
        }
        return buildings
    }

    /// Reads `.osm` or `.geojson`/`.json` by extension.
    public static func read(contentsOf url: URL) throws -> [MapBuilding] {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "osm", "xml": return try readOSM(data)
        case "geojson", "json": return try readGeoJSON(data)
        default: throw Failure.malformed("the extension .\(url.pathExtension) is neither .osm nor .geojson")
        }
    }

    /// Joins way segments end to end into closed rings (of node ids).
    static func join(_ segments: [[Int64]]) -> [[Int64]] {
        var open = segments.filter { $0.count >= 2 }
        var rings: [[Int64]] = []
        while var ring = open.first {
            open.removeFirst()
            while ring.first != ring.last {
                guard let n = open.firstIndex(where: { $0.first == ring.last || $0.last == ring.last }) else {
                    break
                }
                let next = open.remove(at: n)
                ring += (next.first == ring.last ? next : next.reversed()).dropFirst()
            }
            if ring.first == ring.last { rings.append(ring) }
        }
        return rings
    }

    /// Even-odd containment of `point` in `ring`.
    static func contains(_ ring: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let (a, b) = (ring[i], ring[j])
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

private final class OSMReader: NSObject, XMLParserDelegate {
    struct Way {
        var id: Int64
        var refs: [Int64] = []
        var tags: [String: String] = [:]
    }
    package struct Member {
        var ref: Int64
        var role: String

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            ref: Int64,
            role: String
        ) {
            self.ref = ref
            self.role = role
        }
    }
    struct Relation {
        var id: Int64
        var members: [Member] = []
        var tags: [String: String] = [:]
    }
    var nodes: [Int64: SIMD2<Double>] = [:]
    var ways: [Way] = []
    var relations: [Relation] = []
    private var way: Way?
    private var relation: Relation?

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch element {
        case "node":
            if let id = attributes["id"].flatMap(Int64.init),
                let lat = attributes["lat"].flatMap(Double.init),
                let lon = attributes["lon"].flatMap(Double.init)
            {
                nodes[id] = SIMD2(lon, lat)
            }
        case "way": way = attributes["id"].flatMap(Int64.init).map { Way(id: $0) }
        case "relation": relation = attributes["id"].flatMap(Int64.init).map { Relation(id: $0) }
        case "nd": if let ref = attributes["ref"].flatMap(Int64.init) { way?.refs.append(ref) }
        case "member":
            if attributes["type"] == "way", let ref = attributes["ref"].flatMap(Int64.init) {
                relation?.members.append(Member(ref: ref, role: attributes["role"] ?? ""))
            }
        case "tag":
            if let key = attributes["k"], let value = attributes["v"] {
                if way != nil { way?.tags[key] = value } else { relation?.tags[key] = value }
            }
        default: break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?
    ) {
        switch element {
        case "way":
            if let way { ways.append(way) }
            way = nil
        case "relation":
            if let relation { relations.append(relation) }
            relation = nil
        default: break
        }
    }
}

// MARK: - Placing as envelopes

/// What became of a set of map buildings placed in a scene.
public struct MapBuildingReport: Sendable, Equatable {
    public enum HeightSource: String, Sendable, CaseIterable { case height, levels, grid, assumed }
    public struct Placed: Sendable, Equatable {
        public var id: String
        public var objectID: UUID
        public var heightSource: HeightSource
        /// Ground (the lowest terrain under it, or the floor) and roof, metres.
        public var base: Float
        public var top: Float
        public var boxes: Int
        public var cells: Int
    }
    public var placed: [Placed] = []
    /// Buildings left out, and why: degenerate footprints, outside the scene, under a cell.
    public var skipped: [(id: String, reason: String)] = []
    /// Cells of later buildings given up where an earlier building already stood.
    public var overlapCells = 0
    /// Roofs lowered to stay inside the domain.
    public var clipped = 0

    public static func == (a: Self, b: Self) -> Bool {
        a.placed == b.placed && a.overlapCells == b.overlapCells && a.clipped == b.clipped
            && a.skipped.map(\.id) == b.skipped.map(\.id)
            && a.skipped.map(\.reason) == b.skipped.map(\.reason)
    }

    public func count(_ source: HeightSource) -> Int { placed.filter { $0.heightSource == source }.count }

    /// Why a building over the charge was left out (`MapBuildingPlacement.clearsChargeBuilding`).
    public static let holdsTheCharge = "holds the charge"
    /// The import note a cleared building leaves, which the standing repeats.
    public static let clearedChargeNote =
        "The building over the charge was cleared to open ground: the charge goes off in the open, not inside it."
    /// Whether the building over the charge was cleared.
    public var clearedCharge: Bool { skipped.contains { $0.reason == Self.holdsTheCharge } }

    public var summary: String {
        "\(placed.count) buildings placed (\(count(.height)) by height, \(count(.levels)) by levels, "
            + (count(.grid) > 0 ? "\(count(.grid)) from the height grid, " : "")
            + "\(count(.assumed)) assumed), \(skipped.count) left out"
            + (overlapCells > 0 ? ", \(overlapCells) overlapping cells given up" : "")
            + (clipped > 0 ? ", \(clipped) roofs lowered to the domain's top" : "")
    }
}

public struct MapBuildingPlacement: Sendable {
    /// The longitude and latitude of the scene's (0, 0).
    public var origin: SIMD2<Double>
    /// The footprints are rasterised on cells this size, aligned with the scene's origin; a cell
    /// is in a building where its centre is inside the footprint.
    public var resolution: Float
    /// Metres a level, for `building:levels`, and the levels assumed where nothing is tagged.
    public var levelHeight: Float = 3
    public var assumedLevels: Float = 2
    /// Building heights in metres on a grid of longitude and latitude, such as GHSL's average net
    /// building height: where a building's tags give no height, the cell holding its footprint's
    /// centre gives it, if above 0. A cell's mean over its built-up area, not the building's own.
    public var heightGrid: ElevationGrid?
    /// Clear the building whose footprint holds the charge's cell, leaving open ground there: a real
    /// event's charge is often inside a building (Beirut's Warehouse 12), and one buried in a solid
    /// block releases nothing (`Scenario.blocks`). Off, the building stands and the charge is buried.
    public var clearsChargeBuilding = true

    public init(origin: SIMD2<Double>, resolution: Float) {
        self.origin = origin
        self.resolution = resolution
    }

    /// Scene metres (x east, y north) of a longitude and latitude, by a local equirectangular
    /// mapping about the origin.
    public func position(_ lonLat: SIMD2<Double>) -> SIMD2<Double> {
        let east = ElevationGrid.metresPerDegree * cos(origin.y * .pi / 180)
        return (lonLat - origin) * SIMD2(east, ElevationGrid.metresPerDegree)
    }

    /// The height of `building` and where it came from: `height`, else `building:levels` (plus
    /// `roof:levels`) at `levelHeight`, else `heightGrid`, else `assumedLevels`; less `min_height`
    /// or `building:min_level` below it.
    public func heights(_ building: MapBuilding) -> (
        bottom: Float, top: Float, source: MapBuildingReport.HeightSource
    ) {
        let top: Float
        let source: MapBuildingReport.HeightSource
        if let height = building.height, height > 0 {
            (top, source) = (height, .height)
        } else if let levels = building.levels, levels > 0 {
            (top, source) = ((levels + max(building.roofLevels ?? 0, 0)) * levelHeight, .levels)
        } else if let grid = heightGrid, let height = Self.gridHeight(grid, building), height > 0 {
            (top, source) = (height, .grid)
        } else {
            (top, source) = (assumedLevels * levelHeight, .assumed)
        }
        let bottom = max(building.minHeight ?? (building.minLevel.map { $0 * levelHeight } ?? 0), 0)
        return (min(bottom, top), top, source)
    }

    /// The grid's value in the cell holding the centre of the footprint's outer ring's vertices.
    static func gridHeight(_ grid: ElevationGrid, _ building: MapBuilding) -> Float? {
        guard let ring = building.rings.first, !ring.isEmpty else { return nil }
        let centre = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        let cell = SIMD2<Int>(((centre - grid.southWest) / grid.step).rounded(.toNearestOrAwayFromZero))
        guard cell.x >= 0, cell.y >= 0, cell.x < grid.columns, cell.y < grid.rows else { return nil }
        let value = grid.elevation(column: cell.x, row: cell.y)
        return value.isNaN ? nil : value
    }
}

extension Scenario {
    /// Places `buildings` as stationary envelopes, each its own building of solid boxes extruded
    /// from its footprint (rasterised at `placement.resolution`) from the ground (the lowest point
    /// of the terrain under it, if there is one) to its height. Footprints with fewer than three
    /// distinct corners or no area, outside the scene, under a cell or (by default) over the charge
    /// are left out (a charge inside a solid block would not go off), and a later
    /// building gives up the cells of an earlier one it overlaps; the report says which. The
    /// attribution is added to the scene's. Nothing changes if the scene would not hold them.
    @discardableResult
    public mutating func addMapBuildings(
        _ buildings: [MapBuilding], placement: MapBuildingPlacement,
        attribution: String? = MapBuilding.openStreetMapAttribution
    ) throws -> MapBuildingReport {
        let r = placement.resolution
        guard r.isFinite, r > 0 else {
            throw MapBuilding.Failure.malformed("the resolution must be positive")
        }
        var copy = self
        var report = MapBuildingReport()
        // The new buildings' constructions, set together: they are new objects, so none replaces another.
        var constructions: [EnvelopeConstruction] = []
        let columns = Int((domainSize.x / r).rounded(.up))
        let rows = Int((domainSize.y / r).rounded(.up))
        var taken = Set<Int>()
        let chargeCell =
            min(max(Int(charge.position.x / r), 0), columns - 1)
            + columns * min(max(Int(charge.position.y / r), 0), rows - 1)
        for building in buildings {
            // Local metres; duplicates and closing points dropped.
            var rings: [[SIMD2<Double>]] = []
            for ring in building.rings {
                var points: [SIMD2<Double>] = []
                for p in ring where p.x.isFinite && p.y.isFinite {
                    let q = placement.position(p)
                    if points.last.map({ simd_distance($0, q) > 1e-6 }) ?? true { points.append(q) }
                }
                if points.count > 1, simd_distance(points[0], points[points.count - 1]) <= 1e-6 {
                    points.removeLast()
                }
                rings.append(points)
            }
            guard let outline = rings.first, outline.count >= 3 else {
                report.skipped.append((building.id, "fewer than three distinct corners"))
                continue
            }
            let area = zip(outline, outline.dropFirst() + [outline[0]]).reduce(0.0) {
                $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y)
            }
            guard abs(area) > 1e-6 else {
                report.skipped.append((building.id, "a footprint with no area"))
                continue
            }
            let low = rings.flatMap { $0 }.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
            let high = rings.flatMap { $0 }.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
            let i0 = max(Int((low.x / Double(r)).rounded(.down)), 0)
            let i1 = min(Int((high.x / Double(r)).rounded(.up)), columns)
            let j0 = max(Int((low.y / Double(r)).rounded(.down)), 0)
            let j1 = min(Int((high.y / Double(r)).rounded(.up)), rows)
            guard i0 < i1, j0 < j1 else {
                report.skipped.append((building.id, "outside the scene"))
                continue
            }
            // Cells whose centre is inside, even-odd over every ring (holes are courtyards).
            var cells: [Int] = []
            var overlap = 0
            for j in j0..<j1 {
                for i in i0..<i1 {
                    let centre = SIMD2(Double(i) + 0.5, Double(j) + 0.5) * Double(r)
                    let inside = rings.reduce(false) { $0 != MapBuilding.contains($1, centre) }
                    guard inside else { continue }
                    let cell = i + columns * j
                    if taken.contains(cell) { overlap += 1 } else { cells.append(cell) }
                }
            }
            report.overlapCells += overlap
            // A footprint over the charge's cell would bury it in a solid block, and no blast leave it.
            guard !placement.clearsChargeBuilding || charge.mass <= 0 || !cells.contains(chargeCell) else {
                report.skipped.append((building.id, MapBuildingReport.holdsTheCharge))
                continue
            }
            guard !cells.isEmpty else {
                report.skipped.append(
                    (
                        building.id,
                        overlap > 0 ? "inside another building" : "smaller than a cell, or outside the scene"
                    ))
                continue
            }
            let heights = placement.heights(building)
            let ground =
                cells.map { cell in
                    groundHeight(
                        at: SIMD3((Float(cell % columns) + 0.5) * r, (Float(cell / columns) + 0.5) * r, 0))
                }.min() ?? 0
            var top = ground + heights.top
            if top > domainSize.z - r {
                top = domainSize.z - r
                report.clipped += 1
            }
            let bottom = ground + heights.bottom
            guard top > bottom else {
                report.skipped.append((building.id, "no height inside the domain"))
                continue
            }
            let boxes = Self.rectangles(Set(cells), columns: columns, cell: r).map {
                Box(min: SIMD3($0.min.x, $0.min.y, bottom), max: SIMD3($0.max.x, $0.max.y, top))
            }
            guard boxes.count <= 2048 else {
                report.skipped.append((building.id, "more than 2,048 boxes at this resolution"))
                continue
            }
            let id = try copy.addEnvelopeObject(
                try BuildingEnvelope(solids: boxes), name: building.name ?? "\(building.kind) \(building.id)")
            taken.formUnion(cells)
            // Its construction from its material tag, if any, and its windows from its kind and height.
            var construction =
                EnvelopeConstruction.fromMap(objectID: id, material: building.material)
                ?? .assumed(objectID: id)
            construction.glazing = GlazingMix.forMapBuilding(kind: building.kind, height: top - bottom)
            // Who is in it, where its tags say (emmettl/bombcad-work#41); nil for an untagged `yes`.
            construction.use = BuildingUse(mapTag: building.use) ?? BuildingUse(mapTag: building.kind)
            constructions.append(construction)
            copy.envelopeSources =
                (copy.envelopeSources ?? []) + [
                    EnvelopeSource(
                        objectID: id, kind: .map,
                        detail:
                            "\(building.id), \(heights.source.rawValue) \(heights.top) m, \(cells.count) cells of \(r) m"
                    )
                ]
            report.placed.append(
                .init(
                    id: building.id, objectID: id, heightSource: heights.source, base: ground, top: top,
                    boxes: boxes.count, cells: cells.count))
        }
        if !constructions.isEmpty {
            copy.envelopeConstructions = (copy.envelopeConstructions ?? []) + constructions
        }
        guard copy.rigidBoxes.count <= Scenario.maximumRigidBoxes else {
            throw MapBuilding.Failure.malformed(
                "the buildings need \(copy.rigidBoxes.count) boxes in all and a scene holds \(Scenario.maximumRigidBoxes); "
                    + "choose a coarser resolution or a smaller area")
        }
        if let attribution, !report.placed.isEmpty, !(copy.attributions ?? []).contains(attribution) {
            copy.attributions = (copy.attributions ?? []) + [attribution]
        }
        copy.importNotes = (copy.importNotes ?? []) + ["Map buildings: \(report.summary)."]
        if report.clearedCharge {
            copy.importNotes = (copy.importNotes ?? []) + [MapBuildingReport.clearedChargeNote]
        }
        try copy.validateObjectOwnership()
        self = copy
        return report
    }

    /// Cells (x fastest, `columns` a row) merged into rectangles: runs along x in each row,
    /// then runs of identical rows.
    static func rectangles(_ cells: Set<Int>, columns: Int, cell r: Float) -> [(
        min: SIMD2<Float>, max: SIMD2<Float>
    )] {
        var runs: [Int: [ClosedRange<Int>]] = [:]
        for row in Set(cells.map { $0 / columns }) {
            let xs = cells.filter { $0 / columns == row }.map { $0 % columns }.sorted()
            var list: [ClosedRange<Int>] = []
            for x in xs {
                if let last = list.last, last.upperBound + 1 == x {
                    list[list.count - 1] = last.lowerBound...x
                } else {
                    list.append(x...x)
                }
            }
            runs[row] = list
        }
        var result: [(min: SIMD2<Float>, max: SIMD2<Float>)] = []
        var open: [ClosedRange<Int>: Int] = [:]
        let rows = runs.keys.sorted()
        func close(_ run: ClosedRange<Int>, from start: Int, to end: Int) {
            result.append(
                (
                    SIMD2(Float(run.lowerBound), Float(start)) * r,
                    SIMD2(Float(run.upperBound + 1), Float(end + 1)) * r
                ))
        }
        var previous: Int?
        for row in rows {
            let current = Set(runs[row] ?? [])
            for (run, start) in open where !(current.contains(run) && previous == row - 1) {
                close(run, from: start, to: previous!)
                open[run] = nil
            }
            for run in current where open[run] == nil { open[run] = row }
            previous = row
        }
        for (run, start) in open { close(run, from: start, to: previous!) }
        return result.sorted { ($0.min.y, $0.min.x) < ($1.min.y, $1.min.x) }
    }
}
