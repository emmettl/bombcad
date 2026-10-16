import BlastCore
import Foundation
import Metal

// Blind test 3 (docs/blind-tests.md): Reynolds's high-strength slabs HSCV1–6 in the blast load
// simulator, built from Samples/Reynolds2015/inputs alone (see ReynoldsSlabTest.swift):
//
//   blastbench reynolds [--slabs HSCV1,HSCV4] [--layers 8] [--time 0.3] [--load tail|scaled|raw]
//                       [--span 52] [--bar-depth 1.0625] [--nominal-bars] [--bearings 0.0254]
//                       [--inputs Samples/Reynolds2015/inputs/slabs.json] [--out dir]
//                       [--ensemble 8 [--seed 3] [--samples 1-8]]   (the inputs' spread)
//   blastbench reynolds --series rscr [--contest-shape] [--fc 41.4] ...
//                       (the open comparison after the reveal: the normal-strength 8 in slabs
//                       RSCR4–6 from Samples/Reynolds2015/rscr/inputs.json, on the contest slab's
//                       material, its bars 1 in from the face, each load a shape scaled to its
//                       Table 15 impulse; --fc sets the concrete's strength in MPa)
//
// Writes each slab's result as JSON, its centre's displacement and the applied load as CSV and its
// faces' cracks as PNG and text into --out (default
// /Volumes/StudioData/bombcad/reynolds-prediction/run); with --ensemble, each sample's result,
// without its histories, into its ensemble folder.

