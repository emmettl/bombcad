import BlastCore
import Foundation
import Metal

// `blastbench envelope-debris [--charge 80] [--dx 0.1] [--time 0.03]`: the Norwegian and Swedish
// Kasun cubicle (Kummer, IESS 2018, Fig. 11; Weerheijm and Conway, IESS 2018): 2 × 2 × 2 m inside,
// walls and roof of 0.15 m reinforced concrete in both faces, on the ground, the charge in its
// middle. As an envelope, its walls and roof judged one way on the air's load from inside, those
// that fail thrown (`EnvelopeDebris`): their launch speeds against the Klotz Group's debris launch
// velocity, 525 √(γ L / M) m/s (γ the loading density, kg/m³; L the cube root of the volume, m; M
// the wall's mass per area, kg/m²), and the distance where hazardous debris falls below 1 per
// 55.7 m² against the tests' 290–315 m at 80 kg.
func runEnvelopeDebris(device: MTLDevice) throws {
    let charge = option("charge").flatMap { Float($0) } ?? 80
    let dx = option("dx").flatMap { Float($0) } ?? 0.1
    let duration = option("time").flatMap { Double($0) } ?? 0.03
    let wall: Float = 0.15
    let inside: Float = 2
    let origin = SIMD3<Float>(4, 4, 0)
    let outer = inside + 2 * wall
    let solids = [
        Box(min: origin, max: origin + SIMD3(outer, wall, inside)),
        Box(min: origin + SIMD3(0, wall + inside, 0), max: origin + SIMD3(outer, outer, inside)),
        Box(min: origin + SIMD3(0, wall, 0), max: origin + SIMD3(wall, wall + inside, inside)),
        Box(min: origin + SIMD3(wall + inside, wall, 0), max: origin + SIMD3(outer, wall + inside, inside)),
        Box(min: origin + SIMD3(0, 0, inside), max: origin + SIMD3(outer, outer, inside + wall)),
    ]
    let middle = origin + SIMD3(outer / 2, outer / 2, inside / 2)
    var scenario = Scenario(
        name: "Kasun", domainSize: SIMD3(2 * origin.x + outer, 2 * origin.y + outer, 6), boxes: [],
        charge: Charge(mass: charge, position: middle),
        gauges: [Gauge("Inside", at: origin + SIMD3(wall + 0.4, wall + 0.4, 0.4))])
    let owner = try scenario.addEnvelopeObject(BuildingEnvelope(solids: solids), name: "Kasun")
    scenario.setEnvelopeConstruction(
        EnvelopeConstruction(
            objectID: owner, walls: .reinforcedConcrete, wallThicknessM: wall, roof: .reinforcedConcrete,
            roofThicknessM: wall, source: .user, detail: "0.15 m reinforced concrete, bars in both faces",
            barsInBothFaces: true))
    var configuration = SolverConfiguration.recommended
    configuration.airSleepThreshold = 0
    configuration.airSleepCrossings = 0
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: dx, configuration: configuration)
    try solver.configureEnvelopeComponents(
        objects: scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
    // Walls that fail open in the air, and the gas leaves through them (`--closed` keeps them shut).
    if !flag("closed") {
        try solver.configureEnvelopeVenting(
            objects: scenario.envelopeObjects, constructions: { scenario.envelopeConstruction(for: $0) })
    }
    while solver.time < duration {
        if solver.advance(steps: 16, timeLimit: duration).steps == 0 { break }
    }
    let vented = solver.envelopeVentingSnapshot()
    // Whether the walls opened, and the pressure inside, a corner 0.4 m in, falling as the gas left.
    let opened = (vented?.walls ?? []).filter { $0.failedAtS != nil }
    print(
        "Venting opened \(opened.count) of \(vented?.walls.count ?? 0) walls and roofs"
            + (opened.isEmpty
                ? "" : String(format: ", the first at %.1f ms", 1000 * opened.compactMap(\.failedAtS).min()!))
    )
    if let samples = solver.gaugeHistories.first {
        let times = [0.002, 0.005, 0.01, 0.02, duration - 1e-4]
        print(
            "Inside, overpressure "
                + times.map { t in
                    let sample = samples.min { abs($0.time - t) < abs($1.time - t) }
                    return String(
                        format: "%.0f kPa at %.0f ms", ((sample?.pressure ?? 101_325) - 101_325) / 1000,
                        t * 1000)
                }.joined(separator: ", "))
    }
    let loads = (solver.envelopeComponentHistories() ?? []).filter {
        !$0.invalid || vented?.keeps($0) == true
    }
    .map(EnvelopeComponentLoad.init)
    let damage = EnvelopeDamageAssessment.assess(
        loads: loads, constructions: { scenario.envelopeConstruction(for: $0) },
        rooms: [owner: EnvelopeDamageAssessment.roomVolume(of: scenario.envelopeObjects[0].envelope!)],
        vented: vented)
    for component in damage.flatMap(\.components) {
        let load = loads.first { $0.id == component.id }
        let impulse = (load?.netPa ?? []).reduce(0) { $0 + min($1, 0) } * (load?.binS ?? 0)
        print(
            String(
                format: "%@ %@: outward impulse %.0f Pa s, %.1f°, %@%@", component.kind.rawValue,
                String(component.id.split(separator: "/").dropFirst().joined(separator: "/")),
                -impulse, component.rotationDeg.upperBound, component.levels.upperBound.label,
                component.launch.map {
                    String(
                        format: ", thrown at %.1f m/s (largest deflection), %.1f ms", $0.speedMS,
                        $0.timeS * 1000)
                } ?? ""))
    }
    let volume = inside * inside * inside
    let launch = 525 * (charge / volume * cbrt(volume) / (2400 * wall)).squareRoot()
    print(String(format: "The Klotz Group's debris launch velocity: %.0f m/s", launch))
    guard let debris = solver.envelopeDebris(scenario: scenario, loads: loads, damage: damage) else {
        print("Nothing thrown.")
        return
    }
    for source in debris.sources {
        print(
            String(
                format: "  %@ thrown: %.0f kg in %.0f pieces of %.1f kg, fastest %.0f m/s, mean %.0f m/s",
                String(source.component.split(separator: "/").dropFirst().joined(separator: "/")),
                source.massKg, source.pieces, source.pieceKg,
                source.fastestMS, source.meanMS))
    }
    print(debris.summary)
    print(
        "M"
            + MinimumSafeDistance(kilograms: charge, fragments: nil, debris: debris.hazard, inStructure: true)
            .summary
            .dropFirst())
    print("Measured (Kasun, 80 kg): 1 hazardous piece per 56 m² at 290–315 m; the Klotz Group's tool 260 m")
}
