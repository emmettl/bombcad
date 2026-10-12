import BlastCore
import Foundation
import Metal
import simd

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
                + "(0.5 ms %6.1f)  force %6.1f kN (raw %6.1f)  left %@%@  penetration %5.2f mm  bottom gone %.3f m²  "
                + "layers %d/%d  %@  removed %d bare %d  %.0f s",
            impact.number, impact.mass, impact.peakDisplacement * 1000, impact.peakTime * 1000,
            impact.residualDisplacement * 1000, impact.residualTail * 1000, impact.peakReaction / 1000,
            impact.peakReactionAveraged / 1000, impact.peakImpactForce / 1000,
            impact.peakImpactForceRaw / 1000,
            impact.weightLeft.map { String(format: "%.1f ms", $0 * 1000) } ?? "never",
            impact.faceReseated ? " (face re-seated)" : "",
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
        // `--cone`: trace the punching cone (`ConeTrace`); `--work` with it, the work by mechanism.
        let cone = flag("cone") ? ConeTrace(slab: slab, aggregate: inputs.aggregateSize) : nil
        var traced: StructureSolver?
        let result = try HrynykSlabTest.run(
            device: device, slab: slab, inputs: inputs, settings: settings, masses: masses,
            progress: { print(line($0)) },
            adjust: { model in
                applyRateOptions(&model)
                // `--no-rate`: the concrete without its strain-rate laws.
                if flag("no-rate") {
                    model.material.rateDependent = false
                    model.solidMaterial = model.solidMaterial.map {
                        $0.map {
                            var m = $0
                            m.rateDependent = false
                            return m
                        }
                    }
                }
                if let bond = chosenBondSlip(diameter: slab.barArea.squareRoot() * 2 / Float.pi.squareRoot())
                {
                    model.bondSlip = bond
                }
            },
            prepare: { solver, _ in
                traced = solver
                prepareTrace(solver)
            },
            inspect: { solver, l, impact, t in cone?.inspect(solver, l, impact, t) })
        if let cone, let traced { cone.reportWork(traced, cone.lastImpact) }
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

/// `blastbench hrynyk --cone`: the punching cone traced through each impact. Through the slab's
/// centre section (along x), elements on a 45-degree line down and out from the weight face's
/// edge, every 0.5 ms: the widest crack's opening and the angle of its normal from vertical, the
/// normal stress across it and the shear along it, aggregate interlock's capacity at that opening
/// (Vecchio and Collins's 0.18 sqrt(fc) / (0.31 + 24 w / (a + 16))), the largest confinement gain
/// and the strain rate. And with the work trace, each impact's work by mechanism in the cone's band
/// (from the face's edge to a thickness beyond it, in plan) and in the whole slab.
final class ConeTrace {
    let slab: HrynykSlabTest.Slab
    let aggregate: Float
    var next = 0.0
    var lastImpact = 0
    var workAtStart: [Double] = []
    var bandAtStart: [Double] = []
    var layout: HrynykSlabTest.Layout?

    init(slab: HrynykSlabTest.Slab, aggregate: Float) {
        self.slab = slab
        self.aggregate = aggregate
    }

    func inBand(_ l: HrynykSlabTest.Layout) -> (Int, Int, Int) -> Bool {
        { i, j, k in
            guard k >= l.slabBottom, k < l.slabTop else { return false }
            let r = max(abs(Float(i) + 0.5 - Float(l.centre)), abs(Float(j) + 0.5 - Float(l.centre)))
            return r >= Float(l.faceHalf) - 1 && r <= Float(l.faceHalf + l.thicknessElements) + 2
        }
    }

    func reportWork(_ solver: StructureSolver, _ impact: Int) {
        guard let l = layout, solver.tracesWork, !workAtStart.isEmpty else { return }
        let all = zip(solver.workTotals(), workAtStart).map { $0 - $1 }
        let band = zip(solver.workTotals(where: inBand(l)), bandAtStart).map { $0 - $1 }
        print("    impact \(impact) work by mechanism (J):")
        print("    " + workHeader("", 8))
        print("    " + workRow("cone", 8, band))
        print("    " + workRow("slab", 8, all))
    }

    func inspect(_ solver: StructureSolver, _ l: HrynykSlabTest.Layout, _ impact: Int, _ t: Double) {
        layout = l
        if impact != lastImpact {
            if lastImpact > 0 { reportWork(solver, lastImpact) }
            lastImpact = impact
            next = 0
            if solver.tracesWork {
                workAtStart = solver.workTotals()
                bandAtStart = solver.workTotals(where: inBand(l))
            }
            print("  impact \(impact):")
        }
        guard t >= next - 1e-9, t <= 0.02 else { return }
        next += 0.0005
        let h = l.h
        let j = l.centre
        let fc = slab.compressiveStrength / 1e6
        var text = "    \(String(format: "%5.1f", t * 1000)) ms"
        for m in [1, l.thicknessElements / 2, l.thicknessElements - 2] {
            let i = l.centre + l.faceHalf + m
            let k = l.slabTop - 1 - m
            let flag = solver.flag(i, j, k)
            guard flag == .active else {
                text += "  [\(m)] \(flag == .bare ? "bare" : "gone")"
                continue
            }
            let planes = solver.crackPlanes(i, j, k)
            let p =
                planes.history.x >= planes.history.y
                ? (planes.history.x >= planes.history.z ? 0 : 2)
                : (planes.history.y >= planes.history.z ? 1 : 2)
            let w = planes.history[p] * h * 1000  // mm
            let n = planes.normals.count == 3 ? planes.normals[p] : SIMD3<Float>(0, 0, 1)
            let s = solver.stress(i, j, k)
            let sigma = simd_float3x3(
                SIMD3(s[0], s[3], s[5]), SIMD3(s[3], s[1], s[4]), SIMD3(s[5], s[4], s[2]))
            let traction = sigma * n
            let normal = simd_dot(traction, n)
            let shear = simd_length(traction - normal * n)
            let cap = 0.18 * fc.squareRoot() / (0.31 + 24 * w / (aggregate * 1000 + 16))
            let angle = acos(min(abs(n.z), 1)) * 180 / .pi
            let gain = solver.confinementGain(i, j, k).max()
            text += String(
                format: "  [%d] w %.2f mm %2.0f° σn %5.1f τ %4.1f cap %4.1f MPa g %.2f %3.0f/s", m, w, angle,
                normal / 1e6, shear / 1e6, cap, gain, solver.strainRate(i, j, k))
        }
        print(text)
        // Under the face: the top two layers at its centre and inside its edge, with the largest
        // compressive strain so far, the confinement gain, the vertical stress and any compaction.
        var under = "            under"
        for (offset, depth) in [(0, 0), (0, 1), (l.faceHalf - 1, 0), (l.faceHalf - 1, 1)] {
            let (i, k) = (l.centre + offset, l.slabTop - 1 - depth)
            guard solver.flag(i, j, k) == .active else {
                under += "  [\(offset),\(depth)] \(solver.flag(i, j, k) == .bare ? "bare" : "gone")"
                continue
            }
            under += String(
                format: "  [%d,%d] εc %.4f g %.2f σz %6.1f MPa compacted %.3f", offset, depth,
                solver.plasticStrain(i, j, k), solver.confinementGain(i, j, k).max(),
                solver.stress(i, j, k)[2] / 1e6, solver.compaction(i, j, k))
        }
        print(under)
    }
}
