import BlastCore
import BlastModel
import Foundation
import Metal
import simd

/// `scenebench clarke-airblast --series A|B [--dx 0.0025] [--until 0.001] --out run.json`: Clarke
/// et al.'s free-air and surface shots (Proc. R. Soc. A 476, 2020; emmettl/bombcad-work#23's first
/// rung): 78 g of PE4 (93.6 g of TNT at their 1.2) below a rigid plate, its load read at 0, 25,
/// 50, 75 and 100 mm from the plate's centre and integrated to 100 mm, as their Hopkinson bars.
/// A quarter of the rig, on mirror planes through the charge's axis.
///
/// - **A**: the charge in free air inside the empty steel pot (500 mm across inside, 30 mm walls and
///   floor, 375 mm high), its top 28 mm below the rim; the plate 140 mm above the rim.
/// - **B**: the charge on sand filling the pot to the rim, taken as rigid ground (the domain's
///   floor at the rim, a surface burst); the plate 190 mm above it.
///
/// The charge is BombCAD's sphere (hemisphere on the ground), not their 3:1 disc.
enum ClarkeAirblast {
    struct Reading: Codable {
        var radiusM: Double
        var peakPa: Double
        /// The most the overpressure's running integral reaches, Pa s.
        var impulsePaS: Double
        var arrivalS: Double?
    }
    struct Run: Codable {
        var series: String
        var cellSize: Float
        var cells: Int
        var wallS: Double
        var readings: [Reading]
        /// ∫ 2πr i dr to 100 mm by the trapezoid over the five radii, as the paper's, N s.
        var totalNs: Double
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let out = value("out"), let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("--out run.json and a Metal device")
        }
        let series = value("series") ?? "A"
        let dx = Float(value("dx").flatMap(Double.init) ?? 0.0025)
        let tnt: Float = 0.078 * 1.2
        let side: Float = 0.4
        let inner: Float = 0.25
        let outer: Float = 0.28
        var scene: Scenario
        if series == "B" {
            // The sand's surface as the ground: a surface burst, mirrored three ways (an eighth of
            // the charge's free-air mass, the quarter of the hemisphere inside).
            let plate: Float = 0.19
            scene = Scenario(
                name: "Clarke B", domainSize: SIMD3(side, side, plate), boxes: [],
                charge: Charge(mass: tnt / 4, position: .zero))
        } else {
            let rim: Float = 0.375
            let plate = rim + 0.14
            var boxes: [Box] = []
            // The pot's wall, strip by strip across y, and its floor.
            var y: Float = 0
            while y < outer {
                let y1 = min(y + dx, outer)
                let mid = 0.5 * (y + y1)
                let xOut = (outer * outer - mid * mid).squareRoot()
                let xIn = mid < inner ? (inner * inner - mid * mid).squareRoot() : 0
                if xOut > xIn { boxes.append(Box(min: SIMD3(xIn, y, 0), max: SIMD3(xOut, y1, rim))) }
                y = y1
            }
            boxes.append(Box(min: .zero, max: SIMD3(inner, inner, 0.03)))
            // Its top 28 mm below the rim; a 3:1 disc 19 mm high, its centre 9.5 mm below that.
            let centre = rim - 0.028 - 0.0095
            scene = Scenario(
                name: "Clarke A", domainSize: SIMD3(side, side, plate), boxes: boxes,
                charge: Charge(mass: tnt / 4, position: SIMD3(0, 0, centre)))
        }
        // The plate is the domain's top; the axis's two mirror planes; open beyond the rig.
        scene.reflectiveFaces = [.zMin, .zMax, .xMin, .yMin]
        scene.gauges = []
        let top = scene.domainSize.z
        let radii: [Float] = [0, 0.025, 0.05, 0.075, 0.1]
        let configuration = SolverConfiguration.recommended
        let until = value("until").flatMap(Double.init) ?? 0.001
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        solver.mappedStartLatest = until / 4
        let points = radii.map { SIMD3(max($0, 0.5 * dx), 0.5 * dx, top - 0.5 * dx) }
        solver.setGauges(
            cells: points.map { (Int($0.x / dx), Int($0.y / dx), Int($0.z / dx)) }, points: points)
        print(
            String(
                format: "Clarke %@: %d cells of %.2f mm, plate %.0f mm up, starts at t = %.6f s (%@)", series,
                solver.grid.cellCount, dx * 1000, top * 1000, solver.time,
                solver.time > 0 ? "mapped" : "balloon"))
        let start = ContinuousClock.now
        while solver.time < until * (1 - 1e-6) {
            let batch = solver.advance(steps: 64, timeLimit: until)
            guard batch.isStable, batch.steps > 0 else {
                print("Stopped at \(solver.time) s (stable \(batch.isStable))")
                break
            }
        }
        let wall = DistrictBenchmark.seconds(start)
        var readings: [Reading] = []
        for (n, samples) in solver.gaugeHistories.enumerated() where n < radii.count {
            let ambient = Double(scene.atmosphere.pressure)
            let over = samples.map { Double($0.pressure) - ambient }
            var impulse = 0.0
            var sum = 0.0
            for i in over.indices.dropLast() {
                sum += 0.5 * (over[i] + over[i + 1]) * Double(samples[i + 1].time - samples[i].time)
                impulse = max(impulse, sum)
            }
            let peak = over.max() ?? 0
            readings.append(
                Reading(
                    radiusM: Double(radii[n]), peakPa: peak, impulsePaS: impulse,
                    arrivalS: samples.first { Double($0.pressure) - ambient > 0.02 * peak }.map {
                        Double($0.time)
                    }))
        }
        var total = 0.0
        for (a, b) in zip(readings, readings.dropFirst()) {
            total += 0.5 * (a.radiusM * a.impulsePaS + b.radiusM * b.impulsePaS) * (b.radiusM - a.radiusM)
        }
        total *= 2 * .pi
        let run = Run(
            series: series, cellSize: dx, cells: solver.grid.cellCount, wallS: wall, readings: readings,
            totalNs: total)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(run).write(to: URL(filePath: out))
        print(
            "Ran to \(String(format: "%.5f", solver.time)) s in \(String(format: "%.0f", wall)) s; "
                + readings.map {
                    String(
                        format: "%.0f mm %.2f MPa ms %.0f MPa", $0.radiusM * 1000, $0.impulsePaS / 1000,
                        $0.peakPa / 1e6)
                }
                .joined(separator: ", ") + String(format: "; total to 100 mm %.1f N s", total))
    }
}
