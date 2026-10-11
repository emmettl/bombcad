import BlastCore
import Foundation
import Metal

// Blind test 1 (docs/blind-tests.md): Hrynyk's slabs struck at the centre by a falling weight,
// built from Samples/Hrynyk2013/inputs alone (see HrynykSlabTest.swift):
//
//   blastbench hrynyk [--slabs TH2,TH6,TH7] [--layers 16] [--impacts 4] [--time 0.2]
//                     [--inputs Samples/Hrynyk2013/inputs/slabs.json] [--out dir]
//                     [--ensemble 16 [--seed 1] [--samples 0-16]]   (the inputs' spread)
//
// Writes each slab's impacts as JSON and their histories as CSV into --out (default
// /Volumes/StudioData/bombcad/blind/predictor/run-<layers>); with --ensemble, each sample's
// impacts as JSON into its ensemble folder.

func runHrynyk(device: MTLDevice) throws {
    let inputs = try HrynykSlabTest.inputs(
        from: URL(filePath: option("inputs") ?? "Samples/Hrynyk2013/inputs/slabs.json"))
    var settings = HrynykSlabTest.Settings()
    if let layers = option("layers").flatMap({ Int($0) }) { settings.elementsThroughDepth = layers }
    if let time = option("time").flatMap({ Double($0) }) { settings.duration = time }
    let names = option("slabs")?.split(separator: ",").map(String.init)
    let slabs = inputs.slabs.filter { names?.contains($0.name) ?? true }
    let masses = Array(inputs.masses.prefix(option("impacts").flatMap { Int($0) } ?? 4))
    let out = URL(
        filePath: option("out")
            ?? "/Volumes/StudioData/bombcad/blind/predictor/run-\(settings.elementsThroughDepth)")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    func line(_ impact: HrynykSlabTest.Impact) -> String {
        String(
            format:
                "  %d  %3.0f kg  peak %6.2f mm at %5.1f ms  residual %6.2f (tail %6.2f) mm  reaction %6.1f kN "
                + "(0.5 ms %6.1f)  force %6.1f kN (raw %6.1f)  left %@  penetration %5.2f mm  bottom gone %.3f m²  "
                + "layers %d/%d  %@  removed %d bare %d  %.0f s",
            impact.number, impact.mass, impact.peakDisplacement * 1000, impact.peakTime * 1000,
            impact.residualDisplacement * 1000, impact.residualTail * 1000, impact.peakReaction / 1000,
            impact.peakReactionAveraged / 1000, impact.peakImpactForce / 1000,
            impact.peakImpactForceRaw / 1000,
            impact.weightLeft.map { String(format: "%.1f ms", $0 * 1000) } ?? "never",
            impact.penetration * 1000, impact.bottomAreaGone, impact.layersCrossed, impact.thicknessLayers,
            impact.punched ? "PUNCHED" : "not punched", impact.elementsRemoved, impact.elementsBare,
            impact.wallSeconds)
    }

    if let count = option("ensemble").flatMap({ Int($0) }) {
        let seed = option("seed").flatMap { UInt64($0) } ?? 1
        let range = option("samples").map { text -> ClosedRange<Int> in
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 2 ? parts[0]...parts[1] : (parts.first ?? 0)...(parts.first ?? count)
        }
        let folder = out.appending(path: "ensemble")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for slab in slabs {
            let samples = HrynykSlabTest.ensembleSamples(slab, count: count, seed: seed)
            for (index, values) in samples.enumerated() where range?.contains(index) ?? true {
                let file = folder.appending(path: "\(slab.name)-\(index).json")
                if FileManager.default.fileExists(atPath: file.path) { continue }
                print("\(slab.name) sample \(index): \(values.sorted { $0.key < $1.key })")
                var result = try HrynykSlabTest.run(
                    device: device, slab: slab, inputs: inputs, settings: settings, masses: masses,
                    values: values
                ) { print(line($0)) }
                for n in result.impacts.indices {
                    result.impacts[n].displacementHistory = []
                    result.impacts[n].forceHistory = []
                }
                struct Sample: Encodable {
                    var index: Int
                    var values: [String: Double]
                    var result: HrynykSlabTest.Result
                }
                try encoder.encode(Sample(index: index, values: values, result: result)).write(to: file)
            }
        }
        return
    }

    print(
        "Hrynyk's slabs struck at the centre, \(settings.elementsThroughDepth) elements through, "
            + "masses \(masses.map { String(format: "%.0f", $0) }.joined(separator: ", ")) kg\n")
    for slab in slabs {
        print("\(slab.name): \(slab.barName) at \(Int((slab.spacing * 1000).rounded())) mm")
        let result = try HrynykSlabTest.run(
            device: device, slab: slab, inputs: inputs, settings: settings, masses: masses
        ) { print(line($0)) }
        print(
            String(
                format: "  %d elements of %.2f mm, step %.3f µs; sagged %.3f mm under its own weight\n",
                result.elementCount, result.elementSize * 1000, result.timeStep * 1e6,
                result.selfWeightSag * 1000))
        try encoder.encode(result).write(to: out.appending(path: "\(slab.name).json"))
        for impact in result.impacts {
            let stem = "\(slab.name)-impact\(impact.number)"
            let displacement =
                "time_ms,midpoint_displacement_mm\n"
                + impact.displacementHistory.map { String(format: "%.2f,%.4f", $0.x * 1000, $0.y * 1000) }
                .joined(separator: "\n") + "\n"
            try displacement.write(
                to: out.appending(path: "\(stem)-displacement.csv"), atomically: true, encoding: .utf8)
            let forces =
                "time_ms,total_reaction_kN,reaction_above_kN,impact_force_filtered_kN,impact_force_raw_kN\n"
                + impact.forceHistory.map { row in
                    String(
                        format: "%.4f,%.3f,%.3f,%.3f,%.3f", row[0] * 1000, row[1] / 1000, row[2] / 1000,
                        row[3] / 1000,
                        row[4] / 1000)
                }.joined(separator: "\n") + "\n"
            try forces.write(to: out.appending(path: "\(stem)-forces.csv"), atomically: true, encoding: .utf8)
        }
    }
}
