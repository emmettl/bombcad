import BlastCore
import BlastRender
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// Command-line companion to the app: measures solver throughput, compares a surface burst
// against the Kinney-Graham curve and renders offscreen snapshots.
//
//   blastbench [throughput] [--preset open|single|street|courtyard|wall|box|frame|infill|storeys|tall|tower|column|
//               protected|glass|carpark|underpass|house|blockwall|chamber] [--full]
//   blastbench structure [--preset wall|box] [--contact] [--elastic]
//   blastbench validate [--dx 0.25]
//   blastbench beam [--layers 12,24] [--rate 0.1]
//   blastbench shear [--layers 12,24] [--rate 0.05] [--slice 92] [--dowel 1]
//   blastbench impact [--tests SS0a-1,SS0b-1] [--layers 16] [--time 0.2] [--beams 0.1]
//   blastbench closeair [--z 0.3,0.5,0.75,1] [--dx 0.02] [--mapped] [--refine 2]
//   blastbench closein [--tests P1,P7] [--dx 0.05] [--h 0.025] [--time 0.3] [--refine 2] [--afterburn] [--progress]
//   blastbench slab [--history] [--sensitivity [--convergence]] [--layers 16,32] [--strip 25]
//                   [--shells 2,1 [--shell-layers 8] [--shell-rate none|designFactors|strainRate]]
//   blastbench snapshot --out frame.png [--preset street] [--dx 0.25] [--time 0.03] [--mode peak]
//                       [--stationary-walls]

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "throughput"

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func flag(_ name: String) -> Bool { arguments.contains("--\(name)") }

func preset(named name: String?) -> ScenarioPreset {
    switch name {
    case "open": .openGround
    case "single": .singleBuilding
    case "courtyard": .courtyard
    case "wall": .blastWall
    case "box": .concreteBox
    case "frame": .frame
    case "infill": .infilledFrame
    case "storeys": .threeStorey
    case "tall": .tallFrame
    case "tower": .coreTower
    case "column": .columnCloseIn
    case "protected": .protectedBuilding
    case "glass": .glassFacade
    case "carpark": .carPark
    case "underpass": .underpass
    case "house": .blockHouse
    case "blockwall": .blockWall
    case "chamber": .internalExplosion
    default: .streetCanyon
    }
}

/// The preset named by `--preset`, with its structure meshed with shells of `--shells` metres
/// (0.25 when given without a size) if asked.
func chosenScenario() -> Scenario {
    var scenario = preset(named: option("preset")).scenario
    if flag("shells") || option("shells") != nil, var structure = scenario.structure {
        structure.elementKind = .shell
        structure.elementSize = option("shells").flatMap { Float($0) } ?? 0.25
        if let layers = option("shell-layers").flatMap({ Int($0) }) { structure.shellLayers = layers }
        scenario.structure = structure
    }
    if option("cracks") != nil || flag("oriented"), var structure = scenario.structure {
        structure.crackAxes = chosenCrackAxes()
        scenario.structure = structure
    }
    // `--no-second-crack` carries tension that turns away from fixed crack axes across them.
    if flag("no-second-crack") { scenario.structure?.secondCracks = false }
    // `--dowel 0.3` scales the bars' dowel action in every material of the structure.
    if let dowel = option("dowel").flatMap({ Float($0) }), var structure = scenario.structure {
        structure.material.dowelFactor = dowel
        structure.solidMaterial = structure.solidMaterial.map {
            $0.map {
                var m = $0
                m.dowelFactor = dowel
                return m
            }
        }
        scenario.structure = structure
    }
    // `--no-units` gives masonry its wall's strength throughout, without units and joints.
    if flag("no-units") { scenario.structure?.unitJoints = false }
    // `--bond` lets masonry come away from concrete at the bond of mortar to concrete.
    if flag("bond"), var structure = scenario.structure {
        structure.interfaceBond = StructureModel.masonryBond
        scenario.structure = structure
    }
    // `--solid-near 4` meshes the pieces within 4 m of the charge with solid elements and the
    // rest with shells.
    if let distance = option("solid-near").flatMap({ Float($0) }), let structure = scenario.structure {
        scenario.structure = structure.solidNear(scenario.charge.position, within: distance, shellSize: 0.25)
    }
    return scenario
}

/// `--cracks lattice` or `--cracks fixed` (or `--oriented`, the same as fixed); turning by default.
func chosenCrackAxes() -> CrackAxes {
    switch option("cracks") {
    case "lattice": .lattice
    case "fixed": .fixedAtFirstCrack
    default: flag("oriented") ? .fixedAtFirstCrack : .turningUntilOpen
    }
}