func runReynolds(device: MTLDevice) throws {
    var inputs = try ReynoldsSlabTest.inputs(
        from: URL(filePath: option("inputs") ?? "Samples/Reynolds2015/inputs/slabs.json"))
    var settings = ReynoldsSlabTest.Settings()
    if option("series") == "rscr" {
        inputs = try ReynoldsSlabTest.rscrInputs(
            from: URL(filePath: option("rscr-inputs") ?? "Samples/Reynolds2015/rscr/inputs.json"),
            hscv: inputs,
            contestShape: flag("contest-shape"))
        settings.contestMaterial = true
        settings.barDepthInches = 1
        settings.load = .given
    }
    if let fc = option("fc").flatMap({ Double($0) }) { settings.sample["fc"] = fc * 1e6 }
    if let layers = option("layers").flatMap({ Int($0) }) { settings.elementsThroughDepth = layers }
    if let time = option("time").flatMap({ Double($0) }) { settings.duration = time }
    if let shape = option("load").flatMap({ ReynoldsSlabTest.LoadShape(rawValue: $0) }) {
        settings.load = shape
    }
    if let span = option("span").flatMap({ Float($0) }) { settings.spanInches = span }
    if let depth = option("bar-depth").flatMap({ Float($0) }) { settings.barDepthInches = depth }
    if flag("nominal-bars") { settings.nominalSpacing = true }
    if let width = option("bearings").flatMap({ Float($0) }) { settings.bearingWidth = width }
    let names = option("slabs")?.split(separator: ",").map(String.init)
    let slabs = inputs.slabs.filter { names?.contains($0.name) ?? true }
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/reynolds-prediction/run")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    func line(_ r: ReynoldsSlabTest.Result) -> String {
        let d = r.damage
        let cracks = d.mainCracks.map { String(format: "%.0f (%.2f)", $0.x, $0.y) }.joined(separator: ", ")
        return String(
            format:
                "  %@: %@; peak %.2f mm at %.2f ms, residual %.2f mm (range %.2f over the last %.0f ms); "
                + "concrete spans %@, bar elements ruptured %d, removed %d bare %d; blast face crushed %.4f m²%@, "
                + "gone %.4f m², back face gone %.4f m²; %.0f s\n    back-face cracks at mm (mean opening mm): %@",
            r.slab, r.fails ? "FAILS" : "holds", r.peak * 1000, r.peakTime * 1000, r.residual * 1000,
            r.restRange * 1000, r.settings.restWindow * 1000, d.concreteSpans ? "yes" : "no",
            d.barElementsRuptured, d.removed, d.bare, d.blastFaceCrushed,
            d.crushedFrom.map { String(format: " (%.0f to %.0f mm)", $0, d.crushedTo ?? $0) } ?? "",
            d.blastFaceGone, d.backFaceGone, r.wallSeconds, cracks)
    }

    if let count = option("ensemble").flatMap({ Int($0) }) {
        let seed = option("seed").flatMap { UInt64($0) } ?? 3
        let range = option("samples").map { text -> ClosedRange<Int> in
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 2 ? parts[0]...parts[1] : (parts.first ?? 1)...(parts.first ?? count)
        }
        let folder = out.appending(path: "ensemble")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = ReynoldsSlabTest.ensembleSamples(count: count, seed: seed)
        for slab in slabs {
            for (offset, values) in samples.enumerated() where range?.contains(offset + 1) ?? true {
                let index = offset + 1
                let file = folder.appending(path: "\(slab.name)-\(index).json")
                if FileManager.default.fileExists(atPath: file.path) { continue }
                print("\(slab.name) sample \(index): \(values.sorted { $0.key < $1.key })")
                var result = try ReynoldsSlabTest.run(
                    device: device, slab: slab, inputs: inputs,
                    settings: ReynoldsSlabTest.settings(settings, values: values))
                print(line(result))
                result.history = []
                result.damage.backCracks = []
                result.damage.blastCracks = []
                result.damage.backPlan = []
                result.damage.blastPlan = []
                result.damage.backFaceProfile = []
                try encoder.encode(result).write(to: file)
            }
        }
        return
    }

    print(
        String(
            format: "Reynolds's slabs, %d elements through, %.2f in wide, span %.0f in, load %@, %.0f ms\n",
            settings.elementsThroughDepth, settings.widthInches, settings.spanInches, settings.load.rawValue,
            settings.duration * 1000))
    for slab in slabs {
        let load = ReynoldsSlabTest.load(slab, settings: settings)
        print(
            String(
                format:
                    "%@: bars at %.0f in (%.3f mm²/mm), load peak %.1f kPa (tabulated %.1f), impulse %.0f kPa ms, "
                    + "ends %.1f ms; %@",
                slab.name, slab.barSpacingInches, ReynoldsSlabTest.barArea(slab, settings: settings) * 1000,
                (load.history.map(\.y).max() ?? 0) / 1000, slab.tablePeak / 1000, load.impulse,
                (load.history.last?.x ?? 0) * 1000, slab.traceName))
        let result = try ReynoldsSlabTest.run(
            device: device, slab: slab, inputs: inputs, settings: settings, progress: { print("  " + $0) })
        print(line(result))
        if let peak = slab.measuredPeak, let residual = slab.measuredResidual {
            print(
                String(
                    format: "    measured: peak %.1f mm (ratio %.2f), residual %.1f mm (ratio %.2f)",
                    peak * 1000,
                    result.peak / peak, residual * 1000, result.residual / residual))
        }
        try encoder.encode(result).write(to: out.appending(path: "\(slab.name).json"))
        let displacement =
            "time_ms,centre_displacement_mm\n"
            + result.history.map { String(format: "%.2f,%.4f", $0.x * 1000, $0.y * 1000) }.joined(
                separator: "\n")
            + "\n"
        try displacement.write(
            to: out.appending(path: "\(slab.name)-displacement.csv"), atomically: true, encoding: .utf8)
        let applied =
            "time_ms,pressure_kPa\n"
            + load.history.map { String(format: "%.3f,%.3f", $0.x * 1000, $0.y / 1000) }.joined(
                separator: "\n")
            + "\n"
        try applied.write(to: out.appending(path: "\(slab.name)-load.csv"), atomically: true, encoding: .utf8)
        let plans =
            "Face away from the blast (rows across the width; x along the span to the right):\n"
            + result.damage.backPlan.joined(separator: "\n") + "\n\nBlast face:\n"
            + result.damage.blastPlan.joined(separator: "\n") + "\n"
        try plans.write(to: out.appending(path: "\(slab.name)-cracks.txt"), atomically: true, encoding: .utf8)
        try writeCrackImage(result.damage.backCracks, to: out.appending(path: "\(slab.name)-back.png"))
        try writeCrackImage(result.damage.blastCracks, to: out.appending(path: "\(slab.name)-blast.png"))
    }
}
