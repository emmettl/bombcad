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
            let line =
                "  \(plies)-ply: stiffness \(format(Double(measured.stiffness) / 1e6, 2)) / "
                + "\(format(Double(stiffness) / 1e6, 2)) kN/mm; peak load \(format(Double(measured.load) / 1e3, 1)) / "
                + "\(format(Double(peak.x) / 1e3, 1)) kN at \(format(Double(measured.deflection) * 1000, 1)) / "
                + "\(format(Double(peak.y) * 1000, 1)) mm; first broken: \(result.firstMode ?? "nothing") at "
                + "\(format(Double(result.firstAt) / 1e3, 1)) kN"
            print(line)
        }
    }
    print("\nShots (dynamic increase \(rate)): peak mid-span deflection measured / model, and failure")
    print(
        "  shot        kPa   kPa ms   measured     model   at ms   removed  first broken (ms)          measured mode"
    )
    for shot in PoulinCLTTest.shots where names?.contains(shot.name) ?? true {
        let result = try PoulinCLTTest.run(device: device, shot: shot, elementSize: h, rate: rate)
        let first = result.firstMode.map { "\($0) (\(format(Double(result.firstAt) * 1000, 1)))" } ?? "-"
        print(
            "  " + pad(shot.name, 10) + pad(format(Double(shot.pressure) / 1e3, 1), 7)
                + pad(format(Double(shot.impulse), 0), 8)
                + pad(format(Double(shot.deflection) * 1000, 1) + " mm", 11)
                + pad(format(Double(result.deflection) * 1000, 1) + " mm", 11)
                + pad(format(Double(result.time) * 1000, 1), 8) + pad("\(result.removed)", 9) + pad(first, 27)
                + shot.mode)
        fflush(stdout)
    }
}
