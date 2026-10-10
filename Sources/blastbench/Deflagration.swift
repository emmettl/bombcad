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
    default:
        print("Unknown deflagration check \(mode). Use vessel, vented, tube, ball or layout.")
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
                    } : nil)
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

/// A narrow tube closed at x = 0 and open at the far end, lit at the closed end: the flame should
/// run at the expansion ratio times the burning velocity. Prints profiles along the tube.
private func runTube(device: MTLDevice, gas: FlammableGas, ball: Bool) throws {
    let dx = option("dx").flatMap { Float($0) } ?? 0.02
    let length: Float = option("length").flatMap { Float($0) } ?? (ball ? 1.2 : 2)
    let width = ball ? length : 4 * dx
    var scenario = Scenario(
        name: "Tube", domainSize: SIMD3(length, width, width), boxes: [],
        charge: Charge(mass: 0, position: .zero))
    scenario.reflectiveFaces = ball ? [] : BoundaryFaces.all.subtracting(.xMax)
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
    if let scale = option("turbulence").flatMap({ Float($0) }) {
        base.acceleration.turbulence = scale > 0 ? FlameTurbulence(scale: scale) : nil
    }
    if let radius = option("wrinkling").flatMap({ Float($0) }) { base.acceleration.wrinklingRadius = radius }
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
            + " wrinkling \(a.wrinklingRadius.map { "from \($0) m" } ?? "off"),"
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
                    + pad(format(c.nfpa68 / 1000, 1), 9)
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
