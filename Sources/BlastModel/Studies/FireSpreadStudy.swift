import Foundation

/// `scenebench fire` and `blastmodel fire` (emmettl/bombcad-work#38; docs/fire-spread.md): fire spread over a district's
/// buildings after the blast, for hours, from seeds, through the glass the quick estimate breaks.
///
/// ```
/// fire (<district-scene's inputs> [--radius 2500] | --scene layout.json)
///      [--look look.json] [--no-glass] [--yield-within 1.5]
///      [--thermal-results thermal-results.json [--thermal-seeding fluence|either]]
///      [--ignite-within m [--ignite-at east,north]] [--ignite id,id…]
///      [--ignite-random n [--ignite-band from,to]]
///      [--wind m/s@from°] [--hours 12] [--step-minutes 10] [--members 100] [--seed 0]
///      [--cladding combustible|noncombustible] [--untagged residential]
///      [--piloted 0.1] [--brands 0] [--roof 0.3]
///      [--json fire.json] [--csv timeline.csv] [--buildings-csv buildings.csv]
/// ```
///
/// The seeds come from the surface heating's ignitions (`--thermal-results`), from buildings within
/// `--ignite-within` m of the charge (or of `--ignite-at`, metres east and north of it), or from
/// map ids such as `way/123` (`--ignite`), or `--ignite-random` buildings drawn afresh in each draw
/// from those whose centres lie `--ignite-band` m from the charge; any of them together. The blast's broken glass and failed
/// walls come from the quick estimate's full look, as `scenebench people` makes it, kept in
/// `--look` (the same file `people` keeps) or made and kept there.
package enum FireSpreadStudy {
    /// The look kept between runs, as `scenebench people` keeps it: the buildings by their order.
    struct Kept: Codable {
        var glass: [FacadeLoadSurrogate.SideGlass]
        var structure: [FacadeLoadSurrogate.StructureChance]
    }

    /// Where each building is and what it was, for the outputs.
    struct Place: Codable {
        var index: Int
        /// The map's id (`way/123`), where the scene says.
        var source: String?
        var eastM: Double
        var northM: Double
        var distanceM: Double
        var cladding: FireSpread.Cladding
        var use: BuildingUse
        var heightM: Double
        var floorM2: Double
        var chance: Double
        var medianIgnitionH: Double?
        var mode: FireSpread.Mode?
    }

    struct Output: Codable {
        var standing: [String]
        var scene: String
        var glass: String
        var places: [Place]
        var ensemble: FireSpread.Ensemble
    }

    package static func run(_ args: [String]) throws {
        StudyOutput.lineBuffered()
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        func number(_ name: String) -> Double? { value(name).flatMap(Double.init) }
        var clock = ContinuousClock.now

        // The scene, and the map's id and tags of each envelope.
        let scene: Scenario
        var sources: [UUID: String] = [:]
        var timber = Set<UUID>()
        var cellSize = Float(number("dx") ?? 4)
        if let path = value("scene") {
            scene = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: URL(filePath: path)))
            for s in scene.envelopeSources ?? [] {
                sources[s.objectID] = s.detail.split(separator: ",").first.map(String.init)
            }
        } else {
            let inputs = try DistrictInputs.read(args)
            cellSize = inputs.cellSize
            let radius = Float(number("radius") ?? 2500)
            let (laid, report) = try inputs.scene(radius: radius)
            print(report.summary)
            scene = laid
            let tagged = Dictionary(inputs.buildings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for placed in report.placed {
                sources[placed.objectID] = placed.id
                // A map building tagged wood or timber burns (`building:material`).
                if let material = tagged[placed.id]?.material?.lowercased(),
                    ["wood", "timber", "timber_framing", "wood_frame"].contains(material)
                {
                    timber.insert(placed.objectID)
                }
            }
        }
        let charge = SIMD2(Double(scene.charge.position.x), Double(scene.charge.position.y))
        let ids = scene.envelopeObjects.map(\.id)

        // The blast's glass and walls: the quick estimate's full look.
        var glass: [FacadeLoadSurrogate.SideGlass] = []
        var structure: [FacadeLoadSurrogate.StructureChance] = []
        var glassNote = "none: every window intact (--no-glass)"
        func indexID(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", n))!
        }
        if !args.contains("--no-glass") {
            if let path = value("look"), let data = FileManager.default.contents(atPath: path) {
                let kept = try JSONDecoder().decode(Kept.self, from: data)
                let back = Dictionary(uniqueKeysWithValues: ids.indices.map { (indexID($0), ids[$0]) })
                glass = kept.glass.compactMap { side in
                    back[side.owner].map {
                        var s = side
                        s.owner = $0
                        return s
                    }
                }
                structure = kept.structure.compactMap { c in
                    back[c.owner].map {
                        var s = c
                        s.owner = $0
                        return s
                    }
                }
                glassNote = "the quick estimate's full look, read from \(path)"
                print("Look read from \(path)")
            } else {
                let prepared = FacadeLoadSurrogate.Prepared(
                    scene: scene, cellSize: cellSize, incidence: SurrogateBench.incidence(args))
                let within = number("yield-within") ?? 1.5
                let look = prepared.look(
                    charge: scene.charge.position, mass: Double(scene.charge.mass),
                    constructions: { scene.envelopeConstruction(for: $0) },
                    uncertainty: FacadeLoadSurrogate.Uncertainty(
                        yieldLogSD: log(within) / 1.645, samples: 100))
                glass = look.glass
                structure = look.structure
                glassNote = "the quick estimate's full look"
                print(String(format: "Full look in %.1f s", StudyClock.seconds(clock)))
                if let path = value("look") {
                    let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                    let kept = Kept(
                        glass: glass.map {
                            var s = $0
                            s.owner = indexID(order[$0.owner]!)
                            return s
                        },
                        structure: structure.map {
                            var s = $0
                            s.owner = indexID(order[$0.owner]!)
                            return s
                        })
                    try JSONEncoder().encode(kept).write(to: URL(filePath: path))
                    print("Look kept in \(path)")
                }
            }
        }

        // The buildings.
        let untagged = value("untagged").flatMap(BuildingUse.init(rawValue:)) ?? .residential
        let cladding: FireSpread.Cladding? =
            switch value("cladding") {
            case "combustible", "timber": .combustible
            case "noncombustible", "non-combustible": .nonCombustible
            default: nil
            }
        var buildings = FireSpread.buildings(
            scene: scene, glass: glass, structure: structure, untaggedUse: untagged, cladding: cladding)
        if cladding == nil {
            for n in buildings.indices where timber.contains(buildings[n].id) {
                buildings[n].cladding = .combustible
            }
        }
        var parameters = FireSpread.Parameters()
        if let p = number("piloted") { parameters.pilotedChance = p }
        if let p = number("brands") { parameters.brandChance = p }
        if let p = number("roof") { parameters.roofChance = p }
        var wind = FireSpread.Wind.calm
        if let text = value("wind") {
            let parts = text.split(separator: "@").compactMap { Double($0) }
            guard parts.count == 2 else {
                throw BlastError.allocationFailed("--wind m/s@from-degrees, as 4@250")
            }
            wind = FireSpread.Wind(speedMS: parts[0], fromDegrees: parts[1])
        }

        // The seeds.
        var seeds = Set<Int>()
        if let path = value("thermal-results") {
            let result = try JSONDecoder().decode(
                ThermalResult.self, from: Data(contentsOf: URL(filePath: path)))
            let seeding =
                value("thermal-seeding").flatMap(FireSpread.ThermalSeeding.init(rawValue:)) ?? .fluence
            let hit = FireSpread.ignited(by: result, buildings: buildings, seeding: seeding)
            print("Surface heating ignites \(hit.count) buildings (\(seeding.rawValue))")
            seeds.formUnion(hit)
        }
        if let radius = number("ignite-within") {
            var at = charge
            if let text = value("ignite-at") {
                let xy = text.split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { at += SIMD2(xy[0], xy[1]) }
            }
            seeds.formUnion(FireSpread.buildings(near: at, radius: radius, in: buildings))
        }
        if let list = value("ignite") {
            let wanted = Set(list.split(separator: ",").map(String.init))
            for (n, b) in buildings.enumerated() where sources[b.id].map(wanted.contains) ?? false {
                seeds.insert(n)
            }
        }
        // `--ignite-random n [--ignite-band from,to]`: n buildings whose centres lie that far from
        // the charge, m, drawn afresh in each draw.
        var random: FireSpread.RandomIgnitions?
        if let n = number("ignite-random").map(Int.init) {
            let band =
                value("ignite-band").map { $0.split(separator: ",").compactMap { Double($0) } } ?? [
                    0, .infinity,
                ]
            let candidates = buildings.indices.filter { k in
                let b = buildings[k]
                let c =
                    b.footprint.reduce(SIMD2<Double>.zero) { $0 + $1.centre * $1.area }
                    / max(b.footprintArea, 1e-9)
                let d = ((c - charge) * (c - charge)).sum().squareRoot()
                return d >= (band.first ?? 0) && d < (band.count > 1 ? band[1] : .infinity)
            }
            random = FireSpread.RandomIgnitions(count: n, candidates: candidates)
            print("Random ignitions: \(n) a draw among \(candidates.count) buildings")
        }
        guard !seeds.isEmpty || random != nil else {
            throw BlastError.allocationFailed(
                "no seeds: --thermal-results, --ignite-within, --ignite or --ignite-random")
        }

        clock = .now
        let district = FireSpread.District(buildings: buildings, wind: wind, parameters: parameters)
        let pairs = district.exposures.reduce(0) { $0 + $1.count }
        print(
            String(
                format: "%d buildings (%d combustible), %d neighbour pairs within %.0f m, in %.2f s",
                buildings.count,
                buildings.filter { $0.cladding == .combustible }.count, pairs, parameters.reach(wind: wind),
                StudyClock.seconds(clock)))
        let hours = number("hours") ?? 12
        let members = Int(number("members") ?? 100)
        clock = .now
        let ensemble = FireSpread.ensemble(
            district, seeds: seeds.sorted().map { FireSpread.Ignition(building: $0) }, random: random,
            horizonS: hours * 3600,
            members: members, seed: UInt64(number("seed") ?? 0), stepS: (number("step-minutes") ?? 10) * 60)
        print(String(format: "%d draws to %.0f h in %.2f s", members, hours, StudyClock.seconds(clock)))

        // Where each building is.
        let places = buildings.enumerated().map { n, b -> Place in
            let c =
                b.footprint.reduce(SIMD2<Double>.zero) { $0 + $1.centre * $1.area }
                / max(b.footprintArea, 1e-9)
            let offset = c - charge
            let e = ensemble.buildings[n]
            return Place(
                index: n, source: sources[b.id], eastM: offset.x, northM: offset.y,
                distanceM: (offset * offset).sum().squareRoot(), cladding: b.cladding, use: b.use,
                heightM: b.height,
                floorM2: b.footprintArea * max(1, (b.height / parameters.storeyM).rounded()),
                chance: e.chance,
                medianIgnitionH: e.medianIgnitionS.map { $0 / 3600 }, mode: e.mode)
        }

        print("Standing:")
        for line in FireSpread.standing { print("  \(line)") }
        let broken = buildings.map { $0.brokenGlass.reduce(0, +) / 4 }
        print(
            String(
                format: "Seeds: %d buildings, and %d at random a draw. Wind %.1f m/s from %.0f°. Glass: ",
                seeds.count, random?.count ?? 0, wind.speedMS,
                wind.fromDegrees) + glassNote
                + String(
                    format: ", %.0f%% of the buildings' panes broken on average",
                    100 * broken.reduce(0, +) / Double(max(broken.count, 1))))
        print("Hours | alight (5–50–95%)  | burnt out          | floor reached, m²")
        for step in ensemble.timeline
        where step.atS.truncatingRemainder(dividingBy: 3600) < 1 || step.atS == 1800 {
            print(
                String(
                    format: "%5.1f | %5.0f %5.0f %5.0f | %5.0f %5.0f %5.0f | %8.0f %8.0f %8.0f",
                    step.atS / 3600,
                    step.burning.x, step.burning.y, step.burning.z, step.burnt.x, step.burnt.y, step.burnt.z,
                    step.affectedFloorM2.x, step.affectedFloorM2.y, step.affectedFloorM2.z))
        }
        print(
            String(
                format:
                    "Caught by %.0f h: %.0f (5%%) %.0f (median) %.0f (95%%) of %d buildings, seeds included",
                hours,
                ensemble.caught.x, ensemble.caught.y, ensemble.caught.z, buildings.count))
        print(
            "Modes, mean a draw: "
                + FireSpread.Mode.allCases.map {
                    $0.rawValue + String(format: " %.1f", ensemble.modes[$0.rawValue] ?? 0)
                }.joined(separator: ", "))
        let likely = places.filter { $0.chance >= 0.5 }
        let reach = likely.map(\.distanceM).max() ?? 0
        print(
            String(
                format:
                    "Buildings more likely than not to burn: %d (%d combustible), the farthest %.0f m from the charge",
                likely.count, likely.filter { $0.cladding == .combustible }.count, reach))
        let bands: [Double] = [0, 250, 500, 1000, 1500, 2000, 2500, .infinity]
        for k in 0..<(bands.count - 1) {
            let mine = places.filter { $0.distanceM >= bands[k] && $0.distanceM < bands[k + 1] }
            guard !mine.isEmpty else { continue }
            print(
                String(
                    format: "  %4.0f–%4.0f m: %5d buildings, %6.1f expected to burn", bands[k],
                    min(bands[k + 1], 9999),
                    mine.count, mine.reduce(0) { $0 + $1.chance }))
        }

        if let path = value("json") {
            let output = Output(
                standing: FireSpread.standing, scene: scene.name, glass: glassNote, places: places,
                ensemble: ensemble)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            try encoder.encode(output).write(to: URL(filePath: path))
            print("Wrote \(path)")
        }
        if let path = value("csv") {
            var rows = [
                "hours,alight_p05,alight_median,alight_p95,burnt_p05,burnt_median,burnt_p95,floor_m2_p05,floor_m2_median,floor_m2_p95"
            ]
            for s in ensemble.timeline {
                rows.append(
                    String(
                        format: "%.3f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", s.atS / 3600,
                        s.burning.x,
                        s.burning.y, s.burning.z, s.burnt.x, s.burnt.y, s.burnt.z, s.affectedFloorM2.x,
                        s.affectedFloorM2.y, s.affectedFloorM2.z))
            }
            try (rows.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(path)")
        }
        if let path = value("buildings-csv") {
            var rows = [
                "index,source,east_m,north_m,distance_m,cladding,use,height_m,floor_m2,chance,median_ignition_h,mode"
            ]
            for p in places {
                let fields = [
                    "\(p.index)", p.source ?? "", String(format: "%.1f", p.eastM),
                    String(format: "%.1f", p.northM),
                    String(format: "%.1f", p.distanceM), p.cladding.rawValue, p.use.rawValue,
                    String(format: "%.1f", p.heightM), String(format: "%.0f", p.floorM2),
                    String(format: "%.3f", p.chance),
                    p.medianIgnitionH.map { String(format: "%.2f", $0) } ?? "",
                    p.mode?.rawValue ?? "",
                ]
                rows.append(fields.joined(separator: ","))
            }
            try (rows.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(path)")
        }
    }
}
