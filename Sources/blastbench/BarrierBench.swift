import BlastCore
import Foundation
import Metal
import simd

// A blast wall's shelter, against Xiao et al.'s field test (emmettl/bombcad-work#4,
// docs/protective-design.md):
//
//   blastbench barrier [--dx 0.04,0.025] [--mass 1.5] [--hob 1.2] [--front 1.44] [--wall 2.1,5,1]
//                      [--behind 1,2,3,4,5,6,7,8] [--time 0.03] [--estimate] [--out dir]
//
// D. Xiao et al., "Effects of an Explosion-Proof Wall on Shock Wave Parameters and Safe Area
// Prediction", Sustainability 15, 11164 (2023, CC BY): 1.5 kg of TNT 1.2 m above the ground, its
// test 1-1 1.44 m in front of a wall of five sand-filled units, 2.1 m tall, 5 m wide and 1 m thick;
// gauges on the ground and 1.2 m up, 1 to 8 m behind the wall's back face, on the line through the
// charge and the wall's middle, and two in the open at the ranges of those 3 and 7 m behind.
//
// Here the wall is rigid and the ground too; the line through the charge and the wall's middle is
// the mirrored y = 0 face, so the domain holds half of it. Each gauge behind the wall is set against
// a gauge at the same point on the same grid with the wall taken away. Peaks, the first positive
// phase's impulse and the most the impulse reaches over the run (the second peak round the wall's
// ends adds to it after the first phase ends). CSV in `--out` (default
// /Volumes/StudioData/bombcad/protective/xiao).

