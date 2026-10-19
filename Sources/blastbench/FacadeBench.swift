import BlastCore
import Foundation
import Metal
import simd

/// `blastbench facade [--mass 10] [--range 12] [--dx 0.5] [--fine]`: a closed box building's front
/// facing a surface burst, its wall panels' reflected peak and impulse as the envelope recorder
/// reads them, on coarse cells, refined once and twice, and uniform at each refined cell size;
/// with a gauge 5 cm in front of the wall's middle for comparison. The recorder reads the finest
/// cells against each face where the air is refined.
func runFacade(device: MTLDevice) throws {
    let mass = option("mass").flatMap { Float($0) } ?? 10
    let range = option("range").flatMap { Float($0) } ?? 12
    let coarse = option("dx").flatMap { Float($0) } ?? 0.5
    let scale = cbrt(mass)
    // Open faces 4 m/kg^(1/3) from the charge and the building (`Scenario.structureFaceClearance`).
    let clearance = (Scenario.structureFaceClearance * scale).rounded(.up)
    let (width, depth, height): (Float, Float, Float) = (6, 6, 4)
    let charge = SIMD3<Float>(clearance, clearance + width / 2, 0.25)
    let front = charge.x + range
    let domain = SIMD3(front + depth + clearance, width + 2 * clearance, height + clearance)
    let middle = charge.y
    let t: Float = 0.3
    let back = front + depth
    let solids = [
        Box(min: SIMD3(front, middle - width / 2, 0), max: SIMD3(front + t, middle + width / 2, height)),
        Box(min: SIMD3(back - t, middle - width / 2, 0), max: SIMD3(back, middle + width / 2, height)),
        Box(
            min: SIMD3(front + t, middle - width / 2, 0), max: SIMD3(back - t, middle - width / 2 + t, height)
        ),
        Box(
            min: SIMD3(front + t, middle + width / 2 - t, 0), max: SIMD3(back - t, middle + width / 2, height)
        ),
        Box(min: SIMD3(front, middle - width / 2, height - t), max: SIMD3(back, middle + width / 2, height)),
    ]
    let envelope = try BuildingEnvelope(solids: solids)
    let z = Double(range / scale)
    let arrival = KingeryBulmash.point(at: z)?.arrival(mass: Double(mass)) ?? 0.02
    let duration = arrival + 6e-3 * Double(scale)
    print(
        String(
            format:
                "%.0f kg at %.0f m (Z %.1f), a %.0f × %.0f × %.0f m box; domain %.0f × %.0f × %.0f m, to %.1f ms",
            mass, range, z, width, depth, height, domain.x, domain.y, domain.z, duration * 1000))
    print(
        "  air                         front wall: peak kPa  impulse Pa s   gauge: peak kPa  impulse Pa s   time"
    )
    var cases: [(String, Float, Int, Int)] = [
        ("coarse", coarse, 1, 1), ("refined once", coarse, 2, 1), ("uniform at /2", coarse / 2, 1, 1),
    ]
    if flag("fine") {
        cases += [("refined twice", coarse, 2, 2), ("uniform at /4", coarse / 4, 1, 1)]
    }
    for (name, dx, ratio, levels) in cases {
        var scene = Scenario(
            name: "Facade", domainSize: domain, boxes: [], charge: Charge(mass: mass, position: charge),
            gauges: [Gauge("Front", at: SIMD3(front - 0.05, middle, 1.5))])
        try scene.addEnvelopeObject(envelope, name: "Building")
        // The mapped start since its rerun on 19 October 2026; `--balloon-start` for the balloon it was first run on.
        var configuration =
            (flag("balloon-start")
                ? SolverConfiguration.recommended.balloonStart : SolverConfiguration.recommended)
        configuration.refinement = ratio
        configuration.refinementLevels = levels
        configureRefinement(&configuration)
        let start = ContinuousClock.now
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
        _ = solver.advance(until: duration)
        let elapsed = (ContinuousClock.now - start).components
        let took = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        // The front wall's panels: its solid (0) facing the charge (-x).
        let panels = (solver.envelopeComponentHistories() ?? []).filter {
            $0.component.kind == .wall && $0.component.source == 0
        }
        let area = panels.map(\.outerAreaM2).reduce(0, +)
        let peak = panels.map { Double($0.peakOuterPa) }.max() ?? 0
        let impulse =
            panels.map { $0.outerImpulsePaS.map(Double.init).reduce(0, +) * $0.outerAreaM2 }.reduce(0, +)
            / max(area, 1e-9)
        let ambient = scene.atmosphere.pressure
        let history = solver.gaugeHistories[0]
        print(
            name.padding(toLength: 28, withPad: " ", startingAt: 0)
                + String(
                    format: "%8.1f %13.1f %16.1f %13.1f %7.1f s", peak / 1000, impulse,
                    Double((history.map(\.pressure).max() ?? ambient) - ambient) / 1000,
                    positivePhaseImpulse(history, ambient: ambient), took))
        fflush(stdout)
    }
}
