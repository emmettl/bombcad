import BlastCore
import Foundation
import Metal
import simd

// The terrain's checks (docs/terrain.md):
//
//   blastbench terrain --study wedge [--mach 2] [--wedges 20,30,40,50,55,60] [--dx 0.01,0.005]
//                      [--surfaces terrain,tilted] [--run 1]
//   blastbench terrain --study shield [--mass 100] [--heights 2,4,8] [--dx 0.25] [--refine 2]
//   blastbench terrain --study hill [--dx 0.5,0.25,0.125]
//   blastbench terrain --dem file.asc|file.tif --origin x,y [--size 200,200] [--spacing 1]   (a DEM's crop)
//   [--out dir]   (CSV of every row; default /Volumes/StudioData/bombcad/terrain)

func runTerrain(device: MTLDevice) throws {
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/terrain")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    if let dem = option("dem") {
        try runTerrainDEM(dem)
        return
    }
    switch option("study") ?? "wedge" {
    case "wedge": try runWedgeStudy(device: device, out: out)
    case "shield": try runShieldStudy(device: device, out: out)
    case "hill": try runHillStudy(device: device, out: out)
    default: print("Unknown study; use wedge, shield or hill.")
    }
}

private func list(_ name: String, _ fallback: [Double]) -> [Double] {
    option(name).map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
}

private func runWedgeStudy(device: MTLDevice, out: URL) throws {
    let mach = option("mach").flatMap(Double.init) ?? 2
    let wedges = list("wedges", [20, 30, 40, 45, 48, 50, 52, 55, 60])
    let cells = list("dx", [0.01, 0.005]).map(Float.init)
    let surfaces = (option("surfaces") ?? "terrain,tilted").split(separator: ",").compactMap {
        WedgeReflectionStudy.Surface(rawValue: String($0))
    }
    let run = option("run").flatMap(Float.init) ?? 1
    let theory = ShockReflectionTheory.self
    print(
        String(
            format: "Ms %.2f: detachment %.2f°, sonic %.2f°", mach,
            theory.transitionWedge(shock: mach) * 180 / .pi,
            theory.transitionWedge(shock: mach, sonic: true) * 180 / .pi))
    var csv =
        "surface,dx,wedge,lead_m,run_m,chi_deg,theory_chi_deg,surface_p,regular_p,probe_offset_m,cells,steps,seconds\n"
    print("surface  dx      wedge  lead (cells)  χ      theory  p/p0   RR p/p0  cells     s")
    for surface in surfaces {
        for dx in cells {
            for wedge in wedges {
                var study = WedgeReflectionStudy(wedge: wedge, surface: surface, cellSize: dx)
                study.shockMach = mach
                study.distance = run
                configureRefinement(&study.configuration)
                let r = try study.run(device: device)
                let line = String(
                    format: "%-8@ %.4f  %5.1f  %6.1f       %5.2f  %6@  %5.2f  %7@  %8d  %.1f  %@",
                    surface.rawValue as NSString, dx, wedge, r.lead / Double(dx), r.chi,
                    (r.theoryChi.map { String(format: "%.2f", $0) } ?? "RR") as NSString, r.surfacePressure,
                    (r.regularPressure.map { String(format: "%.2f", $0) } ?? "-") as NSString, r.cells,
                    r.seconds,
                    (r.probeOffset.map { String(format: "probe %+.2f cells", $0 / Double(dx)) } ?? "")
                        as NSString)
                print(line)
                csv +=
                    "\(surface.rawValue),\(dx),\(wedge),\(r.lead),\(r.footRun),\(r.chi),\(r.theoryChi ?? .nan),"
                    + "\(r.surfacePressure),\(r.regularPressure ?? .nan),\(r.probeOffset ?? .nan),\(r.cells),\(r.steps),"
                    + "\(r.seconds)\n"
            }
        }
    }
    try csv.write(to: out.appending(path: "wedge-ms\(mach).csv"), atomically: true, encoding: .utf8)
}

