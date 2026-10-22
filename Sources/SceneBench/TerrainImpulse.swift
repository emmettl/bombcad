import BlastCore
import BlastModel
import Foundation
import Metal
import simd

/// `scenebench terrain-impulse [--angle 3] [--mass 100] [--dx 0.25] [--levels 0|1|2]
/// [--staircase] [--until s] --out run.json`: the incident wave over a plane tilted along x, read
/// at standing heights up and down the slope and across it, on uniform cells (`--levels 0`) or
/// refined once or twice everywhere below the domain's top (emmettl/bombcad-work#78: refined air
/// over terrain read the positive-phase impulse 14–17% low on Beirut's ground). A mirror plane
/// through the charge along x halves the domain. `--angle 0` is flat ground on the same cells.
enum TerrainImpulse {
    struct Reading: Codable {
        var name: String
        var distanceM: Double
        var aboveM: Double
        var peakPa: Double
        /// The most the overpressure's running integral reaches, Pa s.
        var impulsePaS: Double
        var arrivalS: Double?
    }
    struct Run: Codable {
        var label: String
        var angle: Double
        var cellSize: Float
        var levels: Int
        var staircase: Bool
        var cells: Int
        var wallS: Double
        var readings: [Reading]
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let out = value("out"), let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("--out run.json and a Metal device")
        }
        let angle = Float(value("angle").flatMap(Double.init) ?? 3)
        let mass = Float(value("mass").flatMap(Double.init) ?? 100)
        let dx = Float(value("dx").flatMap(Double.init) ?? 0.25)
        let levels = value("levels").flatMap(Int.init) ?? 0
        let staircase = args.contains("--staircase")
        let scale = cbrt(mass)
        // Gauges out to Z = 7 each way; the open faces 4 m/kg^(1/3) beyond them.
        let reach = 7 * scale
        let clearance = 4 * scale
        let half = ((reach + clearance) / (8 * dx)).rounded(.up) * 8 * dx
        let rise = tan(angle * .pi / 180) * 2 * half
        let height = ((rise + 6 * scale) / (8 * dx)).rounded(.up) * 8 * dx
        let domain = SIMD3<Float>(2 * half, half, height)
        var scene = Scenario(
            name: "Tilted plane \(angle)°", domainSize: domain, boxes: [],
            charge: Charge(mass: mass / 2, position: SIMD3(half, 0, 0)))
        // The mirror plane y = 0 through the charge: the scene's charge is the half inside.
        scene.reflectiveFaces = [.zMin, .yMin]
        if angle > 0 {
            scene.replaceTerrain(with: .slope(domain: domain, spacing: dx, foot: 0, angle: angle))
        }
        let ground: (SIMD2<Float>) -> Float = { scene.terrain?.height(at: SIMD3($0, 0)) ?? 0 }
        let charge = scene.charge.position
        // Up the slope (+x), down it (−x) and across it (+y), at Z 3, 5 and 7, at heights of half a
        // base cell, 1 m/kg^(1/3)·0.25 and 0.5.
        var probes: [(name: String, at: SIMD3<Float>, above: Float)] = []
        for (direction, unit) in [
            ("up", SIMD2<Float>(1, 0)), ("down", SIMD2(-1, 0)), ("across", SIMD2(0, 1)),
        ] {
            for z in [3, 5, 7] as [Float] {
                let p = SIMD2(charge.x, charge.y) + unit * z * scale
                for above in [0.5 * dx, 0.25 * scale, 0.5 * scale] {
                    probes.append(
                        (
                            String(format: "%@ Z%.0f +%.2f", direction, z, above),
                            SIMD3(p.x, p.y, ground(p) + above), above
                        ))
                }
            }
        }
        var configuration = SolverConfiguration.recommended
        configuration.terrainCutCells = !staircase
        if levels > 0 {
            configuration.refinement = 2
            configuration.refinementLevels = levels
            configuration.refinementMemory = Int(
                (value("refine-memory").flatMap(Double.init) ?? 8) * Double(1 << 30))
        }
        let until =
            value("until").flatMap(Double.init)
            ?? 1.2 * (KingeryBulmash.point(at: 7.5)?.arrival(mass: Double(mass)) ?? 0.05) + 0.006
            * Double(scale)
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        solver.mappedStartLatest = until / 2
        let cells = probes.map { p -> (i: Int, j: Int, k: Int) in
            let (i, j) = (Int(p.at.x / dx), Int(p.at.y / dx))
            var k = Int(p.at.z / dx)
            while k < solver.grid.nz - 1, solver.isSolid(i, j, k) { k += 1 }
            return (i, j, k)
        }
        solver.setGauges(cells: cells, points: probes.map(\.at))
        print(
            String(
                format: "%@: %d cells of %.3f m, %d levels, %@, to %.4f s", scene.name, solver.grid.cellCount,
                dx,
                levels, staircase ? "staircase" : "cut cells", until))
        // A mapped start's clock begins at its one-dimensional solution's time; the balloon's at 0.
        print(
            String(format: "Starts at t = %.5f s (%@)", solver.time, solver.time > 0 ? "mapped" : "balloon"))
        let start = ContinuousClock.now
        while solver.time < until * (1 - 1e-6) {
            let batch = solver.advance(steps: 64, timeLimit: until)
            guard batch.isStable, batch.steps > 0 else {
                print("Stopped at \(solver.time) s")
                break
            }
        }
        let wall = DistrictBenchmark.seconds(start)
        var readings: [Reading] = []
        for (n, samples) in solver.gaugeHistories.enumerated() where n < probes.count {
            guard let first = samples.first?.pressure else { continue }
            let over = samples.map { Double($0.pressure - first) }
            var impulse = 0.0
            var sum = 0.0
            for i in over.indices.dropLast() {
                sum += 0.5 * (over[i] + over[i + 1]) * Double(samples[i + 1].time - samples[i].time)
                impulse = max(impulse, sum)
            }
            let p = probes[n].at
            readings.append(
                Reading(
                    name: probes[n].name,
                    distanceM: Double(simd_distance(SIMD2(p.x, p.y), SIMD2(charge.x, charge.y))),
                    aboveM: Double(probes[n].above), peakPa: over.max() ?? 0, impulsePaS: impulse,
                    arrivalS: samples.first { $0.pressure - first > 0.02 * Float(over.max() ?? 0) }.map {
                        Double($0.time)
                    }))
        }
        let run = Run(
            label: value("label") ?? URL(filePath: out).deletingPathExtension().lastPathComponent,
            angle: Double(angle), cellSize: dx, levels: levels, staircase: staircase,
            cells: solver.grid.cellCount,
            wallS: wall, readings: readings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(run).write(to: URL(filePath: out))
        print(String(format: "Ran to %.4f s in %.0f s; wrote %d gauges", solver.time, wall, readings.count))
    }
}
