import BlastCore
import BlastModel
import Foundation
import Metal
import simd

/// `scenebench wall-convergence <district-scene's inputs> [--radius 1000] --names a,b,…
/// [--levels 0|1|2] [--whole] [--empty] [--refine-memory 12] --out run.json`, or
/// `scenebench wall-convergence --isolated 500 --dx 4 --mass 500000 --out run.json`: whether the
/// walls' loads that the close calls' refined runs gave are converged (emmettl/bombcad-work#19,
/// #34). The named buildings run as threshold refinement runs them, on the scene cut round them
/// (`ThresholdRefinement.plan`) or with `--whole` on the whole scene, on the scene's cells alone
/// (`--levels 0`), refined to half along corridors to them (1), or to a quarter (2). With
/// `--empty` the buildings are taken away and gauges read the incident wave where they stood.
/// `--isolated d` is one block in the open, its front `d` m from the charge, on uniform cells.
/// Each walls' and façades' component's peak, first-phase impulse and SDOF rotation, and each
/// gauge's, are written for comparing runs.
enum WallConvergence {
    struct Component: Codable {
        var id: String
        var building: String
        var kind: String
        var axis: Int
        var outward: Int
        var distanceM: Double
        /// The largest outer overpressure of any step, and of any bin, Pa.
        var peakStepPa: Double
        var peakBinPa: Double
        /// The outer side's impulse over its first positive phase, Pa s.
        var firstImpulsePaS: Double
        var peakNetPa: Double
        /// The SDOF's support rotation with fixed and simply supported edges, degrees, and its
        /// worst level.
        var rotationDeg: [Double]
        var level: String
    }
    struct Probe: Codable {
        var name: String
        var distanceM: Double
        var arrivalS: Double?
        var peakPa: Double
        var firstImpulsePaS: Double
    }
    struct Run: Codable {
        var label: String
        var cellSize: Float
        var levels: Int
        var whole: Bool
        var empty: Bool
        var cells: Int
        var untilS: Double
        var wallS: Double
        var refinedPools: [String]
        var poolsGrewLate: Bool
        var components: [Component]
        var probes: [Probe]
    }

