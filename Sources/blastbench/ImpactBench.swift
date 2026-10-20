import BlastCore
import Foundation
import Metal
import simd

// `blastbench impact`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Saatci's beams struck by a falling weight (first impacts), against the measured peak and
/// residual mid-span displacements.
func runImpact() throws {
    print("Saatci's beams (2007), struck at mid-span by a weight falling at 8 m/s; first impacts\n")
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let layers = option("layers").flatMap { Int($0) } ?? 16
    let duration = option("time").flatMap { Double($0) } ?? 0.2
    print(
        pad("test", 8) + pad("weight", 8) + pad("measured", 18) + pad("model", 18) + pad("reaction", 18)
            + pad("failed", 8) + pad("run time", 10))
    if flag("peterson") {
        // Peterson et al. (KTH, 2026): 0.8 m beams struck by 70 kg at 6.86 m/s near a support.
        print("Peterson et al. (2026): 150 x 150 mm beams on 0.70 m, struck by 70 kg at 6.86 m/s")
        print(
            pad("test", 13) + pad("damage", 7) + pad("impact kN", 16) + pad("near kN (ms)", 26)
                + pad("far kN (ms)", 26) + pad("failed", 8) + pad("under load", 12))
        func force(_ value: Float?, _ time: Float?) -> String {
            guard let value else { return "-" }
            return "\(format(Double(value) / 1000, 0))"
                + (time.map { " (\(format(Double($0) * 1000, 2)))" } ?? "")
        }
        for test in ImpactBenchmark.petersonTests where names?.contains(test.name) ?? true {
            // `--crack-trace`: the cracks and crushing through the middle of the width every 0.1 ms,
            // as Peterson's high-speed images show them (see `PetersonCrackTrace`).
            let trace = PetersonCrackTrace(name: test.name, strike: test.strike)
            let removals = RemovalTrace()
            let strut = StrutTrace(strike: test.strike, strength: 36e6)
            var applied = false
            let result = try ImpactBenchmark.run(
                device: device, test: test, elementsThroughDepth: layers, duration: min(duration, 0.03),
                specimen: { specimen in
                    chooseSupports(&specimen)
                },
                adjust: { model in
                    if flag("no-rate") { model.material.rateDependent = false }
                    // `--bond`: the 8 mm bars slip.
                    if let bond = chosenBondSlip(diameter: 0.008) { model.bondSlip = bond }
                    applyRateOptions(&model)
                },
                inspect: { solver in
                    if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
                },
                sample: flag("crack-trace") || flag("removal-trace") || flag("strut-trace")
                    ? { solver in
                        if !applied, let erosion = option("crush-erosion").flatMap({ Float($0) }) {
                            solver.crushErosion = erosion
                            applied = true
                        }
                        if flag("crack-trace") { trace.sample(solver) }
                        if flag("removal-trace") { removals.sample(solver) }
                        if flag("strut-trace") { strut.sample(solver) }
                    } : nil)
            if flag("crack-trace") { trace.report() }
            if flag("removal-trace") { removals.report() }
            if flag("strut-trace") { strut.report() }
            print(
                pad(test.name, 13) + pad(test.damage, 7)
                    + pad(force(test.impact, nil) + " / " + force(result.peakImpactForce, nil), 16)
                    + pad(
                        force(test.nearReaction, test.nearTime) + " / "
                            + force(result.supportReactions.x, result.supportReactionTimes.x), 26)
                    + pad(
                        force(test.farReaction, test.farTime) + " / "
                            + force(result.supportReactions.y, result.supportReactionTimes.y), 26)
                    + pad("\(result.summary.erodedElements)", 8)
                    + pad("\(format(Double(result.peak) * 1000)) mm", 12))
        }
        print(
            "\nMeasured / model; times after the impact began. The impact force over 0.42 ms, reactions over 0.5 ms."
        )
        return
    }
    if flag("ando") {
        // Ando et al. (2000): beams without stirrups, struck once each by 300 kg.
        print(
            pad("test", 8) + pad("speed", 8) + pad("measured", 22) + pad("model", 20) + pad("failed", 8)
                + "  remark")
        if let push = option("push").flatMap({ Float($0) }) {
            // `--push 0.026`: each beam pushed slowly through its plate to that deflection and let go.
            for test in ImpactBenchmark.shearTests where names?.contains(test.name) ?? true {
                var specimen = ImpactBenchmark.specimen(test)
                chooseSupports(&specimen)
                let result = try ImpactBenchmark.run(
                    device: device, specimen: specimen, weight: 0, speed: 0, elementsThroughDepth: layers,
                    push: push
                ) { model in
                    if flag("no-rate") { model.material.rateDependent = false }
                    applyRateOptions(&model)
                } inspect: { solver in
                    if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
                    if flag("bars") { printBarYield(solver) }
                }
                print(
                    pad(test.name, 8) + "  pushed to \(format(Double(push) * 1000)) mm: largest load "
                        + "\(format(Double(result.peakReaction) / 1000, 1)) kN, "
                        + "left \(format(Double(result.residual) * 1000)) mm down, "
                        + "\(result.summary.erodedElements) failed")
            }
            return
        }
        for test in ImpactBenchmark.shearTests where names?.contains(test.name) ?? true {
            let result = try ImpactBenchmark.run(
                device: device, test: test, elementsThroughDepth: layers, duration: min(duration, 0.15),
                specimen: chooseSupports
            ) { model in
                if flag("no-rate") { model.material.rateDependent = false }
                // `--bond`: the D19 or D13 bars slip.
                if let bond = chosenBondSlip(diameter: test.heavyBars ? 0.019 : 0.013) {
                    model.bondSlip = bond
                }
                applyRateOptions(&model)
            } inspect: { solver in
                if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
                if flag("bars") { printBarYield(solver) }
            } prepare: {
                prepareTrace($0)
            }
            let numbers =
                "\(test.peak.map { format(Double($0) * 1000) } ?? "-") / \(test.residual.map { format(Double($0) * 1000) } ?? "-")"
            let measured = test.broken ? "\(numbers), broken" : numbers
            print(
                pad(test.name, 8) + pad("\(format(Double(test.speed), 0)) m/s", 8) + pad(measured, 22)
                    + pad(
                        "\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm",
                        20)
                    + pad("\(result.summary.erodedElements)", 8) + "  " + test.remark)
            if flag("bars") {
                print("    largest reaction at a support \(format(Double(result.peakReaction) / 1000, 0)) kN")
            }
            if flag("history") {
                // Mid-span displacement every 5 ms, in mm.
                let samples = stride(from: 0.0, through: min(duration, 0.15), by: 0.005).map { t in
                    result.history.first { Double($0.x) >= t }.map { format(Double($0.y) * 1000, 1) } ?? "-"
                }
                print("    " + samples.joined(separator: " "))
            }
        }
        return
    }
    if let size = option("beams").flatMap({ Float($0) }) {
        print(
            pad("test", 8) + pad("weight", 8) + pad("measured", 18) + pad("beams", 18) + pad("reaction", 18)
                + pad("sheared", 9) + pad("removed", 9))
        for test in ImpactBenchmark.tests where names?.contains(test.name) ?? true {
            let result = try ImpactBenchmark.runBeams(
                device: device, test: test, size: size, duration: duration,
                sectionShear: flag("section-shear") ? true : flag("no-section-shear") ? false : nil)
            let measured =
                test.peak.map {
                    "\(format(Double($0) * 1000)) / \(format(Double(test.residual ?? 0) * 1000)) mm"
                }
                ?? "failed"
            print(
                pad(test.name, 8) + pad("\(Int(test.weight)) kg", 8) + pad(measured, 18)
                    + pad(
                        "\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm",
                        18)
                    + pad(
                        "\(Int(test.reaction / 1000)) / \(format(Double(result.peakReaction) / 1000, 0)) kN",
                        18)
                    + pad("\(result.sheared)", 9) + pad("\(result.removed)", 9))
        }
        return
    }
    for test in ImpactBenchmark.tests where names?.contains(test.name) ?? true {
        let result = try ImpactBenchmark.run(
            device: device, test: test, elementsThroughDepth: layers, duration: duration,
            specimen: chooseSupports
        ) { model in
            if flag("no-rate") { model.material.rateDependent = false }
            // `--bond`: the No. 30 bars slip.
            if let bond = chosenBondSlip(diameter: 0.0299) { model.bondSlip = bond }
            applyRateOptions(&model)
        } inspect: { solver in
            // `--map`: the cracks left in the middle row of elements, top row first.
            if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
        } prepare: {
            prepareTrace($0)
        }
        let measured =
            test.peak.map { "\(format(Double($0) * 1000)) / \(format(Double(test.residual ?? 0) * 1000)) mm" }
            ?? "failed"
        print(
            pad(test.name, 8) + pad("\(Int(test.weight)) kg", 8) + pad(measured, 18)
                + pad(
                    "\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm", 18
                )
                + pad(
                    "\(Int(test.reaction / 1000)) / \(format(Double(result.peakReaction) / 1000, 0)) kN", 18)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10)
                + (flag("force") ? "  impact \(format(Double(result.peakImpactForce) / 1000, 0)) kN" : ""))
    }
    print(
        "\nPeak / residual mid-span displacement, the residual the mean over the last 30 ms; largest"
            + " support reaction, measured / model.")
}

