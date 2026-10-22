import BlastCore
import Foundation
import Metal
import simd

/// `scenebench district-compare <district-scene's inputs> [--radius 1000] [--until 3]
/// [--window 0.5] [--budget 2048] [--ground saturated] [--observers rigby.csv] [--pane 1.2,1.5]
/// [--design-probability 0.008] [--glass 0.006,0.004] [--staircase] [--bare] [--trace]
/// [--save-loads folder] [--refine 2 --levels 2 --threshold 0.005 --refine-memory GB --hold Pa]
/// [--ceiling auto|m] [--place-dx m] [--profile] [--steer 0.8,1.5 --steer-reach 12 --steer-by ring|near --steer-on glass|structure] [--corridor x,y,60] [--doubt [--doubt-band 1,1.6]]
/// [--refine-toward x,y;x,y [--toward-width 1.5]] [--export-field folder [--field-above 2] [--first-phase]]
/// --out folder`: the district's event, and what an accident survey
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
        /// Median then design for each `--glass` thickness in turn (the first as above).
        var broken: [Bool]
    }

    struct Building: Codable {
        var id: UUID
        var distanceM: Double
        /// The centre of its blocks' box in the domain, m: to match buildings across runs, whose
        /// ids are made afresh.
        var centreM: [Float]?
        var heightM: Float
        var sides: [Side]
        var concrete: EnvelopeDamageLevel
        var stone: EnvelopeDamageLevel
        /// As the app judges it: some pane broken, and its walls' and roofs' worst level.
        var glassBroken: Bool? = nil
        var level: EnvelopeDamageLevel? = nil
        /// With `--doubt`, whether finer cells could flip that (`EnvelopeDoubt.Verdict`).
        var doubt: String? = nil
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
        /// Sides broken for each `--glass` thickness, median then design.
        var sidesBroken: [Double]
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
        /// With `--steer`: the coarse first pass's wall time, the buildings judged and those in doubt.
        var steerWallS: Double?
        var steerBuildings: Int?
        var steerInDoubt: Int?
        /// Each refined level's blocks summed over the run's steps.
        var refinedBlockSteps: [Int]?
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        // A line at a time, so that what is printed survives a failure later on.
        setvbuf(stdout, nil, _IOLBF, 0)
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
        // The mapped start since its rerun on 20 October 2026; `--balloon-start` for the balloon it was first run on.
        var configuration =
            args.contains("--bare")
            ? SolverConfiguration()
            : args.contains("--balloon-start") ? .recommended.balloonStart : .recommended
        configuration.terrainCutCells = !args.contains("--staircase")
        // Refined air: `--refine 2 --levels 2 --threshold 0.005 --refine-memory 18` (GB), and
        // `--hold 500` (Pa) holding it beside the façades while they are loaded.
        if let ratio = value("refine").flatMap(Int.init) { configuration.refinement = ratio }
        if let levels = value("levels").flatMap(Int.init) { configuration.refinementLevels = levels }
        if let threshold = value("threshold").flatMap(Float.init) {
            configuration.refinementThreshold = threshold
        }
        if let memory = value("refine-memory").flatMap(Double.init) {
            configuration.refinementMemory = Int(memory * Double(1 << 30))
        }
        configuration.refinementHoldsEnvelopes = value("hold").flatMap(Float.init)
        // `--ceiling auto|m`: no refinement more than this above the ground; auto, the height of
        // all but the tallest 2% of the buildings and four cells for the shock's top.
        if let ceiling = value("ceiling") {
            let heights = report.placed.map { $0.top - $0.base }.sorted()
            let most =
                heights.isEmpty ? 0 : heights[min(heights.count - 1, Int(0.98 * Double(heights.count)))]
            configuration.refinementCeiling = ceiling == "auto" ? most + 4 * dx : Float(ceiling)
            print(
                String(
                    format:
                        "Refinement ceiling %.0f m above the ground (98%% of the buildings to %.0f m, the tallest %.0f m)",
                    configuration.refinementCeiling ?? 0, most, heights.last ?? 0))
        }
        if let name = value("ground") {
            guard let type = GroundType(rawValue: name) else {
                throw BlastError.allocationFailed("--ground \(name)")
            }
            configuration.ground = type
        }
        // A charge inside a building's block would release nothing: no run to make.
        guard !scene.chargeIsBlocked else { throw BlastError.chargeBlocked(scene.charge.position) }
        // The event, in a scope of its own, so that the solver and its pools are let go before the
        // buildings are judged from what it recorded.
        // Each refined level's blocks summed over the steps of the last event (blocks at each
        // batch's end times its steps): what the refinement cost, apart from the Mac's load.
        var blockSteps: [Int] = []
        // `--export-field folder`: the run's peak fields at `--field-above` metres (2) over the
        // ground, with the plan's inputs, as `field-export` writes them (FieldExport.swift).
        func event(_ configuration: SolverConfiguration, exportField: URL? = nil) throws -> (
            Double, Int, Double, [Arrival], [LinePoint], [EnvelopeComponentHistory]
        ) {
            blockSteps = []
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
            if exportField != nil, args.contains("--first-phase") {
                try FieldExport.recordFirstPhase(
                    solver: solver, scene: scene, above: Float(value("field-above").flatMap(Double.init) ?? 2)
                )
            }
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects,
                options: EnvelopeHistoryOptions(
                    windowS: value("window").flatMap(Double.init) ?? 0.5,
                    memoryBudget: (value("budget").flatMap(Int.init) ?? 2048) << 20, windowFromArrival: true))
            print("\(solver.grid.cellCount) cells, \(solver.envelopeComponents()?.count ?? 0) components")
            // `--profile`: the GPU's time in each stage, over batches of 16 steps (`blastbench profile`).
            let profiling = args.contains("--profile")
            if profiling { try solver.enableGPUProfiling(true, detailed: true) }
            var stages: [String: Double] = [:]
            var phases = SIMD4<Double>.zero
            let start = ContinuousClock.now
            var steps = 0
            var lastReport = 0.0
            while solver.time < until {
                // `--trace [steps]`: batches of that many steps (16), each printed.
                let batch =
                    args.contains("--trace") || profiling
                    ? solver.advance(steps: value("trace").flatMap(Int.init) ?? 16, timeLimit: until)
                    : solver.advance(until: until)
                if let profile = solver.lastBatchGPUProfile, profiling {
                    for (name, seconds) in profile.stages { stages[name, default: 0] += seconds }
                    phases += SIMD4(profile.airS, profile.mechanicsS, profile.couplingS, profile.observationS)
                }
                // Where the refined air lies, every half second: each level's blocks by height.
                if profiling, !solver.refinementPools.isEmpty,
                    Int(solver.time / 0.5)
                        > Int((solver.time - batch.lastTimeStep * Double(batch.steps)) / 0.5)
                {
                    let block = Double(dx) * 4
                    for (level, row) in solver.refinedBlocksByHeight().enumerated() {
                        let height = block / pow(Double(configuration.refinement), Double(level))
                        let total = row.reduce(0, +)
                        let bands = row.enumerated().filter { $0.element > 0 }.map {
                            String(format: "%.0f m %d", Double($0.offset) * height, $0.element)
                        }
                        print(
                            String(
                                format: "  t %.2f s, level %d: %d blocks of %.0f m; by height: ", solver.time,
                                level + 1, total, height) + bands.joined(separator: ", "))
                    }
                }
                steps += batch.steps
                if !solver.refinementPools.isEmpty {
                    let rows = solver.refinedBlocksByHeight()
                    if blockSteps.count != rows.count { blockSteps = [Int](repeating: 0, count: rows.count) }
                    for (level, row) in rows.enumerated() {
                        blockSteps[level] += row.reduce(0, +) * batch.steps
                    }
                }
                // No steps: within the solver's tolerance of the end.
                guard batch.steps > 0 else { break }
                guard batch.isStable else {
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
            print(String(format: "Step buffers' GPU time %.2f s", solver.stepGPUSeconds))
            if profiling {
                let total = stages.values.reduce(0, +)
                print(
                    String(
                        format:
                            "GPU s: air %.1f, mechanics %.1f, coupling %.1f, observation %.1f; stages %.1f",
                        phases.x, phases.y, phases.z, phases.w, total))
                for (name, seconds) in stages.sorted(by: { $0.value > $1.value }) {
                    print(
                        "  " + name.padding(toLength: 28, withPad: " ", startingAt: 0)
                            + String(format: " %8.2f s  %5.1f%%", seconds, 100 * seconds / max(total, 1e-12)))
                }
            }
            let placed = solver.refinedPatchesPlaced
            for (level, pool) in solver.refinementPools.enumerated() {
                print(
                    "Refined level \(level + 1): \(pool), \(blockSteps.indices.contains(level) ? blockSteps[level] : 0) block-steps, \(placed[level]) placed"
                )
            }
            if !solver.refinementPools.isEmpty {
                print("Refined pools grew late: \(solver.refinementPoolGrewLate)")
            }

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
                        name: observer.name, kind: observer.kind, distanceM: distance,
                        observedS: observer.seen,
                        observedEarliestS: observer.earliest, simulatedS: at, peakPa: peak,
                        kingeryBulmashS: KingeryBulmash.point(at: distance / cbrt(mass))?.arrival(mass: mass))
                )
            }
            var linePoints: [LinePoint] = []
            for (n, d) in line.enumerated() where observers.count + n < histories.count {
                let (_, peak) = arrival(histories[observers.count + n])
                linePoints.append(
                    LinePoint(
                        distanceM: Double(d), peakPa: peak,
                        kingeryBulmashPa: KingeryBulmash.point(at: Double(d) / cbrt(mass))?.incidentPressure))
            }

            if let exportField {
                // `--first-phase`: the first positive phase's impulse as a third target, recorded
                // as the run went (set up before the run, above). The id and layout are `--id` and
                // `--layout`, as field-export takes them, where given.
                try FieldExport.write(
                    solver: solver, scene: scene, folder: exportField,
                    id: value("id") ?? exportField.lastPathComponent,
                    layout: value("layout"), buildings: report.placed.count,
                    above: Float(value("field-above").flatMap(Double.init) ?? 2), edgeCells: 4,
                    configuration: args.contains("--bare")
                        ? "bare"
                        : args.contains("--balloon-start") ? "recommended, balloon start" : "recommended",
                    ground: value("ground"), steps: steps, wallS: wall, stable: solver.time >= until * 0.999,
                    arguments: args)
            }

            // Buildings.
            let recorded = (solver.envelopeComponentHistories() ?? []).filter { !$0.invalid }
            return (solver.time, steps, wall, arrivals, linePoints, recorded)
        }
        let pane = (value("pane").map { $0.split(separator: ",").compactMap { Double($0) } } ?? [1.2, 1.5])
        let paneArea = pane[0] * pane[1]
        let design = value("design-probability").flatMap(Double.init) ?? 0.008
        // Glass thicknesses to judge, m: the construction's (nil) unless `--glass` lists them.
        let glass: [Double?] =
            value("glass").map { $0.split(separator: ",").compactMap { Double($0) }.map { Optional($0) } }
            ?? [nil]
        let strengths = [
            GlassStrength.sixtySecond(area: paneArea),
            GlassStrength.sixtySecond(area: paneArea, probability: design),
        ]
        // Each building's glass and structure from its components' loads.
        func judge(_ loads: [EnvelopeComponentLoad]) -> ([Building], [EnvelopeBuildingDamage]) {
            var buildings: [Building] = []
            let byOwner = Dictionary(grouping: loads.indices, by: { loads[$0].owner })
            let objects = scene.envelopeObjects
            let judging = ContinuousClock.now
            let assessed = EnvelopeDamageAssessment.assess(
                loads: loads, constructions: { scene.envelopeConstruction(for: $0) })
            // The end-of-run judgement as the app makes it, timed for Scripts/perf/run-standard.py.
            print(
                String(
                    format: "Judged %d buildings from %d components, as the app does, in %.2f s",
                    assessed.count,
                    loads.count, DistrictBenchmark.seconds(judging)))
            let concrete = Dictionary(
                uniqueKeysWithValues: assessed.map { ($0.id, $0.structuralLevels.upperBound) })
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
                let low = envelope.blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude))
                {
                    simd_min($0, $1)
                }
                let high = envelope.blocks.map(\.max).reduce(
                    SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                ) {
                    simd_max($0, $1)
                }
                let centre = 0.5 * (low + high)
                let toCharge = SIMD2(charge.x - centre.x, charge.y - centre.y)
                let construction = scene.envelopeConstruction(for: object.id)
                var sides: [Side] = []
                let strips = mine.filter { loads[$0].kind == .facade || loads[$0].kind == .wall }
                let bySide = Dictionary(grouping: strips) {
                    loads[$0].axis * 2 + (loads[$0].outward > 0 ? 1 : 0)
                }
                for (key, members) in bySide.sorted(by: { $0.key < $1.key }) {
                    let axis = key / 2
                    let outward = key % 2 == 1 ? 1 : -1
                    var broken = [Bool](repeating: false, count: 2 * glass.count)
                    var peak: Float = 0
                    for index in members {
                        let load = loads[index]
                        let net = load.netPa
                        let largest = net.map(abs).max() ?? 0
                        peak = max(peak, Float(largest))
                        guard largest > 300 else { continue }
                        for s in broken.indices where !broken[s] {
                            let system = EnvelopePanel.largeDeflectionGlass(
                                thickness: glass[s / 2] ?? Double(construction.glassThicknessM),
                                material: .annealedGlass, a: pane[0], b: pane[1],
                                sixtySecondStrength: strengths[s % 2])
                            broken[s] =
                                system.response(pressures: net, step: load.binS).lostResistanceAt != nil
                        }
                    }
                    let faces = axis < 2 ? Float(outward) * toCharge[axis] > 0 : outward > 0
                    sides.append(
                        Side(
                            axis: axis, outward: outward, facesCharge: axis < 2 && faces,
                            strips: members.count,
                            peakNetPa: peak, brokenMedian: broken[0], brokenDesign: broken[1], broken: broken)
                    )
                }
                buildings.append(
                    Building(
                        id: object.id, distanceM: Double(simd_length(toCharge)),
                        centreM: [centre.x, centre.y],
                        heightM: high.z - low.z,
                        sides: sides.filter { $0.axis < 2 }, concrete: concrete[object.id] ?? .none,
                        stone: stone[object.id] ?? .none))
            }
            return (buildings, assessed)
        }
        let objects = scene.envelopeObjects
        // `--steer 0.8,1.5`: refinement steered by the decision (docs/refinement-steering.md). A
        // first pass on the coarse cells alone judges every building with its loads scaled by
        // each factor in turn; the run proper refines only within `--steer-reach` metres (12) of
        // the buildings whose glass or structure comes out differently between the two, the
        // decisions that the coarse cells' error leaves in doubt.
        var steered: (wallS: Double, buildings: Int, inDoubt: Int)?
        if let factors = value("steer").map({ $0.split(separator: ",").compactMap { Double($0) } }),
            factors.count == 2, configuration.refinement > 1
        {
            var coarse = configuration
            coarse.refinement = 1
            print("First pass, on the coarse cells:")
            let first = try event(coarse)
            let base = first.5.map(EnvelopeComponentLoad.init)
            // `--steer-on glass|structure`: the decisions asked for; both by default.
            let on = value("steer-on")
            func decisions(_ factor: Double) -> [UUID: [Int]] {
                let loads = base.map { load in
                    var scaled = load
                    scaled.outerPa = load.outerPa.map { $0 * factor }
                    scaled.innerPa = load.innerPa.map { $0 * factor }
                    scaled.stripPa = load.stripPa.map {
                        ($0.outer.map { $0 * factor }, $0.inner.map { $0 * factor })
                    }
                    return scaled
                }
                return Dictionary(
                    uniqueKeysWithValues: judge(loads).0.map { building in
                        (
                            building.id,
                            (on != "structure" ? building.sides.map { $0.brokenMedian ? 1 : 0 } : [])
                                + (on != "glass"
                                    ? [
                                        EnvelopeDamageLevel.allCases.firstIndex(of: building.concrete) ?? 0,
                                        EnvelopeDamageLevel.allCases.firstIndex(of: building.stone) ?? 0,
                                    ] : [])
                        )
                    })
            }
            let low = decisions(factors[0])
            let high = decisions(factors[1])
            let inDoubt = Set(low.keys.filter { low[$0] != high[$0] })
            let reach = Float(value("steer-reach").flatMap(Double.init) ?? 12)
            let boxes = objects.filter { inDoubt.contains($0.id) }.compactMap { object -> RefinementRegion? in
                guard let blocks = object.envelope?.blocks, !blocks.isEmpty else { return nil }
                let low = blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
                    simd_min($0, $1)
                }
                let high = blocks.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
                    simd_max($0, $1)
                }
                return RefinementRegion(low: low - reach, high: high + reach)
            }
            // `--steer-by near`: only about those buildings. The default, `ring`: everywhere out to
            // the farthest of them and a reach beyond, a disc of strips about the charge, since a
            // shock refined only as it nears a building arrives smeared by the coarse cells it
            // crossed (docs/refinement-steering.md).
            if value("steer-by") == "near" {
                configuration.refinementConfinedTo = boxes
            } else {
                let centre = SIMD2(charge.x, charge.y)
                let ring =
                    boxes.map { box in
                        [box.low.x, box.high.x].flatMap { x in
                            [box.low.y, box.high.y].map { y in SIMD2(x, y) }
                        }
                        .map { simd_distance($0, centre) }.max() ?? 0
                    }.max() ?? 0
                let strips = 32
                configuration.refinementConfinedTo = (0..<strips).map { n in
                    let y0 = -ring + 2 * ring * Float(n) / Float(strips)
                    let y1 = y0 + 2 * ring / Float(strips)
                    let nearest = y0 > 0 ? y0 : (y1 < 0 ? -y1 : 0)
                    let half = (ring * ring - nearest * nearest).squareRoot()
                    return RefinementRegion(
                        low: SIMD3(centre.x - half, centre.y + y0, -1e4),
                        high: SIMD3(centre.x + half, centre.y + y1, 1e4))
                }
                print(String(format: "Ring of %.0f m about the charge", ring))
            }
            steered = (first.2, low.count, inDoubt.count)
            print(
                String(
                    format:
                        "Steered: %d of %d buildings in doubt between ×%.2f and ×%.2f, refined within %.0f m of them",
                    inDoubt.count, low.count, factors[0], factors[1], reach))
        }
        // `--corridor x,y[,half-width]` (m in the domain, 60): refinement only along the way from
        // the charge to that point and a reach beyond it, for a question about one building
        // (docs/refinement-steering.md): boxes along the line, each its piece's extent widened.
        if let numbers = value("corridor").map({ $0.split(separator: ",").compactMap { Float($0) } }),
            numbers.count >= 2, configuration.refinement > 1
        {
            let start = SIMD2(charge.x, charge.y)
            let target = SIMD2(numbers[0], numbers[1])
            let width = numbers.count > 2 ? numbers[2] : 60
            let direction = simd_normalize(target - start)
            let end = target + direction * width
            let pieces = 32
            configuration.refinementConfinedTo = (0..<pieces).map { n in
                let a = start + (end - start) * Float(n) / Float(pieces)
                let b = start + (end - start) * Float(n + 1) / Float(pieces)
                let low = simd_min(a, b) - width
                let high = simd_max(a, b) + width
                return RefinementRegion(low: SIMD3(low.x, low.y, -1e4), high: SIMD3(high.x, high.y, 1e4))
            }
            print(String(format: "Corridor to (%.0f, %.0f) m, %.0f m either side", target.x, target.y, width))
        }
        // `--refine-toward x,y[;x,y...]` (m in the domain): refinement toward the buildings nearest
        // those points, along corridors from the charge, as the app's "Refine toward"
        // (`Scenario.refinementCorridors`, 1.5 m/kg^(1/3) either side; `--toward-width` another).
        if let text = value("refine-toward"), configuration.refinement > 1 {
            let points = text.split(separator: ";").map { $0.split(separator: ",").compactMap { Float($0) } }
                .filter { $0.count >= 2 }
            let ids = points.compactMap { point -> UUID? in
                let at = SIMD2(point[0], point[1])
                return scene.envelopeObjects.min { a, b in
                    func centre(_ object: SceneObject) -> SIMD2<Float> {
                        guard let box = object.bounds else { return SIMD2(repeating: .infinity) }
                        return 0.5 * SIMD2(box.min.x + box.max.x, box.min.y + box.max.y)
                    }
                    return simd_distance(centre(a), at) < simd_distance(centre(b), at)
                }?.id
            }
            let width = value("toward-width").flatMap(Float.init) ?? RefinementRegion.corridorScaledHalfWidth
            configuration.refinementConfinedTo = scene.refinementCorridors(
                toward: ids, scaledHalfWidth: width)
            for id in ids {
                if let box = scene.object(id: id)?.bounds {
                    let centre = 0.5 * (box.min + box.max)
                    print(
                        String(
                            format: "Refining toward the building at (%.0f, %.0f) m, %.0f m from the charge",
                            centre.x, centre.y,
                            simd_distance(SIMD2(centre.x, centre.y), SIMD2(charge.x, charge.y))))
                }
            }
        }
        // `--confine-box x0,y0,x1,y1`: refinement only in that box, m in the domain (to time the
        // refinement's fixed costs with a box the shock never reaches).
        if let numbers = value("confine-box").map({ $0.split(separator: ",").compactMap { Float($0) } }),
            numbers.count == 4
        {
            configuration.refinementConfinedTo = [
                RefinementRegion(
                    low: SIMD3(numbers[0], numbers[1], -1e4), high: SIMD3(numbers[2], numbers[3], 1e4))
            ]
        }
        let (finalTime, steps, wall, arrivals, linePoints, recorded) = try event(
            configuration, exportField: value("export-field").map { URL(filePath: $0) })
        let loads = recorded.map(EnvelopeComponentLoad.init)
        let (firstJudged, assessed) = judge(loads)
        // The app's own outcome for each building, and with `--doubt` whether the cells could flip
        // it: its loads judged again at the ends of the band the validation gives its face.
        var judged = firstJudged
        let byID = Dictionary(uniqueKeysWithValues: assessed.map { ($0.id, $0) })
        let doubt =
            args.contains("--doubt")
            ? EnvelopeDoubt.assess(
                loads: loads, scenario: scene, cellSize: dx, configuration: configuration,
                constructions: { scene.envelopeConstruction(for: $0) },
                band: value("doubt-band").flatMap { text -> ClosedRange<Double>? in
                    let f = text.split(separator: ",").compactMap { Double($0) }
                    return f.count == 2 ? f[0]...f[1] : nil
                }) : nil
        let verdicts = Dictionary(uniqueKeysWithValues: (doubt?.buildings ?? []).map { ($0.id, $0.verdict) })
        for n in judged.indices {
            judged[n].glassBroken = byID[judged[n].id].map { $0.panesBroken > 0 }
            judged[n].level = byID[judged[n].id]?.structuralLevels.upperBound
            judged[n].doubt = verdicts[judged[n].id]?.rawValue
        }
        if let doubt {
            print(
                String(
                    format: "Doubt at %.3f m/kg^(1/3), loads ×%.2f–%.2f: ", doubt.scaledCell,
                    doubt.factors.lowerBound, doubt.factors.upperBound)
                    + "\(doubt.count(.settled)) settled, \(doubt.count(.inDoubt)) in doubt, "
                    + "\(doubt.count(.likelyDifferent)) likely different")
        }
        // The façades' glass by each building's mix, as the app judges it.
        let distances = Dictionary(uniqueKeysWithValues: judged.map { ($0.id, $0.distanceM) })
        DistrictGlass.printBands(
            "Glass by the map's mixes",
            assessed.compactMap { building in
                distances[building.id].map {
                    (
                        $0, scene.envelopeConstruction(for: building.id).glazing?.name ?? "",
                        (building.facadeGlass ?? []).filter { $0.axis < 2 }.map(\.glass)
                    )
                }
            })
        if let folder = value("save-loads") {
            let heights = Dictionary(uniqueKeysWithValues: judged.map { ($0.id, $0.heightM) })
            try DistrictGlass.save(
                to: URL(filePath: folder), loads: loads, objects: objects.filter { distances[$0.id] != nil },
                distance: { distances[$0] ?? 0 },
                height: { heights[$0] ?? 0 },
                mix: { scene.envelopeConstruction(for: $0).glazing?.name ?? "" })
        }
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
                    facingBrokenDesign: share(facing, \.brokenDesign),
                    sidesBroken: (0..<(2 * glass.count)).map { s in share(sides) { $0.broken[s] } },
                    concrete: levels(\.concrete), stone: levels(\.stone)))
        }
        let result = Report(
            massKg: scene.charge.mass, radiusM: radius, cellSizeM: dx, ground: value("ground"),
            untilS: finalTime,
            steps: steps, wallS: wall, binS: recorded.first?.binS, arrivals: arrivals, line: linePoints,
            bands: bands, buildings: judged, steerWallS: steered?.wallS, steerBuildings: steered?.buildings,
            steerInDoubt: steered?.inDoubt, refinedBlockSteps: blockSteps.isEmpty ? nil : blockSteps)
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
        if glass.count > 1 {
            print(
                "Sides broken (median / design) for each glass thickness, \(glass.map { "\(($0 ?? 0) * 1000) mm" }):"
            )
            for b in bands {
                print(
                    String(format: "  %4.0f–%4.0f m  ", b.fromM, b.toM)
                        + stride(from: 0, to: b.sidesBroken.count, by: 2).map {
                            String(format: "%.2f / %.2f", b.sidesBroken[$0], b.sidesBroken[$0 + 1])
                        }.joined(separator: "   "))
            }
        }
    }
}
