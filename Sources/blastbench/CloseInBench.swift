import BlastCore
import Foundation
import Metal
import simd

// `blastbench closein`.
// Split from main.swift (emmettl/bombcad-work#51).

func runCloseIn() throws {
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.05
    let elementSize = option("h").flatMap { Float($0) } ?? 0.025
    let duration = option("time").flatMap { Double($0) } ?? 0.3
    let refinement = option("refine").flatMap { Int($0) } ?? 1
    print("Full-scale slabs under close-in charges (Chiquito et al., 2023)")
    print(
        "Air cells \(format(Double(cellSize), 3)) m\(refinement > 1 ? ", refined by \(refinement)" : ""), "
            + "elements \(format(Double(elementSize), 3)) m, \(format(duration * 1000, 0)) ms\n")
    func percent(_ value: Float?) -> String { value.map { "\(format(Double($0) * 100, 1))%" } ?? "-" }
    func mm(_ value: Float?) -> String { value.map { "\(format(Double($0) * 1000, 0))" } ?? "-" }
    for test in CloseInSlabTest.tests where names?.contains(test.name) ?? true {
        var inspect: ((StructureSolver, Double) -> Void)? =
            flag("spall") ? spallProbe() : flag("where") ? failureProbe(at: duration * 0.99) : nil
        if flag("faces") { inspect = faceProbe(at: duration * 0.99) }
        if flag("census") {
            var done = false
            inspect = { structure, time in
                guard !done, time >= duration * 0.99 else { return }
                done = true
                let h = structure.model.elementSize
                let c = CloseInSlabTest.centre
                removalCensus(
                    structure, i: Int(((c.x - structure.origin.x) / h).rounded(.down)),
                    j: Int(((c.y - structure.origin.y) / h).rounded(.down)))
            }
        }
        if flag("energy") { inspect = energyProbe() }
        if let path = option("trace") {
            let until = option("trace-until").flatMap { Double($0) } ?? 0.001
            inspect = closeInTrace(path: path.replacingOccurrences(of: "%", with: test.name), until: until)
        }
        let result = try CloseInSlabTest.run(
            device: device, test: test, cellSize: cellSize, elementSize: elementSize, duration: duration,
            refinement: refinement, mappedCharge: !flag("no-map"), afterburning: burning,
            airModel: chosenGas(), openFaces: chosenFaces(),
            heldLengthwise: !flag("sliding"), stepsPerSample: option("trace") != nil ? 1 : 16,
            roomy: flag("roomy"), balloonStart: flag("balloon-start"),
            adjust: { scenario in
                if flag("no-rate") { scenario.structure?.material.rateDependent = false }
                if let scale = option("charge-scale").flatMap({ Float($0) }) { scenario.charge.mass *= scale }
                if let dowel = option("dowel").flatMap({ Float($0) }) {
                    scenario.structure?.material.dowelFactor = dowel
                }
                if let rupture = option("rupture").flatMap({ Float($0) }) {
                    scenario.structure?.material.steel?.ruptureStrain = rupture
                }
                if flag("no-bare") { scenario.structure?.bareBars = false }
                if flag("skirts") {
                    // Walls along the slab's long edges, from the ground to just below it, which
                    // close the space under it to the wave.
                    let slab = CloseInSlabTest.slab
                    for (low, high) in [(slab.min.y - 0.1, slab.min.y), (slab.max.y, slab.max.y + 0.1)] {
                        scenario.boxes.append(
                            Box(min: SIMD3(1.4, low, 0), max: SIMD3(5.4, high, slab.min.z - 0.02)))
                    }
                }
                if flag("under") {
                    // Under the slab, 0.1 m below its bottom face, at its centre and 1 m along the
                    // span; and on the ground below its centre.
                    let c = CloseInSlabTest.centre
                    let bottom = CloseInSlabTest.slab.min.z - 0.1
                    scenario.gauges += [
                        Gauge("Under, centre", at: SIMD3(c.x, c.y, bottom)),
                        Gauge("Under, 1 m along", at: SIMD3(c.x + 1, c.y, bottom)),
                        Gauge("Ground, centre", at: SIMD3(c.x, c.y, 0.01)),
                    ]
                }
                if var structure = scenario.structure {
                    applyRateOptions(&structure)
                    // `--bond pullout`: bars that slip, of the 12 mm bars' diameter.
                    if let bond = chosenBondSlip(diameter: 0.012) { structure.bondSlip = bond }
                    scenario.structure = structure
                }
            },
            progress: flag("progress")
                ? { line in
                    print("  " + line)
                    fflush(stdout)
                } : nil,
            inspect: { structure, time in
                lastStructure = structure
                applyFragmentThresholds(structure)
                inspect?(structure, time)
            }, prepare: prepareTrace)
        if let path = option("history") {
            // `--history <csv>`: the mid-span deflection every sample, `%` for the test's name.
            let rows = result.history.map { "\($0.x),\($0.y * 1000)" }.joined(separator: "\n")
            try ("time_s,deflection_mm\n" + rows).write(
                toFile: path.replacingOccurrences(of: "%", with: test.name), atomically: true, encoding: .utf8
            )
        }
        if let path = option("trace") {
            let centre = result.gaugeHistories[5]
            let text = centre.map { "\($0.time),\($0.pressure)" }.joined(separator: "\n")
            try text.write(
                toFile: path.replacingOccurrences(of: "%", with: test.name + "-gauge"), atomically: true,
                encoding: .utf8)
        }
        print(
            "\(test.name): \(format(Double(test.charge), 2)) kg TNT at \(format(Double(test.standoff), 1)) m; \(test.remark)"
        )
        print("                      measured        model")
        print(
            "  permanent (mm)      " + pad(mm(test.deflection), 15)
                + "  \(mm(result.permanent)) (peak \(mm(result.peak)))")
        print(
            "  spalled, top        " + pad(percent(test.damagedTop), 15) + "  \(percent(result.damagedTop))")
        print(
            "  spalled, bottom     " + pad(percent(test.damagedBottom), 15)
                + "  \(percent(result.damagedBottom))")
        print(
            "  perforated          " + pad(test.perforated ? "yes" : "no", 15)
                + "  \(result.perforated ? "yes" : "no")")
        let measured = [
            test.nearGauge, test.nearGauge, test.farGauge, test.farGauge, nil, nil, nil, nil, nil,
        ]
        for ((name, pressure), range) in zip(result.gaugePeaks, measured) {
            let text =
                range.map {
                    $0.lowerBound == $0.upperBound
                        ? format(Double($0.lowerBound) / 1e6, 2)
                        : "\(format(Double($0.lowerBound) / 1e6, 2))-\(format(Double($0.upperBound) / 1e6, 2))"
                } ?? "-"
            print(
                "  \(pad(name + " (MPa)", 18))  " + pad(text, 15) + "  \(format(Double(pressure) / 1e6, 2))")
        }
        print("  impulse at the slab's centre: \(format(Double(result.gaugeImpulses[5]), 0)) Pa s")
        for n in result.gaugeImpulses.indices.dropFirst(6) {
            print(
                "  impulse, \(result.gaugePeaks[n].name): \(format(Double(result.gaugeImpulses[n]), 0)) Pa s")
        }
        print("  slab's momentum at 5 ms: \(format(Double(result.impulse), 0)) N s")
        if let structure = lastStructure { printRubble(structure) }
        print("  \(result.summary.erodedElements) elements failed; \(format(result.wallSeconds, 0)) s\n")
    }
}