/// `--pins`: Ando's beams held lengthwise at both ends; `--plates 0.02`: on steel plates that
/// turn freely about their centre lines, instead of clamped over their faces.
func chooseSupports(_ specimen: inout ImpactBenchmark.Specimen) {
    // `--pad 2.3`: an elastic pad between the weight and the plate, of that stiffness per unit
    // area (GPa/m).
    if let pad = option("pad").flatMap({ Float($0) }) { specimen.pad = pad * 1e9 }
    if flag("pins") { specimen.pinnedEnds = true }
    if let plates = option("plates").flatMap({ Float($0) }) { specimen.supportPlates = plates }
}

/// `--bars`: how far the bars along x have yielded, row by row of elements that carry them: the
/// largest plastic strain, the length yielded, and the plastic stretch summed along the bars.
func printBarYield(_ solver: StructureSolver) {
    let h = solver.model.elementSize
    for k in 0..<solver.ez {
        var stretch: Float = 0
        var largest: Float = 0
        var yielded = 0
        var carries = false
        for i in 0..<solver.ex {
            var strain: Float = 0
            var count = 0
            for j in 0..<solver.ey where solver.steelRatio(i, j, k).x > 0 {
                carries = true
                let plastic = solver.barPlasticStrain(i, j, k).x
                guard abs(plastic) < 1e8 else { continue }
                strain += plastic
                count += 1
            }
            guard count > 0 else { continue }
            strain /= Float(count)
            stretch += strain * h
            largest = max(largest, strain)
            if strain > 1e-4 { yielded += 1 }
        }
        if carries {
            print(
                "    bars in row \(k): largest plastic strain \(format(Double(largest) * 100, 2))%, "
                    + "yielded over \(format(Double(Float(yielded) * h) * 1000, 0)) mm, "
                    + "plastic stretch \(format(Double(stretch) * 1000, 2)) mm")
        }
    }
}
