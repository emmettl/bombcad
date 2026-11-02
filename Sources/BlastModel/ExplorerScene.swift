import Foundation
import simd

/// The explorer's scenes (emmettl/bombcad-work#114; docs/explorer.md): districts built in, made up
/// rather than taken from a map, laid out as File ▸ New District lays a map's out. Each is the same
/// every time: its buildings come from a fixed seed, never from a file.
public enum ExplorerScene: String, CaseIterable, Sendable, Identifiable {
    /// A town square ringed by blocks of flats, a glass office on its north side, a terrace of brick
    /// houses on its east and shops on its west; about 400 m across.
    case square

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .square: "A square"
        }
    }

    /// One line under the scene's card.
    public var summary: String {
        switch self {
        case .square: "A town square ringed by flats and shops, with a glass office on one side."
        }
    }

    /// What the scene is, for its standing: made up, not a real place.
    public var source: String {
        switch self {
        case .square: "A made-up town square (BombCAD's own, seeded): not a real place and not map data."
        }
    }

    /// Where the charge goes off first, in longitude and latitude: the middle of the square.
    public var charge: SIMD2<Double> { .zero }

    /// Buildings whose footprint's centre lies within this many metres of the charge are placed.
    public var radiusM: Float { 300 }

    /// The scene's cells, metres: fine enough for its streets of 14 m.
    public var cellSizeM: Float { 2 }

    /// The charge it opens with, kg of TNT.
    public var defaultMassKg: Float { 500 }

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
        }
    }

    /// The place named `name`.
    public func place(_ name: String) -> Place? { places.first { $0.name == name } }

    /// The place behind a building from the scene's first charge, for the comparison "behind a
    /// building".
    public var behindABuilding: Place { places[3] }

    // MARK: The square

    /// Blocks on a grid this many metres apart, each this many across, the streets between them
    /// `pitch − block` wide; the middle block left open as the square.
    static let pitch: Float = 84
    static let block: Float = 70

    /// The scene's buildings, as a map's would be read (`MapBuilding.read`).
    public func buildings() -> [MapBuilding] {
        switch self {
        case .square: Self.squareBuildings()
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
        return prints.enumerated().map { n, p in
            let ring = [
                SIMD2(p.x, p.y), SIMD2(p.x + p.w, p.y), SIMD2(p.x + p.w, p.y + p.h), SIMD2(p.x, p.y + p.h),
                SIMD2(p.x, p.y),
            ].map(lonLat)
            return MapBuilding(
                id: "way/\(100 + n)", name: p.name, kind: p.kind, rings: [ring], height: p.height,
                material: p.material)
        }
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
