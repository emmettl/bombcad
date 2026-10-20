import BlastCore
import Foundation
import Metal
import simd

// `blastbench beam`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Compares the structural model with the measured response of the Blast Blind Simulation
/// Contest's normal-strength slab.
/// Janney's reinforced beam bent slowly to failure, against the measured moment and deflection.
func runBeam() throws {
    print("Reinforced concrete beam in four-point bending (Janney, Hognestad and McHenry, 1956)")
    print(
        "Measured: yield near 37 kN m at 11 mm, \(format(Double(BeamBenchmark.measuredPeakMoment) / 1000)) kN m "
            + "at failure, \(format(Double(BeamBenchmark.measuredFailureDeflection) * 1000, 0)) mm; "
            + "section analysis \(format(Double(BeamBenchmark.sectionMoment) / 1000)) kN m\n")
    // `--layers 12,24` chooses the meshes, by elements through the depth; `--rate` the plates' speed (m/s).
    let meshes = (option("layers") ?? "12,24").split(separator: ",").compactMap { Int($0) }
    let rate = option("rate").flatMap { Float($0) } ?? 0.1
    var results: [(layers: Int, result: BeamBenchmark.Result)] = []
    print(
        pad("layers", 8) + pad("elements", 10) + pad("peak", 12) + pad("vs test", 9) + pad("fails at", 10)
            + pad("rms", 10) + pad("failed", 8) + pad("run time", 10))
    var shownBreakdown = false
    for layers in meshes {
        // `--crack-spacing 25` sets the distance, in millimetres, a crack's energy is spread over.
        let spacing = option("crack-spacing").flatMap { Float($0) }
        let dowel = option("dowel").flatMap { Float($0) }
        let result = try BeamBenchmark.run(
            device: device, elementsThroughDepth: layers,
            deflection: option("to").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.06, rate: rate,
            unload: flag("unload"), crackSlip: !flag("no-crack-slip"),
            bondSlip: chosenBondSlip(diameter: 0.019), pressedInterlock: flag("pressed-interlock"),
            adjustModel: applyHourglassOptions,
            adjust: { material in
                applyRateOptions(&material)
                if let spacing { material.crackSpacing = spacing / 1000 }
                if let dowel { material.dowelFactor = dowel }
            },
            prepare: prepareTrace,
            sample: { solver, deflection, _ in
                // `--work --breakdown 40`: where hourglass control's work has gone by 40 mm.
                guard solver.tracesWork,
                    let at = option("breakdown").flatMap({ Float($0) }).map({ $0 / 1000 }),
                    deflection >= at, !shownBreakdown
                else { return }
                shownBreakdown = true
                printHourglassBreakdown(
                    solver, label: "\(layers) layers at \(format(Double(deflection) * 1000, 1)) mm")
                print("  " + workHeader("", 8))
                print("  " + workRow("", 8, solver.workTotals()))
            })
        shownBreakdown = false
        results.append((layers, result))
        if let residual = result.residual {
            print(
                "  unloaded from \(format(Double(result.curve.last?.x ?? 0) * 1000, 1)) mm: \(format(Double(residual) * 1000, 1)) mm left"
            )
        }
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                + pad("\(format(Double(result.peakMoment) / 1000)) kN m", 12)
                + pad("\(format(Double(result.peakMoment / BeamBenchmark.measuredPeakMoment) * 100, 0))%", 9)
                + pad(result.failureDeflection.map { "\(format(Double($0) * 1000, 0)) mm" } ?? "holds", 10)
                + pad("\(format(Double(result.curveError()) / 1000)) kN m", 10)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
    }
    print("\nMid-span moment (kN m) against central deflection:")
    print(
        pad("deflection", 12) + pad("measured", 10) + results.map { pad("\($0.layers) layers", 12) }.joined())
    for millimetres in [1, 2, 5, 8, 10, 12, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60] {
        let deflection = Float(millimetres) / 1000
        let measured =
            deflection <= BeamBenchmark.measuredFailureDeflection
            ? format(Double(BeamBenchmark.measuredMoment(at: deflection)) / 1000) : "failed"
        print(
            pad("\(millimetres) mm", 12) + pad(measured, 10)
                + results.map { pad(format(Double($0.result.moment(at: deflection)) / 1000), 12) }.joined())
    }
}
