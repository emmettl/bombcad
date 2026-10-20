import BlastCore
import Foundation
import Metal
import simd

// `blastbench pushoff`.
// Split from main.swift (emmettl/bombcad-work#51).

func runPushOff() throws {
    print(
        "Walraven and Reinhardt's push-off tests (HERON 26(1A), 1981), mix 1, with external restraint bars:")
    print("one crack driven along each specimen's measured opening and slip. Stresses in MPa; across")
    print("the crack compressive positive. 'fit' is the paper's eqs. 1a/1b at the same opening and slip;")
    print("'MCFT' the modified compression field theory's shear limit with the measured stress across.\n")
    let names = option("specimens").map { $0.split(separator: ",").map(String.init) }
    let size = option("size").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.05
    func mpa(_ value: Float?) -> String { value.map { format(Double($0) / 1e6, 2) } ?? "-" }
    for specimen in PushOffTest.specimens where names?.contains(specimen.name) ?? true {
        // `--close`: then pushed back to 0.05 mm open, the slip held, and slid 0.5 mm further.
        let end = SIMD2(specimen.finalSlip, 0.00005)
        let beyond = flag("close") ? [end, end + SIMD2(0.0005, 0)] : []
        let result = try PushOffTest.run(
            device: device, specimen: specimen, size: size,
            beyond: beyond
        ) { model in applyRateOptions(&model) }
        if flag("close") {
            let closing = result.samples.filter { $0.slip >= specimen.finalSlip - 1e-6 }
            for sample in [closing.first, closing.dropFirst(closing.count / 2).first, closing.last]
                .compactMap({ $0 })
            {
                print(
                    "  closed: slip \(format(Double(sample.slip) * 1000, 2)) mm, open \(format(Double(sample.width) * 1000, 2)) mm: "
                        + "shear \(format(Double(sample.shear) / 1e6, 2)), across \(format(Double(sample.normal) / 1e6, 2)) MPa"
                )
            }
        }
        let material = PushOffTest.material(for: specimen)
        print(
            "\(specimen.name): cube strength \(format(Double(specimen.cubeStrength) / 1e6)) MPa, "
                + "initial width \(format(Double(specimen.initialWidth) * 1000, 2)) mm")
        print(
            pad("slip", 8) + pad("width", 8) + pad("shear", 8) + pad("model", 8) + pad("fit", 8)
                + pad("MCFT", 8)
                + pad("across", 9) + pad("model", 8) + pad("fit", 8))
        var slips: [Float] = [0.1, 0.2, 0.4, 0.8, 1.2, 1.6, 2.0].map { $0 / 1000 }.filter {
            $0 <= specimen.finalSlip
        }
        slips.append(specimen.finalSlip)
        for slip in slips {
            let width = specimen.width(at: slip)
            let modelled = result.modelled(at: slip)
            let pressed = specimen.measuredNormal(at: slip)
            let limit = pressed.map {
                PushOffTest.compressionFieldShear(
                    width: width, pressure: $0, compressiveStrength: material.compressiveStrength,
                    aggregate: material.aggregateSize)
            }
            print(
                pad("\(format(Double(slip) * 1000, 2))", 8) + pad("\(format(Double(width) * 1000, 2))", 8)
                    + pad(mpa(specimen.measuredShear(at: slip)), 8) + pad(mpa(modelled.shear), 8)
                    + pad(
                        mpa(
                            PushOffTest.fittedShear(
                                width: width, slip: slip, cubeStrength: specimen.cubeStrength)), 8)
                    + pad(mpa(limit), 8) + pad(mpa(pressed), 9) + pad(mpa(modelled.normal), 8)
                    + pad(
                        mpa(
                            PushOffTest.fittedNormal(
                                width: width, slip: slip, cubeStrength: specimen.cubeStrength)), 8))
        }
        print("")
    }
}
