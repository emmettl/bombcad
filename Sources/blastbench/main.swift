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
//   blastbench [throughput] [--preset open|single|street|courtyard|wall|box|frame] [--full]
//   blastbench structure [--preset wall|box] [--contact]
//   blastbench validate [--dx 0.25]
//   blastbench slab [--history] [--sensitivity]
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
    default: .streetCanyon
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
    let scenario = preset(named: option("preset")).scenario
    let event = scenario.acousticCrossingTime
    print("Device: \(device.name)")
    print(
        "Scenario: \(scenario.name), \(Int(scenario.charge.mass)) kg TNT equivalent, "
            + "\(format(event * 1000, 0)) ms event (charge to farthest corner at ambient sound speed)")
    print("")
    print(
        pad("cell", 8) + pad("cells", 12) + pad("memory", 10) + pad("steps/s", 10) + pad("Mcell/s", 10)
            + pad("slow-mo", 10) + pad("steps", 8) + pad("event wall time", 20))

    var stepsPerMetre = 0.0
    for cellSize in [Float(0.5), 0.25, 0.125] {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        let cells = solver.grid.cellCount
        // Run the whole event unless it would take minutes; then time a sample and extrapolate
        // the step count from the previous, coarser run.
        let runWholeEvent = cells < 20_000_000 || flag("full")
        let start = ContinuousClock.now
        var steps = 0
        if runWholeEvent {
            steps = solver.advance(until: event).steps
        } else {
            steps = solver.advance(steps: 192).steps
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let stepRate = Double(steps) / seconds

        var totalSteps = Double(steps)
        var wallTime = seconds
        if runWholeEvent {
            stepsPerMetre = Double(steps) * Double(cellSize)
        } else {
            // The step count scales inversely with cell size.
            totalSteps = stepsPerMetre / Double(cellSize)
            wallTime = totalSteps / stepRate
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
                + pad("\(format(wallTime, 1)) s" + (runWholeEvent ? "" : " (est.)"), 20))
    }
}

/// Time at which a gauge's overpressure first reaches half of its peak, in seconds.
func arrivalTime(_ history: [GaugeSample], ambient: Float) -> Double {
    let peak = (history.map(\.pressure).max() ?? ambient) - ambient
    return history.first { $0.pressure - ambient >= 0.5 * peak }?.time ?? 0
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
    let points = KingeryBulmash.hemisphericalSurfaceBurst
    scenario.gauges = points.map { point in
        Gauge(
            "Z = \(format(point.scaledDistance, 2))", at: SIMD3(32 + Float(point.range(mass: mass)), 32, 0.05)
        )
    }
    print("Surface burst of \(Int(mass)) kg on rigid ground against Kingery-Bulmash (hemispherical surface")
    print("burst), at the three scaled distances tabulated in IATG 01.80.")

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
    var scenario = preset(named: option("preset")).scenario
    if let mass = option("mass").flatMap({ Float($0) }) { scenario.charge.mass = mass }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let time = option("time").flatMap { Double($0) } ?? 0.03
    let output = option("out") ?? "snapshot.png"
    let width = option("width").flatMap { Int($0) } ?? 1600
    let height = option("height").flatMap { Int($0) } ?? 1000

    let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
    solver.configuration.movingWalls = !flag("stationary-walls")
    let started = ContinuousClock.now
    var sleptAt: Double?
    while solver.time < time - 1e-9 {
        let result = solver.advance(steps: 64, timeLimit: time)
        if solver.airIsAsleep, sleptAt == nil { sleptAt = solver.time }
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
    if let summary = solver.structure?.summary() {
        print(
            "Structure: \(summary.activeElements) elements intact, \(summary.erodedElements) failed, "
                + "peak deflection \(format(Double(summary.maxDisplacement) * 1000, 0)) mm, "
                + "worst damage \(format(Double(min(summary.maxDamage, 1)) * 100, 0))%")
    }
}

/// Times the structural solver on its own, without the air.
func runStructure() throws {
    guard let model = preset(named: option("preset") ?? "box").scenario.structure else {
        print("That preset has no deformable structure; try --preset wall or --preset box.")
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
            + "contact \(solver.contactMode == .always ? "on" : "off until something fails")")
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(solver.elementCount) / seconds / 1e6, 0)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 0))x slower than real time")
}

/// Compares the structural model with the measured response of the Blast Blind Simulation
/// Contest's normal-strength slab.
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
    let cases: [(Int, SlabBenchmark.RateTreatment)] = [
        (8, .strainRate), (4, .strainRate), (8, .designFactors), (8, .none),
    ]
    for (layers, rate) in cases {
        let result = try SlabBenchmark.run(device: device, elementsThroughThickness: layers, rate: rate)
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
    let fine = try SlabBenchmark.run(device: device, elementsThroughThickness: 8)
    let coarse = try SlabBenchmark.run(device: device, elementsThroughThickness: 4)
    print("\nMid-span displacement history (mm):")
    print(pad("time", 8) + pad("measured", 10) + pad("8 layers", 10) + pad("4 layers", 10))
    for time in stride(from: Float(0.005), through: 0.0701, by: 0.005) {
        print(
            pad("\(format(Double(time) * 1000, 0)) ms", 8)
                + pad(format(Double(SlabBenchmark.measuredDisplacement(at: time)) * 1000, 0), 10)
                + pad(format(Double(fine.displacement(at: time)) * 1000, 0), 10)
                + pad(format(Double(coarse.displacement(at: time)) * 1000, 0), 10))
    }
    print(
        "Root-mean-square difference over the record: \(format(Double(fine.historyError) * 1000, 1)) mm "
            + "(8 layers), \(format(Double(coarse.historyError) * 1000, 1)) mm (4 layers)")
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
    ]
    for (label, scale, adjust) in variants {
        let result = try SlabBenchmark.run(device: device, loadScale: scale, adjust: adjust)
        print(
            pad(label, 40) + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 8)
                + pad("failed \(result.summary.erodedElements)", 14))
    }
}

do {
    switch command {
    case "slab": try runSlab()
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
