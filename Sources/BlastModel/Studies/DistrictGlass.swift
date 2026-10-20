import Foundation
import simd

/// A district's façade strips and their loads, saved so that their glass can be judged again
/// under other mixes without running the event again (`district-compare --save-loads`,
/// `district-glass`): a JSON index and the strips' net pressures as 16-bit floats.
package enum DistrictGlass {
    package struct Building: Codable {
        var distanceM: Double
        var heightM: Float
        /// The mix the map gave it (`GlazingMix.name`).
        package var mix: String
    }

    package struct Strip: Codable {
        package var building: Int
        package var axis: Int
        package var outward: Int
        package var areaM2: Double
        package var binS: Double
        var first: Int
        var count: Int
        /// The strip's box, m (saved since 19 October 2026; nil in older files).
        var low: SIMD3<Float>?
        var high: SIMD3<Float>?
        /// The component's kind (`EnvelopeComponent.Kind`) in components.json, the walls' and roofs'
        /// file beside the façades' (saved since 20 October 2026); nil in strips.json, all façades.
        var kind: String?
    }

    package struct Index: Codable {
        package var buildings: [Building]
        package var strips: [Strip]
        /// Pascals per stored unit: a power of two that keeps the largest net pressure inside 16-bit
        /// floats' ±65,504, whose relative precision is the same at any scale (saved since 19
        /// October 2026; nil, 1 Pa, in older files, whose close-in peaks were clipped).
        var scalePa: Float?
    }

    /// GEER-070's façades (DesignSafe layer; data/Beirut2020/SURVEY.md §3.1) by distance band, from
    /// 500 m: the share W1 or worse (some windows broken) and the share W3 (nearly every window,
    /// door and frame blown out), for the bands' printout.
    package static let geer: [(from: Double, to: Double, damaged: Double, blownOut: Double)] = [
        (500, 750, 0.84, 577.0 / 750), (750, 1000, 0.62, 357.0 / 1298), (1000, 1250, 0.39, 301.0 / 1737),
        (1250, 1500, 0.35, 449.0 / 2565), (1500, 1750, 0.38, 126.0 / 1380), (1750, 2000, 0.28, 6.0 / 386),
        (2000, 2500, 0.26, 78.0 / 534), (2500, 3000, 0.11, 12.0 / 290),
    ]

    /// A side counted as blown out, against GEER's W3: nine in ten of its panes expected broken.
    package static let blownOutFraction = 0.9

    package static func save(
        to folder: URL, loads: [EnvelopeComponentLoad], objects: [SceneObject], distance: (UUID) -> Double,
        height: (UUID) -> Float, mix: (UUID) -> String
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let order = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($0.element.id, $0.offset) })
        let buildings = objects.map {
            Building(distanceM: distance($0.id), heightM: height($0.id), mix: mix($0.id))
        }
        // The façades in strips.json and net.f16, as ever; the walls, slabs and roofs beside them in
        // components.json and components.f16, each with its kind, for judging the structure.
        for (facades, name) in [(true, "strips"), (false, "components")] {
            var strips: [Strip] = []
            var values: [Float] = []
            for load in loads where (load.kind == .facade) == facades && load.kind != .pane {
                guard let building = order[load.owner] else { continue }
                let net = load.netPa
                let spans = load.spans
                strips.append(
                    Strip(
                        building: building, axis: load.axis, outward: load.outward,
                        areaM2: spans.short * spans.long,
                        binS: load.binS, first: values.count, count: net.count, low: load.region.min,
                        high: load.region.max, kind: facades ? nil : load.kind.rawValue))
                values += net.map { Float($0) }
            }
            let largest = values.reduce(0) { max($0, abs($1)) }
            var scale: Float = 1
            while largest / scale > 65_504 { scale *= 2 }
            let stored = values.map { Float16(min(max($0 / scale, -65_504), 65_504)) }
            try JSONEncoder().encode(Index(buildings: buildings, strips: strips, scalePa: scale)).write(
                to: folder.appending(path: "\(name).json"))
            try stored.withUnsafeBufferPointer { Data(buffer: $0) }.write(
                to: folder.appending(path: facades ? "net.f16" : "components.f16"))
        }
    }

    /// Each building's façade sides' glass under `mix` (nil: the mix each was given), and its distance.
    package static func judge(_ folder: URL, mix override: GlazingMix?) throws -> [(
        distanceM: Double, mix: String, sides: [GlazingBreakage]
    )] {
        try judgeWithPeaks(folder, mix: override).map { ($0.distanceM, $0.mix, $0.sides) }
    }

    /// As `judge`, with each side's peak net load (Pa), for the openings' fragility.
    static func judgeWithPeaks(_ folder: URL, mix override: GlazingMix?) throws -> [(
        distanceM: Double, mix: String, sides: [GlazingBreakage], peaks: [Double]
    )] {
        let index = try JSONDecoder().decode(
            Index.self, from: Data(contentsOf: folder.appending(path: "strips.json")))
        let data = try Data(contentsOf: folder.appending(path: "net.f16"))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        let scale = Double(index.scalePa ?? 1)
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        var sides = [[Int: GlazingBreakage]](repeating: [:], count: index.buildings.count)
        var peaks = [[Int: Double]](repeating: [:], count: index.buildings.count)
        for strip in index.strips {
            let building = index.buildings[strip.building]
            guard let mix = override ?? mixes[building.mix] else { continue }
            let net = values[strip.first..<(strip.first + strip.count)].map { Double($0) * scale }
            let key = strip.axis * 2 + (strip.outward > 0 ? 1 : 0)
            sides[strip.building][key, default: GlazingBreakage()] =
                sides[strip.building][key, default: GlazingBreakage()]
                + mix.breakage(netPa: net, binS: strip.binS, areaM2: strip.areaM2)
            peaks[strip.building][key] = max(peaks[strip.building][key] ?? 0, net.map(abs).max() ?? 0)
        }
        return index.buildings.indices.map { n in
            let keys = sides[n].keys.sorted()
            return (
                index.buildings[n].distanceM, override?.name ?? index.buildings[n].mix,
                keys.map { sides[n][$0]! },
                keys.map { peaks[n][$0] ?? 0 }
            )
        }
    }

    /// By the GEER bands: the share of panes broken, the mean chance that a side has some broken
    /// (against GEER's W1 or worse) and the share of sides blown out (against its W3).
    static func bands(_ judged: [(distanceM: Double, mix: String, sides: [GlazingBreakage])]) -> [(
        from: Double, to: Double, panes: Double, sidesAny: Double, sidesBlown: Double, geer: Double,
        geerBlown: Double
    )] {
        geer.map { band in
            let sides = judged.filter { $0.distanceM >= band.from && $0.distanceM < band.to }.flatMap(\.sides)
            let total = sides.reduce(GlazingBreakage(), +)
            let count = Double(max(sides.count, 1))
            let any = sides.reduce(0) { $0 + $1.anyBroken } / count
            let blown = Double(sides.filter { $0.fraction >= blownOutFraction }.count) / count
            return (band.from, band.to, total.fraction, any, blown, band.damaged, band.blownOut)
        }
    }

    package static func printBands(
        _ title: String, _ judged: [(distanceM: Double, mix: String, sides: [GlazingBreakage])],
        peaks: [[Double]]? = nil
    ) {
        let total = judged.flatMap(\.sides).reduce(GlazingBreakage(), +)
        print(
            String(
                format: "%@: %.0f m² of glass broken of %.0f m² (%.0f of %.0f panes)", title, total.brokenM2,
                total.glazedM2, total.broken, total.panes))
        // Inside 3 km, the reach of the surveys, by mix: the glass assumed and the glass broken.
        let near = judged.filter { $0.distanceM < 3000 }
        for mix in Set(near.map(\.mix)).sorted() {
            let glass = near.filter { $0.mix == mix }.flatMap(\.sides).reduce(GlazingBreakage(), +)
            print(
                String(
                    format: "  inside 3 km, %@: %d buildings, %.0f m² of glass, %.0f m² broken (%.2f)", mix,
                    near.filter { $0.mix == mix }.count, glass.glazedM2, glass.brokenM2,
                    glass.glazedM2 > 0 ? glass.brokenM2 / glass.glazedM2 : 0))
        }
        let inside = near.flatMap(\.sides).reduce(GlazingBreakage(), +)
        print(
            String(
                format: "  inside 3 km: %d buildings, %.0f m² of glass, %.0f m² broken (%.2f)", near.count,
                inside.glazedM2, inside.brokenM2, inside.glazedM2 > 0 ? inside.brokenM2 / inside.glazedM2 : 0)
        )
        print(
            "\(title): panes broken, sides with some broken, sides blown out (\(blownOutFraction) of panes) | "
                + "openings blown out (fitted) | GEER openings W1+ and W3, seen two months on"
        )
        for band in bands(judged) {
            // The openings' chance by the fragility fitted to GEER, on each side's peak.
            var openings = "  –  "
            if let peaks {
                let chances = judged.indices.filter {
                    judged[$0].distanceM >= band.from && judged[$0].distanceM < band.to
                }.flatMap { peaks[$0] }.map { FacadeLoadSurrogate.OpeningsFragility.chance(peakPa: $0) }
                if !chances.isEmpty {
                    openings = String(format: "%.2f", chances.reduce(0, +) / Double(chances.count))
                }
            }
            print(
                String(
                    format: "  %4.0f–%4.0f m  %.2f  %.2f  %.2f | %@ | %.2f  %.2f", band.from, band.to,
                    band.panes,
                    band.sidesAny, band.sidesBlown, openings as NSString, band.geer, band.geerBlown))
        }
    }

    /// `scenebench district-glass --loads folder [--mix map|older|apartments|commercial|industrial]...`:
    /// a saved district's glass under each mix asked for (the map's, by default).
    package static func run(_ args: [String]) throws {
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
            let judged = try judgeWithPeaks(URL(filePath: path), mix: mix)
            printBands(
                "\(name) (\(String(format: "%.1f", StudyClock.seconds(start))) s)",
                judged.map { ($0.distanceM, $0.mix, $0.sides) }, peaks: judged.map(\.peaks))
        }
    }
}
