import BlastCore
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

// Blind test 2 (docs/blind-tests.md): Mendonça et al.'s slabs under an open-air charge, built
// from Samples/Mendonca2020/inputs alone (see MendoncaSlabTest.swift):
//
//   blastbench mendonca [--slabs 1,2,4,5,7,9,10] [--layers 8] [--dx 0.0125] [--refine 2] [--mapped]
//                       [--time 0.2] [--heavy-across] [--lift 0.1] [--timber] [--awake]
//                       [--inputs Samples/Mendonca2020/inputs/slabs.json] [--out dir]
//                       after the reveal: [--charge-factor 1.5] [--ft-factor 0.5] [--gf-factor 1] [--fc-factor 1]
//                       [--fy-factor 1] [--afterburn] [--no-rate] [--bond splitting] [--rate-window steps]
//                       [--margin 1] [--domain-height 3.2] [--under-block 0.06]
//                       [--ensemble 8 [--seed 1] [--samples 1-8]]   (the inputs' spread)
//
// Writes each slab's result as JSON, its histories as CSV and its faces' cracks as PNG and text
// into --out (default /Volumes/StudioData/bombcad/mendonca-prediction/run); with --ensemble, each
// sample's result, without its histories, into its ensemble folder.

func runMendonca(device: MTLDevice) throws {
    let inputs = try MendoncaSlabTest.inputs(
        from: URL(filePath: option("inputs") ?? "Samples/Mendonca2020/inputs/slabs.json"))
    var settings = MendoncaSlabTest.Settings()
    if let layers = option("layers").flatMap({ Int($0) }) { settings.elementsThroughDepth = layers }
    if let dx = option("dx").flatMap({ Float($0) }) { settings.cellSize = dx }
    if let refine = option("refine").flatMap({ Int($0) }) { settings.refinement = refine }
    if flag("mapped") { settings.mappedCharge = true }
    if let time = option("time").flatMap({ Double($0) }) { settings.duration = time }
    if flag("heavy-across") { settings.heavyBarsAlongSpan = false }
    if flag("timber") { settings.timberBearings = true }
    if flag("awake") { settings.airAwake = true }
    if let lift = option("lift").flatMap({ Float($0) }) { settings.chargeLift = lift }
    // Studies after the reveal: the charge, and the concrete's and bars' strengths, scaled.
    if let factor = option("charge-factor").flatMap({ Float($0) }) { settings.chargeFactor = factor }
    if let factor = option("fc-factor").flatMap({ Float($0) }) { settings.fcFactor = factor }
    if let factor = option("ft-factor").flatMap({ Float($0) }) { settings.ftFactor = factor }
    if let factor = option("gf-factor").flatMap({ Float($0) }) { settings.gfFactor = factor }
    if let factor = option("fy-factor").flatMap({ Float($0) }) { settings.fyFactor = factor }
    // `--margin 2 --domain-height 5`: more air round the slab; `--under-block 0.06`: a rigid block
    // under the slab between its bearings, 60 mm below it, keeping the wave from beneath.
    if let margin = option("margin").flatMap({ Float($0) }) { settings.margin = margin }
    if let height = option("domain-height").flatMap({ Float($0) }) { settings.domainHeight = height }
    if let gap = option("under-block").flatMap({ Float($0) }) { settings.underBlockGap = gap }
    // `--soft-supports 6e7 [--support-capacity 130e3]`: the bearings as soft ground (Pa/m, Pa).
    if let modulus = option("soft-supports").flatMap({ Float($0) }) { settings.softSupportModulus = modulus }
    if let capacity = option("support-capacity").flatMap({ Float($0) }) {
        settings.softSupportCapacity = capacity
    }
    // `--record 0.06`: the gauges' pressures kept to 60 ms; `--hold-down`: the slab tied to its
    // bearings, unable to lift off.
    if let record = option("record").flatMap({ Double($0) }) { settings.pressureRecord = record }
    if flag("hold-down") { settings.holdDown = true }
    let names = option("slabs")?.split(separator: ",").map(String.init)
    let slabs = inputs.slabs.filter { names?.contains($0.name) ?? true }
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/mendonca-prediction/run")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    func line(_ r: MendoncaSlabTest.Result) -> String {
        let d = r.damage
        let corners = r.gauges.prefix(5).map {
            String(format: "%@ %.0f kPa %.0f kPa ms", $0.name, $0.peak / 1000, $0.impulse)
        }.joined(separator: "; ")
        return String(
            format:
                "  slab %@: %@; peak %.2f mm at %.2f ms, end %.2f mm (last 10 ms %.2f), rebound %.2f mm; "
                + "concrete spans %@, bars span %@; %d pieces (largest %.0f%%), removed %d bare %d, bars ruptured %d; "
                + "top gone %.4f m² crushed %.4f m², bottom gone %.4f m²%@; %.0f s\n    %@",
            r.slab.name, d.collapses ? "COLLAPSES" : "survives", r.peakDisplacement * 1000, r.peakTime * 1000,
            r.endDisplacement * 1000, r.endDisplacementMean * 1000, r.largestRebound * 1000,
            d.concreteSpans ? "yes" : "no", d.barsSpan ? "yes" : "no", d.pieces, d.largestShare * 100,
            d.removed,
            d.bare, d.barElementsRuptured, d.topGone, d.topCrushed, d.bottomGone, r.blownUp ? " BLEW UP" : "",
            r.wallSeconds, corners)
    }

    if let count = option("ensemble").flatMap({ Int($0) }) {
        let seed = option("seed").flatMap { UInt64($0) } ?? 1
        let range = option("samples").map { text -> ClosedRange<Int> in
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 2 ? parts[0]...parts[1] : (parts.first ?? 1)...(parts.first ?? count)
        }
        let folder = out.appending(path: "ensemble")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = MendoncaSlabTest.ensembleSamples(count: count, seed: seed)
        for slab in slabs {
            for (index, values) in samples.enumerated() where range?.contains(index) ?? (index > 0) {
                let file = folder.appending(path: "\(slab.name)-\(index).json")
                if FileManager.default.fileExists(atPath: file.path) { continue }
                print("slab \(slab.name) sample \(index): \(values.sorted { $0.key < $1.key })")
                var result = try MendoncaSlabTest.run(
                    device: device, slab: slab, inputs: inputs,
                    settings: MendoncaSlabTest.settings(settings, values: values))
                print(line(result))
                result.history = []
                result.bodyHistory = []
                result.pressureHistory = []
                result.damage.bottomCracks = []
                result.damage.topCracks = []
                struct Sample: Encodable {
                    var index: Int
                    var values: [String: Double]
                    var result: MendoncaSlabTest.Result
                }
                try encoder.encode(Sample(index: index, values: values, result: result)).write(to: file)
            }
        }
        return
    }

    print(
        String(
            format: "Mendonça's slabs, %d elements through, air in %.4g m cells%@%@, %.0f ms\n",
            settings.elementsThroughDepth, settings.cellSize,
            settings.refinement > 1 ? " refined by \(settings.refinement)" : "",
            settings.mappedCharge ? ", mapped start" : "", settings.duration * 1000))
    for slab in slabs {
        print(
            String(
                format: "slab %@: layout %@, %.0f MPa, %.0f kg/m³, %.2f kg at %.2f m", slab.name,
                slab.layout.rawValue, slab.compressiveStrength / 1e6, slab.density, slab.charge, slab.standoff
            ))
        // Studies after the reveal: the rate, hourglass and bond options (`--no-rate`, `--bond`,
        // `--rate-window`, ...) on the slab, and `--afterburn` in the air.
        let result = try MendoncaSlabTest.run(
            device: device, slab: slab, inputs: inputs, settings: settings,
            adjust: { scenario in
                guard var model = scenario.structure else { return }
                if flag("no-rate") { model.material.rateDependent = false }
                if let bond = chosenBondSlip(diameter: inputs.meshBar) { model.bondSlip = bond }
                applyRateOptions(&model)
                scenario.structure = model
            },
            configure: { solver in
                if flag("afterburn") {
                    solver.configuration.afterburning = true
                    solver.configuration.mappedCharge = false
                }
                // `--far-field`: open faces that stand ambient air beyond them, not copies of the cells
                // inside; `--recommended`: the recommended air (hot air, afterburning, far-field faces).
                if flag("far-field") { solver.configuration.openFaces = .farField }
                if flag("recommended") {
                    let recommended = SolverConfiguration.recommended
                    solver.configuration.airModel = recommended.airModel
                    solver.configuration.afterburning = recommended.afterburning
                    solver.configuration.openFaces = recommended.openFaces
                    solver.configuration.mappedCharge = false
                }
            },
            progress: { print("  " + $0) })
        print(line(result))
        print(
            String(
                format: "  %d elements of %.2f mm, %d air cells; air asleep at %@\n", result.elementCount,
                result.elementSize * 1000, result.cellCount,
                result.airSleptAt.map { String(format: "%.1f ms", $0 * 1000) } ?? "never"))
        try encoder.encode(result).write(to: out.appending(path: "slab\(slab.name).json"))
        let displacement =
            "time_ms,centre_displacement_mm\n"
            + result.history.map { String(format: "%.2f,%.4f", $0.x * 1000, $0.y * 1000) }.joined(
                separator: "\n")
            + "\n"
        try displacement.write(
            to: out.appending(path: "slab\(slab.name)-displacement.csv"), atomically: true, encoding: .utf8)
        let body =
            "time_ms,mean_lift_mm,near_bearing_lift_mm,far_bearing_lift_mm\n"
            + result.bodyHistory.map {
                String(format: "%.2f,%.4f,%.4f,%.4f", $0.x * 1000, $0.y * 1000, $0.z * 1000, $0.w * 1000)
            }.joined(separator: "\n") + "\n"
        try body.write(
            to: out.appending(path: "slab\(slab.name)-flight.csv"), atomically: true, encoding: .utf8)
        let header = (["time_ms"] + result.gauges.map { "\($0.name)_kPa" }).joined(separator: ",")
        let rows = (0..<(result.pressureHistory.first?.count ?? 0)).map { n in
            ([String(format: "%.3f", Double(n) * settings.pressureInterval * 1000)]
                + result.pressureHistory.map { String(format: "%.2f", $0[n] / 1000) }).joined(separator: ",")
        }
        try ([header] + rows).joined(separator: "\n").appending("\n").write(
            to: out.appending(path: "slab\(slab.name)-pressure.csv"), atomically: true, encoding: .utf8)
        let plans =
            "Bottom face (rows along y, top row at y high; x rising to the right):\n"
            + result.damage.bottomPlan.joined(separator: "\n") + "\n\nTop face:\n"
            + result.damage.topPlan.joined(separator: "\n") + "\n"
        try plans.write(
            to: out.appending(path: "slab\(slab.name)-cracks.txt"), atomically: true, encoding: .utf8)
        try writeCrackImage(
            result.damage.bottomCracks, to: out.appending(path: "slab\(slab.name)-bottom.png"))
        try writeCrackImage(result.damage.topCracks, to: out.appending(path: "slab\(slab.name)-top.png"))
    }
}