/// The air model `--air thermal` or `--air dissociating` asks for, or nil for the default.
func chosenAirModel() -> AirModel? {
    switch option("air") {
    case "thermal": .thermallyPerfect
    case "dissociating": .dissociating
    default: nil
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

guard let device = MTLCreateSystemDefaultDevice() else {
    print("No Metal device available")
    exit(1)
}

func runThroughput() throws {
    let scenario = chosenScenario()
    let event = scenario.acousticCrossingTime
    print("Device: \(device.name)")
    print(
        "Scenario: \(scenario.name), \(Int(scenario.charge.mass)) kg TNT equivalent, "
            + "\(format(event * 1000, 0)) ms event (charge to farthest corner at ambient sound speed)")
    print("")
    print(
        pad("cell", 8) + pad("cells", 12) + pad("memory", 10) + pad("steps/s", 10) + pad("Mcell/s", 10)
            + pad("slow-mo", 10) + pad("steps", 8) + pad("swept", 8) + pad("event wall time", 20))

    var stepsPerMetre = 0.0
    var lastSwept = 1.0
    for cellSize in [Float(0.5), 0.25, 0.125] {
        let solver = try makeAirSolver(scenario, cellSize: cellSize)
        let cells = solver.grid.cellCount
        // Run the whole event unless it would take minutes; then time a sample and extrapolate
        // the step count from the previous, coarser run. The sample sweeps every tile, since
        // early steps skip far more air than the event as a whole; the estimate assumes the
        // coarser run's swept fraction.
        let runWholeEvent = cells < 20_000_000 || flag("full")
        if flag("no-skip") || !runWholeEvent {
            solver.configuration.skipStillAir = false
            solver.restart()
        }
        let start = ContinuousClock.now
        var steps = 0
        var swept = 1.0
        if runWholeEvent && solver.configuration.refinement > 1 {
            // Batch by batch, to follow how much of the air is refined.
            var refined = 0.0
            var batches = 0
            while solver.time < event {
                let result = solver.advance(steps: 64, timeLimit: event)
                if result.steps == 0 { break }
                swept =
                    (swept * Double(steps) + result.sweptFraction * Double(result.steps))
                    / Double(steps + result.steps)
                steps += result.steps
                refined += Double(result.refinedTiles)
                batches += 1
            }
            let blocks = Double(
                ((solver.grid.nx + 3) / 4) * ((solver.grid.ny + 3) / 4) * ((solver.grid.nz + 3) / 4))
            print(
                "  refined blocks of 4 x 4 x 4 cells: \(format(refined / Double(max(batches, 1)), 0)) on average, "
                    + "of \(Int(blocks))")
        } else if runWholeEvent {
            let result = solver.advance(until: event)
            (steps, swept) = (result.steps, result.sweptFraction)
        } else {
            let result = solver.advance(steps: 192)
            (steps, swept) = (result.steps, result.sweptFraction)
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let stepRate = Double(steps) / seconds

        var totalSteps = Double(steps)
        var wallTime = seconds
        if runWholeEvent {
            stepsPerMetre = Double(steps) * Double(cellSize)
            lastSwept = swept
        } else {
            // The step count scales inversely with cell size.
            totalSteps = stepsPerMetre / Double(cellSize)
            swept = flag("no-skip") ? 1 : lastSwept
            wallTime = totalSteps / stepRate * swept
        }
        let slowMotion = wallTime / event
        print(
            pad("\(format(Double(cellSize), 3)) m", 8)
                + pad("\(format(Double(cells) / 1e6, 1)) M", 12)
                + pad("\(format(Double(solver.memoryFootprint) / 1e9, 2)) GB", 10)
                + pad(format(stepRate, 0), 10)
                + pad(format(stepRate * Double(cells) / 1e6, 0), 10)
                + pad("\(format(slowMotion, 0))x", 10)
                + pad(format(totalSteps, 0), 8)
                + pad("\(format(100 * swept, 0))%", 8)
                + pad("\(format(wallTime, 1)) s" + (runWholeEvent ? "" : " (est.)"), 20))
    }
}

/// Time at which a gauge's overpressure first reaches half of its peak, in seconds.
func arrivalTime(_ history: [GaugeSample], ambient: Float) -> Double {
    let peak = (history.map(\.pressure).max() ?? ambient) - ambient
    return history.first { $0.pressure - ambient >= 0.5 * peak }?.time ?? 0
}

/// The internal explosion test of Shang et al. (2026).
func runChamber() throws {
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.1
    let elementSize = option("h").flatMap { Float($0) } ?? 0.1
    let duration = option("time").flatMap { Double($0) } ?? 0.3
    let downstand = !flag("no-downstand")
    let chargeScale = option("charge-scale").flatMap { Float($0) } ?? 1
    if let text = option("pressures") {
        // The roof's resistance: the vent closed, the chamber filled with air at a steady
        // overpressure, and the roof edge watched.
        print(
            "Chamber of Shang et al. (2026), vent closed, filled with steady overpressure; roof edge at mid-span"
        )
        print(pad("kPa", 8) + pad("peak", 10) + pad("end", 10) + "failed")
        for kilopascals in text.split(separator: ",").compactMap({ Float($0) }) {
            let result = try ChamberTest.pressureTest(
                device: device, overpressure: kilopascals * 1000, elementSize: elementSize, duration: duration
            )
            print(
                pad(format(Double(kilopascals), 0), 8)
                    + pad("\(format(Double(result.peakDeflection) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.edgeHistory.last?.y ?? 0) * 1000, 0)) mm", 10)
                    + "\(result.summary.erodedElements)")
        }
        return
    }
    print(
        "Internal explosion in a reinforced concrete chamber (Shang et al., 2026): "
            + "4 x \(format(Double(50 * chargeScale), 1)) kg TNT, half-model")
    print(
        "Air cells \(format(Double(cellSize), 3)) m, elements \(format(Double(elementSize), 3)) m, \(format(duration * 1000, 0)) ms"
            + (downstand ? "" : ", no down-stand"))
    var scenario = ChamberTest.scenario(
        elementSize: elementSize, downstand: downstand, ties: !flag("no-ties"), elastic: flag("elastic"),
        chargeScale: chargeScale, crackAxes: chosenCrackAxes())
    if let residual = option("crack-residual").flatMap({ Float($0) }) {
        scenario.structure?.material.crackResidual = residual
        print("Residual crack opening \(format(Double(residual) * 100, 0))%")
    }
    if flag("no-second-crack") { scenario.structure?.secondCracks = false }
    if let dowel = option("dowel").flatMap({ Float($0) }) { scenario.structure?.material.dowelFactor = dowel }
    let result = try ChamberTest.run(
        device: device, scenario: scenario, cellSize: cellSize, duration: duration,
        afterburning: flag("afterburn"),
        afterburnEnergy: option("afterburn-energy").flatMap { Float($0) }.map { $0 * 1e6 },
        airModel: chosenAirModel() ?? .idealGas,
        refinement: option("refine").flatMap { Int($0) } ?? 1,
        contact: flag("no-contact") ? .off : nil,
        // `--progress` reports every 10 ms of a long run.
        progress: flag("progress")
            ? { line in
                print(line)
                fflush(stdout)
            } : nil)
    print(
        "\nPeak reflected overpressure (MPa); the six sensors measured \(ChamberTest.measuredPeaks.map { format(Double($0.pressure) / 1e6, 2) }.joined(separator: ", "))"
    )
    for (name, pressure) in result.gaugePeaks {
        print("  \(pad(format(Double(pressure) / 1e6, 2), 6))  \(name)")
    }
    print(
        "\nRoof free edge at mid-span: peak \(format(Double(result.peakDeflection) * 1000, 0)) mm, "
            + "\(format(Double(result.residual) * 1000, 0)) mm at the end (measured residual \(format(Double(ChamberTest.measuredResidual) * 1000, 0)) mm)"
    )
    print(
        "Structure: \(result.summary.erodedElements) of \(result.summary.activeElements + result.summary.erodedElements) elements failed; "
            + "run took \(format(result.wallSeconds, 1)) s")
    for (part, failed, total) in result.failures {
        print("  \(pad("\(failed)", 6)) of \(pad("\(total)", 6))  \(part)")
    }
    for probe in result.probes {
        print("\(probe.name): peak \(format(Double(probe.history.map(\.y).max() ?? 0) * 1000, 0)) mm outward")
    }
    if flag("history") {
        print("    time      roof edge" + result.probes.map { pad($0.name, 24) }.joined())
        for (n, sample) in result.edgeHistory.enumerated() where Int((sample.x * 1000).rounded()) % 5 == 0 {
            print(
                "    \(pad(format(Double(sample.x) * 1000, 1), 6)) ms \(pad(format(Double(sample.y) * 1000, 1), 9))"
                    + result.probes.map { pad(format(Double($0.history[n].y) * 1000, 1), 24) }.joined())
        }
    }
}

/// Gas pressure in a closed room against UFC 3-340-02 Figure 2-152.
/// A solver for `scenario`, with the air options given on the command line (`--afterburn`).
/// The air's refinement from `--refine 2|4`, `--refine-threshold` and `--refine-memory` (MB).
func configureRefinement(_ configuration: inout SolverConfiguration) {
    if let ratio = option("refine").flatMap({ Int($0) }) { configuration.refinement = ratio }
    if let threshold = option("refine-threshold").flatMap({ Float($0) }) {
        configuration.refinementThreshold = threshold
    }
    if let memory = option("refine-memory").flatMap({ Int($0) }) {
        configuration.refinementMemory = memory << 20
    }
}

func makeAirSolver(_ scenario: Scenario, cellSize: Float) throws -> BlastSolver {
    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    if let air = chosenAirModel() {
        solver.configuration.airModel = air
        try solver.load(scenario)
    }
    if flag("mapped") {
        solver.configuration.mappedCharge = true
        try solver.load(scenario)
    }
    if flag("afterburn") {
        solver.configuration.afterburning = true
        if let time = option("burn-time").flatMap({ Float($0) }) {
            solver.configuration.afterburnTime = time / 1000
        }
        if let energy = option("afterburn-energy").flatMap({ Float($0) }) {
            solver.configuration.afterburnEnergy = energy * 1e6
        }
        try solver.load(scenario)
    }
    return solver
}

func runGasPressure() throws {
    let side: Float = 6
    let settle = option("time").flatMap { Double($0) } ?? 0.08
    print(
        "Charge in the middle of a closed \(Int(side)) m cubic room, after the shocks have settled (\(format(settle * 1000, 0)) ms)"
            + (flag("afterburn") ? ", with afterburning" : "")
            + (chosenAirModel().map { ", \($0) air" } ?? ""))
    print(
        pad("W/V kg/m3", 11) + pad("charge", 10) + pad("model", 12) + pad("(g-1)E/V", 12)
            + pad("UFC 2-152", 12)
            + pad("model/UFC", 11) + pad("burnt", 8))
    // `--per-volume 0.1415` runs other ratios (that one is Cooper's closed-vessel example).
    let ratios =
        option("per-volume").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [
            0.25, 0.5, 1, 2, 4,
        ]
    for chargePerVolume in ratios {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: chargePerVolume * side * side * side, position: SIMD3(repeating: side / 2)))
        scenario.reflectiveFaces = .all
        let solver = try makeAirSolver(scenario, cellSize: option("dx").flatMap { Float($0) } ?? 0.25)
        solver.advance(until: settle)
        let burnt = 1 - solver.speciesTotals().fuel / Double(scenario.charge.mass)
        let volume = Double(side * side * side)
        let totals = solver.totals()
        // Mean pressure of the gas: (gamma - 1) times its internal energy per volume, less the
        // kinetic energy still sloshing about (small by now).
        var kinetic = 0.0
        solver.withState { cells in
            for cell in cells {
                kinetic +=
                    0.5
                    * Double(
                        cell.momentumX * cell.momentumX + cell.momentumY * cell.momentumY
                            + cell.momentumZ * cell.momentumZ) / Double(max(cell.density, 1e-6))
            }
        }
        let cellVolume = Double(pow(solver.grid.cellSize, 3))
        let gamma = Double(solver.configuration.gamma)
        let mean =
            Double(
                solver.configuration.airModel.pressure(
                    density: Float(totals.mass / volume),
                    internalEnergy: Float((totals.energy - kinetic * cellVolume) / volume),
                    gamma: Float(gamma)))
            - Double(scenario.atmosphere.pressure)
        let ideal = (gamma - 1) * Double(scenario.charge.energy) / volume
        let reference = UFC340.peakGasPressure(chargePerVolume: Double(chargePerVolume)) ?? .nan
        print(
            pad(format(Double(chargePerVolume), 2), 11) + pad("\(Int(scenario.charge.mass)) kg", 10)
                + pad("\(format(mean / 1e6, 2)) MPa", 12) + pad("\(format(ideal / 1e6, 2)) MPa", 12)
                + pad("\(format(reference / 1e6, 2)) MPa", 12)
                + pad("\(format(100 * mean / reference, 0))%", 11)
                + pad(solver.configuration.afterburning ? "\(format(100 * burnt, 0))%" : "-", 8))
    }
}

func runValidation() throws {
    var cellSizes: [Float] = [0.5, 0.25, 0.125]
    if let text = option("dx"), let value = Float(text) {
        cellSizes = [value]
    }
    func configure(_ solver: BlastSolver) {
        if let theta = option("theta").flatMap({ Float($0) }) { solver.configuration.limiterTheta = theta }
        if let cfl = option("cfl").flatMap({ Float($0) }) { solver.configuration.cfl = cfl }
        if let cells = option("balloon").flatMap({ Float($0) }) {
            solver.configuration.minimumBalloonCells = cells
        }
        if flag("hll") { solver.configuration.riemannSolver = .hll }
        if flag("afterburn") { solver.configuration.afterburning = true }
        if let air = chosenAirModel() { solver.configuration.airModel = air }
        if flag("mapped") { solver.configuration.mappedCharge = true }
        if let time = option("burn-time").flatMap({ Float($0) }) {
            solver.configuration.afterburnTime = time / 1000
        }
        configureRefinement(&solver.configuration)
    }
    func header(_ first: String) -> String {
        pad(first, 10) + pad("reference", 12)
            + cellSizes.map { pad("dx \(format(Double($0), 3))", 16) }.joined()
    }
    func row(_ label: String, _ reference: Double, _ values: [Double], digits: Int = 1) -> String {
        pad(label, 10) + pad(format(reference, digits), 12)
            + values.map { pad("\(format($0, digits)) (\(format(100 * $0 / reference, 0))%)", 16) }.joined()
    }

    // 1. Kingery-Bulmash: the design-practice standard for a surface burst.
    var scenario = ScenarioPreset.openGround.scenario
    let mass = Double(scenario.charge.mass)
    // Scaled distances from close in to as far as the domain allows (`--z` overrides).
    let distances =
        option("z").map { $0.split(separator: ",").compactMap { Double($0) } }
        ?? [0.75, 1, 1.5, 2, 3, 4, 5, 6]
    let points = distances.compactMap { KingeryBulmash.point(at: $0) }
    scenario.gauges = points.map { point in
        Gauge(
            "Z = \(format(point.scaledDistance, 2))", at: SIMD3(32 + Float(point.range(mass: mass)), 32, 0.05)
        )
    }
    print("Surface burst of \(Int(mass)) kg on rigid ground against the Kingery-Bulmash hemispherical")
    print(
        "surface-burst curves (Swisdak's polynomials), at scaled distances \(distances.map { format($0, 2) }.joined(separator: ", ")) m/kg^(1/3)."
    )

    var incident: [[(peak: Double, impulse: Double, arrival: Double)]] = []
    for cellSize in cellSizes {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        configure(solver)
        try solver.load(scenario)
        solver.advance(until: 0.1)
        incident.append(
            zip(scenario.gauges, solver.gaugeHistories).map { gauge, history in
                let cell = solver.nearestFluidCell(to: gauge.position)
                return (
                    Double((history.map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure) / 1000,
                    Double(solver.impulse(cell.i, cell.j, cell.k)),
                    arrivalTime(history, ambient: scenario.atmosphere.pressure) * 1000
                )
            })
    }
    print("\nIncident peak overpressure (kPa)\n" + header("range"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.incidentPressure / 1000,
                incident.map { $0[n].peak }))
    }
    print("\nIncident positive impulse (Pa s)\n" + header("range"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.incidentImpulse(mass: mass),
                incident.map { $0[n].impulse }, digits: 0))
    }
    print("\nArrival time (ms)\n" + header("range"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.arrival(mass: mass) * 1000,
                incident.map { $0[n].arrival }))
    }

    // 2. Reflected: the far x face of the domain becomes a rigid wall at each stand-off.
    var reflected: [[(peak: Double, impulse: Double)]] = []
    for cellSize in cellSizes {
        var column: [(peak: Double, impulse: Double)] = []
        for point in points {
            var wall = ScenarioPreset.openGround.scenario
            wall.reflectiveFaces = [.zMin, .xMax]
            wall.charge.position = SIMD3(64 - Float(point.range(mass: mass)), 32, 0)
            wall.gauges = [Gauge("Wall", at: SIMD3(63.99, 32, 0.05))]
            let solver = try BlastSolver(device: device, scenario: wall, cellSize: cellSize)
            configure(solver)
            try solver.load(wall)
            solver.advance(until: 0.1)
            let cell = solver.nearestFluidCell(to: wall.gauges[0].position)
            column.append(
                (
                    Double((solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - wall.atmosphere.pressure)
                        / 1000,
                    Double(solver.impulse(cell.i, cell.j, cell.k))
                ))
        }
        reflected.append(column)
    }
    print("\nReflected peak overpressure on a rigid wall (kPa)\n" + header("stand-off"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.reflectedPressure / 1000,
                reflected.map { $0[n].peak }))
    }
    print("\nReflected positive impulse on a rigid wall (Pa s)\n" + header("stand-off"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.reflectedImpulse(mass: mass),
                reflected.map { $0[n].impulse }, digits: 0))
    }

    // 3. Kinney-Graham free air, for twice the mass (perfectly rigid ground acts as a mirror).
    let open = ScenarioPreset.openGround.scenario
    let equivalentMass = 2 * mass
    print("\nThe same burst against Kinney-Graham free air for \(Int(equivalentMass)) kg.")
    var peaks: [[Double]] = []
    var impulses: [[Double]] = []
    for cellSize in cellSizes {
        let solver = try BlastSolver(device: device, scenario: open, cellSize: cellSize)
        configure(solver)
        try solver.load(open)
        solver.advance(until: 0.1)
        peaks.append(
            solver.gaugeHistories.map { history in
                Double((history.map(\.pressure).max() ?? 0) - open.atmosphere.pressure) / 1000
            })
        impulses.append(
            open.gauges.map { gauge in
                let cell = solver.nearestFluidCell(to: gauge.position)
                return Double(solver.impulse(cell.i, cell.j, cell.k))
            })
    }
    print("\nPeak overpressure (kPa)\n" + header("range"))
    for (n, gauge) in open.gauges.enumerated() {
        let range = Double(simd_distance(gauge.position, open.charge.position))
        print(
            row(
                "\(format(range, 0)) m",
                KinneyGraham.peakOverpressure(mass: equivalentMass, range: range) / 1000, peaks.map { $0[n] })
        )
    }
    print("\nPositive impulse (Pa s)\n" + header("range"))
    for (n, gauge) in open.gauges.enumerated() {
        let range = Double(simd_distance(gauge.position, open.charge.position))
        print(
            row(
                "\(format(range, 0)) m", KinneyGraham.positiveImpulse(mass: equivalentMass, range: range),
                impulses.map { $0[n] }, digits: 0))
    }
}

