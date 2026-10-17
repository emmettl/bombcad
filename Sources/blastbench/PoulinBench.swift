import BlastCore
import Foundation
import Metal
import simd

/// `blastbench poulin [--shots CLT3-4.2,...] [--h 0.0745] [--rate 1.28] [--no-static]`: Poulin's
/// CLT panels in the University of Ottawa's shock tube (`PoulinCLTTest`): the static four-point
/// bending tests' stiffness and peak, then each shot's peak mid-span deflection and failure
/// against the measured.
func runPoulin(device: MTLDevice) throws {
    let h = option("h").flatMap { Float($0) } ?? 0.0745
    let rate = option("rate").flatMap { Float($0) } ?? 1.28
    let names = option("shots").map { Set($0.split(separator: ",").map(String.init)) }
    print(
        "Poulin's CLT panels (E1, 2,235 mm span, third-point loads), \(format(Double(h) * 1000, 1)) mm shells"
    )
    if !flag("no-static") {
        print("\nStatic four-point bending, measured / model (no dynamic increase)")
        for plies in [3, 5] {
            let measured = PoulinCLTTest.staticMeasured(plies: plies)
            let result = try PoulinCLTTest.push(
                device: device, plies: plies, load: 2 * measured.load, elementSize: h,
                rollingScale: option("rolling-scale").flatMap { Float($0) } ?? 1)
            // Stiffness from the curve's first third; the peak where it runs away.
            let early = result.curve.filter { $0.x < measured.load / 3 }
            let stiffness = early.last.map { $0.x / max($0.y, 1e-9) } ?? 0
            let runaway = zip(result.curve, result.curve.dropFirst()).first { a, b in
                (b.y - a.y) / max(b.x - a.x, 1) > 10 / max(stiffness, 1)
            }
            let peak = runaway?.0 ?? result.curve.last ?? .zero
            print(
                String(
                    format:
                        "  %d-ply: stiffness %.2f / %.2f kN/mm; peak load %.1f / %.1f kN at %.1f / %.1f mm; "
                        + "damage fibre %.2f, splitting %.2f, rolling %.2f", plies, measured.stiffness / 1e6,
                    stiffness / 1e6, measured.load / 1e3, peak.x / 1e3, measured.deflection * 1000,
                    peak.y * 1000,
                    result.fibre, result.splitting, result.rolling))
        }
    }
    print("\nShots (dynamic increase \(rate)): peak mid-span deflection measured / model, and failure")
    print(
        "  shot        kPa   kPa ms   measured     model   at ms   fibre  split  roll  removed  measured mode"
    )
    for shot in PoulinCLTTest.shots where names?.contains(shot.name) ?? true {
        let result = try PoulinCLTTest.run(device: device, shot: shot, elementSize: h, rate: rate)
        print(
            String(
                format: "  %-10@ %5.1f  %6.0f  %7.1f mm %7.1f mm  %5.1f   %5.2f  %5.2f %5.2f  %6d   %@",
                shot.name,
                shot.pressure / 1e3, shot.impulse, shot.deflection * 1000, result.deflection * 1000,
                result.time * 1000, result.fibre, result.splitting, result.rolling, result.removed, shot.mode)
        )
        fflush(stdout)
    }
}
