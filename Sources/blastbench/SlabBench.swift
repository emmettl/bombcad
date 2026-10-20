import BlastCore
import Foundation
import Metal
import simd

// `blastbench slab`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The cracks on the slab's unloaded face at 80 ms, in plan, wider than `--plan` millimetres (0.1
/// by default; a crack's width is its strain over its band: the element with bars that slip, the
/// crack spacing without), and where the cracking lies along the span: columns of elements cracked
/// that wide across most of the width, whose opening, averaged across it, is the largest within
/// an element either side, and the length of span holding nine tenths of the face's opening.
func printSlabCrackPlan(_ solver: StructureSolver) {
    let h = solver.model.elementSize
    let band = solver.model.bondSlip != nil ? h : max(h, solver.model.material.crackSpacing)
    let visible = (option("plan").flatMap { Float($0) } ?? 0.1) / 1000
    let threshold = visible / band
    print(
        "  cracks wider than \(format(Double(visible) * 1000, 2)) mm on the unloaded face at 80 ms, in plan "
            + "(supports at the ^):")
    let supports = [6, 58].map { Int((Float($0) * 0.0254 / h).rounded()) }
    print("    " + String((0..<solver.ex).map { supports.contains($0) ? "^" : " " }))
    for row in solver.crackPlan(layer: 0, threshold: threshold) { print("    " + row) }
    var mean = [Float](repeating: 0, count: solver.ex)
    var share = [Float](repeating: 0, count: solver.ex)
    for i in 0..<solver.ex {
        for j in 0..<solver.ey {
            let opening = solver.crackOpening(i, j, 0)
            mean[i] += opening / Float(solver.ey)
            if opening > threshold { share[i] += 1 / Float(solver.ey) }
        }
    }
    let middle = Float(solver.ex) / 2
    var lines: [(at: Float, width: Float)] = []
    for i in 0..<solver.ex where share[i] > 0.5 {
        let left = i > 0 ? mean[i - 1] : 0
        let right = i + 1 < solver.ex ? mean[i + 1] : 0
        if mean[i] >= left && mean[i] > right {
            lines.append(((Float(i) + 0.5 - middle) * h, mean[i] * band))
        }
    }
    print("  lines of cracking across the width (mm from mid-span: mean width across it, mm):")
    print(
        "    "
            + lines.map { "\(format(Double($0.at) * 1000, 0)): \(format(Double($0.width) * 1000, 2))" }
            .joined(separator: ", "))
    let gaps = zip(lines, lines.dropFirst()).map { $1.at - $0.at }
    if let first = lines.first, let last = lines.last, !gaps.isEmpty {
        print(
            "  \(lines.count) lines over \(format(Double(last.at - first.at) * 1000, 0)) mm, "
                + "\(format(Double(gaps.reduce(0, +) / Float(gaps.count)) * 1000, 0)) mm apart on average")
    }
    // The shortest run of columns holding nine tenths of the opening along the face.
    let total = mean.reduce(0, +)
    var shortest = (from: 0, to: solver.ex - 1)
    for from in 0..<solver.ex {
        var sum: Float = 0
        for to in from..<solver.ex {
            sum += mean[to]
            if sum >= 0.9 * total {
                if to - from < shortest.to - shortest.from { shortest = (from, to) }
                break
            }
        }
    }
    print(
        "  nine tenths of the opening along the face within \(format(Double(shortest.to - shortest.from + 1) * Double(h) * 1000, 0)) mm, "
            + "from \(format(Double((Float(shortest.from) - middle) * h) * 1000, 0)) to "
            + "\(format(Double((Float(shortest.to + 1) - middle) * h) * 1000, 0)) mm; the face opened "
            + "\(format(Double(total * h) * 1000, 1)) mm in all")
}

