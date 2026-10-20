import BlastCore
import Foundation
import Metal
import simd

// Channelling at far-field distances (emmettl/bombcad-work#13, docs/hybrid-far-field.md):
//
//   blastbench canyon [--mass 1000] [--widths 10,20] [--dx 4,1] [--height 15] [--depth 20]
//                     [--street 60,260] [--z 8,10,12,14,16,20,24] [--offset 0] [--estimate] [--out dir]
//
// A TNT surface burst on rigid ground, and a straight radial street running away from it between
// two continuous walls of buildings (`--height` m tall, `--depth` m deep) from 60 to 260 m out. The
// street's centreline is the mirrored y = 0 face and the charge sits where it meets the mirrored
// x = 0 face, so the domain holds a quarter of the burst and one side of the street. Gauges in the
// air cell beside the wall (1.5 m up and at half the walls' height) and on the centreline, at the
// scaled distances `--z`, are set against gauges at the same points over open ground, run on the
// same grid without the buildings. `--estimate` prints the advisor's cost of each run and stops.
// CSV of every gauge in `--out` (default /Volumes/StudioData/bombcad/canyon).
//
// `--offset y` (emmettl/bombcad-work#4): a street that does not point at the charge. Its centreline
// runs along x at `y` m from the charge, between two walls laid out in full, and the domain holds
// half of the burst (only the x = 0 face mirrored, the charge `room` m in from the y = 0 face, so
// that no mirrored row of buildings stands on the charge's other side). At a gauge x m out the
// street lies atan(y / x) off the radial direction. Gauges stand where the range is `--z` W^(1/3): beside the far wall (its face turned
// toward the charge's side), beside the near wall (turned away), each 1.5 m up and at half height,
// and on the centreline.

private struct CanyonGauge {
    var width: Float
    var place: String
    var z: Double
    var position: SIMD3<Float>
}