func runSnapshot() throws {
    var scenario = chosenScenario()
    if let mass = option("mass").flatMap({ Float($0) }) { scenario.charge.mass = mass }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let time = option("time").flatMap { Double($0) } ?? 0.03
    let output = option("out") ?? "snapshot.png"
    let width = option("width").flatMap { Int($0) } ?? 1600
    let height = option("height").flatMap { Int($0) } ?? 1000

    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    solver.configuration.movingWalls = !flag("stationary-walls")
    let started = ContinuousClock.now
    var sleptAt: Double?
    var largest: Float = 0  // the structure's largest deflection, sampled every batch
    while solver.time < time - 1e-9 {
        let result = solver.advance(steps: 64, timeLimit: time)
        if solver.airIsAsleep, sleptAt == nil { sleptAt = solver.time }
        if let summary = solver.bodySummary() { largest = max(largest, summary.maxDisplacement) }
        if result.steps == 0 || !result.isStable { break }
    }
    let wall = ContinuousClock.now - started
    solver.refreshVisualization()

    let renderer = try SceneRenderer(device: device)
    renderer.setScene(scenario, solver: solver)
    switch option("mode") {
    case "now": renderer.settings.mode = .overpressure
    case "impulse": renderer.settings.mode = .impulse
    default: renderer.settings.mode = .peakOverpressure
    }
    renderer.settings.showWave = !flag("no-wave")
    if flag("highlight") {
        renderer.settings.highlight = scenario.structure?.solids.first ?? scenario.boxes.first
    }
    if let opacity = option("opacity").flatMap({ Float($0) }) { renderer.settings.waveOpacity = opacity }
    if let scale = option("scale").flatMap({ Float($0) }) { renderer.settings.pressureScale = scale }
    renderer.settings.showCharge = time == 0
    var camera = OrbitCamera.framing(scenario)
    if let distance = option("distance").flatMap({ Float($0) }) { camera.distance = distance }
    if let azimuth = option("azimuth").flatMap({ Float($0) }) { camera.azimuth = azimuth }
    if let elevation = option("elevation").flatMap({ Float($0) }) { camera.elevation = elevation }

    guard
        let frame = renderer.snapshot(
            commandQueue: solver.commandQueue, width: width, height: height, camera: camera),
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        print("Could not render the snapshot")
        exit(1)
    }
    CGImageDestinationAddImage(destination, frame.image, nil)
    CGImageDestinationFinalize(destination)
    print(
        "Wrote \(output): t = \(format(solver.time * 1000)) ms after \(solver.stepCount) steps, "
            + "frame rendered in \(format(frame.gpuSeconds * 1000, 2)) ms")
    print(
        "Simulated in \(format(Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18, 1)) s"
            + (sleptAt.map { "; the air went quiet and was frozen at \(format($0 * 1000, 0)) ms" } ?? ""))
    if let summary = solver.bodySummary() {
        print(
            "Structure: \(summary.activeElements) elements intact, \(summary.erodedElements) failed, "
                + "deflection \(format(Double(summary.maxDisplacement) * 1000, 0)) mm "
                + "(largest \(format(Double(largest) * 1000, 0)) mm), "
                + "worst damage \(format(Double(min(summary.maxDamage, 1)) * 100, 0))%")
    }
}

