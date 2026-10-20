import BlastCore
import Foundation
import Metal
import simd

// `blastbench shear`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Vecchio and Shim's beam OA1, with no stirrups, pushed to its diagonal-tension failure.
func runShearBeam() throws {
    print("Beam OA1 of Vecchio and Shim (2004), no stirrups, failing in diagonal tension")
    print(
        "Measured: peak \(format(Double(ShearBeamBenchmark.measuredPeak) / 1000, 0)) kN at "
            + "\(format(Double(ShearBeamBenchmark.measuredPeakDeflection) * 1000)) mm, then a sudden drop\n")
    let meshes = (option("layers") ?? "12,24").split(separator: ",").compactMap { Int($0) }
    let rate = option("rate").flatMap { Float($0) } ?? 0.05
    var results: [(layers: Int, result: ShearBeamBenchmark.Result)] = []
    print(
        pad("layers", 8) + pad("elements", 10) + pad("peak", 10) + pad("vs test", 9) + pad("at", 9)
            + pad("failed", 8) + pad("run time", 10))
    for layers in meshes {
        // `--dowel 0.5` scales the bars' dowel action.
        let dowel = option("dowel").flatMap { Float($0) }
        // `--slice 92` models a slice of the beam that many millimetres wide.
        let slice = option("slice").flatMap { Float($0) }.map { $0 / 1000 }
        // `--work`: the work each mechanism has done at every millimetre and at the peak, through
        // the whole beam, and at the peak by part of the beam. Scaled to the whole beam.
        var milestones: [(deflection: Float, load: Float, external: Double, totals: [Double])] = []
        var shownBreakdown = false
        var atPeak: (deflection: Float, load: Float, external: Double, totals: [Double], parts: [[Double]])?
        var external = 0.0
        var last = SIMD2<Float>.zero
        let regions: [(String, (Int, Int, Int, StructureSolver) -> Bool)] = [
            ("top quarter", { _, _, k, s in 4 * k >= 3 * s.ez }),
            ("middle half", { _, _, k, s in 4 * k >= s.ez && 4 * k < 3 * s.ez }),
            ("bottom quarter", { _, _, k, s in 4 * k < s.ez }),
            (
                "0.5 m about the load",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize < 0.25 }
            ),
            (
                "shear spans",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize >= 0.25 }
            ),
        ]
        let scale = Double(ShearBeamBenchmark.width / (slice ?? ShearBeamBenchmark.width))
        let result = try ShearBeamBenchmark.run(
            device: device, elementsThroughDepth: layers, slice: slice, rate: rate,
            bondSlip: chosenBondSlip(diameter: 0.028),
            mapAt: option("map").flatMap { Float($0) }.map { $0 / 1000 },
            pressedInterlock: flag("pressed-interlock"),
            adjustModel: applyHourglassOptions,
            adjust: { material in
                applyRateOptions(&material)
                if let dowel { material.dowelFactor = dowel }
                // `--crack-spacing 25` (mm) and `--aggregate 10` (mm), for studying the shear strength.
                if let spacing = option("crack-spacing").flatMap({ Float($0) }) {
                    material.crackSpacing = spacing / 1000
                }
                if let size = option("aggregate").flatMap({ Float($0) }) {
                    material.aggregateSize = size / 1000
                }
            },
            prepare: prepareTrace,
            sample: flag("work")
                ? { solver, deflection, load in
                    if let at = option("breakdown").flatMap({ Float($0) }).map({ $0 / 1000 }),
                        deflection >= at,
                        !shownBreakdown
                    {
                        shownBreakdown = true
                        printHourglassBreakdown(
                            solver, label: "\(layers) layers at \(format(Double(deflection) * 1000, 1)) mm")
                    }
                    external += Double(0.5 * (load + last.y) * (deflection - last.x))
                    last = SIMD2(deflection, load)
                    let crossed =
                        Int(deflection * 1000) > (milestones.last.map { Int($0.deflection * 1000) } ?? 0)
                    let peak = load > (atPeak?.load ?? 0)
                    guard crossed || peak else { return }
                    let totals = solver.workTotals().map { $0 * scale }
                    if crossed { milestones.append((deflection, load, external, totals)) }
                    if peak {
                        let parts = regions.map { region in
                            solver.workTotals { region.1($0, $1, $2, solver) }.map { $0 * scale }
                        }
                        atPeak = (deflection, load, external, totals, parts)
                    }
                } : nil)
        results.append((layers, result))
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                + pad("\(format(Double(result.peak) / 1000, 0)) kN", 10)
                + pad("\(format(Double(result.peak / ShearBeamBenchmark.measuredPeak) * 100, 0))%", 9)
                + pad("\(format(Double(result.peakDeflection) * 1000)) mm", 9)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
        if let atPeak {
            print("\nWork done by each mechanism (J), \(layers) layers; 'load' the work the load has done:")
            print(workHeader("deflection", 12) + pad("load", 10))
            for m in milestones {
                print(
                    workRow("\(format(Double(m.deflection) * 1000)) mm", 12, m.totals)
                        + pad(format(m.external, 1), 10))
            }
            print(
                workRow("peak \(format(Double(atPeak.deflection) * 1000)) mm", 12, atPeak.totals)
                    + pad(format(atPeak.external, 1), 10))
            print("At the peak, \(format(Double(atPeak.load) / 1000, 0)) kN, by part of the beam:")
            print(workHeader("part", 22))
            for (region, totals) in zip(regions, atPeak.parts) { print(workRow(region.0, 22, totals)) }
            print("")
        }
    }
    // `--map 9` draws the cracks through the middle of the width at 9 mm of deflection.
    for (layers, result) in results where !result.crackMap.isEmpty {
        print(
            "\nCracks open past 0.1% strain, \(layers) layers, at \(option("map") ?? "") mm "
                + "(\(format(Double(result.mapLoad) / 1000, 0)) kN): | vertical, / and \\ inclined, - horizontal"
        )
        for line in result.crackMap { print(line) }
    }
    print("\nMid-span load (kN) against deflection:")
    print(
        pad("deflection", 12) + pad("measured", 10) + results.map { pad("\($0.layers) layers", 12) }.joined())
    for tenths in [5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 140, 160] {
        let deflection = Float(tenths) / 10000
        let measured =
            deflection <= ShearBeamBenchmark.measuredPeakDeflection
            ? format(Double(ShearBeamBenchmark.measuredLoad(at: deflection)) / 1000, 0) : "-"
        print(
            pad("\(format(Double(tenths) / 10)) mm", 12) + pad(measured, 10)
                + results.map { pad(format(Double($0.result.load(at: deflection)) / 1000, 0), 12) }.joined())
    }
}
