import Foundation
import simd

/// The explorer's scenes (emmettl/bombcad-work#114; docs/explorer.md), laid out as File ▸ New District
/// lays a map's out. The square and the street are built in, made up rather than taken from a map,
/// the same every time from a fixed seed. Beirut's port is a real place, from map data, fetched once
/// as a release asset (`ExplorerDistrict`, `Beirut.Release`).
public enum ExplorerScene: String, CaseIterable, Sendable, Identifiable {
    /// A town square ringed by blocks of flats, a glass office on its north side, a terrace of brick
    /// houses on its east and shops on its west; about 400 m across.
    case square
    /// A high street of shops and flats, three to five storeys of brick and concrete, a bank on it,
    /// a back lane behind each row and streets of terraced houses beyond.
    case street
    /// Beirut's port and the city round it, within 1.5 km of where the charge went off on
    /// 4 August 2020: OpenStreetMap's buildings, GHSL's heights, Copernicus's ground.
    case beirut

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .square: "A square"
        case .street: "A street"
        case .beirut: "Beirut's port, 2020"
        }
    }

    /// One line under the scene's card.
    public var summary: String {
        switch self {
        case .square: "A town square ringed by flats and shops, with a glass office on one side."
        case .street: "A high street of shops and flats, with terraced houses behind."
        case .beirut: "The city round the port as it stood, from map data."
        }
    }

    /// The scene's opening line, said before anything else: Beirut's, that it was a real disaster.
    public var opening: String? {
        switch self {
        case .square, .street: nil
        case .beirut:
            "On 4 August 2020, ammonium nitrate stored at Beirut's port exploded. 218 people died and about "
                + "6,500 were hurt. What follows is a model's estimate, not a record of that day."
        }
    }

    /// What the scene is, for its standing.
    public var source: String {
        switch self {
        case .square: "A made-up town square (BombCAD's own, seeded): not a real place and not map data."
        case .street: "A made-up high street (BombCAD's own, seeded): not a real place and not map data."
        case .beirut: "Beirut's port within 1.5 km, from OpenStreetMap, GHSL and Copernicus GLO-30."
        }
    }

    /// Whether the scene is built into the app; Beirut's is downloaded (`Beirut.Release`).
    public var isBuiltIn: Bool { self != .beirut }

    /// Where the charge goes off first, in longitude and latitude.
    public var charge: SIMD2<Double> {
        switch self {
        case .square, .street: .zero
        case .beirut: Beirut.charge
        }
    }

    /// Buildings whose footprint's centre lies within this many metres of the charge are placed.
    public var radiusM: Float {
        switch self {
        case .square, .street: 300
        case .beirut: Beirut.radiusM
        }
    }

    /// The scene's cells, metres: fine enough for the made-up scenes' narrow streets; for Beirut the 6 m
    /// File ▸ New District's advisor took for its district, which keeps the scene's memory to a few
    /// gigabytes (nil would leave it to the advisor, who takes the finest this Mac holds).
    public var cellSizeM: Float? {
        switch self {
        case .square, .street: 2
        case .beirut: 6
        }
    }

    /// Whether the drag keeps the scene on the learned response where its inputs lie outside the
    /// training, rather than leave those buildings to the CPU's preview as elsewhere
    /// (emmettl/bombcad-work#118; docs/learned-models.md, "What lies outside the training, on the
    /// CPU"). Beirut's 6 m cells put every roof's panel height just outside it (2.5–3.1 deviations),
    /// and on the CPU its walls' drag would take 0.2–0.4 s a frame, not 13 ms: kept, for now, until
    /// the networks are trained on 6 m cells or the user decides otherwise.
    public var keepsLearnedResponse: Bool { self == .beirut }

    /// The ground under the charge: Beirut's port was on saturated fill.
    public var ground: GroundType {
        switch self {
        case .square, .street: .rigid
        case .beirut: .saturated
        }
    }

    /// The charge it opens with, kg of TNT: Beirut's about 0.5 kt.
    public var defaultMassKg: Float {
        switch self {
        case .square, .street: 500
        case .beirut: 500_000
        }
    }

    /// A place to put the charge, by name, for the keyboard and VoiceOver: metres east and north of
    /// the scene's first charge.
    public struct Place: Sendable, Equatable, Identifiable {
        public var name: String
        public var offset: SIMD2<Float>
        public var id: String { name }
    }

    public var places: [Place] {
        switch self {
        case .square:
            [
                Place(name: "In the middle of the square", offset: SIMD2(0, 0)),
                Place(name: "In the street outside the glass office", offset: SIMD2(0, 42)),
                Place(name: "At the corner of the square", offset: SIMD2(42, -42)),
                Place(name: "In the street behind the brick terrace", offset: SIMD2(Self.pitch + 42, 0)),
            ]
        case .street:
            [
                Place(name: "In the middle of the high street", offset: SIMD2(0, 0)),
                Place(name: "Outside the bank", offset: SIMD2(Self.bank.lowerBound + 12, -4)),
                Place(name: "At the corner of the side street", offset: SIMD2(Self.sideStreets[0], 0)),
                Place(
                    name: "In the back lane behind the shops", offset: SIMD2(0, Self.frontage + Self.lane / 2)
                ),
            ]
        case .beirut:
            [Place(name: "At the port, where it went off", offset: SIMD2(0, 0))]
        }
    }

    /// The place named `name`.
    public func place(_ name: String) -> Place? { places.first { $0.name == name } }

    /// The building a protection is set up for (emmettl/bombcad-work#117), and the stand-off: the
    /// line the charge is kept back along, from `from` (metres east and north of the scene's first
    /// charge) outward along `along`, at most `range` m; nil where the scene offers none.
    public struct StandOff: Sendable, Equatable {
        public var building: String
        public var from: SIMD2<Float>
        public var along: SIMD2<Float>
        public var range: ClosedRange<Float>
        /// "from the glass office".
        public var phrase: String
    }

    public var standOff: StandOff? {
        switch self {
        // The office's south face, the square's north edge across its street, then out over the square.
        case .square:
            StandOff(
                building: "The glass office", from: SIMD2(0, Self.pitch - Self.block / 2),
                along: SIMD2(0, -1),
                range: 3...120, phrase: "from the glass office")
        // Along the high street's middle from outside the bank, east.
        case .street:
            StandOff(
                building: "The bank", from: SIMD2((Self.bank.lowerBound + Self.bank.upperBound) / 2, 0),
                along: SIMD2(1, 0), range: 0...150, phrase: "along the street from the bank")
        case .beirut: nil
        }
    }

    /// The place behind a building from the scene's first charge, for the comparison "behind a
    /// building"; nil where the scene offers none.
    public var behindABuilding: Place? {
        switch self {
        case .square, .street: places[3]
        case .beirut: nil
        }
    }

    /// The scene's buildings and ground: built in, or read from Beirut's downloaded `asset`.
    public func district(asset: URL? = nil) throws -> (buildings: [MapBuilding], ground: ElevationGrid?) {
        switch self {
        case .square: return (Self.squareBuildings(), nil)
        case .street: return (Self.streetBuildings(), nil)
        case .beirut:
            guard let asset else { throw ExplorerDistrict.Failure.missing }
            let district = try ExplorerDistrict(contentsOf: asset)
            return (district.mapBuildings(), district.groundGrid())
        }
    }

    // MARK: The square

    /// Blocks on a grid this many metres apart, each this many across, the streets between them
    /// `pitch − block` wide; the middle block left open as the square.
    static let pitch: Float = 84
    static let block: Float = 70

    /// A built-in scene's buildings, as a map's would be read (`MapBuilding.read`); none for Beirut's,
    /// which is downloaded.
    public func buildings() -> [MapBuilding] {
        switch self {
        case .square: Self.squareBuildings()
        case .street: Self.streetBuildings()
        case .beirut: []
        }
    }

    /// One building's footprint (x, y the south-west corner, w east, h north; metres from the
    /// square's middle), its height and tags.
    struct Footprint {
        var x: Float, y: Float, w: Float, h: Float
        var height: Float
        var kind: String
        var material: String?
        var name: String?
    }

    static func squareBuildings() -> [MapBuilding] {
        var rng = ExplorerRandom(seed: 114)
        var prints: [Footprint] = []
        for i in -2...2 {
            for j in -2...2 where !(i == 0 && j == 0) {
                let x0 = Float(i) * pitch - block / 2
                let y0 = Float(j) * pitch - block / 2
                prints += blockBuildings(i: i, j: j, x0: x0, y0: y0, rng: &rng)
            }
        }
        return mapBuildings(prints, firstID: 100)
    }

    /// Metres from the square's middle to longitude and latitude about (0°, 0°), as
    /// `MapBuildingPlacement` reads them back (`ElevationGrid.metresPerDegree`).
    static func lonLat(_ p: SIMD2<Float>) -> SIMD2<Double> {
        SIMD2(Double(p.x), Double(p.y)) / ElevationGrid.metresPerDegree
    }

    /// A block's buildings round its edges, a courtyard inside; the blocks facing the square each
    /// their own kind.
    static func blockBuildings(i: Int, j: Int, x0: Float, y0: Float, rng: inout ExplorerRandom) -> [Footprint]
    {
        var out: [Footprint] = []
        // A row along an edge, in frontages of `width`, each its own height.
        func row(
            alongX: Bool, from start: Float, length: Float, at offset: Float, depth: Float,
            width: ClosedRange<Float>, make: (inout ExplorerRandom) -> (Float, String, String?, String?)
        ) {
            var p: Float = 0
            while p < length - 4 {
                let f = min(rng.uniform(width), length - p)
                let (height, kind, material, name) = make(&rng)
                out.append(
                    alongX
                        ? Footprint(
                            x: start + p, y: offset, w: f, h: depth, height: height, kind: kind,
                            material: material, name: name)
                        : Footprint(
                            x: offset, y: start + p, w: depth, h: f, height: height, kind: kind,
                            material: material, name: name))
                p += f
            }
        }
        func ring(
            depth: Float, width: ClosedRange<Float>,
            make: (inout ExplorerRandom) -> (Float, String, String?, String?)
        ) {
            row(alongX: true, from: x0, length: block, at: y0, depth: depth, width: width, make: make)
            row(
                alongX: true, from: x0, length: block, at: y0 + block - depth, depth: depth, width: width,
                make: make)
            row(
                alongX: false, from: y0 + depth, length: block - 2 * depth, at: x0, depth: depth,
                width: width,
                make: make)
            row(
                alongX: false, from: y0 + depth, length: block - 2 * depth, at: x0 + block - depth,
                depth: depth,
                width: width, make: make)
        }
        let flats: (inout ExplorerRandom) -> (Float, String, String?, String?) = { rng in
            (rng.uniform(9...18), "apartments", rng.uniform(0...1) < 0.4 ? "brick" : nil, nil)
        }
        switch (i, j) {
        case (0, 1):
            // The glass office facing the square, its whole south side; flats behind it.
            out.append(
                Footprint(
                    x: x0, y: y0, w: block, h: 22, height: 32, kind: "office", material: "concrete",
                    name: "The glass office"))
            row(
                alongX: true, from: x0, length: block, at: y0 + block - 12, depth: 12, width: 12...20,
                make: flats)
            row(
                alongX: false, from: y0 + 22, length: block - 34, at: x0, depth: 12, width: 12...20,
                make: flats)
            row(
                alongX: false, from: y0 + 22, length: block - 34, at: x0 + block - 12, depth: 12,
                width: 12...20,
                make: flats)
        case (1, 0):
            // A terrace of brick houses round the block, its west row facing the square.
            ring(depth: 10, width: 6...6) { _ in (9, "terrace", "brick", nil) }
            for n in out.indices where out[n].x == x0 && out[n].w == 10 { out[n].name = "The brick terrace" }
        case (-1, 0):
            ring(depth: 12, width: 8...14) { rng in (rng.uniform(8...12), "retail", "brick", nil) }
        case (0, -1):
            ring(depth: 14, width: 16...24) { rng in (rng.uniform(15...18), "apartments", "concrete", nil) }
        default:
            ring(depth: 12, width: 10...22, make: flats)
        }
        return out
    }

    // MARK: The street

    /// The high street runs east–west, `street` m wide; a row of shops and flats `frontage` m deep
    /// stands each side, a back lane `lane` m wide behind each, then streets of terraced houses.
    static let streetWidth: Float = 18
    static let frontage: Float = 9 + 14
    static let lane: Float = 6
    /// The side streets crossing it, at these metres east, 12 m wide.
    static let sideStreets: [Float] = [60, -150]
    /// The bank's frontage on the high street's south side, metres east.
    static let bank: ClosedRange<Float> = -40 ... -16

    static func streetBuildings() -> [MapBuilding] {
        var rng = ExplorerRandom(seed: 115)
        var prints: [Footprint] = []
        let reach: Float = 270
        // Frontages along x from -reach to reach in `width`, skipping the side streets.
        func row(
            y: Float, depth: Float, width: ClosedRange<Float>,
            make: (inout ExplorerRandom) -> (Float, String, String?)
        ) {
            var x = -reach
            while x < reach - 4 {
                if let side = sideStreets.first(where: { x + 2 > $0 - 6 && x < $0 + 6 }) {
                    x = side + 6
                    continue
                }
                let f = min(rng.uniform(width), reach - x)
                let next = sideStreets.first { $0 - 6 > x && $0 - 6 < x + f }
                let w = next.map { $0 - 6 - x } ?? f
                if w > 3 {
                    let (height, kind, material) = make(&rng)
                    prints.append(
                        Footprint(x: x, y: y, w: w, h: depth, height: height, kind: kind, material: material))
                }
                x += w
            }
        }
        let shops: (inout ExplorerRandom) -> (Float, String, String?) = { rng in
            (
                rng.uniform(9...15), rng.uniform(0...1) < 0.5 ? "retail" : "apartments",
                rng.uniform(0...1) < 0.6 ? "brick" : "concrete"
            )
        }
        let houses: (inout ExplorerRandom) -> (Float, String, String?) = { _ in (8, "terrace", "brick") }
        for side: Float in [1, -1] {
            // The high street's row, then a back lane, then pairs of terraces back to back across roads.
            let near = streetWidth / 2
            row(y: side > 0 ? near : -near - 14, depth: 14, width: 8...14, make: shops)
            var y = near + 14 + lane
            while y + 10 < reach * 0.4 {
                row(y: side > 0 ? y : -y - 10, depth: 10, width: 6...6, make: houses)
                y += 10 + 12
                row(y: side > 0 ? y : -y - 10, depth: 10, width: 6...6, make: houses)
                y += 10 + 20
            }
        }
        // The bank: one building in its frontage on the south side, stone-faced concrete.
        let south: Float = -streetWidth / 2 - 14
        prints.removeAll { $0.y == south && $0.x + $0.w > bank.lowerBound && $0.x < bank.upperBound }
        let width: Float = bank.upperBound - bank.lowerBound
        prints.append(
            Footprint(
                x: bank.lowerBound, y: south, w: width, h: 14, height: 15, kind: "commercial",
                material: "concrete",
                name: "The bank"))
        return mapBuildings(prints, firstID: 5_000)
    }

    /// Footprints as map buildings, numbered from `firstID`.
    static func mapBuildings(_ prints: [Footprint], firstID: Int) -> [MapBuilding] {
        prints.enumerated().map { n, p in
            let ring = [
                SIMD2(p.x, p.y), SIMD2(p.x + p.w, p.y), SIMD2(p.x + p.w, p.y + p.h), SIMD2(p.x, p.y + p.h),
                SIMD2(p.x, p.y),
            ].map(lonLat)
            return MapBuilding(
                id: "way/\(firstID + n)", name: p.name, kind: p.kind, rings: [ring], height: p.height,
                material: p.material)
        }
    }

    // MARK: Writing it as a map

    /// The scene as an OpenStreetMap file (`MapBuilding.read` reads it back), for the benches:
    /// `blastmodel explorer-scene` writes it, `scenebench drag-time --osm` judges it.
    public func osm() -> String {
        var nodes: [String] = []
        var ways: [String] = []
        var next = 1
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
        }
        for (n, building) in buildings().enumerated() {
            var refs: [Int] = []
            for point in (building.rings.first ?? []).dropLast() {
                nodes.append(
                    String(format: "  <node id=\"%d\" lat=\"%.9f\" lon=\"%.9f\"/>", next, point.y, point.x))
                refs.append(next)
                next += 1
            }
            refs.append(refs[0])
            var body = refs.map { "<nd ref=\"\($0)\"/>" }.joined()
            body += "<tag k=\"building\" v=\"\(escaped(building.kind))\"/>"
            if let height = building.height {
                body += String(format: "<tag k=\"height\" v=\"%.1f\"/>", height)
            }
            if let material = building.material {
                body += "<tag k=\"building:material\" v=\"\(escaped(material))\"/>"
            }
            if let name = building.name { body += "<tag k=\"name\" v=\"\(escaped(name))\"/>" }
            ways.append("  <way id=\"\(100 + n)\">\(body)</way>")
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<!-- \(source) -->\n<osm version=\"0.6\" generator=\"BombCAD explorer\">\n"
            + (nodes + ways).joined(separator: "\n") + "\n</osm>\n"
    }
}

/// SplitMix64: the explorer's scenes the same on every platform and every run.
struct ExplorerRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform over `range`.
    mutating func uniform(_ range: ClosedRange<Float>) -> Float {
        let unit = Float(Double(next() >> 11) / Double(1 << 53))
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