/// Times a structure meshed with shells (and beams) on its own.
func runShellStructure(_ base: StructureModel) throws {
    var model = base
    model.elementKind = .shell
    model.elementSize = option("shells").flatMap { Float($0) } ?? 0.25
    if let layers = option("shell-layers").flatMap({ Int($0) }) { model.shellLayers = layers }
    let solver = try ShellSolver(device: device, model: model)
    if flag("contact") { solver.contactMode = .always }
    solver.advance(steps: 200)
    let steps = 4000
    let start = ContinuousClock.now
    solver.advance(steps: steps)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let stepSeconds = Double(solver.criticalTimeStep)
    let count = solver.elementCount + solver.beamCount
    print(
        "Structure: \(solver.elementCount) shells and \(solver.beamCount) beams of "
            + "\(format(Double(model.elementSize) * 1000, 0)) mm, \(model.shellLayers) layers, "
            + "time step \(format(stepSeconds * 1e6, 1)) µs, \(format(Double(solver.memoryFootprint) / 1e6, 0)) MB"
    )
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(count) / seconds / 1e6, 1)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 1))x slower than real time")
}

/// Times the structural solver on its own, without the air.
func runStructure() throws {
    guard var model = preset(named: option("preset") ?? "box").scenario.structure else {
        print("That preset has no deformable structure; try --preset wall or --preset box.")
        return
    }
    if flag("elastic") {
        // The same mesh with a linear elastic material, to show what the concrete law costs.
        let concrete = model.material
        model.material = .elastic(
            density: concrete.density, youngsModulus: concrete.youngsModulus,
            poissonRatio: concrete.poissonRatio)
        model.reinforcement = []
    }
    if flag("shells") || option("shells") != nil {
        try runShellStructure(model)
        return
    }
    let solver = try StructureSolver(device: device, model: model)
    if flag("contact") { solver.contactMode = .always }
    solver.advance(steps: 200)
    let steps = 4000
    let start = ContinuousClock.now
    solver.advance(steps: steps)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let stepSeconds = Double(solver.criticalTimeStep)
    print("Device: \(device.name)")
    print(
        "Structure: \(solver.elementCount) hexahedral elements of \(format(Double(model.elementSize) * 1000, 1)) mm, "
            + "\(model.material.name.lowercased()), time step \(format(stepSeconds * 1e6, 1)) µs, "
            + "contact \(solver.contactMode == .always ? "on" : "off until something fails"), "
            + "\(format(Double(solver.memoryFootprint) / 1e6, 0)) MB")
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(solver.elementCount) / seconds / 1e6, 0)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 0))x slower than real time")
}