/// A face's crack field as a PNG, four pixels an element, y rising up the image and x to the
/// right: white uncracked, darkening to black at a 1 mm opening (as its square root), red where
/// the concrete is removed and orange where it is left as bare bars.
func writeCrackImage(_ field: [[Float]], to url: URL) throws {
    let scale = 4
    let rows = field.count
    let columns = field.first?.count ?? 0
    guard rows > 0, columns > 0 else { return }
    let width = columns * scale
    let height = rows * scale
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for (j, row) in field.enumerated() {
        for (i, value) in row.enumerated() {
            let colour: (UInt8, UInt8, UInt8)
            if value == -1 {
                colour = (220, 30, 30)
            } else if value == -2 {
                colour = (240, 150, 0)
            } else {
                let grey = UInt8((255 * (1 - min(max(value, 0) / 1, 1).squareRoot())).rounded())
                colour = (grey, grey, grey)
            }
            for dy in 0..<scale {
                for dx in 0..<scale {
                    let y = (rows - 1 - j) * scale + dy
                    let p = 4 * (y * width + i * scale + dx)
                    (pixels[p], pixels[p + 1], pixels[p + 2], pixels[p + 3]) = (
                        colour.0, colour.1, colour.2, 255
                    )
                }
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw BlastError.allocationFailed("crack image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BlastError.allocationFailed("crack image") }
}
