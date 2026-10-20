import BlastCore
import Foundation
import Metal
import simd

// `blastbench gravity`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A layout's structure stood under gravity alone, damped, and judged as the IFC corpus judges
/// imported buildings (`GravityCheck`).
func runGravity(device: MTLDevice) throws {
    let preset = preset(named: option("preset"))
    guard let model = preset.scenario.structure else {
        print("\(preset.title) has no structure.")
        exit(2)
    }
    let duration = option("time").flatMap { Double($0) } ?? GravityCheck.duration
    let damping = option("damping").flatMap { Float($0) } ?? GravityCheck.damping
    let started = ContinuousClock.now
    var counts = (shells: 0, beams: 0)
    var hinges = (released: 0, of: 0)
    let check = try GravityCheck.run(model, device: device, duration: duration, damping: damping) {
        counts = ($0.elementCount, $0.beamCount)
        hinges = ($0.hingesReleased, $0.hingeTurns.count)
    }
    let seconds = (ContinuousClock.now - started) / .seconds(1)
    print(
        "\(preset.title): \(counts.shells) shells, \(counts.beams) beams, \(String(format: "%.0f", check.weight / 1000)) kN"
    )
    print(
        String(
            format:
                "%.2f s under gravity, damped at %.0f/s: %.1f%% of the weight carried, %.1f%% still, peak %.1f mm, %d eroded",
            duration, damping, 100 * check.carried, 100 * check.still, 1000 * check.peak, check.eroded))
    print(
        String(
            format: "moving weight at %.2f s %.3f m/s, at %.2f s %.3f m/s (falling: %.3f m/s): %@ (%.0f s)",
            duration * 5 / 6, check.settling.early, duration, check.settling.late, 9.81 / damping,
            check.verdict.rawValue, seconds))
    if hinges.of > 0 { print("\(hinges.released) of \(hinges.of) steel connections fractured") }
}