/// Compares the structural model with the measured response of the Blast Blind Simulation
/// Contest's normal-strength slab.
/// Janney's reinforced beam bent slowly to failure, against the measured moment and deflection.
func runBeam() throws {
    print("Reinforced concrete beam in four-point bending (Janney, Hognestad and McHenry, 1956)")
    print(
        "Measured: yield near 37 kN m at 11 mm, \(format(Double(BeamBenchmark.measuredPeakMoment) / 1000)) kN m "
            + "at failure, \(format(Double(BeamBenchmark.measuredFailureDeflection) * 1000, 0)) mm; "
            + "section analysis \(format(Double(BeamBenchmark.sectionMoment) / 1000)) kN m\n")
    // `--layers 12,24` chooses the meshes, by elements through the depth; `--rate` the plates' speed (m/s).
    let meshes = (option("layers") ?? "12,24").split(separator: ",").compactMap { Int($0) }
    let rate = option("rate").flatMap { Float($0) } ?? 0.1
    var results: [(layers: Int, result: BeamBenchmark.Result)] = []
    print(
        pad("layers", 8) + pad("elements", 10) + pad("peak", 12) + pad("vs test", 9) + pad("fails at", 10)
            + pad("rms", 10) + pad("failed", 8) + pad("run time", 10))
    for layers in meshes {
        // `--crack-spacing 25` sets the distance, in millimetres, a crack's energy is spread over.
        let spacing = option("crack-spacing").flatMap { Float($0) }
        let dowel = option("dowel").flatMap { Float($0) }
        let result = try BeamBenchmark.run(
            device: device, elementsThroughDepth: layers, rate: rate, crackAxes: chosenCrackAxes()
        ) { material in
            if let spacing { material.crackSpacing = spacing / 1000 }
            if let dowel { material.dowelFactor = dowel }
        }
        results.append((layers, result))
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                + pad("\(format(Double(result.peakMoment) / 1000)) kN m", 12)
                + pad("\(format(Double(result.peakMoment / BeamBenchmark.measuredPeakMoment) * 100, 0))%", 9)
                + pad(result.failureDeflection.map { "\(format(Double($0) * 1000, 0)) mm" } ?? "holds", 10)
                + pad("\(format(Double(result.curveError()) / 1000)) kN m", 10)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
    }
    print("\nMid-span moment (kN m) against central deflection:")
    print(
        pad("deflection", 12) + pad("measured", 10) + results.map { pad("\($0.layers) layers", 12) }.joined())
    for millimetres in [1, 2, 5, 8, 10, 12, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60] {
        let deflection = Float(millimetres) / 1000
        let measured =
            deflection <= BeamBenchmark.measuredFailureDeflection
            ? format(Double(BeamBenchmark.measuredMoment(at: deflection)) / 1000) : "failed"
        print(
            pad("\(millimetres) mm", 12) + pad(measured, 10)
                + results.map { pad(format(Double($0.result.moment(at: deflection)) / 1000), 12) }.joined())
    }
}

