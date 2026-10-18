import BlastCore
import Foundation
import Metal

// Kenny's drop-hammer tests on slender strips, against the beams' dynamic buckling (see
// KennyImpactTest.swift):
//
//   blastbench kenny [--series SIa,AIb,...] [--measured-bow] [--no-rate] [--dx 0.004] [--stroke 0.010]

func runKenny(device: MTLDevice) throws {
    let names = option("series").map { $0.split(separator: ",").map(String.init) }
    let chosen = KennyImpactTest.series.filter { names?.contains($0.name) ?? true }
    for series in chosen {
        let r = try KennyImpactTest.run(
            device: device, series: series, measuredBow: flag("measured-bow"), rateLaw: !flag("no-rate"),
            elementSize: option("dx").flatMap { Float($0) } ?? 0.004,
            stroke: option("stroke").flatMap { Float($0) } ?? 0.010)
        print(
            String(
                format:
                    "%@ L %.0f mm: deflection %.1f mm at %.0f mm (measured %.1f at %.0f), ratio %.2f; hammer stopped at %.1f ms, left at %.1f ms",
                series.name, series.length * 1000, r.deflection * 1000, r.position * 1000,
                series.deflection * 1000,
                series.position * 1000, r.deflection / series.deflection, r.stopped * 1000, r.parted * 1000))
    }
}
