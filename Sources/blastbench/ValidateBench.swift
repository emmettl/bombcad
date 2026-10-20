import BlastCore
import Foundation
import Metal
import simd

// `blastbench validate`.
// Split from main.swift (emmettl/bombcad-work#51).

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
        applyChosenAir(&solver.configuration)
        // The fine one-dimensional start with afterburning and hot air, as the app's default since
        // 18 October 2026; `--balloon-start` for the sphere of hot gas, `--mapped` for it otherwise.
        solver.configuration.mappedCharge =
            flag("mapped") || (solver.configuration.afterburning && !flag("balloon-start"))
        if let cells = option("mapped-cells").flatMap({ Float($0) }) {
            solver.configuration.mappedChargeCells = cells
        }
        if flag("mapped-no-burn") { solver.configuration.mappedChargeBurns = false }
        if let mixing = option("mapped-mixing").flatMap({ Float($0) }) {
            solver.configuration.mappedChargeMixing = mixing
        }
        if let time = option("burn-time").flatMap({ Float($0) }) {
            solver.configuration.afterburnTime = time / 1000
        }
        configureRefinement(&solver.configuration)
        solver.configuration.radiativeCooling = try? chosenCooling()
        solver.configuration.gravity = chosenGravity()
        solver.configuration.mixing = chosenMixing()
        solver.configuration.afterburnLimit = chosenBurnLimit()
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
    // `--mass 10`: another charge, the domain scaled with its cube root, so the gauges keep their
    // scaled distances.
    var massScale: Float = 1
    if let chosen = option("mass").flatMap({ Float($0) }) {
        massScale = cbrt(chosen / scenario.charge.mass)
        scenario.charge.mass = chosen
    }
    let mass = Double(scenario.charge.mass)
    // Scaled distances from close in to as far as the domain allows (`--z` overrides).
    let distances =
        option("z").map { $0.split(separator: ",").compactMap { Double($0) } }
        ?? [0.75, 1, 1.5, 2, 3, 4, 5, 6]
    let points = distances.compactMap { KingeryBulmash.point(at: $0) }
    // `--domain-scale 2`: the domain this many times larger, charge and gauges in its middle, to
    // see what its open faces send back.
    let scale = (option("domain-scale").flatMap { Float($0) } ?? 1) * massScale
    scenario.domainSize = (scenario.domainSize * scale).rounded(.up)
    let centre = (32 * scale).rounded()
    scenario.charge.position = SIMD3(centre, centre, 0)
    scenario.gauges = points.map { point in
        Gauge(
            "Z = \(format(point.scaledDistance, 2))",
            at: SIMD3(centre + Float(point.range(mass: mass)), centre, 0.05)
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
        solver.advance(until: option("until").flatMap { Double($0) } ?? 0.1)
        if let directory = option("histories") {
            // Each gauge's whole history (`--until` past the positive phase for the negative one).
            for (gauge, history) in zip(scenario.gauges, solver.gaugeHistories) {
                let rows = history.map { "\($0.time * 1000),\($0.pressure - scenario.atmosphere.pressure)" }
                let name = gauge.name.replacingOccurrences(of: " ", with: "")
                try? (["time_ms,overpressure_pa"] + rows).joined(separator: "\n")
                    .write(
                        toFile:
                            "\(directory)/validate-\(option("tag").map { $0 + "-" } ?? "")dx\(cellSize)-\(name).csv",
                        atomically: true,
                        encoding: .utf8)
            }
        }
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

    // With `--histories` the incident histories are what is wanted; the rest is skipped.
    if option("histories") != nil { return }

    // 2. Reflected: the far x face of the domain becomes a rigid wall at each stand-off.
    var reflected: [[(peak: Double, impulse: Double)]] = []
    for cellSize in cellSizes {
        var column: [(peak: Double, impulse: Double)] = []
        for point in points {
            // Each solver let go before the next is made: at 0.125 m one holds 67 million cells,
            // about 6.7 GB, and eight left to the end of the loop took the Studio into swap.
            let value = try autoreleasepool { () throws -> (peak: Double, impulse: Double) in
                var wall = ScenarioPreset.openGround.scenario
                // The charge `--mass` chose, at the stand-offs its scaled distances give.
                wall.charge.mass = scenario.charge.mass
                wall.reflectiveFaces = [.zMin, .xMax]
                wall.charge.position = SIMD3(64 - Float(point.range(mass: mass)), 32, 0)
                wall.gauges = [Gauge("Wall", at: SIMD3(63.99, 32, 0.05))]
                let solver = try BlastSolver(device: device, scenario: wall, cellSize: cellSize)
                configure(solver)
                try solver.load(wall)
                solver.advance(until: 0.1)
                let cell = solver.nearestFluidCell(to: wall.gauges[0].position)
                return (
                    Double((solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - wall.atmosphere.pressure)
                        / 1000,
                    Double(solver.impulse(cell.i, cell.j, cell.k))
                )
            }
            column.append(value)
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
