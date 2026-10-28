import BlastCore
import Foundation
import simd

/// `scenebench people <district-scene's inputs> [--radius 2500] [--time evening|workday|night]
/// [--density 1] [--untagged residential] [--yield-within 1.5] [--csv out.csv]`: the people in a
/// laid-out district and those its quick estimate expects hurt (emmettl/bombcad-work#41;
/// docs/people-in-the-scene.md): the full look, as the app's, then `OccupantInjury.estimate`,
/// totalled by distance band and by use, with the band over the assumptions.
enum PeopleEstimate {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 2500)
        let (scene, report) = try inputs.scene(radius: radius)
        print("\(report.summary)")
        let dx = inputs.cellSize
        let mass = Double(scene.charge.mass)
        var clock = ContinuousClock.now
        // `--look file.json`: the full look's chances kept from an earlier run of the same inputs (the
        // buildings by their order, since a layout gives them new identifiers), or made and kept there.
        struct Kept: Codable {
            var glass: [FacadeLoadSurrogate.SideGlass]
            var structure: [FacadeLoadSurrogate.StructureChance]
        }
        let ids = scene.envelopeObjects.map(\.id)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        func indexID(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", n))!
        }
        let glass: [FacadeLoadSurrogate.SideGlass]
        let structure: [FacadeLoadSurrogate.StructureChance]
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
            print("Look read from \(path)")
        } else {
            let prepared = FacadeLoadSurrogate.Prepared(
                scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args))
            let within = value("yield-within").flatMap(Double.init) ?? 1.5
            let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(within) / 1.645, samples: 100)
            let look = prepared.look(
                charge: scene.charge.position, mass: mass,
                constructions: { scene.envelopeConstruction(for: $0) },
                uncertainty: uncertainty)
            print(String(format: "Full look in %.1f s", DistrictBenchmark.seconds(clock)))
            glass = look.glass
            structure = look.structure
            if let path = value("look") {
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

        var assumptions = OccupantInjury.Assumptions()
        if let time = value("time").flatMap(OccupancyTime.init(rawValue:)) { assumptions.time = time }
        if let density = value("density").flatMap(Double.init) { assumptions.densityScale = density }
        if let use = value("untagged").flatMap(BuildingUse.init(rawValue:)) { assumptions.untaggedUse = use }
        clock = .now
        let estimate = OccupantInjury.estimate(
            scene: scene, glass: glass, structure: structure, charge: scene.charge.position, mass: mass,
            assumptions: assumptions)
        print(String(format: "People estimated in %.2f s", DistrictBenchmark.seconds(clock)))
        print(estimate.summary)
        print(
            String(
                format:
                    "Inside %.0f, out of doors %.0f. The CIA's siting curves would kill %.0f of those inside.",
                estimate.buildings.reduce(0) { $0 + $1.occupants },
                estimate.buildings.reduce(0) { $0 + $1.outdoors },
                OccupantInjury.ciaDeaths(estimate, scene: scene, mass: mass)))

        // By distance band (the building's centre from the charge) and by use.
        let objects = Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, $0) })
        let charge = scene.charge.position
        func distance(_ id: UUID) -> Double {
            guard let object = objects[id] else { return .infinity }
            let b = OccupantInjury.Bounds(object)
            return Double(simd_length(SIMD2(b.centre.x - charge.x, b.centre.y - charge.y)))
        }
        let bands: [Double] = [0, 250, 500, 750, 1000, 1500, 2000, 2500, .infinity]
        print(
            "Band (m) | buildings | people | hurt (mean) | severe | glass | walls | blast | share hurt | broken"
        )
        var rows: [String] = []
        for k in 0..<(bands.count - 1) {
            let mine = estimate.buildings.filter {
                let d = distance($0.owner)
                return d >= bands[k] && d < bands[k + 1]
            }
            guard !mine.isEmpty else { continue }
            let people = mine.reduce(0) { $0 + $1.occupants + $1.outdoors }
            let hurt = mine.reduce(0) { $0 + $1.expected }
            let area = mine.reduce(0) { $0 + $1.floorAreaM2 }
            print(
                String(
                    format: "%4.0f–%4.0f | %6d | %9.0f | %8.0f | %6.0f | %7.0f | %6.0f | %6.0f | %.3f | %.2f",
                    bands[k], min(bands[k + 1], 9999), mine.count, people, hurt,
                    mine.reduce(0) { $0 + $1.severe }, mine.reduce(0) { $0 + $1.glass },
                    mine.reduce(0) { $0 + $1.structure }, mine.reduce(0) { $0 + $1.blast },
                    people > 0 ? hurt / people : 0,
                    area > 0 ? mine.reduce(0) { $0 + $1.broken * $1.floorAreaM2 } / area : 0))
        }
        for use in BuildingUse.allCases {
            let mine = estimate.buildings.filter { $0.use == use }
            guard !mine.isEmpty else { continue }
            print(
                String(
                    format: "%@: %d buildings (%d by tag), %.0f people, %.0f hurt", use.rawValue, mine.count,
                    mine.filter { !$0.useAssumed }.count, mine.reduce(0) { $0 + $1.occupants + $1.outdoors },
                    mine.reduce(0) { $0 + $1.expected }))
        }
        if let path = value("csv") {
            rows = [
                "distance_m,use,assumed,floor_m2,inside,outdoors,expected,low,high,severe,glass,structure,blast,broken"
            ]
            for b in estimate.buildings {
                rows.append(
                    String(
                        format: "%.1f,%@,%d,%.0f,%.2f,%.2f,%.3f,%.3f,%.3f,%.4f,%.3f,%.3f,%.3f,%.3f",
                        distance(b.owner),
                        b.use.rawValue, b.useAssumed ? 1 : 0, b.floorAreaM2, b.occupants, b.outdoors,
                        b.expected,
                        b.low, b.high, b.severe, b.glass, b.structure, b.blast, b.broken))
            }
            try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(path)")
        }
    }
}