/// One run of a surface burst over a terrain, read along the centreline: the surface's peak and
/// impulse in every column, and the arrival time at gauges on the surface.
private struct ProfileRun {
    var x: [Float] = []
    var surface: [Float] = []
    var peak: [Float] = []
    var impulse: [Float] = []
    var gauges: [Float] = []
    var arrivals: [Double] = []
    var gaugePeaks: [Float] = []
    /// Positive impulse from each gauge's history, Pa s.
    var gaugeImpulses: [Double] = []
    var cells = 0
    var steps = 0
    var seconds = 0.0
    var maskSeconds = 0.0
}

/// A surface burst of `mass` at x = 5 m on the centreline, the y = 0 face a mirror (so half the
/// charge is laid down), over `terrain` or flat ground, with `blocks`.
private func profileRun(
    device: MTLDevice, mass: Float, domain: SIMD3<Float>, terrain: Terrain?, blocks: [Box] = [], dx: Float,
    duration: Double, gauges: [Float]
) throws -> ProfileRun {
    var scenario = Scenario(
        name: "Shielding", domainSize: domain, boxes: blocks,
        charge: Charge(mass: mass / 2, position: SIMD3(5, 0, 0)))
    scenario.reflectiveFaces = [.zMin, .yMin]
    scenario.terrain = terrain
    scenario.gauges = gauges.map { x in
        let top = blocks.filter { $0.min.x <= x && x <= $0.max.x }.map(\.max.z).max() ?? 0
        return Gauge(
            "x \(x)", at: SIMD3(x, 0.5 * dx, max(terrain?.height(at: SIMD2(x, 0)) ?? 0, top) + 0.5 * dx))
    }
    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    let maskClock = Date()
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: dx, configuration: configuration)
    var run = ProfileRun()
    run.maskSeconds = Date().timeIntervalSince(maskClock)
    let clock = Date()
    run.steps = solver.advance(until: duration).steps
    run.seconds = Date().timeIntervalSince(clock)
    run.cells = solver.grid.cellCount
    let grid = solver.grid
    for i in 0..<grid.nx {
        var k = Int(solver.terrainSurface?[i] ?? 0)
        while k < grid.nz - 1, solver.isSolid(i, 0, k) { k += 1 }
        run.x.append((Float(i) + 0.5) * dx)
        run.surface.append(Float(k) * dx)
        run.peak.append(solver.peakOverpressure(i, 0, k))
        run.impulse.append(solver.impulse(i, 0, k))
    }
    let ambient = scenario.atmosphere.pressure
    run.gauges = gauges
    for history in solver.gaugeHistories {
        run.arrivals.append(history.first { $0.pressure - ambient > 2000 }?.time ?? .nan)
        run.gaugePeaks.append((history.map(\.pressure).max() ?? ambient) - ambient)
        run.gaugeImpulses.append(
            zip(history, history.dropFirst()).reduce(0.0) { total, pair in
                let a = max(Double(pair.0.pressure - ambient), 0)
                let b = max(Double(pair.1.pressure - ambient), 0)
                return total + 0.5 * (a + b) * (pair.1.time - pair.0.time)
            })
    }
    return run
}