func runCanyon(device: MTLDevice) throws {
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/canyon")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    func list(_ name: String, _ fallback: [Float]) -> [Float] {
        option(name).map { $0.split(separator: ",").compactMap { Float($0) } } ?? fallback
    }
    let mass = option("mass").flatMap(Double.init) ?? 1000
    let scale = cbrt(mass)
    let widths = list("widths", [10, 20])
    let cells = list("dx", [4, 1])
    let height = option("height").flatMap(Float.init) ?? 15
    let depth = option("depth").flatMap(Float.init) ?? 20
    let street = list("street", [60, 260])
    let offset = option("offset").flatMap(Float.init) ?? 0
    let zs = list("z", [8, 10, 12, 14, 16, 20, 24]).map(Double.init)
    let zMax = zs.max() ?? 24
    let last = KingeryBulmash.point(at: zMax)!
    let duration =
        option("time").flatMap(Double.init)
        ?? (last.scaledArrival + 1.5 * (KingeryBulmash.scaledDuration(at: zMax) ?? 0.01)) * scale
    // Open faces at least 1.5 sqrt(R W^(1/3)) from the gauges, as `blastbench landscape` keeps its top.
    let room = Float(1.5 * (zMax * scale * scale).squareRoot())
    // A street off the charge: the charge this far in from the domain's y = 0 face.
    let shift: Float = offset > 0 ? room : 0
    let domain = SIMD3<Float>(
        street[1] + 30, shift + offset + max(depth + (widths.max() ?? 20) / 2, 0) + room, room)
    let chargeAt = SIMD3<Float>(0, shift, 0)
    var configuration = SolverConfiguration.recommended
    applyChosenAir(&configuration)
    configureRefinement(&configuration)
    print(
        String(
            format:
                "%.0f kg of TNT on rigid ground, a quarter of it in a %.0f by %.0f by %.0f m corner; a street "
                + "%.0f m off the charge, from %.0f to %.0f m, between walls %.0f m tall, %.0f m deep; gauges at Z %@, "
                + "to %.2f s",
            mass, domain.x, domain.y, domain.z, offset, street[0], street[1], height, depth,
            zs.map { format($0, 0) }.joined(separator: ", ") as NSString, duration))

    func scenario(blocks: [Box], gauges: [CanyonGauge]) -> Scenario {
        var scenario = Scenario(
            name: "Street canyon at distance", domainSize: domain, boxes: blocks,
            charge: Charge(mass: Float(offset > 0 ? mass / 2 : mass / 4), position: chargeAt))
        scenario.reflectiveFaces = offset > 0 ? [.zMin, .xMin] : [.zMin, .xMin, .yMin]
        scenario.gauges = gauges.map {
            Gauge("w\(String(format: "%g", $0.width)) \($0.place) Z \(format($0.z, 0))", at: $0.position)
        }
        return scenario
    }
    func walls(_ width: Float) -> [Box] {
        guard offset > 0 else {
            return [Box(x: street[0]...street[1], y: (width / 2)...(width / 2 + depth), height: height)]
        }
        let y = shift + offset
        return [
            Box(x: street[0]...street[1], y: (y - width / 2 - depth)...(y - width / 2), height: height),
            Box(x: street[0]...street[1], y: (y + width / 2)...(y + width / 2 + depth), height: height),
        ]
    }
    struct Recorded {
        var peak: Double
        var impulse: Double
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
        print(
            String(
                format: "    %d steps in %.0f s", solver.stepCount, Date().timeIntervalSince(started)))
        let ambient = scene.atmosphere.pressure
        // `--histories`: every gauge's overpressure over time, a CSV a run.
        if flag("histories") {
            var text = "gauge,time_s,overpressure_pa\n"
            for (gauge, history) in zip(scene.gauges, solver.gaugeHistories) {
                for sample in history {
                    text += "\(gauge.name),\(sample.time),\(sample.pressure - ambient)\n"
                }
            }
            let name =
                "histories-dx\(format(Double(dx), 2))-\(label.replacingOccurrences(of: " ", with: "-")).csv"
            try text.write(to: out.appending(path: name), atomically: true, encoding: .utf8)
        }
        return solver.gaugeHistories.map { history in
            Recorded(
                peak: Double((history.map(\.pressure).max() ?? ambient) - ambient),
                impulse: positivePhaseImpulse(history, ambient: ambient),
                arrival: arrivalTime(history, ambient: ambient))
        }
    }

    var csv =
        "dx_m,width_m,effective_width_m,place,z,x_m,y_m,z_m,range_m,peak_pa,open_peak_pa,impulse_pa_s,"
        + "open_impulse_pa_s,arrival_s,open_arrival_s,kb_peak_pa,kb_impulse_pa_s,offset_m,angle_deg\n"
    for dx in cells {
        print(String(format: "\n%.2f m cells (%.3f m/kg^(1/3))", dx, Double(dx) / scale))
        // The street as the mask lays it: the first solid cell out from the centreline, 1.5 m up,
        // midway along. Gauges go in the air cell before it.
        var gauges: [CanyonGauge] = []
        var effective: [Float: Float] = [:]
        for width in widths {
            let probe = try BlastSolver(
                device: device, scenario: scenario(blocks: walls(width), gauges: []), cellSize: dx,
                configuration: configuration)
            let grid = probe.grid
            let i = min(grid.nx - 1, Int((street[0] + street[1]) / 2 / dx))
            let k = min(grid.nz - 1, Int(1.5 / dx))
            if offset > 0 {
                // From the centreline out to each wall's first solid cell; gauges in the air cell before.
                let centre = min(grid.ny - 1, Int((shift + offset) / dx))
                var far = centre
                while far < grid.ny - 1, !probe.isSolid(i, far, k) { far += 1 }
                var near = centre
                while near > 0, !probe.isSolid(i, near, k) { near -= 1 }
                effective[width] = Float(far - near - 1) * dx
                let farY = (Float(far) - 0.5) * dx
                let nearY = (Float(near) + 1.5) * dx
                print(
                    String(
                        format: "  %g m street %.0f m off: %.0f m wide as laid", width, offset,
                        Float(far - near - 1) * dx))
                for z in zs {
                    let range = Float(z * scale)
                    guard range > offset else { continue }
                    let x = (range * range - offset * offset).squareRoot()
                    guard x > street[0], x < street[1] else { continue }
                    for (place, y) in [("far", farY), ("near", nearY)] {
                        gauges.append(
                            CanyonGauge(width: width, place: "\(place) low", z: z, position: SIMD3(x, y, 1.5))
                        )
                        gauges.append(
                            CanyonGauge(
                                width: width, place: "\(place) mid", z: z, position: SIMD3(x, y, height / 2)))
                    }
                    gauges.append(
                        CanyonGauge(
                            width: width, place: "centre", z: z, position: SIMD3(x, shift + offset, 1.5)))
                }
                continue
            }
            var j = 0
            while j < grid.ny - 1, !probe.isSolid(i, j, k) { j += 1 }
            effective[width] = 2 * Float(j) * dx
            let wallY = (Float(j) - 0.5) * dx
            print(
                String(
                    format: "  %g m street: %.0f m wide as laid, gauges %.2f m off its walls", width,
                    2 * Float(j) * dx, Float(j) * dx - wallY))
            for z in zs {
                let x = Float(z * scale)
                guard x > street[0], x < street[1] else { continue }
                gauges.append(
                    CanyonGauge(width: width, place: "wall low", z: z, position: SIMD3(x, wallY, 1.5)))
                gauges.append(
                    CanyonGauge(width: width, place: "wall mid", z: z, position: SIMD3(x, wallY, height / 2)))
                gauges.append(
                    CanyonGauge(width: width, place: "centre", z: z, position: SIMD3(x, 0.5 * dx, 1.5)))
            }
        }
        let open = try run(scenario(blocks: [], gauges: gauges), dx: dx, label: "open ground")
        for width in widths {
            let mine = gauges.indices.filter { gauges[$0].width == width }
            let canyon = try run(
                scenario(blocks: walls(width), gauges: mine.map { gauges[$0] }), dx: dx,
                label: "\(String(format: "%g", width)) m street")
            if canyon.isEmpty { continue }
            print("    gauge                 range m   peak kPa (open)    ratio   impulse Pa s (open)  ratio")
            for (n, g) in mine.enumerated() {
                let c = canyon[n]
                let o = open[g]
                let gauge = gauges[g]
                let range = Double(simd_length(gauge.position - chargeAt))
                let kb = KingeryBulmash.point(at: range / scale)
                print(
                    pad("\(gauge.place) Z \(format(gauge.z, 0))", 22) + pad(format(range, 0), 10)
                        + pad("\(format(c.peak / 1000, 2)) (\(format(o.peak / 1000, 2)))", 19)
                        + pad(format(c.peak / o.peak, 2), 8)
                        + pad("\(format(c.impulse, 1)) (\(format(o.impulse, 1)))", 21)
                        + format(c.impulse / o.impulse, 2))
                csv +=
                    "\(dx),\(width),\(effective[width] ?? .nan),\(gauge.place),\(gauge.z),\(gauge.position.x),"
                    + "\(gauge.position.y),\(gauge.position.z),\(range),\(c.peak),\(o.peak),\(c.impulse),"
                    + "\(o.impulse),\(c.arrival),\(o.arrival),\(kb?.incidentPressure ?? .nan),"
                    + "\(kb?.incidentImpulse(mass: mass) ?? .nan),\(offset),"
                    + "\(atan2(offset, gauge.position.x) * 180 / .pi)\n"
            }
        }
    }
    if flag("estimate") { return }
    let tag =
        "m\(Int(mass))-dx" + cells.map { format(Double($0), 2) }.joined(separator: "_")
        + (offset > 0 ? "-off\(Int(offset))" : "")
    try csv.write(to: out.appending(path: "canyon-\(tag).csv"), atomically: true, encoding: .utf8)
    print("\nWrote \(out.appending(path: "canyon-\(tag).csv").path)")
}
