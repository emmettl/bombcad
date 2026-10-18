import BlastCore
import Foundation
import Metal

/// `blastbench laminated [--osnes] [--hooper] [--strength MPa] [--elements 24]`: laminated panes
/// meshed as shells (`LaminatedShellTest`) beside the envelope's single degree of freedom, on
/// Osnes et al.'s 15 shock-tube shots (edges pinned) and Hooper's 8 framed panes (structural
/// silicone). `--strength` is the glass's 60 s strength (E1300's median for each pane unless
/// given).
func runLaminated(device: MTLDevice) throws {
    let both = !flag("osnes") && !flag("hooper")
    let strength = option("strength").flatMap(Double.init).map { $0 * 1e6 }
    let elements = option("elements").flatMap(Int.init) ?? 24
    func ms(_ t: Double?) -> String { t.map { String(format: "%.2f ms", $0 * 1e3) } ?? "-" }
    if both || flag("osnes") {
        print("Osnes et al.: 3.8/1.52/3.8 mm, 300 x 300 mm, edges pinned")
        let laminate = LaminatedGlass(
            plies: [0.0038, 0.0038], interlayer: .pvb, interlayerThickness: 0.00152)
        let step = 1e-5
        for shot in LaminatedGlassMeasurements.osnes {
            let pressures = LaminatedGlassMeasurements.friedlander(
                pMax: shot.pMax, duration: shot.duration, b: shot.b, step: step)
            let r = try LaminatedShellTest.run(
                device: device, laminate: laminate, a: 0.3, b: 0.3, edges: .pinned, pressures: pressures,
                step: step, duration: 0.015, elements: elements, sixtySecondStrength: strength)
            print(
                String(
                    format:
                        "  %@ %.0f kPa: cracked %@ / %@ (SDOF %@), %.1f / %.1f mm (SDOF %.1f), %d removed",
                    shot.test, shot.pMax / 1e3, shot.cracked ? "yes" : "no", ms(r.crackedAt),
                    ms(r.sdof.crackedAt), shot.deflection, r.peak * 1e3, r.sdof.peakDeflection * 1e3,
                    r.removed))
        }
    }
    if both || flag("hooper") {
        print("Hooper: structural silicone, 20 mm bite")
        let step = 2e-5
        for test in LaminatedGlassMeasurements.hooper {
            let laminate = LaminatedGlass(
                plies: [test.ply * 1e-3, test.ply * 1e-3], interlayer: .pvb,
                interlayerThickness: test.interlayer * 1e-3,
                edgeCapacity: LaminatedGlass.siliconeCapacity(bite: 0.02))
            let pressures = LaminatedGlassMeasurements.triangle(
                peak: test.peak * 1e3, impulse: test.impulse, step: step, until: 0.04)
            let r = try LaminatedShellTest.run(
                device: device, laminate: laminate, a: test.a, b: test.b, edges: .silicone,
                pressures: pressures, step: step, duration: 0.03, elements: elements,
                sixtySecondStrength: strength)
            let release =
                r.releasedAt.map {
                    String(format: "let go at %.1f ms, %.1f m/s", $0 * 1e3, r.speedAtRelease ?? 0)
                } ?? "held"
            let sdof =
                r.sdof.lostResistanceAt.map {
                    String(format: "lost at %.1f ms, %.1f m/s", $0 * 1e3, abs(r.sdof.velocityAtLoss ?? 0))
                } ?? "held"
            print(
                "  \(test.test): cracked \(ms(r.crackedAt)) (SDOF \(ms(r.sdof.crackedAt))), "
                    + String(format: "%.0f mm (measured %.0f), ", r.peak * 1e3, test.deflection)
                    + "\(release) (SDOF \(sdof); measured \(test.speed) m/s, \(test.outcome)), \(r.removed) removed"
            )
        }
    }
}