/// The shortest path through the air from the charge (x = 5 m, on the ground) to the ground at
/// `x` along the centreline: a string pulled taut over the profile of the terrain and the blocks,
/// the upper convex hull of its points.
private func pathLength(to x: Float, terrain: Terrain?, blocks: [Box] = [], step: Float = 0.05) -> Float {
    func height(_ at: Float) -> Float {
        let top = blocks.filter { $0.min.x <= at && at <= $0.max.x }.map(\.max.z).max() ?? 0
        return max(terrain?.height(at: SIMD2(at, 0)) ?? 0, top)
    }
    var points: [SIMD2<Float>] = []
    var at: Float = 5
    while at < x {
        points.append(SIMD2(at, height(at)))
        at += step
    }
    points.append(SIMD2(x, height(x)))
    for block in blocks where block.min.x > 5 && block.max.x < x {
        points.append(SIMD2(block.min.x, block.max.z))
        points.append(SIMD2(block.max.x, block.max.z))
    }
    points.sort { $0.x < $1.x }
    var hull: [SIMD2<Float>] = []
    for p in points {
        while hull.count >= 2 {
            let a = hull[hull.count - 2]
            let b = hull[hull.count - 1]
            // Keep only right turns: drop b while it lies on or below the chord from a to p.
            if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0 { hull.removeLast() } else { break }
        }
        hull.append(p)
    }
    return zip(hull, hull.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
}

/// Linear interpolation of `values` at `x` over increasing `xs`, extrapolated beyond either end.
private func interpolate(_ xs: [Float], _ values: [Double], at x: Float) -> Double {
    guard xs.count >= 2 else { return values.first ?? .nan }
    let upper = min(max(xs.firstIndex(where: { $0 >= x }) ?? xs.count - 1, 1), xs.count - 1)
    let f = Double((x - xs[upper - 1]) / (xs[upper] - xs[upper - 1]))
    return values[upper - 1] + f * (values[upper] - values[upper - 1])
}

private func runShieldStudy(device: MTLDevice, out: URL) throws {
    let mass = option("mass").flatMap(Float.init) ?? 100
    let dx = option("dx").flatMap(Float.init) ?? 0.25
    let heights = list("heights", [2, 4, 8]).map(Float.init)
    let crest: Float = 25
    let domain = SIMD3<Float>(72, 24, 20)
    let duration = option("time").flatMap(Double.init) ?? 0.24
    let gauges: [Float] = [11, 15, 19, 22, 25, 28, 31, 34, 38, 42, 48, 54, 60, 66]
    print("\(mass) kg surface burst at x = 5 m; crest at x = \(crest) m; \(dx) m cells")
    let flat = try profileRun(
        device: device, mass: mass, domain: domain, terrain: nil, dx: dx, duration: duration, gauges: gauges)
    print(String(format: "flat: %d cells, %d steps, %.1f s", flat.cells, flat.steps, flat.seconds))
    var cases: [(name: String, terrain: Terrain?, blocks: [Box])] = []
    for h in heights {
        cases.append(
            (
                "ridge \(h) m",
                .ridge(domain: domain, spacing: dx, crest: crest, height: h, halfWidth: 2 * h), []
            ))
    }
    if let h = heights.first(where: { $0 == 4 }) ?? heights.first {
        cases.append(
            (
                "steep ridge \(h) m",
                .ridge(domain: domain, spacing: dx, crest: crest, height: h, halfWidth: h), []
            ))
        cases.append(
            ("wall \(h) m", nil, [Box(x: (crest - 0.25)...(crest + 0.25), y: 0...domain.y, height: h)]))
    }
    var profile = "case,x,surface_z,peak_pa,impulse_pa_s,flat_peak_pa,flat_impulse_pa_s\n"
    for n in flat.x.indices {
        profile +=
            "flat,\(flat.x[n]),0,\(flat.peak[n]),\(flat.impulse[n]),\(flat.peak[n]),\(flat.impulse[n])\n"
    }
    var arrivals = "case,x,path_m,arrival_s,flat_arrival_at_path_s,flat_arrival_at_x_s,peak_pa,flat_peak_pa\n"
    let flatPaths = gauges.map { pathLength(to: $0, terrain: nil) }
    for (name, terrain, blocks) in cases {
        let run = try profileRun(
            device: device, mass: mass, domain: domain, terrain: terrain, blocks: blocks, dx: dx,
            duration: duration,
            gauges: gauges)
        print(
            String(
                format: "\n%@: %d steps, %.1f s (flat %.1f s), mask %.2f s", name as NSString, run.steps,
                run.seconds,
                flat.seconds, run.maskSeconds))
        print("   x     z    peak/flat  impulse/flat  arrival  by path   flat at x")
        for n in run.x.indices {
            profile +=
                "\(name),\(run.x[n]),\(run.surface[n]),\(run.peak[n]),\(run.impulse[n]),\(flat.peak[n]),\(flat.impulse[n])\n"
        }
        for (g, x) in gauges.enumerated() {
            // Over the wall the path climbs its front, crosses its top and comes down its back.
            let path = pathLength(to: x, terrain: terrain, blocks: blocks)
            let byPath = interpolate(flatPaths, flat.arrivals, at: path)
            let column = min(Int(x / dx), run.x.count - 1)
            arrivals +=
                "\(name),\(x),\(path),\(run.arrivals[g]),\(byPath),\(flat.arrivals[g]),\(run.gaugePeaks[g]),\(flat.gaugePeaks[g])\n"
            print(
                String(
                    format: "%5.1f %5.2f   %5.2f      %5.2f        %6.2f   %6.2f   %6.2f ms", x,
                    run.surface[column],
                    run.gaugePeaks[g] / flat.gaugePeaks[g], run.impulse[column] / flat.impulse[column],
                    run.arrivals[g] * 1000, byPath * 1000, flat.arrivals[g] * 1000))
        }
    }
    let tag = "m\(Int(mass))-dx\(dx)" + (option("refine").map { "-r\($0)" } ?? "")
    try profile.write(to: out.appending(path: "shield-profile-\(tag).csv"), atomically: true, encoding: .utf8)
    try arrivals.write(to: out.appending(path: "shield-gauges-\(tag).csv"), atomically: true, encoding: .utf8)
}

private func runHillStudy(device: MTLDevice, out: URL) throws {
    let mass = option("mass").flatMap(Float.init) ?? 100
    let cells = list("dx", [0.5, 0.25, 0.125]).map(Float.init)
    let domain = SIMD3<Float>(72, 24, 20)
    let duration = option("time").flatMap(Double.init) ?? 0.24
    let gauges: [Float] = [11, 15, 19, 22, 25, 28, 31, 34, 38, 42, 48, 54, 60, 66]
    var csv =
        "dx,x,surface_z,peak_pa,impulse_pa_s,gauge_impulse_pa_s,arrival_s,flat_peak_pa,flat_impulse_pa_s,"
        + "flat_gauge_impulse_pa_s,flat_arrival_s,steps,seconds,flat_seconds,cells\n"
    print("\(mass) kg surface burst at x = 5 m; a hill 6 m high, 8 m radius, its top at x = 25 m")
    for dx in cells {
        let hill = Terrain.hill(
            domain: domain, spacing: min(dx, 0.25), centre: SIMD2(25, 0), height: 6, radius: 8)
        let flat = try profileRun(
            device: device, mass: mass, domain: domain, terrain: nil, dx: dx, duration: duration,
            gauges: gauges)
        let run = try profileRun(
            device: device, mass: mass, domain: domain, terrain: hill, dx: dx, duration: duration,
            gauges: gauges)
        print(
            String(
                format: "\n%.3f m cells: %d cells, %d steps, %.1f s (flat %.1f s)", dx, run.cells, run.steps,
                run.seconds,
                flat.seconds))
        print("   x    peak kPa (flat)   impulse Pa s (flat)   gauge impulse (flat)   arrival ms (flat)")
        for (g, x) in gauges.enumerated() {
            let column = min(Int(x / dx), run.x.count - 1)
            // The gauge's own peak (its cell's history), the surface's impulse from the column.
            print(
                String(
                    format: "%5.1f  %6.1f (%5.1f)    %6.1f (%5.1f)      %6.1f (%5.1f)        %6.2f (%6.2f)",
                    x,
                    run.gaugePeaks[g] / 1000, flat.gaugePeaks[g] / 1000, run.impulse[column],
                    flat.impulse[column],
                    run.gaugeImpulses[g], flat.gaugeImpulses[g], run.arrivals[g] * 1000,
                    flat.arrivals[g] * 1000))
            csv +=
                "\(dx),\(x),\(run.surface[column]),\(run.gaugePeaks[g]),\(run.impulse[column]),\(run.gaugeImpulses[g]),"
                + "\(run.arrivals[g]),\(flat.gaugePeaks[g]),\(flat.impulse[column]),\(flat.gaugeImpulses[g]),"
                + "\(flat.arrivals[g]),\(run.steps),\(run.seconds),"
                + "\(flat.seconds),\(run.cells)\n"
        }
    }
    let tag = "m\(Int(mass))" + (option("refine").map { "-r\($0)" } ?? "")
    try csv.write(to: out.appending(path: "hill-\(tag).csv"), atomically: true, encoding: .utf8)
}

private func runTerrainDEM(_ path: String) throws {
    let grid = try ElevationGrid(contentsOf: URL(filePath: path))
    let origin = list("origin", [grid.southWest.x, grid.southWest.y])
    let size = list("size", [200, 200]).map(Float.init)
    let spacing = option("spacing").flatMap(Float.init) ?? 1
    let (terrain, report) = try grid.terrain(
        origin: SIMD2(origin[0], origin[1]), size: SIMD2(size[0], size[1]), spacing: spacing,
        name: URL(filePath: path).lastPathComponent)
    print(
        "\(grid.columns) × \(grid.rows) cells of \(grid.step.x) \(grid.units.rawValue); crop "
            + "\(terrain.columns) × \(terrain.rows) nodes, \(report.lowest)–\(report.highest) m, "
            + "\(report.filled) filled; relief \(terrain.highest) m")
}

/// Lays `name`'s terrain under `scenario`: a hill, a ridge across x, a 20° slope or flat ground
/// a metre apart, centred on the domain's floor and half the domain's height at most; or a DEM's
/// crop from `--origin` (the DEM's south-west corner by default) at `--spacing` (1 m). The charge
/// (moved to `--charge-at x,y` if given) and the gauges are lifted onto it.
func applyTerrain(_ name: String, to scenario: inout Scenario) {
    let domain = scenario.domainSize
    let centre = SIMD2(domain.x, domain.y) / 2
    let spacing = option("spacing").flatMap(Float.init) ?? 1
    let height = 0.4 * domain.z
    var terrain: Terrain
    switch name {
    case "hill":
        terrain = .hill(
            domain: domain, spacing: spacing, centre: centre, height: height, radius: 0.15 * domain.x)
    case "ridge":
        terrain = .ridge(
            domain: domain, spacing: spacing, crest: centre.x, height: height, halfWidth: 2 * height)
    case "slope": terrain = .slope(domain: domain, spacing: spacing, foot: 0.3 * domain.x, angle: 20)
    case "flat": terrain = .flat(domain: domain, spacing: spacing)
    default:
        do {
            let grid = try ElevationGrid(contentsOf: URL(filePath: name))
            let origin = list("origin", [grid.southWest.x, grid.southWest.y])
            terrain = try grid.terrain(
                origin: SIMD2(origin[0], origin[1]), size: SIMD2(domain.x, domain.y), spacing: spacing,
                name: URL(filePath: name).lastPathComponent
            ).terrain
        } catch {
            print("Could not read the terrain \(name): \(error)")
            exit(1)
        }
    }
    if terrain.highest >= domain.z {
        terrain.heights = terrain.heights.map { $0 * 0.5 * domain.z / terrain.highest }
        print("Scaled the terrain to half the domain's height.")
    }
    if let at = option("charge-at").map({ $0.split(separator: ",").compactMap { Float($0) } }), at.count == 2
    {
        scenario.charge.position.x = at[0]
        scenario.charge.position.y = at[1]
    }
    scenario.replaceTerrain(with: terrain)
}