/// The bars' share of element (i, j, k)'s Cauchy stress along x, times h²: from their force with
/// bars that slip (per unit reference area, so times the element's stretch), else E_s (λ − 1 −
/// ε_p) ρ, exact while they are loaded one way.
func barShare(_ solver: StructureSolver, _ i: Int, _ j: Int, _ k: Int, steelModulus: Float) -> Float {
    let h = solver.model.elementSize
    var stretch: Float = 0
    for (b, c) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        stretch +=
            (simd_length(solver.position(i + 1, j + b, k + c) - solver.position(i, j + b, k + c)) / h - 1) / 4
    }
    if let force = solver.barForce(i, j, k) { return force.x * (1 + stretch) }
    let plastic = solver.barPlasticStrain(i, j, k).x
    return abs(plastic) < 1e8 ? steelModulus * (stretch - plastic) * solver.steelRatio(i, j, k).x * h * h : 0
}

/// `--stiffening`: where the tension along the span is carried, over the columns of elements
/// `columns` (along x), summed over each column and averaged over them, in kN: the bars, and the
/// concrete in tension by its crack across x (opened by its strain past the cracking strain
/// over its band): never cracked, cracked under 0.02 mm, 0.02 to 0.1 mm and wider. With
/// `profile`, column by column too. Bars that slip report their force; bonded bars' force is E_s (ε − ε_p), from the
/// element's stretch along x.
func tensionStiffening(_ solver: StructureSolver, columns: Range<Int>, label: String, profile: Bool) {
    let h = solver.model.elementSize
    let material = solver.model.material
    let band = solver.model.bondSlip != nil ? h : max(h, material.crackSpacing)
    let steelModulus = material.steel?.youngsModulus ?? 200e9
    var parts = [Double](repeating: 0, count: 5)  // bars, uncracked, <0.02, 0.02-0.1, wider
    var rows: [String] = []
    var layers = [[Double]](repeating: [Double](repeating: 0, count: 5), count: solver.ez)
    var net = [Double](repeating: 0, count: solver.ez)
    for i in columns {
        var column = [Double](repeating: 0, count: 5)
        var widest: Float = 0
        for j in 0..<solver.ey {
            for k in 0..<solver.ez where solver.flag(i, j, k) == .active {
                let ratio = solver.steelRatio(i, j, k).x
                let bar = ratio > 0 ? barShare(solver, i, j, k, steelModulus: steelModulus) : 0
                column[0] += Double(bar)
                let concrete = solver.stress(i, j, k)[0] * h * h - bar
                if k < solver.ez - 2 { net[k] += Double(concrete) / Double(columns.count) }
                guard concrete > 0 else { continue }
                let planes = solver.crackPlanes(i, j, k)
                // The plane whose normal lies nearest x.
                let plane = (0..<3).max { abs(planes.normals[$0].x) < abs(planes.normals[$1].x) } ?? 0
                let factor = solver.crackingFactor(i, j, k)
                let onset =
                    material.tensileStrength * material.concreteRateFactor * max(factor, 1)
                    / material.youngsModulus
                let opening = factor > 0 ? max(planes.history[plane] - onset, 0) * band : 0
                widest = max(widest, k == 0 ? opening : 0)
                let bin = factor == 0 ? 1 : opening < 2e-5 ? 2 : opening < 1e-4 ? 3 : 4
                column[bin] += Double(concrete)
                layers[k][bin] += Double(concrete) / Double(columns.count)
            }
        }
        for n in 0..<5 { parts[n] += column[n] / Double(columns.count) }
        if profile {
            let concrete = column[1...4].reduce(0, +)
            rows.append(
                "    \(pad(format(Double((Float(i) + 0.5 - Float(solver.ex) / 2) * h) * 1000, 0), 6)) mm: bars "
                    + "\(pad(format(column[0] / 1000, 1), 6)), concrete \(pad(format(concrete / 1000, 1), 6)) kN "
                    + "(uncracked \(pad(format(column[1] / 1000, 1), 5)), <0.02 mm \(pad(format(column[2] / 1000, 1), 5)), "
                    + "0.02-0.1 \(pad(format(column[3] / 1000, 1), 5)), wider \(pad(format(column[4] / 1000, 1), 5))); "
                    + "face crack \(format(Double(widest) * 1000, 2)) mm")
        }
    }
    if profile, flag("line") {
        // `--line`: along the span at mid-width, in the two layers of elements the bars run
        // through: the bars' force and the concrete's stress along x, the crack across x, and the
        // bars' slip at the node between the layers.
        let j = solver.ey / 2
        let bottom = (0..<solver.ez).first { solver.steelRatio(columns.lowerBound, j, $0).x > 0 } ?? 1
        print("    along the span at mid-width, bars in layers \(bottom) and \(bottom + 1):")
        print("        x mm   bars kN   concrete MPa     crack mm      slip mm  largest")
        for i in columns {
            var bars: Float = 0
            var concrete: [Float] = []
            var cracks: [Float] = []
            for k in bottom...(bottom + 1) {
                let bar = barShare(solver, i, j, k, steelModulus: steelModulus)
                bars += bar
                concrete.append((solver.stress(i, j, k)[0] * h * h - bar) / (h * h))
                let planes = solver.crackPlanes(i, j, k)
                let nearest = (0..<3).max { abs(planes.normals[$0].x) < abs(planes.normals[$1].x) } ?? 0
                let factor = solver.crackingFactor(i, j, k)
                let onset = material.tensileStrength * max(factor, 1) / material.youngsModulus
                cracks.append(factor > 0 ? max(planes.history[nearest] - onset, 0) * band : 0)
            }
            let slip = solver.barSlip(i, j, bottom + 1)
            var line = "    " + pad(format(Double((Float(i) + 0.5 - Float(solver.ex) / 2) * h) * 1000, 0), 8)
            line += pad(format(Double(bars) / 1000, 2), 10)
            line += concrete.map { pad(format(Double($0) / 1e6, 2), 7) }.joined()
            line += cracks.map { pad(format(Double($0) * 1000, 3), 7) }.joined()
            line +=
                pad(format(Double(slip?.slip.x ?? 0) * 1000, 3), 9)
                + pad(format(Double(slip?.largest.x ?? 0) * 1000, 3), 9)
            print(line)
        }
    }
    if profile, let column = option("column").flatMap({ Float($0) }) {
        // `--column -44`: that column (mm from mid-span) element by element, at mid-width.
        let i = Int((column / 1000 / h + Float(solver.ex) / 2).rounded(.down))
        let j = solver.ey / 2
        print(
            "    column \(i), mid-width, bottom first: concrete and bar stress (MPa), crack history, rate factor"
        )
        for k in 0..<solver.ez {
            let planes = solver.crackPlanes(i, j, k)
            let bar: Float = barShare(solver, i, j, k, steelModulus: steelModulus)
            let sigma = solver.stress(i, j, k)
            let total: Double = Double(sigma[0]) / 1e6
            let barStress: Double = Double(bar / (h * h)) / 1e6
            // The concrete's stress across the crack nearest x, and the shear on it.
            let tensor = simd_float3x3(
                SIMD3(sigma[0] - bar / (h * h), sigma[3], sigma[5]), SIMD3(sigma[3], sigma[1], sigma[4]),
                SIMD3(sigma[5], sigma[4], sigma[2]))
            let nearest = (0..<3).max { abs(planes.normals[$0].x) < abs(planes.normals[$1].x) } ?? 0
            let traction = tensor * planes.normals[nearest]
            let across = simd_dot(traction, planes.normals[nearest])
            let along = simd_length(traction - across * planes.normals[nearest])
            let history: [String] = (0..<3).map { format(Double(planes.history[$0]) * 1e3, 3) }
            let normals: [String] = planes.normals.map { n -> String in
                let parts: [String] = [n.x, n.y, n.z].map { format(Double($0), 2) }
                return "(" + parts.joined(separator: ",") + ")"
            }
            var line =
                "      k \(k): total \(format(total, 2)), bars \(format(barStress, 2)), concrete across the crack "
            line +=
                "\(format(Double(across) / 1e6, 2)), shear on it \(format(Double(along) / 1e6, 2)), history "
            line += history.joined(separator: " ") + " e-3, normals " + normals.joined(separator: " ")
            line +=
                ", factor \(format(Double(solver.crackingFactor(i, j, k)), 2)), ratio \(solver.steelRatio(i, j, k).x)"
            line += ", stress " + sigma.map { format(Double($0) / 1e6, 2) }.joined(separator: " ")
            print(line)
        }
    }
    let concrete = parts[1...4].reduce(0, +)
    print(
        "  \(label): bars \(format(parts[0] / 1000, 1)) kN, concrete in tension \(format(concrete / 1000, 1)) kN "
            + "(\(format(100 * concrete / max(parts[0] + concrete, 1), 0))% of the tension): uncracked "
            + "\(format(parts[1] / 1000, 1)), under 0.02 mm \(format(parts[2] / 1000, 1)), 0.02-0.1 mm "
            + "\(format(parts[3] / 1000, 1)), wider \(format(parts[4] / 1000, 1))")
    for row in rows { print(row) }
    if profile {
        print("    by layer, bottom first (kN): uncracked, under 0.02 mm, 0.02-0.1, wider")
        for (k, layer) in layers.enumerated() {
            print(
                "      k \(k): " + layer[1...4].map { pad(format($0 / 1000, 1), 6) }.joined()
                    + "   net, tension and compression: \(format(net[k] / 1000, 1))")
        }
    }
}