/// A 1 kg charge burst in the air at each scaled distance above rigid ground, against the
/// Kingery-Bulmash reflected peak and impulse under it (the surface-burst curves at W / 1.8).
func runCloseAir() throws {
    let distances = option("z").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.3, 0.5, 0.75, 1]
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.02
    print("1 kg TNT burst in the air above rigid ground, reflected square on below it; cells \(format(Double(cellSize), 3)) m")
    print(pad("Z", 6) + pad("K-B peak", 12) + pad("model", 14) + pad("K-B impulse", 14) + pad("model", 16))
    for z in distances {
        let height = z
        let size = max(3 * height, 1.2)
        var scenario = Scenario(
            name: "Close-in reflection", domainSize: SIMD3(size, size, 2 * height + 0.4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(size / 2, size / 2, height)),
            gauges: [
                Gauge(
                    "ground",
                    // In the air cell against the ground, refined or not: a cell further up misses
                    // the momentum the gas still carries towards it.
                    at: SIMD3(size / 2, size / 2, (option("gauge-cells").flatMap { Float($0) } ?? 0.25) * cellSize))
            ])
        scenario.reflectiveFaces = .ground
        let solver = try makeAirSolver(scenario, cellSize: cellSize)
        solver.advance(until: Double(height) / 340 + 0.004)
        let samples = solver.gaugeHistories[0]
        let ambient = scenario.atmosphere.pressure
        let peak = (samples.map(\.pressure).max() ?? ambient) - ambient
        var impulse: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
        }
        let w = 1.0 / 1.8
        guard let point = KingeryBulmash.point(at: Double(height) / cbrt(w)) else { continue }
        if flag("field") {
            let cell = solver.nearestFluidCell(to: scenario.gauges[0].position)
            print("  field at the gauge: peak \(format(Double(solver.peakOverpressure(cell.i, cell.j, cell.k)) / 1e6, 1)) MPa, impulse \(format(Double(solver.impulse(cell.i, cell.j, cell.k)), 0)) Pa s; \(samples.count) samples")
        }
        print(
            pad(format(Double(z), 2), 6) + pad("\(format(point.reflectedPressure / 1e6, 1)) MPa", 12)
                + pad("\(format(Double(peak) / 1e6, 1)) (\(format(Double(peak) / point.reflectedPressure * 100, 0))%)", 14)
                + pad("\(format(point.reflectedImpulse(mass: w), 0)) Pa s", 14)
                + pad("\(format(Double(impulse), 0)) (\(format(Double(impulse) / point.reflectedImpulse(mass: w) * 100, 0))%)", 16))
    }
}

/// Chiquito et al.'s full-scale slabs under charges hung 0.5 and 1 m above them.
func runCloseIn() throws {
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.05
    let elementSize = option("h").flatMap { Float($0) } ?? 0.025
    let duration = option("time").flatMap { Double($0) } ?? 0.3
    let refinement = option("refine").flatMap { Int($0) } ?? 1
    print("Full-scale slabs under close-in charges (Chiquito et al., 2023)")
    print(
        "Air cells \(format(Double(cellSize), 3)) m\(refinement > 1 ? ", refined by \(refinement)" : ""), "
            + "elements \(format(Double(elementSize), 3)) m, \(format(duration * 1000, 0)) ms\n")
    func percent(_ value: Float?) -> String { value.map { "\(format(Double($0) * 100, 1))%" } ?? "-" }
    func mm(_ value: Float?) -> String { value.map { "\(format(Double($0) * 1000, 0))" } ?? "-" }
    for test in CloseInSlabTest.tests where names?.contains(test.name) ?? true {
        let result = try CloseInSlabTest.run(
            device: device, test: test, cellSize: cellSize, elementSize: elementSize, duration: duration,
            refinement: refinement, mappedCharge: !flag("no-map"), afterburning: flag("afterburn"),
            heldLengthwise: !flag("sliding"),
            adjust: { scenario in
                if flag("no-rate") { scenario.structure?.material.rateDependent = false }
                if let scale = option("charge-scale").flatMap({ Float($0) }) { scenario.charge.mass *= scale }
                if let dowel = option("dowel").flatMap({ Float($0) }) { scenario.structure?.material.dowelFactor = dowel }
            },
            progress: flag("progress")
                ? { line in
                    print("  " + line)
                    fflush(stdout)
                } : nil)
        print("\(test.name): \(format(Double(test.charge), 2)) kg TNT at \(format(Double(test.standoff), 1)) m; \(test.remark)")
        print("                      measured        model")
        print(
            "  permanent (mm)      " + pad(mm(test.deflection), 15) + "  \(mm(result.permanent)) (peak \(mm(result.peak)))")
        print("  spalled, top        " + pad(percent(test.damagedTop), 15) + "  \(percent(result.damagedTop))")
        print("  spalled, bottom     " + pad(percent(test.damagedBottom), 15) + "  \(percent(result.damagedBottom))")
        print("  perforated          " + pad(test.perforated ? "yes" : "no", 15) + "  \(result.perforated ? "yes" : "no")")
        let measured = [test.nearGauge, test.nearGauge, test.farGauge, test.farGauge, nil, nil]
        for ((name, pressure), range) in zip(result.gaugePeaks, measured) {
            let text = range.map { $0.lowerBound == $0.upperBound
                ? format(Double($0.lowerBound) / 1e6, 2) : "\(format(Double($0.lowerBound) / 1e6, 2))-\(format(Double($0.upperBound) / 1e6, 2))" } ?? "-"
            print("  \(pad(name + " (MPa)", 18))  " + pad(text, 15) + "  \(format(Double(pressure) / 1e6, 2))")
        }
        print("  impulse at the slab's centre: \(format(Double(result.gaugeImpulses.last ?? 0), 0)) Pa s")
        print("  slab's momentum at 5 ms: \(format(Double(result.impulse), 0)) N s")
        print("  \(result.summary.erodedElements) elements failed; \(format(result.wallSeconds, 0)) s\n")
    }
}

