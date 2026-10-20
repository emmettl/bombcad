import BlastCore
import Foundation
import Metal
import simd

// `blastbench tie`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A reinforced tie pulled to a mean strain of 1.5e-3 (`TieBenchmark`), its cracks and pull against
/// the Model Code's spacing and tension stiffening. `--h 0.02,0.01` the meshes, `--bond none` bonded
/// bars, `--factor 1.25` the concrete's strengths raised by that factor as at blast rates (its
/// fracture energy by the factor's square root, as the tensile rate law raises it), the bond not.
func runTie() throws {
    let sizes = (option("h") ?? "0.02,0.01").split(separator: ",").compactMap { Float($0) }
    let factor = option("factor").flatMap { Float($0) } ?? 1
    let strain = option("strain").flatMap { Float($0) } ?? 1.5e-3
    let bond =
        option("bond") == nil
        ? BondSlip(condition: .pullOut, barDiameter: TieBenchmark.diameter)
        : chosenBondSlip(diameter: TieBenchmark.diameter)
    let strength = TieBenchmark.material.tensileStrength * factor
    print(
        "Tie 1 m x 100 mm x 100 mm, 2% of 12 mm bars, pulled to \(format(Double(strain) * 1000, 2))e-3; "
            + "strengths x\(format(Double(factor), 2))")
    let transfer = TieBenchmark.transferLength(raised: factor)
    print(
        "Model Code, the bond kept static: cracks \(format(Double(transfer) * 1000, 0)) to \(format(Double(2 * transfer) * 1000, 0)) mm apart; pull "
            + "\(format(Double(TieBenchmark.expectedLoad(strain: strain, beta: 0.4, strength: strength)) / 1000, 1)) kN "
            + "(beta 0.4) to \(format(Double(TieBenchmark.expectedLoad(strain: strain, beta: 0.6, strength: strength)) / 1000, 1)) kN (0.6); "
            + "bare bars \(format(Double(TieBenchmark.expectedLoad(strain: strain, beta: 0, strength: strength)) / 1000, 1)) kN"
    )
    for h in sizes {
        // `--discrete`: the bars as discrete trusses with the same bond.
        let result = try TieBenchmark.run(
            device: device, elementSize: h, bond: bond, strain: strain, discrete: flag("discrete")
        ) { material in
            material.concreteRateFactor = factor
            material.fractureEnergy *= factor.squareRoot()
            applyRateOptions(&material)
        }
        let spacings = result.spacings
        let mean = spacings.isEmpty ? 0 : spacings.reduce(0, +) / Float(spacings.count)
        print(
            "  \(format(Double(h) * 1000, 1)) mm elements: \(spacings.count + 1) cracks, "
                + "\(format(Double(spacings.min() ?? 0) * 1000, 0))-\(format(Double(spacings.max() ?? 0) * 1000, 0)) mm apart "
                + "(mean \(format(Double(mean) * 1000, 0))); pull \(format(Double(result.load) / 1000, 1)) kN"
        )
        if flag("discrete") {
            let every = max(1, result.bar.forces.count / 20)
            print(
                "    bar 0 forces (kN): "
                    + stride(from: 0, to: result.bar.forces.count, by: every).map {
                        format(Double(result.bar.forces[$0]) / 1000, 1)
                    }.joined(separator: " "))
            print(
                "    bar 0 slips (mm):  "
                    + stride(from: 0, to: result.bar.slips.count, by: every).map {
                        format(Double(result.bar.slips[$0]) * 1000, 3)
                    }.joined(separator: " "))
        }
    }
}
