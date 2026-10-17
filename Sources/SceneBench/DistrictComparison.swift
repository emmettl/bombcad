import BlastCore
import Foundation
import Metal
import simd

/// `scenebench district-compare <district-scene's inputs> [--radius 1000] [--until 3]
/// [--window 0.5] [--budget 2048] [--ground saturated] [--observers rigby.csv] [--pane 1.2,1.5]
/// [--design-probability 0.008] [--staircase] [--bare] [--trace] --out folder`: the district's event, and what an accident survey
/// can be set against: arrival times at observers' positions (Rigby et al.'s CSV: lat, lon, and
/// the time seen), peak overpressures on a line of gauges over the open side, and each building's
/// glass and structure from its components' histories, by distance from the charge.
///
/// Glass: map buildings carry no panes, so each façade strip is taken to hold one typical pane
/// (`--pane`, annealed, the construction's thickness) on the strip's net pressure, judged on
/// Moore's large-deflection plate at the median 60 s strength for its area and at the strength
/// with `--design-probability` of breaking (ASTM E1300's 8 in 1,000): a side's glass is broken
/// where any strip's pane is. Structure: each building judged twice, as reinforced concrete (the
/// default construction) and as unreinforced stone 0.5 m thick.
enum DistrictComparison {
    struct Arrival: Codable {
        var name: String
        var kind: String
        var distanceM: Double
        var observedS: Double
        var observedEarliestS: Double
        var simulatedS: Double?
        var peakPa: Float
        var kingeryBulmashS: Double?
    }

    struct LinePoint: Codable {
        var distanceM: Double
        var peakPa: Float
        var kingeryBulmashPa: Double?
    }

    struct Side: Codable {
        var axis: Int
        var outward: Int
        var facesCharge: Bool
        var strips: Int
        var peakNetPa: Float
        var brokenMedian: Bool
        var brokenDesign: Bool
    }

    struct Building: Codable {
        var id: UUID
        var distanceM: Double
        var heightM: Float
        var sides: [Side]
        var concrete: EnvelopeDamageLevel
        var stone: EnvelopeDamageLevel
    }

    struct Band: Codable {
        var fromM: Double
        var toM: Double
        var buildings: Int
        var sides: Int
        var sidesBrokenMedian: Double
        var sidesBrokenDesign: Double
        var facingSides: Int
        var facingBrokenMedian: Double
        var facingBrokenDesign: Double
        var concrete: [Int]
        var stone: [Int]
    }