func runBarrier(device: MTLDevice) throws {
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/protective/xiao")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    func list(_ name: String, _ fallback: [Float]) -> [Float] {
        option(name).map { $0.split(separator: ",").compactMap { Float($0) } } ?? fallback
    }
    let mass = option("mass").flatMap(Double.init) ?? 1.5
    let hob = option("hob").flatMap(Float.init) ?? 1.2
    let front = option("front").flatMap(Float.init) ?? 1.44
    let wall = list("wall", [2.1, 5, 1])
    let behind = list("behind", [1, 2, 3, 4, 5, 6, 7, 8])
    let cells = list("dx", [0.04])
    let duration = option("time").flatMap(Double.init) ?? 0.03
    // The charge with 3 m of room behind it; the far side 3 m past the last gauge.
    let chargeX: Float = 3
    let back = chargeX + front + wall[2]
    let domain = SIMD3<Float>(back + (behind.max() ?? 8) + 3, max(wall[1] / 2 + 3, 5), max(wall[0] + 3, 5))
    var configuration = SolverConfiguration.recommended
    applyChosenAir(&configuration)
    configureRefinement(&configuration)
    print(
        String(
            format:
                "%.2f kg of TNT %.2f m up, %.2f m before a wall %.2f m tall, %.1f m wide, %.1f m thick; half of it "
                + "in a %.1f by %.1f by %.1f m box; to %.3f s",
            mass, hob, front, wall[0], wall[1], wall[2], domain.x, domain.y, domain.z, duration))
    let wallBox = Box(
        min: SIMD3(chargeX + front, 0, 0), max: SIMD3(back, wall[1] / 2, wall[0]))
    struct Point {
        var name: String
        var behind: Float
        var height: Float
    }
    func scenario(walled: Bool, dx: Float) -> (Scenario, [Point]) {
        var points: [Point] = []
        for d in behind {
            points.append(Point(name: "ground \(format(Double(d), 0)) m", behind: d, height: 0.5 * dx))
            points.append(Point(name: "1.2 m up \(format(Double(d), 0)) m", behind: d, height: hob))
        }
        var scene = Scenario(
            name: "Xiao et al.'s blast wall", domainSize: domain, boxes: walled ? [wallBox] : [],
            charge: Charge(mass: Float(mass / 2), position: SIMD3(chargeX, 0, hob)))
        scene.reflectiveFaces = [.zMin, .yMin]
        scene.gauges = points.map { Gauge($0.name, at: SIMD3(back + $0.behind, 0.5 * dx, $0.height)) }
        return (scene, points)
    }
    struct Recorded {
        var peak: Double
        var impulse: Double
        var most: Double
        var arrival: Double
    }
    func run(_ scene: Scenario, dx: Float, label: String) throws -> [Recorded] {
        let estimate = RunCost.estimate(scene, cellSize: dx, configuration: configuration, duration: duration)
        print(
            String(
                format:
                    "  %@ on %g m cells: advisor %.1fM cells, %d steps, %.2f GB, %.0f s on a quiet Studio",
                label as NSString, dx, Double(estimate.cells) / 1e6, estimate.steps,
                Double(estimate.memory) / 1e9, estimate.seconds))
        if flag("estimate") { return [] }
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        let started = Date()
        while solver.time < duration - 1e-9 {
            let result = solver.advance(steps: 64, timeLimit: duration)
            if result.steps == 0 || !result.isStable {
                print("  stopped at \(solver.time) s: \(result.isStable ? "no progress" : "unstable")")
                break
            }
        }
        print(String(format: "    %d steps in %.0f s", solver.stepCount, Date().timeIntervalSince(started)))
        let ambient = scene.atmosphere.pressure
        if flag("histories") {
            var text = "gauge,time_s,overpressure_pa\n"
            for (gauge, history) in zip(scene.gauges, solver.gaugeHistories) {
                for sample in history {
                    text += "\(gauge.name),\(sample.time),\(sample.pressure - ambient)\n"
                }
            }
            try text.write(
                to: out.appending(path: "histories-dx\(format(Double(dx), 3))-\(label).csv"),
                atomically: true,
                encoding: .utf8)
        }
        return solver.gaugeHistories.map { history in
            var most = 0.0
            var total = 0.0
            for n in 0..<max(history.count - 1, 0) {
                let a = Double(history[n].pressure - ambient)
                let b = Double(history[n + 1].pressure - ambient)
                total += 0.5 * (a + b) * (history[n + 1].time - history[n].time)
                most = max(most, total)
            }
            return Recorded(
                peak: Double((history.map(\.pressure).max() ?? ambient) - ambient),
                impulse: positivePhaseImpulse(history, ambient: ambient), most: most,
                arrival: arrivalTime(history, ambient: ambient))
        }
    }
    var csv =
        "dx_m,gauge,behind_m,height_m,range_m,peak_pa,open_peak_pa,impulse_pa_s,open_impulse_pa_s,"
        + "most_impulse_pa_s,open_most_impulse_pa_s,arrival_s,open_arrival_s\n"
    for dx in cells {
        print(String(format: "\n%.3f m cells", dx))
        let (open, points) = scenario(walled: false, dx: dx)
        let (walled, _) = scenario(walled: true, dx: dx)
        let o = try run(open, dx: dx, label: "open")
        let w = try run(walled, dx: dx, label: "walled")
        if w.isEmpty { continue }
        print(
            "    gauge                peak kPa (open)   ratio   impulse Pa s (open)  ratio   most (open)   ratio"
        )
        for (n, p) in points.enumerated() {
            let range = Double(simd_length(SIMD2(back + p.behind - chargeX, p.height - hob)))
            print(
                pad(p.name, 21) + pad("\(format(w[n].peak / 1000, 2)) (\(format(o[n].peak / 1000, 2)))", 18)
                    + pad(format(w[n].peak / o[n].peak, 2), 8)
                    + pad("\(format(w[n].impulse, 1)) (\(format(o[n].impulse, 1)))", 21)
                    + pad(format(w[n].impulse / o[n].impulse, 2), 8)
                    + pad("\(format(w[n].most, 1)) (\(format(o[n].most, 1)))", 14)
                    + format(w[n].most / o[n].most, 2))
            csv +=
                "\(dx),\(p.name),\(p.behind),\(p.height),\(range),\(w[n].peak),\(o[n].peak),\(w[n].impulse),"
                + "\(o[n].impulse),\(w[n].most),\(o[n].most),\(w[n].arrival),\(o[n].arrival)\n"
        }
    }
    if flag("estimate") { return }
    let tag = "dx" + cells.map { format(Double($0), 3) }.joined(separator: "_")
    try csv.write(to: out.appending(path: "barrier-\(tag).csv"), atomically: true, encoding: .utf8)
    print("\nWrote \(out.appending(path: "barrier-\(tag).csv").path)")
}
