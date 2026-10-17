import BlastCore
import Foundation
import simd

/// A district's façade strips and their loads, saved so that their glass can be judged again
/// under other mixes without running the event again (`district-compare --save-loads`,
/// `district-glass`): a JSON index and the strips' net pressures as 16-bit floats.
enum DistrictGlass {
    struct Building: Codable {
        var distanceM: Double
        var heightM: Float
        /// The mix the map gave it (`GlazingMix.name`).
        var mix: String
    }

    struct Strip: Codable {
        var building: Int
        var axis: Int
        var outward: Int
        var areaM2: Double
        var binS: Double
        var first: Int
        var count: Int
    }

    struct Index: Codable {
        var buildings: [Building]
        var strips: [Strip]
    }

    /// GEER-070's façades (DesignSafe layer; data/Beirut2020/SURVEY.md §3.1): the share W1 or
    /// worse by distance band, from 500 m, for the bands' printout.
    static let geer: [(from: Double, to: Double, damaged: Double)] = [
        (500, 750, 0.84), (750, 1000, 0.62), (1000, 1250, 0.39), (1250, 1500, 0.35), (1500, 1750, 0.38),
        (1750, 2000, 0.28), (2000, 2500, 0.26), (2500, 3000, 0.11),
    ]

    static func save(
        to folder: URL, loads: [EnvelopeComponentLoad], objects: [SceneObject], distance: (UUID) -> Double,
        height: (UUID) -> Float, mix: (UUID) -> String
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let order = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($0.element.id, $0.offset) })
        let buildings = objects.map {
            Building(distanceM: distance($0.id), heightM: height($0.id), mix: mix($0.id))
        }
        var strips: [Strip] = []
        var values: [Float16] = []
        for load in loads where load.kind == .facade {
            guard let building = order[load.owner] else { continue }
            let net = load.netPa
            let spans = load.spans
            strips.append(
                Strip(
                    building: building, axis: load.axis, outward: load.outward,
                    areaM2: spans.short * spans.long,
                    binS: load.binS, first: values.count, count: net.count))
            values += net.map { Float16(Float(min(max($0, -65_504), 65_504))) }
        }
        try JSONEncoder().encode(Index(buildings: buildings, strips: strips)).write(
            to: folder.appending(path: "strips.json"))
        try values.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: folder.appending(path: "net.f16"))
    }

    /// Each building's façade sides' glass under `mix` (nil: the mix each was given), and its distance.
    static func judge(_ folder: URL, mix override: GlazingMix?) throws -> [(
        distanceM: Double, sides: [GlazingBreakage]
    )] {
        let index = try JSONDecoder().decode(
            Index.self, from: Data(contentsOf: folder.appending(path: "strips.json")))
        let data = try Data(contentsOf: folder.appending(path: "net.f16"))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        var sides = [[Int: GlazingBreakage]](repeating: [:], count: index.buildings.count)
        for strip in index.strips {
            let building = index.buildings[strip.building]
            guard let mix = override ?? mixes[building.mix] else { continue }
            let net = values[strip.first..<(strip.first + strip.count)].map { Double($0) }
            let key = strip.axis * 2 + (strip.outward > 0 ? 1 : 0)
            sides[strip.building][key, default: GlazingBreakage()] =
                sides[strip.building][key, default: GlazingBreakage()]
                + mix.breakage(netPa: net, binS: strip.binS, areaM2: strip.areaM2)
        }
        return index.buildings.indices.map { n in
            (index.buildings[n].distanceM, sides[n].keys.sorted().map { sides[n][$0]! })
        }
    }

    /// By the GEER bands: the share of panes broken, and the mean chance that a side has some broken.
    static func bands(_ judged: [(distanceM: Double, sides: [GlazingBreakage])]) -> [(
        from: Double, to: Double, panes: Double, sidesAny: Double, geer: Double
    )] {
        geer.map { band in
            let sides = judged.filter { $0.distanceM >= band.from && $0.distanceM < band.to }.flatMap(\.sides)
            let total = sides.reduce(GlazingBreakage(), +)
            let any = sides.isEmpty ? 0 : sides.reduce(0) { $0 + $1.anyBroken } / Double(sides.count)
            return (band.from, band.to, total.fraction, any, band.damaged)
        }
    }

    static func printBands(_ title: String, _ judged: [(distanceM: Double, sides: [GlazingBreakage])]) {
        print("\(title): panes broken, sides with some broken, GEER's façades damaged")
        for band in bands(judged) {
            print(
                String(
                    format: "  %4.0f–%4.0f m  %.2f  %.2f  %.2f", band.from, band.to, band.panes,
                    band.sidesAny, band.geer))
        }
    }

    /// `scenebench district-glass --loads folder [--mix map|older|apartments|commercial|industrial]...`:
    /// a saved district's glass under each mix asked for (the map's, by default).
    static func run(_ args: [String]) throws {
        guard
            let path = args.firstIndex(of: "--loads").flatMap({
                args.indices.contains($0 + 1) ? args[$0 + 1] : nil
            })
        else { throw BlastError.allocationFailed("--loads folder") }
        let named: [String: GlazingMix?] = [
            "map": nil, "older": .olderLowRise, "apartments": .apartments, "commercial": .commercial,
            "industrial": .industrial,
        ]
        let asked = args.indices.filter { args[$0] == "--mix" && args.indices.contains($0 + 1) }.map {
            args[$0 + 1]
        }
        for name in asked.isEmpty ? ["map"] : asked {
            guard let mix = named[name] else { throw BlastError.allocationFailed("--mix \(name)") }
            let start = ContinuousClock.now
            let judged = try judge(URL(filePath: path), mix: mix)
            printBands(
                "\(name) (\(String(format: "%.1f", DistrictBenchmark.seconds(start))) s)", judged)
        }
    }
}
