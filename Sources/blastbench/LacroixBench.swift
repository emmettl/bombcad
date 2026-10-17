import BlastCore
import Foundation
import Metal
import simd

/// `blastbench lacroix [--shots B12.2,...] [--rate 1.14] [--no-static]`: Lacroix's glulam beams in
/// the University of Ottawa's shock tube (`LacroixGlulamTest`): the static tests (on which the
/// model is calibrated), then each shot's peak mid-span deflection and whether and where it broke.
func runLacroix(device: MTLDevice) throws {
    let rate = option("rate").flatMap { Float($0) } ?? 1.14
    let names = option("shots").map { Set($0.split(separator: ",").map(String.init)) }
    print("Lacroix's glulam beams (2,235 mm span, third-point loads)")
    if !flag("no-static") {
        print(
            "\nStatic four-point bending, measured / model (calibrated: tension strength = rupture modulus)")
        for series in LacroixGlulamTest.series {
            let measured = LacroixGlulamTest.staticMeasured(series.name)
            let result = try LacroixGlulamTest.push(device: device, series: series, load: 2 * measured.load)
            let early = result.curve.filter { $0.x < measured.load / 3 }
            let stiffness = early.last.map { $0.x / max($0.y, 1e-9) } ?? 0
            let at = result.curve.first { $0.x >= (result.atBreak ?? .infinity) }?.y ?? result.deflection
            print(
                "  \(series.name) mm: stiffness \(format(Double(measured.load / measured.deflection) / 1e6, 2)) / "
                    + "\(format(Double(stiffness) / 1e6, 2)) kN/mm; broke at "
                    + "\(format(Double(measured.load) / 1e3, 1)) / "
                    + "\(result.atBreak.map { format(Double($0) / 1e3, 1) } ?? "-") kN, "
                    + "\(format(Double(measured.deflection) * 1000, 1)) / \(format(Double(at) * 1000, 1)) mm")
        }
    }
    print("\nShots (dynamic increase \(rate)): mid-span deflection measured / model; where it broke")
    print("  shot        kPa   kPa ms   peak, measured / model      broke at, measured / model")
    for shot in LacroixGlulamTest.shots where names?.contains(shot.name) ?? true {
        let result = try LacroixGlulamTest.run(device: device, shot: shot, rate: rate)
        print(
            "  " + pad(shot.name, 10) + pad(format(Double(shot.pressure) / 1e3, 1), 7)
                + pad(format(Double(shot.impulse), 0), 8)
                + pad(
                    format(Double(shot.deflection) * 1000, 1) + " / "
                        + format(Double(result.deflection) * 1000, 1)
                        + " mm", 28)
                + (shot.atBreak.map { format(Double($0) * 1000, 1) } ?? "held") + " / "
                + (result.atBreak.map { format(Double($0) * 1000, 1) } ?? "held"))
        fflush(stdout)
    }
}
