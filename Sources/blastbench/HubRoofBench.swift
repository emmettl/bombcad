import BlastCore
import Foundation
import Metal

/// `blastbench hubroof [--laminated] [--dx 0.5] [--time 0.3]`: the transport hub under its 100 kg,
/// its shed's roof toughened or laminated, and the roof glass falling on the platforms 15 m below
/// graded pane by pane (`RoofGlassHazard`).
func runHubRoof(device: MTLDevice) throws {
    let laminated = flag("laminated")
    let cell = option("dx").flatMap(Float.init) ?? 0.5
    let duration = option("time").flatMap(Double.init) ?? 0.3
    let scenario = ScenarioPreset.transportHub(title: "Transport hub", laminatedRoof: laminated)
    let solver = try BlastSolver(
        // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
        device: device, scenario: scenario, cellSize: cell, configuration: .recommended.balloonStart)
    let result = solver.advance(until: duration)
    guard let shells = solver.bodies.first?.shells else { return }
    let summary = shells.summary()
    let roof = RoofGlassHazard.assess(shells)
    print(
        "Shed roof \(laminated ? "laminated" : "toughened"), \(duration * 1e3) ms"
            + (result.isStable ? "" : " (unstable)") + ": \(summary.erodedElements) elements removed")
    print(
        String(
            format:
                "  %d panes: %d cracked and held, %d with glass fallen (%.0f kg, %.1f kJ striking), %d hazardous",
            roof.panes, roof.held, roof.fallen, roof.fallenKg, roof.energyJ / 1e3, roof.hazardous))
}