    /// The positive phase's impulse of `pressures` (overpressures in bins `binS` long): the most
    /// their running integral from the start reaches, so that a dip below zero just behind the
    /// shock, sharper on finer cells, does not end it early.
    static func firstImpulse(_ pressures: [Double], binS: Double) -> Double {
        var sum = 0.0
        var most = 0.0
        for p in pressures {
            sum += p * binS
            most = max(most, sum)
        }
        return most
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let out = value("out"), let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("--out run.json and a Metal device")
        }
        let levels = value("levels").flatMap(Int.init) ?? 0
        let whole = args.contains("--whole")
        let empty = args.contains("--empty")
        var scene: Scenario
        var chosen: [UUID]
        var cellSize: Float
        var corridors: [RefinementRegion]?
        var untilS: Double
        if let distance = value("isolated").flatMap(Float.init) {
            // One block, 20 m deep, 40 m wide and 15 m tall, its front `distance` m from the charge,
            // a quarter of the scene: the charge in the corner on the ground and two mirror planes
            // through it and the block's middle, the open faces 4 m/kg^(1/3) beyond it, 320 m up
            // as Beirut's runs.
            cellSize = Float(value("dx").flatMap(Double.init) ?? 4)
            let mass = Float(value("mass").flatMap(Double.init) ?? 500_000)
            let clearance = (4 * cbrt(mass) / 8).rounded(.up) * 8
            let size = SIMD3<Float>(distance + 20 + clearance, 20 + clearance, 320)
            // On the ground and two mirror planes, the scene's charge is the quarter of the surface
            // burst inside the domain (`mapping`: 2^3 times it in free air, twice `mass`).
            scene = Scenario(
                name: "Isolated block", domainSize: size, boxes: [],
                charge: Charge(mass: mass / 4, position: .zero))
            scene.reflectiveFaces = [.zMin, .xMin, .yMin]
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(distance, 0, 0), max: SIMD3(distance + 20, 20, 15))]
                ),
                name: "block")
            chosen = [id]
            let z = Double(distance + 20) / cbrt(Double(mass))
            untilS =
                1.1 * (KingeryBulmash.point(at: z)?.arrival(mass: Double(mass)) ?? 1)
                + ThresholdRefinement.holdS(mass: Double(mass))
            corridors = scene.refinementCorridors(toward: chosen)
        } else {
            let inputs = try DistrictInputs.read(args)
            let (built, report) = try inputs.scene(
                radius: Float(value("radius").flatMap(Double.init) ?? 1000))
            print(report.summary)
            cellSize = inputs.cellSize
            let names = (value("names") ?? "").split(separator: ",").map(String.init)
            let ids = built.envelopeObjects.filter { object in names.contains { object.name.hasSuffix($0) } }
                .map(\.id)
            guard ids.count == names.count else {
                throw BlastError.allocationFailed("\(ids.count) of \(names.count) buildings found")
            }
            // As threshold refinement plans it: the same buildings, cut and timing.
            let plan = try ThresholdRefinement.plan(
                scene: built, cellSize: cellSize,
                doubts: Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }),
                maxBuildings: ids.count, maxCells: 200_000_000)
            chosen = plan.buildings
            untilS = plan.untilS
            if whole {
                scene = built
                corridors = built.refinementCorridors(toward: chosen)
            } else {
                scene = plan.scene
                corridors = plan.corridors
            }
        }
        let objects = Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, $0) })
        let charge = scene.charge.position
        // Gauges 2 m over the ground where each building's middle and its point nearest the charge
        // stand (in an empty scene, the incident wave there).
        var probes: [(name: String, at: SIMD3<Float>)] = []
        for id in chosen {
            guard let box = objects[id]?.bounds else { continue }
            let middle = 0.5 * (box.min + box.max)
            let nearest = simd_clamp(charge, box.min, box.max)
            for (name, p) in [("middle", middle), ("nearest", nearest)] {
                let ground = scene.terrain?.height(at: SIMD3(p.x, p.y, 0)) ?? 0
                probes.append(("\(objects[id]?.name ?? "?") \(name)", SIMD3(p.x, p.y, ground + 2)))
            }
        }
        if empty {
            for object in scene.envelopeObjects { try scene.removeObject(id: object.id) }
        }
        var configuration = SolverConfiguration.recommended
        if levels > 0 {
            configuration.refinement = 2
            configuration.refinementLevels = levels
            configuration.refinementConfinedTo = corridors
            configuration.refinementMemory = Int(
                (value("refine-memory").flatMap(Double.init) ?? 12) * Double(1 << 30))
        }
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: cellSize, configuration: configuration)
        solver.mappedStartLatest = untilS / 2
        let cells = probes.map { p -> (i: Int, j: Int, k: Int) in
            var k = Int(p.at.z / cellSize)
            let (i, j) = (Int(p.at.x / cellSize), Int(p.at.y / cellSize))
            while k < solver.grid.nz - 1, solver.isSolid(i, j, k) { k += 1 }
            return (i, j, k)
        }
        solver.setGauges(
            cells: Array(cells.prefix(BlastSolver.maxGauges)),
            points: probes.prefix(BlastSolver.maxGauges).map(\.at))
        if !empty {
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects.filter { chosen.contains($0.id) },
                options: EnvelopeHistoryOptions(
                    windowS: untilS, memoryBudget: 1 << 30,
                    windowFromArrival: true))
        }
        print(
            String(
                format: "%@: %d cells of %.1f m, refined %d levels, %d buildings, to %.3f s",
                scene.name, solver.grid.cellCount, cellSize, levels, chosen.count, untilS))
        let start = ContinuousClock.now
        var last = 0.0
        while solver.time < untilS * (1 - 1e-6) {
            let batch = solver.advance(steps: 64, timeLimit: untilS)
            guard batch.isStable, batch.steps > 0 else {
                print("Stopped at \(solver.time) s (stable \(batch.isStable))")
                break
            }
            let wall = DistrictBenchmark.seconds(start)
            if wall - last >= 60 {
                last = wall
                print(String(format: "  t %.3f s, %.0f s", solver.time, wall))
            }
        }
        let wall = DistrictBenchmark.seconds(start)
        print(String(format: "Ran to %.3f s in %.0f s", solver.time, wall))

        var components: [Component] = []
        for history in solver.envelopeComponentHistories() ?? [] where !history.invalid {
            let component = history.component
            guard [.facade, .wall].contains(component.kind) else { continue }
            let load = EnvelopeComponentLoad(history)
            let middle = 0.5 * (component.region.min + component.region.max)
            let damage = EnvelopeDamageAssessment.assess(
                load, construction: scene.envelopeConstruction(for: component.owner),
                buildingTop: Double(objects[component.owner]?.bounds?.max.z ?? 0),
                buildingBase: Double(objects[component.owner]?.bounds?.min.z ?? 0))
            components.append(
                Component(
                    id: component.id, building: objects[component.owner]?.name ?? "?",
                    kind: component.kind.rawValue, axis: component.axis, outward: component.outward,
                    distanceM: Double(simd_distance(SIMD2(middle.x, middle.y), SIMD2(charge.x, charge.y))),
                    peakStepPa: Double(history.peakOuterPa), peakBinPa: load.outerPa.max() ?? 0,
                    firstImpulsePaS: firstImpulse(load.outerPa, binS: load.binS),
                    peakNetPa: Double(history.peakNetPa),
                    rotationDeg: damage.map { [$0.rotationDeg.lowerBound, $0.rotationDeg.upperBound] } ?? [],
                    level: damage.map { "\($0.levels.upperBound)" } ?? "none"))
        }
        var readings: [Probe] = []
        for (n, samples) in solver.gaugeHistories.enumerated() where n < probes.count {
            guard let first = samples.first?.pressure else { continue }
            let over = samples.map { Double($0.pressure - first) }
            let at = samples.first { $0.pressure - first > 500 }?.time
            // The samples' own times: the most the trapezoid's running integral reaches.
            var impulse = 0.0
            var sum = 0.0
            for i in over.indices.dropLast() {
                sum += 0.5 * (over[i] + over[i + 1]) * Double(samples[i + 1].time - samples[i].time)
                impulse = max(impulse, sum)
            }
            let p = probes[n].at
            readings.append(
                Probe(
                    name: probes[n].name,
                    distanceM: Double(simd_distance(SIMD2(p.x, p.y), SIMD2(charge.x, charge.y))),
                    arrivalS: at.map { Double($0) }, peakPa: over.max() ?? 0, firstImpulsePaS: impulse))
        }
        let pools = solver.refinementPools.map { "\($0)" }
        let result = Run(
            label: value("label") ?? URL(filePath: out).deletingPathExtension().lastPathComponent,
            cellSize: cellSize, levels: levels, whole: whole, empty: empty, cells: solver.grid.cellCount,
            untilS: untilS, wallS: wall, refinedPools: pools, poolsGrewLate: solver.refinementPoolGrewLate,
            components: components, probes: readings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(result).write(to: URL(filePath: out))
        print("Pools: \(pools.joined(separator: "; ")); grew late: \(solver.refinementPoolGrewLate)")
        print("Wrote \(components.count) components and \(readings.count) gauges to \(out)")
    }
}