    struct Report: Codable {
        var massKg: Float
        var radiusM: Float
        var cellSizeM: Float
        var ground: String?
        var untilS: Double
        var steps: Int
        var wallS: Double
        var binS: Double?
        var arrivals: [Arrival]
        var line: [LinePoint]
        var bands: [Band]
        var buildings: [Building]
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let out = value("out"), let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("--out folder and a Metal device")
        }
        let folder = URL(filePath: out)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1000)
        let until = value("until").flatMap(Double.init) ?? 3
        let (built, report) = try inputs.scene(radius: radius)
        var scene = built
        print(report.summary)
        let charge = scene.charge.position
        let dx = inputs.cellSize
        let metresPerDegree = ElevationGrid.metresPerDegree
        let corner = SIMD2(
            inputs.centre.x - Double(radius) / (metresPerDegree * cos(inputs.centre.y * .pi / 180)),
            inputs.centre.y - Double(radius) / metresPerDegree)
        let placement = MapBuildingPlacement(origin: corner, resolution: dx)
        func ground(_ p: SIMD2<Float>) -> Float { scene.terrain?.height(at: p) ?? 0 }

        // Observers: 2 m above the ground where they stood, inside the domain.
        var observers: [(name: String, kind: String, at: SIMD2<Float>, seen: Double, earliest: Double)] = []
        if let path = value("observers") {
            let lines = try String(contentsOf: URL(filePath: path), encoding: .utf8).split(separator: "\n")
            for line in lines.dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 8, f[1] != "Fireball", let seen = Double(f[4]), let earliest = Double(f[5]),
                    let lat = Double(f[6]), let lon = Double(f[7])
                else { continue }
                let p = SIMD2<Float>(placement.position(SIMD2(lon, lat)))
                guard p.x > dx, p.y > dx, p.x < 2 * radius - dx, p.y < 2 * radius - dx else { continue }
                observers.append(("\(f[1]) \(f[0])", f[1], p, seen, earliest))
            }
        }
        // A line over the open side: north from the charge, over the basin and the sea.
        let line = stride(from: 100, through: Double(radius) - 20, by: 100).map { Float($0) }
        var gauges = observers.map { Gauge($0.name, at: SIMD3($0.at.x, $0.at.y, ground($0.at) + 2)) }
        gauges += line.map { d in
            let p = SIMD2(charge.x, charge.y + d)
            return Gauge("line \(Int(d))", at: SIMD3(p.x, p.y, ground(p) + 2))
        }
        scene.gauges = Array(gauges.prefix(BlastSolver.maxGauges))

        // The recommended air (far-field faces: copying faces at a district's low top channel the
        // wave), or the bare core with `--bare`; whole cells for the terrain with `--staircase`.
        var configuration = args.contains("--bare") ? SolverConfiguration() : .recommended
        configuration.terrainCutCells = !args.contains("--staircase")
        if let name = value("ground") {
            guard let type = GroundType(rawValue: name) else {
                throw BlastError.allocationFailed("--ground \(name)")
            }
            configuration.ground = type
        }
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        // A gauge in a building is lifted to the first air above it.
        let points = scene.gauges.map(\.position)
        let cells = points.map { p -> (i: Int, j: Int, k: Int) in
            let i = Int(p.x / dx)
            let j = Int(p.y / dx)
            var k = Int(p.z / dx)
            while k < solver.grid.nz - 1, solver.isSolid(i, j, k) { k += 1 }
            return (i, j, k)
        }
        solver.setGauges(cells: cells, points: points)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(
                windowS: value("window").flatMap(Double.init) ?? 0.5,
                memoryBudget: (value("budget").flatMap(Int.init) ?? 2048) << 20, windowFromArrival: true))
        print("\(solver.grid.cellCount) cells, \(solver.envelopeComponents()?.count ?? 0) components")
        let start = ContinuousClock.now
        var steps = 0
        var lastReport = 0.0
        while solver.time < until {
            let batch =
                args.contains("--trace")
                ? solver.advance(steps: 16, timeLimit: until) : solver.advance(until: until)
            steps += batch.steps
            guard batch.steps > 0, batch.isStable else {
                print("Unstable at t \(solver.time) s")
                break
            }
            if args.contains("--trace") {
                print(
                    String(
                        format: "  t %.5f s, %d steps, dt %.2e s, max overpressure %.3g Pa, swept %.4f",
                        solver.time,
                        batch.steps, batch.lastTimeStep, batch.maxOverpressure, batch.sweptFraction))
            }
            if solver.time - lastReport >= 0.25 {
                lastReport = solver.time
                print(
                    String(
                        format: "  t %.3f s, %d steps, %.0f s", solver.time, steps,
                        DistrictBenchmark.seconds(start)))
            }
        }
        let wall = DistrictBenchmark.seconds(start)
        print(String(format: "Ran to %.3f s in %d steps, %.0f s", solver.time, steps, wall))

        // Arrival: the first sample 500 Pa above the gauge's first.
        let mass = Double(scene.charge.mass)
        func arrival(_ samples: [GaugeSample]) -> (Double?, Float) {
            guard let first = samples.first?.pressure else { return (nil, 0) }
            let at = samples.first { $0.pressure - first > 500 }?.time
            return (at, (samples.map(\.pressure).max() ?? first) - first)
        }
        let histories = solver.gaugeHistories
        var arrivals: [Arrival] = []
        for (n, observer) in observers.enumerated() where n < histories.count {
            let distance = Double(simd_distance(observer.at, SIMD2(charge.x, charge.y)))
            let (at, peak) = arrival(histories[n])
            arrivals.append(
                Arrival(
                    name: observer.name, kind: observer.kind, distanceM: distance, observedS: observer.seen,
                    observedEarliestS: observer.earliest, simulatedS: at, peakPa: peak,
                    kingeryBulmashS: KingeryBulmash.point(at: distance / cbrt(mass))?.arrival(mass: mass)))
        }
        var linePoints: [LinePoint] = []
        for (n, d) in line.enumerated() where observers.count + n < histories.count {
            let (_, peak) = arrival(histories[observers.count + n])
            linePoints.append(
                LinePoint(
                    distanceM: Double(d), peakPa: peak,
                    kingeryBulmashPa: KingeryBulmash.point(at: Double(d) / cbrt(mass))?.incidentPressure))
        }

        // Buildings.
        let recorded = (solver.envelopeComponentHistories() ?? []).filter { !$0.invalid }
        let loads = recorded.map(EnvelopeComponentLoad.init)
        let pane = (value("pane").map { $0.split(separator: ",").compactMap { Double($0) } } ?? [1.2, 1.5])
        let paneArea = pane[0] * pane[1]
        let design = value("design-probability").flatMap(Double.init) ?? 0.008
        let strengths = [
            GlassStrength.sixtySecond(area: paneArea),
            GlassStrength.sixtySecond(area: paneArea, probability: design),
        ]
        let byOwner = Dictionary(grouping: loads.indices, by: { loads[$0].owner })
        let objects = scene.envelopeObjects
        var buildings: [Building] = []
        let concrete = Dictionary(
            uniqueKeysWithValues: EnvelopeDamageAssessment.assess(
                loads: loads, constructions: { scene.envelopeConstruction(for: $0) }
            ).map { ($0.id, $0.structuralLevels.upperBound) })
        let stone = Dictionary(
            uniqueKeysWithValues: EnvelopeDamageAssessment.assess(
                loads: loads,
                constructions: {
                    EnvelopeConstruction(
                        objectID: $0, walls: .unreinforcedMasonry, wallThicknessM: 0.5, source: .user,
                        detail: "stone 0.5 m, assumed for the comparison")
                }
            ).map { ($0.id, $0.structuralLevels.upperBound) })
        for object in objects {
            guard let envelope = object.envelope, let mine = byOwner[object.id] else { continue }
            let low = envelope.blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
                simd_min($0, $1)
            }
            let high = envelope.blocks.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
                simd_max($0, $1)
            }
            let centre = 0.5 * (low + high)
            let toCharge = SIMD2(charge.x - centre.x, charge.y - centre.y)
            let construction = scene.envelopeConstruction(for: object.id)
            var sides: [Side] = []
            let strips = mine.filter { loads[$0].kind == .facade || loads[$0].kind == .wall }
            let bySide = Dictionary(grouping: strips) {
                loads[$0].axis * 2 + (recorded[$0].component.outward > 0 ? 1 : 0)
            }
            for (key, members) in bySide.sorted(by: { $0.key < $1.key }) {
                let axis = key / 2
                let outward = key % 2 == 1 ? 1 : -1
                var broken = [false, false]
                var peak: Float = 0
                for index in members {
                    let load = loads[index]
                    let net = load.netPa
                    let largest = net.map(abs).max() ?? 0
                    peak = max(peak, Float(largest))
                    guard largest > 300 else { continue }
                    for (s, strength) in strengths.enumerated() where !broken[s] {
                        let system = EnvelopePanel.largeDeflectionGlass(
                            thickness: Double(construction.glassThicknessM), material: .annealedGlass,
                            a: pane[0], b: pane[1], sixtySecondStrength: strength)
                        broken[s] = system.response(pressures: net, step: load.binS).lostResistanceAt != nil
                    }
                }
                let faces = axis < 2 ? Float(outward) * toCharge[axis] > 0 : outward > 0
                sides.append(
                    Side(
                        axis: axis, outward: outward, facesCharge: axis < 2 && faces, strips: members.count,
                        peakNetPa: peak, brokenMedian: broken[0], brokenDesign: broken[1]))
            }
            buildings.append(
                Building(
                    id: object.id, distanceM: Double(simd_length(toCharge)), heightM: high.z - low.z,
                    sides: sides.filter { $0.axis < 2 }, concrete: concrete[object.id] ?? .none,
                    stone: stone[object.id] ?? .none))
        }
        let judged = buildings
        let edges: [Double] = [0, 250, 500, 750, 1000, 1250, 1500, 1750, 2000, 2500, 3000]
        var bands: [Band] = []
        for (from, to) in zip(edges, edges.dropFirst()) {
            let inBand = judged.filter { $0.distanceM >= from && $0.distanceM < to }
            guard !inBand.isEmpty else { continue }
            let sides = inBand.flatMap(\.sides)
            let facing = sides.filter(\.facesCharge)
            func share(_ list: [Side], _ broken: (Side) -> Bool) -> Double {
                list.isEmpty ? 0 : Double(list.filter(broken).count) / Double(list.count)
            }
            func levels(_ level: (Building) -> EnvelopeDamageLevel) -> [Int] {
                EnvelopeDamageLevel.allCases.map { l in inBand.filter { level($0) == l }.count }
            }
            bands.append(
                Band(
                    fromM: from, toM: to, buildings: inBand.count, sides: sides.count,
                    sidesBrokenMedian: share(sides, \.brokenMedian),
                    sidesBrokenDesign: share(sides, \.brokenDesign),
                    facingSides: facing.count, facingBrokenMedian: share(facing, \.brokenMedian),
                    facingBrokenDesign: share(facing, \.brokenDesign), concrete: levels(\.concrete),
                    stone: levels(\.stone)))
        }
        let result = Report(
            massKg: scene.charge.mass, radiusM: radius, cellSizeM: dx, ground: value("ground"),
            untilS: solver.time,
            steps: steps, wallS: wall, binS: recorded.first?.binS, arrivals: arrivals, line: linePoints,
            bands: bands, buildings: judged)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: folder.appending(path: "comparison.json"))

        print("Arrivals (observed best / earliest, simulated, Kingery–Bulmash), s:")
        for a in arrivals.sorted(by: { $0.distanceM < $1.distanceM }) {
            print(
                String(
                    format: "  %-12@ %5.0f m  %.3f / %.3f  %@  %@  peak %.1f kPa", a.name as NSString,
                    a.distanceM,
                    a.observedS, a.observedEarliestS,
                    (a.simulatedS.map { String(format: "%.3f", $0) } ?? "  -  ") as NSString,
                    (a.kingeryBulmashS.map { String(format: "%.3f", $0) } ?? "  -  ") as NSString,
                    a.peakPa / 1000))
        }
        print("Line north (simulated, Kingery–Bulmash), kPa:")
        for p in linePoints {
            print(
                String(
                    format: "  %5.0f m  %7.1f  %@", p.distanceM, p.peakPa / 1000,
                    (p.kingeryBulmashPa.map { String(format: "%7.1f", $0 / 1000) } ?? "-") as NSString))
        }
        print(
            "Bands: buildings, sides broken (median / design), facing sides broken, concrete and stone levels"
        )
        for b in bands {
            print(
                String(
                    format: "  %4.0f–%4.0f m  %5d  %.2f / %.2f  %.2f / %.2f  %@  %@", b.fromM, b.toM,
                    b.buildings,
                    b.sidesBrokenMedian, b.sidesBrokenDesign, b.facingBrokenMedian, b.facingBrokenDesign,
                    b.concrete.map(String.init).joined(separator: ",") as NSString,
                    b.stone.map(String.init).joined(separator: ",") as NSString))
        }
    }
}