func runSlab() throws {
    if flag("unload") {
        // `--unload`: pushed slowly at mid-span to the test's peak, then released.
        let layers = option("layers").flatMap { Int($0) } ?? 8
        let to = option("to").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.105
        let strengths: [SlabBenchmark.RateTreatment] =
            flag("rate-only") ? [.strainRate] : flag("static-only") ? [.none] : [.none, .strainRate]
        for strength in strengths {
            let result = try SlabBenchmark.pushAndRelease(
                device: device, elementsThroughThickness: layers, deflection: to, strength: strength,
                width: option("strip").flatMap { Float($0) }.map { $0 / 1000 } ?? SlabBenchmark.fullWidth,
                adjust: { model in applyRateOptions(&model) },
                trace: flag("trace")
                    ? { time, deflection, push in
                        print(
                            "  \(format(time * 1000, 0)) ms: \(format(Double(deflection) * 1000, 1)) mm, \(format(Double(push) / 1000, 1)) kN"
                        )
                        fflush(stdout)
                    } : nil,
                shapes: { peak, left in
                    print(
                        "  at peak (mm, support to mid-span): "
                            + peak.map { format(Double($0) * 1000, 1) }.joined(separator: " "))
                    print(
                        "  left:                              "
                            + left.map { format(Double($0) * 1000, 1) }.joined(separator: " "))
                    print(
                        "  recovered:                         "
                            + zip(peak, left).map { format(Double($0 - $1) * 1000, 1) }.joined(separator: " ")
                    )
                },
                hinge: flag("hinge")
                    ? { label, rows in
                        print("  \(label):")
                        for row in rows { print("    " + row) }
                    } : nil)
            print(
                "\(strength.rawValue): pushed to \(format(Double(result.reached) * 1000, 1)) mm with "
                    + "\(format(Double(result.force) / 1000, 1)) kN at most, \(format(Double(result.residual) * 1000, 1)) mm left"
            )
        }
        return
    }
    let load = SlabBenchmark.load
    print("Blast Blind Simulation Contest slab (normal-strength concrete, Grade 60 bars)")
    print(
        "Load: peak \(format(Double((load.history.map(\.y).max() ?? 0) / 6894.76))) psi after scaling the "
            + "hand-read record to the stated \(format(Double(load.impulse / 6.89476), 0)) psi ms")
    print(
        "Measured: peak \(format(Double(SlabBenchmark.measuredPeak) * 1000, 0)) mm at about "
            + "\(format(Double(SlabBenchmark.measuredPeakTime) * 1000, 0)) ms, "
            + "\(format(Double(SlabBenchmark.measuredResidual) * 1000, 0)) mm at the end of the record\n")
    print(
        pad("layers", 8) + pad("elements", 10) + pad("strength", 14) + pad("peak", 10) + pad("vs test", 9)
            + pad("at", 8) + pad("residual", 10) + pad("vs test", 9) + pad("failed", 8) + pad("run time", 10))
    var cases: [(Int, SlabBenchmark.RateTreatment)] = [
        (8, .strainRate), (4, .strainRate), (8, .designFactors), (8, .none),
    ]
    // `--layers 16,32` runs just those meshes, with the strain-rate laws; `--strip 25` runs a
    // strip of the slab that many millimetres wide, which bends the same way, for fine meshes.
    if let layers = option("layers") {
        cases = layers.split(separator: ",").compactMap { Int($0) }.map { ($0, .strainRate) }
    }
    let width = option("strip").flatMap { Float($0) }.map { $0 / 1000 } ?? SlabBenchmark.fullWidth
    var meshes: [(layers: Int, result: SlabBenchmark.Result)] = []
    // `--shells 2,1` runs shells of those sizes in inches instead, with `--shell-layers` layers.
    if let sizes = option("shells") {
        cases = []
        let layers = option("shell-layers").flatMap { Int($0) } ?? 8
        for size in sizes.split(separator: ",").compactMap({ Float($0) }) {
            let rate =
                option("shell-rate").flatMap { SlabBenchmark.RateTreatment(rawValue: $0) } ?? .strainRate
            let result = try SlabBenchmark.runShells(
                device: device, elementSize: size * 0.0254, layers: layers, rate: rate, width: width)
            meshes.append((layers, result))
            print(
                pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                    + pad("shells \(format(Double(size), 2)) in", 14)
                    + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 9)
                    + pad("\(format(Double(result.peakTime) * 1000, 0)) ms", 8)
                    + pad("\(format(Double(result.residual) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.residual / SlabBenchmark.measuredResidual) * 100, 0))%", 9)
                    + pad("\(result.summary.erodedElements)", 8)
                    + pad("\(format(result.wallSeconds, 1)) s", 10))
        }
    }
    for (layers, rate) in cases {
        // `--held-bearings` supports the slab on 1 in bearings that hold it down.
        let supports: SlabBenchmark.Supports =
            flag("held-bearings") ? .bearings(width: 0.0254, holdDown: true) : .lines
        // `--work`: the work each mechanism has done every 20 mm on the way down, at the peak and
        // at the end, through the whole slab, and at the peak by part of it.
        var milestones: [(label: String, totals: [Double])] = []
        var atPeak: (deflection: Float, totals: [Double], parts: [[Double]])?
        var shownBreakdown = false
        let regions: [(String, (Int, Int, Int, StructureSolver) -> Bool)] = [
            ("loaded half", { _, _, k, s in 2 * k >= s.ez }),
            ("unloaded half", { _, _, k, s in 2 * k < s.ez }),
            (
                "600 mm about mid-span",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize < 0.3 }
            ),
            (
                "the rest",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize >= 0.3 }
            ),
            (
                "unloaded half, 600 mm",
                { i, _, k, s in
                    2 * k < s.ez && abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize < 0.3
                }
            ),
        ]
        // `--load-scale 0.764`: the pressure record scaled, as for the contest's lower-impulse shot.
        let result = try SlabBenchmark.run(
            device: device, elementsThroughThickness: layers, rate: rate,
            loadScale: option("load-scale").flatMap { Float($0) } ?? 1, supports: supports, width: width,
            // `--span 58`: the supports that many inches apart (52 by default).
            span: option("span").flatMap { Float($0) }.map { $0 * 0.0254 } ?? SlabBenchmark.span,
            bondSlip: chosenBondSlip(diameter: 0.0095),
            adjust: { applyRateOptions(&$0) },
            adjustModel: {
                if flag("pressed-interlock") { $0.pressedInterlock = true }
                applyHourglassOptions(&$0)
            },
            prepare: prepareTrace,
            sample: flag("discrete-trace")
                ? { solver in
                    // `--discrete-trace`: the discrete bars' ruptures every millisecond, and the
                    // largest plastic strain and force of any segment.
                    let millisecond = Int((solver.time * 1000).rounded(.down))
                    guard millisecond > (milestones.count - 1), millisecond % 1 == 0 else { return }
                    milestones.append(("", []))
                    let bars = solver.discreteBarRuptures
                    var worst: Float = 0
                    var strongest: Float = 0
                    for b in 0..<64 {
                        let bar = solver.discreteBar(b)
                        guard !bar.forces.isEmpty else { break }
                        strongest = max(strongest, bar.forces.map(abs).max() ?? 0)
                        worst = max(worst, solver.discreteBarPlastic(b).filter { $0 < 1e8 }.max() ?? 0)
                    }
                    let deflection = -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z
                    if millisecond % 5 == 0, solver.discreteBarRuptures.segments == 0 {
                        // Smeared: the bars' plastic strain along the span at mid-width, in the
                        // layer of elements they lie in, every element.
                        let layer =
                            (0..<solver.ez).first {
                                solver.steelRatio(solver.ex / 2, solver.ey / 2, $0).x > 0
                            } ?? 0
                        print(
                            "    smeared bars' plastic strain (%): "
                                + (0..<solver.ex).map {
                                    format(
                                        Double(solver.barPlasticStrain($0, solver.ey / 2, layer).x) * 100, 1)
                                }.joined(separator: " "))
                    }
                    if millisecond % 5 == 0, solver.discreteBarRuptures.segments > 0 {
                        var each: [String] = []
                        for b in 0..<64 {
                            let plastic = solver.discreteBarPlastic(b)
                            guard !plastic.isEmpty else { break }
                            let worst = plastic.enumerated().max { $0.element < $1.element }!
                            each.append(
                                "\(b):\(format(Double(min(worst.element, 9.99)) * 100, 1))@\(worst.offset)/\(plastic.count)"
                            )
                        }
                        print(
                            "    each bar's largest plastic strain (%) at segment: "
                                + each.joined(separator: " "))
                    }
                    if millisecond % 5 == 0, let bar = Optional(solver.discreteBarPlastic(4)), !bar.isEmpty {
                        print(
                            "    discrete bar 4's plastic strain (%): "
                                + bar.map { format(Double(min($0, 9.99)) * 100, 1) }.joined(separator: " "))
                    }
                    if millisecond % 5 == 0 {
                        // The compression zone: the largest crushing strain in the top layer, and
                        // the crack strain in the bottom layer, near mid-span.
                        let middle = solver.ex / 2
                        let near = (middle - 6)...(middle + 6)
                        print(
                            "    top crushing (%): "
                                + near.map {
                                    format(
                                        Double(solver.plasticStrain($0, solver.ey / 2, solver.ez - 1)) * 100,
                                        2)
                                }
                                .joined(separator: " "))
                        print(
                            "    bottom crack strain (%): "
                                + near.map {
                                    format(Double(solver.crackStrain($0, solver.ey / 2, 0)) * 100, 1)
                                }
                                .joined(separator: " "))
                    }
                    if millisecond % 5 == 0 {
                        // The deflected shape along the span at mid-width, bottom and top faces.
                        let columns = stride(from: 0, through: solver.ex, by: max(1, solver.ex / 16))
                        print(
                            "    shape, bottom (mm): "
                                + columns.map {
                                    format(Double(-solver.displacement($0, solver.ey / 2, 0).z) * 1000, 1)
                                }
                                .joined(separator: " "))
                        print(
                            "    shape, top (mm):    "
                                + columns.map {
                                    format(
                                        Double(-solver.displacement($0, solver.ey / 2, solver.ez).z) * 1000, 1
                                    )
                                }.joined(separator: " "))
                    }
                    print(
                        "  \(millisecond) ms: \(format(Double(deflection) * 1000, 1)) mm, \(bars.ruptured) ruptured, "
                            + "largest plastic \(format(Double(worst) * 100, 2))%, force \(format(Double(strongest) / 1000, 1)) kN"
                    )
                }
                : flag("stiffening")
                    ? { solver in
                        // `--stiffening`: where the tension is carried over the 600 mm about mid-span,
                        // every 20 mm on the way down.
                        let deflection = -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z
                        let step = 0.02 * Float(milestones.count + 1)
                        guard deflection >= step, solver.time < 0.03 else { return }
                        milestones.append(("", []))
                        let reach = Int((0.3 / solver.model.elementSize).rounded())
                        tensionStiffening(
                            solver, columns: (solver.ex / 2 - reach)..<(solver.ex / 2 + reach),
                            label: "\(Int((step * 1000).rounded())) mm, \(format(solver.time * 1000, 1)) ms",
                            profile: flag("profile") && step >= 0.08)
                    }
                    : flag("work")
                        ? { solver in
                            let deflection = -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z
                            let step = 0.02 * Float(milestones.count + 1)
                            let crossed =
                                deflection >= step && atPeak.map { deflection >= $0.deflection } ?? true
                            let peak = deflection > (atPeak?.deflection ?? 0)
                            let end = solver.time >= 0.08
                            if let at = option("breakdown").flatMap({ Double($0) }).map({ $0 / 1000 }),
                                solver.time >= at, !shownBreakdown
                            {
                                shownBreakdown = true
                                printHourglassBreakdown(
                                    solver, label: "at \(format(solver.time * 1000, 1)) ms")
                            }
                            if end, option("breakdown") != nil {
                                printHourglassBreakdown(solver, label: "at 80 ms")
                            }
                            guard crossed || peak || end else { return }
                            let totals = solver.workTotals()
                            if crossed { milestones.append(("\(Int((step * 1000).rounded())) mm", totals)) }
                            if peak {
                                atPeak = (
                                    deflection, totals,
                                    regions.map { region in solver.workTotals { region.1($0, $1, $2, solver) }
                                    }
                                )
                            }
                            if end {
                                milestones.append(
                                    ("80 ms, \(format(Double(deflection) * 1000, 0)) mm", totals))
                            }
                        } : nil,
            inspect: flag("discrete") && !flag("plan")
                ? { solver in
                    let bars = solver.discreteBarRuptures
                    print("  discrete bars: \(bars.ruptured) of \(bars.segments) segments ruptured")
                }
                : flag("hinge")
                    ? { solver in
                        for offset in [Float(0), 0.15] {
                            print("  at 80 ms, \(Int(offset * 1000)) mm from mid-span:")
                            for row in SlabBenchmark.sectionRows(solver, offset: offset) {
                                print("    " + row)
                            }
                        }
                    }
                    // `--map`: the cracks through the middle of the width at 80 ms; `--plan`, on the
                    // unloaded face, and where the cracks across the span lie.
                    : flag("map") || flag("plan")
                        ? { solver in
                            if flag("map") {
                                print("  cracks open past 0.1% strain at 80 ms, half the span from mid-span:")
                                for row in solver.crackMap(row: solver.ey / 2) { print("    " + row) }
                            }
                            if flag("plan") { printSlabCrackPlan(solver) }
                        } : nil)
        if rate == .strainRate { meshes.append((layers, result)) }
        let label =
            ["none": "static", "designFactors": "UFC fixed", "strainRate": "rate laws"][rate.rawValue] ?? ""
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10) + pad(label, 14)
                + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 9)
                + pad("\(format(Double(result.peakTime) * 1000, 0)) ms", 8)
                + pad("\(format(Double(result.residual) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.residual / SlabBenchmark.measuredResidual) * 100, 0))%", 9)
                + pad("\(result.summary.erodedElements)", 8)
                + pad("\(format(result.wallSeconds, 1)) s", 10))
        if let atPeak {
            print("  work done by each mechanism (J):")
            print("  " + workHeader("", 22))
            for m in milestones { print("  " + workRow(m.label, 22, m.totals)) }
            print("  " + workRow("peak \(format(Double(atPeak.deflection) * 1000, 1)) mm", 22, atPeak.totals))
            print("  at the peak, by part of the slab:")
            for (region, totals) in zip(regions, atPeak.parts) { print("  " + workRow(region.0, 22, totals)) }
        }
        if let directory = option("history-csv") {
            // Every sample of the mid-span history, for scoring against a digitised record.
            let name = "slab-\(layers)-\(rate.rawValue)-load\(option("load-scale") ?? "1").csv"
            let rows = result.history.map { "\($0.x * 1000),\($0.y * 1000)" }
            try? (["time_ms,displacement_mm"] + rows).joined(separator: "\n")
                .write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
        }
        if flag("history") {
            for sample in result.history where Int((sample.x * 1000).rounded()) % 5 == 0 {
                print(
                    "    t = \(format(Double(sample.x) * 1000, 2)) ms   \(format(Double(sample.y) * 1000, 1)) mm"
                )
            }
        }
    }

    // The whole history, not just its peak, against the measured record.
    print("\nMid-span displacement history (mm):")
    print(pad("time", 8) + pad("measured", 10) + meshes.map { pad("\($0.layers) layers", 11) }.joined())
    for time in stride(from: Float(0.005), through: 0.0701, by: 0.005) {
        print(
            pad("\(format(Double(time) * 1000, 0)) ms", 8)
                + pad(format(Double(SlabBenchmark.measuredDisplacement(at: time)) * 1000, 0), 10)
                + meshes.map { pad(format(Double($0.result.displacement(at: time)) * 1000, 0), 11) }.joined())
    }
    print(
        "Root-mean-square difference over the record: "
            + meshes.map { "\(format(Double($0.result.historyError) * 1000, 1)) mm (\($0.layers) layers)" }
            .joined(separator: ", "))
    print("\nPeaks the source reports for other tools on the same slab and load:")
    for other in SlabBenchmark.otherPredictions {
        print(
            "  \(format(Double(other.peak) * 1000, 0)) mm "
                + "(\(format(Double(other.peak / SlabBenchmark.measuredPeak) * 100, 0))%)  \(other.tool)")
    }

    guard flag("sensitivity") else { return }
    print("\nSensitivity of the eight-layer, rate-law result to things the source does not pin down:")
    let variants: [(String, Float, (inout StructureMaterial) -> Void)] = [
        ("load 5% lower", 0.95, { _ in }),
        ("load 5% higher", 1.05, { _ in }),
        ("aggregate 10 mm instead of 16 mm", 1, { $0.aggregateSize = 0.010 }),
        ("crack spacing 50 mm instead of 100 mm", 1, { $0.crackSpacing = 0.05 }),
        ("crack spacing 200 mm", 1, { $0.crackSpacing = 0.2 }),
        ("fracture energy halved", 1, { $0.fractureEnergy *= 0.5 }),
        ("tensile strength 20% lower", 1, { $0.tensileStrength *= 0.8 }),
        ("cracks close fully (no residual opening)", 1, { $0.crackResidual = 0 }),
        ("residual crack opening 20%", 1, { $0.crackResidual = 0.2 }),
        ("residual crack opening 30%", 1, { $0.crackResidual = 0.3 }),
        ("residual crack opening 50%", 1, { $0.crackResidual = 0.5 }),
    ]
    var runs: [(String, () throws -> SlabBenchmark.Result)] = variants.map { label, scale, adjust in
        (label, { try SlabBenchmark.run(device: device, loadScale: scale, adjust: adjust) })
    }
    let inch: Float = 0.0254
    runs.append(
        (
            "1 in bearings, held down",
            { try SlabBenchmark.run(device: device, supports: .bearings(width: inch, holdDown: true)) }
        ))
    runs.append(
        (
            "1 in bearings, free to lift",
            { try SlabBenchmark.run(device: device, supports: .bearings(width: inch, holdDown: false)) }
        ))
    if flag("convergence") {
        runs.append(
            (
                "16 elements through the thickness",
                { try SlabBenchmark.run(device: device, elementsThroughThickness: 16) }
            ))
    }
    for (label, run) in runs {
        let result = try run()
        print(
            pad(label, 40) + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 8)
                + pad("residual \(format(Double(result.residual) * 1000, 0)) mm", 16)
                + pad("history RMS \(format(Double(result.historyError) * 1000, 1)) mm", 20)
                + pad("failed \(result.summary.erodedElements)", 14))
    }
}
