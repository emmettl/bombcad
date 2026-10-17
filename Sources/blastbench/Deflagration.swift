import BlastCore
import Foundation
import Metal
import simd

/// `blastbench deflagration`: the gas deflagration's checks (see docs/deflagration.md).
func runDeflagration() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw BlastError.allocationFailed("Metal device")
    }
    let mode = arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "vessel"
    let gas = option("gas").flatMap(FlammableGas.init(rawValue:)) ?? .methane
    let concentration = option("percent").flatMap { Float($0) }.map { $0 / 100 }
    switch mode {
    case "vessel": try runClosedVessel(device: device, gas: gas, concentration: concentration)
    case "vented": try runVented(device: device, gas: gas, concentration: concentration)
    case "layout":
        let data = try JSONEncoder().encode(ScenarioPreset.ventedGasRoom.scenario)
        try data.write(to: URL(fileURLWithPath: option("out") ?? "gas-room.json"))
    case "tube", "ball": try runTube(device: device, gas: gas, ball: mode == "ball")
    case "slope": try runSlope(device: device, gas: gas)
    default:
        print("Unknown deflagration check \(mode). Use vessel, vented, tube, ball, slope or layout.")
        exit(2)
    }
}

private func runClosedVessel(device: MTLDevice, gas: FlammableGas, concentration: Float?) throws {
    let radii = option("radius").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.5]
    let cells = option("cells").map { $0.split(separator: ",").compactMap { Int($0) } } ?? [20]
    let air = chosenAirModel() ?? .idealGas
    print(
        "\(gas.displayName)–air in a closed sphere, ignited at the centre, "
            + (flag("accelerated") ? "the default flame (sub-grid turbulence)" : "laminar flame")
            + ", \(air) air:"
            + " against the thin-flame model with the same burning velocity and the model's AICC pressure")
    print(
        pad("R m", 6) + pad("cells/R", 9) + pad("S_u m/s", 9) + pad("AICC bar", 10) + pad("p_max bar", 11)
            + pad("ref", 7) + pad("t50% ms", 9) + pad("ref", 6) + pad("t90% ms", 9) + pad("ref", 6)
            + pad("K_G bar m/s", 13) + pad("ref", 7)
            + pad("burnt", 7) + pad("energy", 9) + "run s")
    for radius in radii {
        for count in cells {
            var study = ClosedVesselStudy(
                gas: gas, concentration: concentration, radius: radius, cellsPerRadius: count, airModel: air,
                acceleration: flag("accelerated") ? FlameAcceleration() : .laminar)
            if let scale = option("turbulence").flatMap({ Float($0) }) {
                study.acceleration.turbulence = scale > 0 ? FlameTurbulence(scale: scale) : nil
            }
            if flag("mixing") {
                study.mixing = option("mixing-model") == "smagorinsky" ? SubgridMixing() : .sigma
            }
            let clock = Date()
            let r = try study.run(
                device: device,
                report: flag("trace")
                    ? { time, state, pressure in
                        let radius = cbrt(3 * state.burntVolume / (4 * Double.pi))
                        print(
                            "  t \(format(time * 1000, 0)) ms: flame radius \(format(radius, 3)) m, burnt "
                                + "\(format(state.burntFraction * 100, 1))%, \(format(Double(pressure) / 1e5, 3)) bar"
                        )
                    } : nil,
                monitor: flag("area") ? { solver in vesselArea(solver, radius: radius) } : nil)
            print(
                pad(format(Double(radius), 2), 6) + pad("\(count)", 9) + pad(format(r.burningVelocity, 3), 9)
                    + pad(format(r.modelAICC / 1e5, 2), 10) + pad(format(r.peakPressure / 1e5, 2), 11)
                    + pad(format(r.modelAICC / 1e5, 2), 7) + pad(format(r.halfRise * 1000, 0), 9)
                    + pad(format(r.referenceHalfRise * 1000, 0), 6) + pad(format(r.mostRise * 1000, 0), 9)
                    + pad(format(r.referenceMostRise * 1000, 0), 6) + pad(format(r.deflagrationIndex, 1), 13)
                    + pad(format(r.referenceIndex, 1), 7) + pad(format(r.burntFraction * 100, 1) + "%", 7)
                    + pad(format(r.energyError * 100, 2) + "%", 9)
                    + format(Date().timeIntervalSince(clock), 1))
            if let path = option("history") {
                var csv = "time_s,pressure_bar,reference_time_s,reference_bar\n"
                let stride = max(r.reference.times.count / max(r.times.count, 1), 1)
                let reference = Swift.stride(from: 0, to: r.reference.times.count, by: stride).map {
                    (r.reference.times[$0], r.reference.pressures[$0])
                }
                for n in 0..<max(r.times.count, reference.count) {
                    let simulated = n < r.times.count ? "\(r.times[n]),\(r.pressures[n] / 1e5)" : ","
                    let ref = n < reference.count ? "\(reference[n].0),\(reference[n].1 / 1e5)" : ","
                    csv += simulated + "," + ref + "\n"
                }
                try csv.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
    let measured = gas.measuredClosedVessel
    print(
        "Measured in standard vessels (NFPA 68, EN 15967): p_max \(format(measured.maximumPressure + 1.013, 1)) bar,"
            + " K_G \(format(measured.deflagrationIndex, 0)) bar m/s")
}

/// In a closed sphere: the burnt share x and pressure, the front's area (the integral of |grad b|
/// by central differences) against the thin-flame model's 4π r_f² at that x and pressure, and the
/// burning rate against the thin-flame model's.
private func vesselArea(_ solver: BlastSolver, radius: Float) {
    guard let share = solver.unburntShare(), let state = solver.deflagrationState() else { return }
    let grid = solver.grid
    let dx = Double(grid.cellSize)
    func at(_ i: Int, _ j: Int, _ k: Int) -> Double {
        solver.isSolid(i, j, k) ? .nan : Double(share[grid.index(i, j, k)])
    }
    var area = 0.0
    var volume = 0.0
    for k in 1..<(grid.nz - 1) {
        for j in 1..<(grid.ny - 1) {
            for i in 1..<(grid.nx - 1) where !solver.isSolid(i, j, k) {
                volume += dx * dx * dx
                let b = at(i, j, k)
                func side(_ v: Double) -> Double { v.isNaN ? b : v }
                let gx = 0.5 * (side(at(i + 1, j, k)) - side(at(i - 1, j, k)))
                let gy = 0.5 * (side(at(i, j + 1, k)) - side(at(i, j - 1, k)))
                let gz = 0.5 * (side(at(i, j, k + 1)) - side(at(i, j, k - 1)))
                area += (gx * gx + gy * gy + gz * gz).squareRoot() * dx * dx
            }
        }
    }
    let x = state.burntFraction
    let p = Double(solver.gaugeHistories[0].last?.pressure ?? 101_325)
    let r = cbrt(3 * volume / (4 * Double.pi))
    let unburnt = (1 - x) * pow(101_325 / p, 1 / 1.4)
    let flame = r * cbrt(max(1 - unburnt, 0))
    print(
        "  t \(format(solver.time * 1000, 0)) ms: x \(format(x, 3)), p \(format(p / 1e5, 3)) bar, front area "
            + "\(format(area, 4)) m² against 4π r_f² \(format(4 * Double.pi * flame * flame, 4)) (r_f \(format(flame, 3)) m)"
            + ", ratio \(format(area / (4 * Double.pi * flame * flame), 3))")
}

/// A narrow tube closed at x = 0 and open at the far end, lit at the closed end: the flame should
/// run at the expansion ratio times the burning velocity. Prints profiles along the tube.
private func runTube(device: MTLDevice, gas: FlammableGas, ball: Bool) throws {
    let dx = option("dx").flatMap { Float($0) } ?? 0.02
    let length: Float = option("length").flatMap { Float($0) } ?? (ball ? 1.2 : 2)
    let width = ball ? length : 4 * dx
    var scenario = Scenario(
        name: "Tube", domainSize: SIMD3(length, width, width), boxes: [],
        charge: Charge(mass: 0, position: .zero))
    scenario.reflectiveFaces = ball ? (flag("closed") ? .all : []) : BoundaryFaces.all.subtracting(.xMax)
    let ignition =
        ball
        ? SIMD3<Float>(repeating: length / 2 + (option("offset").flatMap { Float($0) } ?? 0) * dx)
        : SIMD3(0, width / 2, width / 2)
    scenario.deflagration = Deflagration(
        gas: gas, region: Box(min: .zero, max: SIMD3(length, width, width)),
        ignition: ignition, acceleration: .laminar)
    if let scale = option("turbulence").flatMap({ Float($0) }), scale > 0 {
        scenario.deflagration?.acceleration.turbulence = FlameTurbulence(scale: scale)
    }
    var configuration = SolverConfiguration()
    if flag("mixing") {
        configuration.mixing = option("mixing-model") == "smagorinsky" ? SubgridMixing() : .sigma
    }
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: dx, configuration: configuration)
    let grid = solver.grid
    let row = grid.cell(containing: ignition)
    let step = option("every").flatMap { Double($0) } ?? 0.05
    var lastRadius = 0.0
    for n in 1...(option("count").flatMap { Int($0) } ?? 6) {
        solver.advance(until: step * Double(n))
        guard let front = solver.unburntShare() else { return }
        print("t = \(format(solver.time * 1000, 0)) ms")
        var line = ""
        let viscosity = solver.eddyViscosities()
        solver.readSpecies { species in
            for i in Swift.stride(from: ball ? row.i : 0, to: grid.nx, by: ball ? 1 : max(grid.nx / 40, 1)) {
                let (j, k) = ball ? (row.j, row.k) : (1, 1)
                let index = grid.index(i, j, k)
                let p = solver.primitive(i, j, k)
                let share = (species?[index].x ?? 0) / p.density
                line +=
                    "  x \(format(Double(grid.cellCentre(i, j, k).x), 3)) b \(format(Double(front[index]), 2))"
                    + " u \(format(Double(p.velocity.x), 2)) rho \(format(Double(p.density), 3))"
                    + " share \(format(Double(share), 2)) p \(format(Double(p.pressure / 1e5), 4))"
                    + (viscosity.map {
                        " u' \(format(Double($0[index]) * (2.0 / 3).squareRoot() / (0.094 * Double(dx)), 3))"
                    } ?? "") + "\n"
            }
        }
        print(line, terminator: "")
        if let viscosity {
            // u' over the grid, by the unburnt share: mean and largest, and where the largest is.
            var sums = [Double](repeating: 0, count: 5)
            var counts = [Int](repeating: 0, count: 5)
            var largest = [(Double, Int)](repeating: (0, 0), count: 5)
            for index in 0..<grid.cellCount where front[index] < 1 - 1e-4 || viscosity[index] > 0 {
                let bin = min(Int(front[index] * 5), 4)
                let up = Double(viscosity[index]) * (2.0 / 3).squareRoot() / (0.094 * Double(dx))
                sums[bin] += up
                counts[bin] += 1
                if up > largest[bin].0 { largest[bin] = (up, index) }
            }
            if flag("shells") {
                // u' and the speed by distance from the ignition point, in shells a cell thick.
                let shells = Int(Float(grid.nx) / 2)
                var maxima = [Double](repeating: 0, count: shells)
                var sums = [Double](repeating: 0, count: shells)
                var bs = [Double](repeating: 0, count: shells)
                var counts = [Int](repeating: 0, count: shells)
                for kk in 0..<grid.nz {
                    for jj in 0..<grid.ny {
                        for ii in 0..<grid.nx {
                            let index = grid.index(ii, jj, kk)
                            let shell = Int(simd_distance(grid.cellCentre(ii, jj, kk), ignition) / dx)
                            guard shell < shells else { continue }
                            let up = Double(viscosity[index]) * (2.0 / 3).squareRoot() / (0.094 * Double(dx))
                            maxima[shell] = max(maxima[shell], up)
                            sums[shell] += up
                            bs[shell] += Double(front[index])
                            counts[shell] += 1
                        }
                    }
                }
                for n in 0..<shells where counts[n] > 0 {
                    print(
                        "  shell \(n): b \(format(bs[n] / Double(counts[n]), 3)) u' mean "
                            + "\(format(sums[n] / Double(counts[n]), 4)) max \(format(maxima[n], 4))")
                }
            }
            for bin in 0..<5 where counts[bin] > 0 {
                let at = largest[bin].1
                let c = grid.cellCentre(at % grid.nx, (at / grid.nx) % grid.ny, at / (grid.nx * grid.ny))
                print(
                    "  b \(format(Double(bin) / 5, 1))–\(format(Double(bin + 1) / 5, 1)): \(counts[bin]) cells, u' mean "
                        + "\(format(sums[bin] / Double(counts[bin]), 4)) max \(format(largest[bin].0, 4)) m/s at "
                        + "\(format(Double(simd_distance(c, ignition)), 3)) m from ignition")
            }
        }
        if let state = solver.deflagrationState(), ball, flag("closed") {
            // The radius of a sphere of the mixture burnt so far, burnt at constant pressure, and the
            // rate it has grown at since the last print against the expansion ratio times the
            // burning velocity.
            let sigma = Double(
                scenario.deflagration!.modelExpansionRatio(
                    atmosphere: scenario.atmosphere, airModel: .idealGas, gamma: 1.4))
            let burnt = state.initialUnburnt - state.unburnt
            let radius = cbrt(3 * burnt * sigma / (Double(scenario.atmosphere.density) * 4 * Double.pi))
            print(
                "  burnt-mass radius \(format(radius, 3)) m = \(format(radius / Double(dx), 1)) cells, growing at "
                    + "\(format((radius - lastRadius) / step, 2)) m/s against "
                    + "\(format(sigma * Double(scenario.deflagration!.laminarBurningVelocity), 2))")
            lastRadius = radius
        }
        if let state = solver.deflagrationState() {
            print(
                "  burnt volume radius \(format(cbrt(3 * state.burntVolume / (4 * Double.pi)), 3)) m, burnt mass "
                    + "\(format((state.initialUnburnt - state.unburnt) * 1000, 3)) g")
        }
    }
}

private func runVented(device: MTLDevice, gas: FlammableGas, concentration: Float?) throws {
    let areas = option("vent").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [5.4]
    let cells = option("dx").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.1]
    var base = VentedRoomStudy()
    base.gas = gas
    base.concentration = concentration
    base.releasePressure = option("release").flatMap { Float($0) } ?? 0
    base.ignition = option("ignition") == "back" ? .backWall : .centre
    base.airModel = chosenAirModel() ?? .idealGas
    if flag("laminar") { base.acceleration = .laminar }
    if flag("copy-faces") { base.openFaces = .copy }
    if let scale = option("turbulence").flatMap({ Float($0) }) {
        base.acceleration.turbulence = scale > 0 ? FlameTurbulence(scale: scale) : nil
    }
    if let factor = option("external").flatMap({ Float($0) }) { base.acceleration.externalFactor = factor }
    if let radius = option("wrinkling").flatMap({ Float($0) }) {
        base.acceleration.instability = radius > 0 ? .onset(radius) : nil
    }
    if let wall = option("wall").flatMap({ Float($0) }) { base.wallThickness = wall }
    if let until = option("until").flatMap({ Double($0) }) { base.maximumTime = until }
    base.postWidth = option("posts").flatMap { Float($0) }
    if let factor = option("factor").flatMap({ Float($0) }) { base.acceleration.factor = factor }
    if let room = option("room") {
        let parts = room.split(separator: "x").compactMap { Float($0) }
        if parts.count == 3 { base.room = SIMD3(parts[0], parts[1], parts[2]) }
    }
    let a = base.acceleration
    print(
        "\(gas.displayName)–air filling a \(format(Double(base.room.x), 1)) × \(format(Double(base.room.y), 1))"
            + " × \(format(Double(base.room.z), 1)) m room, lit at the \(base.ignition == .centre ? "middle" : "back wall"),"
            + " vent release \(format(Double(base.releasePressure) / 1000, 1)) kPa; flame: factor \(a.factor),"
            + " cellular \(a.instability.flatMap { $0.radius(gas: gas, fraction: base.concentration ?? gas.stoichiometricFraction) }.map { "from \(format(Double($0), 3)) m" } ?? "off"),"
            + " sub-grid turbulence \(a.turbulence.map { "a = \($0.scale)" } ?? "off")")
    print(
        pad("A_v m2", 8) + pad("dx m", 7) + pad("P_red kPa", 11) + pad("raw", 8) + pad("at ms", 8)
            + pad("vent ms", 9) + pad("burnt", 8) + pad("Molkov", 8) + pad("Bartk.", 8) + pad("NFPA 68", 9)
            + "run s")
    for area in areas {
        for dx in cells {
            var study = base
            study.ventArea = area
            study.cellSize = dx
            let clock = Date()
            let progress: ((Double, Double) -> Void)? =
                flag("progress")
                ? { time, burnt in print("  t \(format(time * 1000, 0)) ms, burnt \(format(burnt * 100, 1))%")
                }
                : nil
            var inspect: ((BlastSolver) -> Void)?
            if flag("inspect") { inspect = { solver in inspectHottest(solver) } }
            if flag("axis") {
                inspect = { solver in printAxis(solver, ignition: study.scenario().deflagration!.ignition) }
            }
            if flag("slice") {
                inspect = { solver in printSlice(solver, ignition: study.scenario().deflagration!.ignition) }
            }
            var monitor: ((BlastSolver) -> Void)?
            if flag("front") { monitor = { solver in frontStatistics(solver) } }
            let r = try study.run(device: device, progress: progress, inspect: inspect, monitor: monitor)
            let c = r.correlations
            print(
                pad(format(Double(area), 2), 8) + pad(format(Double(dx), 3), 7)
                    + pad(format(r.reducedPressure / 1000, 2), 11) + pad(format(r.rawPeak / 1000, 2), 8)
                    + pad(format(r.peakTime * 1000, 0), 8)
                    + pad(r.ventOpened.map { format($0 * 1000, 0) } ?? "-", 9)
                    + pad(format(r.burntFraction * 100, 1) + "%", 8) + pad(format(c.molkov / 1000, 1), 8)
                    + pad(c.bartknecht.map { format($0 / 1000, 1) } ?? "-", 8)
                    + pad(c.nfpa68.map { format($0 / 1000, 1) } ?? "-", 9)
                    + format(Date().timeIntervalSince(clock), 0))
            if let path = option("history") {
                let file = path.replacingOccurrences(of: "%", with: "\(area)-\(dx)")
                var csv = "time_s,overpressure_kPa\n"
                for (t, p) in zip(r.times, r.overpressures) { csv += "\(t),\(p / 1000)\n" }
                try csv.write(toFile: file, atomically: true, encoding: .utf8)
            }
            if flag("speeds") {
                print(
                    "    flame speed, m/s at m from ignition: "
                        + r.flameSpeeds.map { "\(format($0.position, 2)): \(format($0.speed, 1))" }.joined(
                            separator: ", "))
            }
            if let path = option("arrivals") {
                let file = path.replacingOccurrences(of: "%", with: "\(area)-\(dx)")
                var csv = "position_m,arrival_s\n"
                for a in r.arrivals { csv += "\(a.position),\(a.time)\n" }
                try csv.write(toFile: file, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// The sub-grid velocity u' at the flame (cells a tenth to nine tenths unburnt), inside the room and
/// outside it, and the share of the front's cells it wrinkles.
private func frontStatistics(_ solver: BlastSolver) {
    guard let viscosity = solver.eddyViscosities(), let share = solver.unburntShare() else { return }
    let grid = solver.grid
    let dx = Double(grid.cellSize)
    var line = "  t \(format(solver.time * 1000, 0)) ms:"
    for outside in [false, true] {
        var count = 0
        var sum = 0.0
        var largest = 0.0
        var wrinkled = 0
        var speed = 0.0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    let index = grid.index(i, j, k)
                    guard share[index] > 0.1, share[index] < 0.9, !solver.isSolid(i, j, k) else { continue }
                    // The room's vent wall is at x = 2 + 0.2 + 4.6 = 6.8 m.
                    guard (grid.cellCentre(i, j, k).x > 6.8) == outside else { continue }
                    let up = Double(viscosity[index]) * (2.0 / 3).squareRoot() / (0.094 * dx)
                    let xi = 1.036 * (up / 0.41).squareRoot() * pow(dx / (1.5e-5 / 0.41), 1.0 / 6)
                    count += 1
                    sum += up
                    largest = max(largest, up)
                    if xi > 1 { wrinkled += 1 }
                    speed += Double(simd_length(solver.primitive(i, j, k).velocity))
                }
            }
        }
        guard count > 0 else { continue }
        line +=
            (outside ? "  outside" : "  inside")
            + " \(count) front cells, u' mean \(format(sum / Double(count), 3))"
            + " max \(format(largest, 2)), wrinkled \(format(100 * Double(wrinkled) / Double(count), 0))%,"
            + " |u| mean \(format(speed / Double(count), 2))"
    }
    print(line)
}

/// Prints the unburnt share, velocity and overpressure along the line through the ignition point
/// along x.
private func printAxis(_ solver: BlastSolver, ignition: SIMD3<Float>) {
    let grid = solver.grid
    let cell = grid.cell(containing: ignition)
    guard let share = solver.unburntShare() else { return }
    print("  t \(format(solver.time * 1000, 0)) ms along x through the ignition point:")
    for i in 0..<grid.nx where !solver.isSolid(i, cell.j, cell.k) {
        let p = solver.primitive(i, cell.j, cell.k)
        print(
            "    x \(format(Double(grid.cellCentre(i, cell.j, cell.k).x - ignition.x), 2)) b "
                + "\(format(Double(share[grid.index(i, cell.j, cell.k)]), 3)) u \(format(Double(p.velocity.x), 2)) "
                + "\(format(Double(p.velocity.y), 2)) \(format(Double(p.velocity.z), 2)) dp "
                + "\(format(Double(p.pressure - 101_325), 1))")
    }
}

/// Prints the unburnt share in the vertical plane through the ignition point along x, a character a
/// cell (# burnt, + mostly burnt, - mostly unburnt, . unburnt, space solid).
private func printSlice(_ solver: BlastSolver, ignition: SIMD3<Float>) {
    let grid = solver.grid
    let j = grid.cell(containing: ignition).j
    guard let share = solver.unburntShare() else { return }
    print("  t \(format(solver.time * 1000, 0)) ms, plane y = \(format(Double(ignition.y), 2)) m, x from 0:")
    for k in stride(from: grid.nz - 1, through: 0, by: -1) {
        var line = "    "
        for i in 0..<grid.nx {
            if solver.isSolid(i, j, k) {
                line += " "
                continue
            }
            let b = share[grid.index(i, j, k)]
            line += b < 0.1 ? "#" : b < 0.5 ? "+" : b < 0.9 ? "-" : "."
        }
        print(line)
    }
}

/// Prints the cells of highest pressure and their surroundings.
private func inspectHottest(_ solver: BlastSolver) {
    let grid = solver.grid
    var cells: [(p: Float, i: Int, j: Int, k: Int)] = []
    for k in 0..<grid.nz {
        for j in 0..<grid.ny {
            for i in 0..<grid.nx where !solver.isSolid(i, j, k) {
                cells.append((solver.primitive(i, j, k).pressure, i, j, k))
            }
        }
    }
    cells.sort { $0.p > $1.p }
    let share = solver.unburntShare()
    for c in cells.prefix(8) {
        let p = solver.primitive(c.i, c.j, c.k)
        let t = p.pressure / (p.density * 287.05)
        print(
            "  (\(c.i), \(c.j), \(c.k)) at \(grid.cellCentre(c.i, c.j, c.k)): p \(format(Double(p.pressure) / 1e5, 3)) bar,"
                + " rho \(format(Double(p.density), 4)), T \(format(Double(t), 0)) K,"
                + " u \(p.velocity), b \(share.map { format(Double($0[grid.index(c.i, c.j, c.k)]), 3) } ?? "-")"
        )
    }
}

/// `blastbench deflagration slope [--angle 20] [--dx 0.05] [--until 0.3] [--laminar]`: mixture filling the
/// half space above ground, lit just above it, without gravity, on a plane sloping at `angle` (cut
/// cells, then the staircase) and on a flat floor, the same problem turned. Prints when the burnt gas
/// reaches each equivalent hemisphere's radius, and the peak overpressure at gauges 1 m from the
/// ignition along the ground upslope, downslope and across, and above it, each 0.2 m off the ground.
private func runSlope(device: MTLDevice, gas: FlammableGas) throws {
    let angle = option("angle").flatMap { Float($0) } ?? 20
    let dx = option("dx").flatMap { Float($0) } ?? 0.05
    let until = option("until").flatMap { Double($0) } ?? 0.3
    let theta = angle * .pi / 180
    let foot: Float = 0.4
    let length: Float = 4.8
    let height: Float = 1.6 + (length - foot) * tan(theta)
    let domain = SIMD3<Float>(length, length, height)
    let x0 = length / 2
    let distance: Float = 1
    let offGround: Float = 0.2
    let radii = [0.4, 0.6, 0.8, 1.0]
    print(
        "\(gas.displayName)–air filling the space above ground, lit \(format(Double(2 * dx), 2)) m above it, "
            + "no gravity, \(format(Double(dx), 3)) m cells; a \(format(Double(angle), 0))° slope against a flat floor"
    )
    print(
        pad("ground", 22) + radii.map { pad("t(r=\(format($0, 1))) ms", 13) }.joined()
            + pad("up kPa", 9) + pad("down kPa", 10) + pad("across kPa", 12) + pad("above kPa", 11) + "run s")
    for (name, sloped, cut) in [
        ("slope, cut cells", true, true), ("slope, staircase", true, false), ("flat floor", false, false),
    ] {
        // The ground's frame: a point on it under the ignition, its normal and the upslope direction.
        let base =
            sloped ? SIMD3<Float>(x0, length / 2, (x0 - foot) * tan(theta)) : SIMD3<Float>(x0, length / 2, 0)
        let normal = sloped ? SIMD3<Float>(-sin(theta), 0, cos(theta)) : SIMD3<Float>(0, 0, 1)
        let upslope = sloped ? SIMD3<Float>(cos(theta), 0, sin(theta)) : SIMD3<Float>(1, 0, 0)
        let across = SIMD3<Float>(0, 1, 0)
        var scenario = Scenario(
            name: "Slope", domainSize: domain, boxes: [], charge: Charge(mass: 0, position: .zero))
        if sloped { scenario.terrain = .slope(domain: domain, spacing: dx / 2, foot: foot, angle: angle) }
        let ignition = base + 2 * dx * normal
        scenario.deflagration = Deflagration(
            gas: gas, region: Box(min: .zero, max: domain), ignition: ignition,
            acceleration: flag("laminar") ? .laminar : FlameAcceleration())
        let gauges = [upslope, -upslope, across, normal].map { base + distance * $0 + offGround * normal }
        scenario.gauges = gauges.enumerated().map { Gauge("gauge \($0.offset)", at: $0.element) }
        var configuration = SolverConfiguration()
        configuration.terrainCutCells = cut
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: dx, configuration: configuration)
        let clock = Date()
        var reached = [Double?](repeating: nil, count: radii.count)
        while solver.time < until {
            solver.advance(until: solver.time + 0.002)
            guard let state = solver.deflagrationState() else { break }
            let radius = cbrt(3 * state.burntVolume / (2 * Double.pi))
            for (n, r) in radii.enumerated() where reached[n] == nil && radius >= r {
                reached[n] = solver.time
            }
            if reached.last! != nil { break }
        }
        let peaks = gauges.map { point -> Double in
            let cell = solver.grid.cell(containing: point)
            return Double(solver.peakOverpressure(cell.i, cell.j, cell.k)) / 1000
        }
        print(
            pad(name, 22) + reached.map { pad($0.map { format($0 * 1000, 1) } ?? "-", 13) }.joined()
                + pad(format(peaks[0], 2), 9) + pad(format(peaks[1], 2), 10) + pad(format(peaks[2], 2), 12)
                + pad(format(peaks[3], 2), 11) + format(Date().timeIntervalSince(clock), 0))
    }
}