/// Saatci's beams struck by a falling weight (first impacts), against the measured peak and
/// residual mid-span displacements.
func runImpact() throws {
    print("Saatci's beams (2007), struck at mid-span by a weight falling at 8 m/s; first impacts\n")
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let layers = option("layers").flatMap { Int($0) } ?? 16
    let duration = option("time").flatMap { Double($0) } ?? 0.2
    print(
        pad("test", 8) + pad("weight", 8) + pad("measured", 18) + pad("model", 18) + pad("reaction", 18)
            + pad("failed", 8) + pad("run time", 10))
    if let size = option("beams").flatMap({ Float($0) }) {
        print(pad("test", 8) + pad("weight", 8) + pad("measured", 18) + pad("beams", 18) + pad("reaction", 18) + pad("sheared", 9) + pad("removed", 9))
        for test in ImpactBenchmark.tests where names?.contains(test.name) ?? true {
            let result = try ImpactBenchmark.runBeams(
                device: device, test: test, size: size, duration: duration, sectionShear: !flag("no-section-shear"))
            let measured =
                test.peak.map { "\(format(Double($0) * 1000)) / \(format(Double(test.residual ?? 0) * 1000)) mm" }
                ?? "failed"
            print(
                pad(test.name, 8) + pad("\(Int(test.weight)) kg", 8) + pad(measured, 18)
                    + pad("\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm", 18)
                    + pad("\(Int(test.reaction / 1000)) / \(format(Double(result.peakReaction) / 1000, 0)) kN", 18)
                    + pad("\(result.sheared)", 9) + pad("\(result.removed)", 9))
        }
        return
    }
    for test in ImpactBenchmark.tests where names?.contains(test.name) ?? true {
        let result = try ImpactBenchmark.run(
            device: device, test: test, elementsThroughDepth: layers, duration: duration
        ) { model in
            if flag("no-rate") { model.material.rateDependent = false }
        }
        let measured =
            test.peak.map { "\(format(Double($0) * 1000)) / \(format(Double(test.residual ?? 0) * 1000)) mm" }
            ?? "failed"
        print(
            pad(test.name, 8) + pad("\(Int(test.weight)) kg", 8) + pad(measured, 18)
                + pad("\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm", 18)
                + pad("\(Int(test.reaction / 1000)) / \(format(Double(result.peakReaction) / 1000, 0)) kN", 18)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
    }
    print(
        "\nPeak / residual mid-span displacement, the residual the mean over the last 30 ms; largest"
            + " support reaction, measured / model.")
}

/// Vecchio and Shim's beam OA1, with no stirrups, pushed to its diagonal-tension failure.
func runShearBeam() throws {
    print("Beam OA1 of Vecchio and Shim (2004), no stirrups, failing in diagonal tension")
    print(
        "Measured: peak \(format(Double(ShearBeamBenchmark.measuredPeak) / 1000, 0)) kN at "
            + "\(format(Double(ShearBeamBenchmark.measuredPeakDeflection) * 1000)) mm, then a sudden drop\n")
    let meshes = (option("layers") ?? "12,24").split(separator: ",").compactMap { Int($0) }
    let rate = option("rate").flatMap { Float($0) } ?? 0.05
    var results: [(layers: Int, result: ShearBeamBenchmark.Result)] = []
    print(
        pad("layers", 8) + pad("elements", 10) + pad("peak", 10) + pad("vs test", 9) + pad("at", 9)
            + pad("failed", 8) + pad("run time", 10))
    for layers in meshes {
        // `--dowel 0.5` scales the bars' dowel action.
        let dowel = option("dowel").flatMap { Float($0) }
        // `--slice 92` models a slice of the beam that many millimetres wide.
        let slice = option("slice").flatMap { Float($0) }.map { $0 / 1000 }
        let result = try ShearBeamBenchmark.run(
            device: device, elementsThroughDepth: layers, slice: slice, rate: rate,
            crackAxes: chosenCrackAxes()
        ) { material in
            if let dowel { material.dowelFactor = dowel }
            // `--crack-spacing 25` (mm) and `--aggregate 10` (mm), for studying the shear strength.
            if let spacing = option("crack-spacing").flatMap({ Float($0) }) {
                material.crackSpacing = spacing / 1000
            }
            if let size = option("aggregate").flatMap({ Float($0) }) { material.aggregateSize = size / 1000 }
        }
        results.append((layers, result))
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                + pad("\(format(Double(result.peak) / 1000, 0)) kN", 10)
                + pad("\(format(Double(result.peak / ShearBeamBenchmark.measuredPeak) * 100, 0))%", 9)
                + pad("\(format(Double(result.peakDeflection) * 1000)) mm", 9)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
    }
    print("\nMid-span load (kN) against deflection:")
    print(
        pad("deflection", 12) + pad("measured", 10) + results.map { pad("\($0.layers) layers", 12) }.joined())
    for tenths in [5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 140, 160] {
        let deflection = Float(tenths) / 10000
        let measured =
            deflection <= ShearBeamBenchmark.measuredPeakDeflection
            ? format(Double(ShearBeamBenchmark.measuredLoad(at: deflection)) / 1000, 0) : "-"
        print(
            pad("\(format(Double(tenths) / 10)) mm", 12) + pad(measured, 10)
                + results.map { pad(format(Double($0.result.load(at: deflection)) / 1000, 0), 12) }.joined())
    }
}

func runSlab() throws {
    let load = SlabBenchmark.load
    print("Blast Blind Simulation Contest slab (normal-strength concrete, Grade 60 bars)")
    print(
        "Load: peak \(format(Double((load.history.map(\.y).max() ?? 0) / 6894.76))) psi after scaling the "
            + "hand-read record to the stated \(format(Double(load.impulse / 6.89476), 0)) psi ms")
    print(
        "Measured: peak \(format(Double(SlabBenchmark.measuredPeak) * 1000, 0)) mm at about "
            + "\(format(Double(SlabBenchmark.measuredPeakTime) * 1000, 0)) ms, "
            + "\(format(Double(SlabBenchmark.measuredResidual) * 1000, 0)) mm at the end of the record\n")
    print(
        pad("layers", 8) + pad("elements", 10) + pad("strength", 14) + pad("peak", 10) + pad("vs test", 9)
            + pad("at", 8) + pad("residual", 10) + pad("vs test", 9) + pad("failed", 8) + pad("run time", 10))
    var cases: [(Int, SlabBenchmark.RateTreatment)] = [
        (8, .strainRate), (4, .strainRate), (8, .designFactors), (8, .none),
    ]
    // `--layers 16,32` runs just those meshes, with the strain-rate laws; `--strip 25` runs a
    // strip of the slab that many millimetres wide, which bends the same way, for fine meshes.
    if let layers = option("layers") {
        cases = layers.split(separator: ",").compactMap { Int($0) }.map { ($0, .strainRate) }
    }
    let width = option("strip").flatMap { Float($0) }.map { $0 / 1000 } ?? SlabBenchmark.fullWidth
    var meshes: [(layers: Int, result: SlabBenchmark.Result)] = []
    // `--shells 2,1` runs shells of those sizes in inches instead, with `--shell-layers` layers.
    if let sizes = option("shells") {
        cases = []
        let layers = option("shell-layers").flatMap { Int($0) } ?? 8
        for size in sizes.split(separator: ",").compactMap({ Float($0) }) {
            let rate =
                option("shell-rate").flatMap { SlabBenchmark.RateTreatment(rawValue: $0) } ?? .strainRate
            let result = try SlabBenchmark.runShells(
                device: device, elementSize: size * 0.0254, layers: layers, rate: rate, width: width)
            meshes.append((layers, result))
            print(
                pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                    + pad("shells \(format(Double(size), 2)) in", 14)
                    + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 9)
                    + pad("\(format(Double(result.peakTime) * 1000, 0)) ms", 8)
                    + pad("\(format(Double(result.residual) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.residual / SlabBenchmark.measuredResidual) * 100, 0))%", 9)
                    + pad("\(result.summary.erodedElements)", 8)
                    + pad("\(format(result.wallSeconds, 1)) s", 10))
        }
    }
    for (layers, rate) in cases {
        // `--held-bearings` supports the slab on 1 in bearings that hold it down.
        let supports: SlabBenchmark.Supports =
            flag("held-bearings") ? .bearings(width: 0.0254, holdDown: true) : .lines
        let result = try SlabBenchmark.run(
            device: device, elementsThroughThickness: layers, rate: rate, supports: supports, width: width,
            crackAxes: chosenCrackAxes())
        if rate == .strainRate { meshes.append((layers, result)) }
        let label =
            ["none": "static", "designFactors": "UFC fixed", "strainRate": "rate laws"][rate.rawValue] ?? ""
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10) + pad(label, 14)
                + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 9)
                + pad("\(format(Double(result.peakTime) * 1000, 0)) ms", 8)
                + pad("\(format(Double(result.residual) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.residual / SlabBenchmark.measuredResidual) * 100, 0))%", 9)
                + pad("\(result.summary.erodedElements)", 8)
                + pad("\(format(result.wallSeconds, 1)) s", 10))
        if flag("history") {
            for sample in result.history where Int((sample.x * 1000).rounded()) % 5 == 0 {
                print(
                    "    t = \(format(Double(sample.x) * 1000, 2)) ms   \(format(Double(sample.y) * 1000, 1)) mm"
                )
            }
        }
    }

    // The whole history, not just its peak, against the measured record.
    print("\nMid-span displacement history (mm):")
    print(pad("time", 8) + pad("measured", 10) + meshes.map { pad("\($0.layers) layers", 11) }.joined())
    for time in stride(from: Float(0.005), through: 0.0701, by: 0.005) {
        print(
            pad("\(format(Double(time) * 1000, 0)) ms", 8)
                + pad(format(Double(SlabBenchmark.measuredDisplacement(at: time)) * 1000, 0), 10)
                + meshes.map { pad(format(Double($0.result.displacement(at: time)) * 1000, 0), 11) }.joined())
    }
    print(
        "Root-mean-square difference over the record: "
            + meshes.map { "\(format(Double($0.result.historyError) * 1000, 1)) mm (\($0.layers) layers)" }
            .joined(separator: ", "))
    print("\nPeaks the source reports for other tools on the same slab and load:")
    for other in SlabBenchmark.otherPredictions {
        print(
            "  \(format(Double(other.peak) * 1000, 0)) mm "
                + "(\(format(Double(other.peak / SlabBenchmark.measuredPeak) * 100, 0))%)  \(other.tool)")
    }

    guard flag("sensitivity") else { return }
    print("\nSensitivity of the eight-layer, rate-law result to things the source does not pin down:")
    let variants: [(String, Float, (inout StructureMaterial) -> Void)] = [
        ("load 5% lower", 0.95, { _ in }),
        ("load 5% higher", 1.05, { _ in }),
        ("aggregate 10 mm instead of 16 mm", 1, { $0.aggregateSize = 0.010 }),
        ("crack spacing 50 mm instead of 100 mm", 1, { $0.crackSpacing = 0.05 }),
        ("crack spacing 200 mm", 1, { $0.crackSpacing = 0.2 }),
        ("fracture energy halved", 1, { $0.fractureEnergy *= 0.5 }),
        ("tensile strength 20% lower", 1, { $0.tensileStrength *= 0.8 }),
        ("cracks close fully (no residual opening)", 1, { $0.crackResidual = 0 }),
        ("residual crack opening 20%", 1, { $0.crackResidual = 0.2 }),
        ("residual crack opening 30%", 1, { $0.crackResidual = 0.3 }),
        ("residual crack opening 50%", 1, { $0.crackResidual = 0.5 }),
        ("crushing spread over at least 50 mm", 1, { $0.crushBand = 0.05 }),
        ("crushing averaged over 48 mm (nonlocal)", 1, { $0.crushLength = 0.048 }),
    ]
    var runs: [(String, () throws -> SlabBenchmark.Result)] = variants.map { label, scale, adjust in
        (label, { try SlabBenchmark.run(device: device, loadScale: scale, adjust: adjust) })
    }
    let inch: Float = 0.0254
    runs.append(
        (
            "1 in bearings, held down",
            { try SlabBenchmark.run(device: device, supports: .bearings(width: inch, holdDown: true)) }
        ))
    runs.append(
        (
            "1 in bearings, free to lift",
            { try SlabBenchmark.run(device: device, supports: .bearings(width: inch, holdDown: false)) }
        ))
    if flag("convergence") {
        runs.append(
            (
                "16 elements through the thickness",
                { try SlabBenchmark.run(device: device, elementsThroughThickness: 16) }
            ))
    }
    for (label, run) in runs {
        let result = try run()
        print(
            pad(label, 40) + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 8)
                + pad("residual \(format(Double(result.residual) * 1000, 0)) mm", 16)
                + pad("history RMS \(format(Double(result.historyError) * 1000, 1)) mm", 20)
                + pad("failed \(result.summary.erodedElements)", 14))
    }
}

do {
    switch command {
    case "slab": try runSlab()
    case "beam": try runBeam()
    case "shear": try runShearBeam()
    case "impact": try runImpact()
    case "closein": try runCloseIn()
    case "closeair": try runCloseAir()
    case "gas": try runGasPressure()
    case "chamber": try runChamber()
    case "throughput": try runThroughput()
    case "structure": try runStructure()
    case "validate": try runValidation()
    case "snapshot": try runSnapshot()
    default:
        print("Unknown command \(command). Use throughput, structure, validate, slab or snapshot.")
        exit(2)
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
