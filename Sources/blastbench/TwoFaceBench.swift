import BlastCore
import Foundation
import Metal
import simd

// `blastbench twoface`.
// Split from main.swift (emmettl/bombcad-work#51).

func runTwoFace() throws {
    let breakdownAt = option("breakdown").flatMap { Double($0) }.map { $0 / 1000 }
    var shownBreakdown = false
    /// Elements within 0.3 m of the centre of Wu's slab, in plan.
    func wuNear(_ solver: StructureSolver) -> (Int, Int, Int) -> Bool {
        let h = solver.model.elementSize
        let c = TwoFaceSlabTests.wuCentre
        return { i, j, _ in
            let p = solver.origin + SIMD3(Float(i) + 0.5, Float(j) + 0.5, 0) * h
            return simd_length(SIMD2(p.x - c.x, p.y - c.y)) < 0.3
        }
    }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.025
    let elementSize = option("h").flatMap { Float($0) } ?? 0.0125
    let duration = option("time").flatMap { Double($0) } ?? 0.1
    func mm(_ value: Float?) -> String { value.map { format(Double($0) * 1000, 1) } ?? "-" }
    func cm2(_ value: Float?) -> String { value.map { format(Double($0) * 1e4, 0) } ?? "-" }
    func adjust(_ scenario: inout Scenario) {
        if let scale = option("charge-scale").flatMap({ Float($0) }) { scenario.charge.mass *= scale }
        if var structure = scenario.structure {
            applyRateOptions(&structure)
            // `--bond pullout`: bars that slip, of 8 mm bars (12 mm for Wang's B: see below).
            if let bond = chosenBondSlip(diameter: 0.008) { structure.bondSlip = bond }
            scenario.structure = structure
        }
    }
    func report(_ result: TwoFaceSlabTests.Result, label: String) throws {
        if flag("history") {
            for sample in result.histories[0] where Int((sample.x * 1e4).rounded()) % 10 == 0 {
                print("    \(format(Double(sample.x) * 1000, 1)) ms  \(mm(sample.y)) mm")
            }
        }
        if let directory = option("out") {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            var text = "time," + result.probes.joined(separator: ",") + "\n"
            for n in result.histories[0].indices {
                text +=
                    "\(result.histories[0][n].x),"
                    + result.histories.map { "\($0[n].y)" }.joined(separator: ",") + "\n"
            }
            try text.write(toFile: "\(directory)/\(label).csv", atomically: true, encoding: .utf8)
        }
        if let work = result.work {
            print("  work by mechanism (J), when the first probe peaked and at the end:")
            print("  " + workHeader("", 8))
            if let peak = result.workAtPeak { print("  " + workRow("peak", 8, peak)) }
            print("  " + workRow("end", 8, work))
        }
    }
    // `--yao T1,T2,T3,T4`: Yao et al.'s 4 x 5 x 0.15 m slabs (Applied Sciences, 2023).
    if let names = option("yao").map({ $0.split(separator: ",").map(String.init) }) {
        let yaoElement = option("h").flatMap { Float($0) } ?? 0.01875
        print("Yao et al. (2023): 4 x 5 x 0.15 m slabs, two mats, simply supported on the long sides")
        print(
            "Air \(format(Double(cellSize), 3)) m refined by \(option("refine") ?? "2"), elements \(format(Double(yaoElement), 4)) m, \(format(duration * 1000, 0)) ms"
        )
        print(
            "Underside displacement (mm, down positive), measured / model; top-face pressure peaks (MPa); areas cm2\n"
        )
        print(
            pad("test", 5) + pad("charge", 14) + pad("centre", 13) + pad("to support", 13)
                + pad("to free", 13)
                + pad("diagonal", 13) + pad("p centre", 12) + pad("p 1 m", 18) + pad("top", 8)
                + pad("bottom", 8)
                + pad("failed", 8) + pad("s", 6))
        func mm3(_ value: Float?) -> String { value.map { format(Double($0) * 1000, 2) } ?? "-" }
        for test in TwoFaceSlabTests.yaoTests where names.contains(test.name) {
            let result = try TwoFaceSlabTests.run(
                device: device, test: test, cellSize: cellSize,
                refinement: option("refine").flatMap { Int($0) } ?? 2, elementSize: yaoElement,
                duration: duration,
                afterburning: burning, airModel: chosenGas(), openFaces: chosenFaces(), roomy: flag("roomy"),
                balloonStart: flag("balloon-start"),
                adjust: adjust,
                prepare: { solver in
                    // `--weightless`: the slab without its own weight, as compared before 17 October 2026.
                    if flag("weightless") { solver.gravity = 0 }
                    prepareTrace(solver)
                    lastStructure = solver
                },
                progress: flag("progress")
                    ? {
                        print("  " + $0)
                        fflush(stdout)
                    } : nil,
                configure: applyChosenMask)
            let measured = test.displacements
            let columns = (0..<4).map { "\(mm3(measured?[$0]))/\(mm3(result.peaks[$0]))" }
            let charge = "\(format(Double(test.charge), 1)) kg @\(format(Double(test.standoff), 1))"
            func mpa(_ value: Float?) -> String { value.map { format(Double($0) / 1e6, 2) } ?? "-" }
            print(
                pad(test.name, 5) + pad(charge, 14) + columns.map { pad($0, 13) }.joined()
                    + pad("\(mpa(test.centrePressure))/\(mpa(result.gaugePeaks[0]))", 12)
                    + pad(
                        "\(mpa(test.sidePressure))/\(mpa(result.gaugePeaks[1])),\(mpa(result.gaugePeaks[2]))",
                        18)
                    + pad(format(Double(result.damagedFront) * 1e4, 0), 8)
                    + pad(format(Double(result.damagedBack) * 1e4, 0), 8)
                    + pad("\(result.summary.erodedElements)", 8) + pad(format(result.wallSeconds, 0), 6))
            print(
                "      residual (mm): "
                    + result.residuals.map { format(Double($0) * 1000, 2) }.joined(separator: ", ")
                    + "; impulses at the gauges (kPa ms): "
                    + result.gaugeImpulses.map { format(Double($0), 0) }.joined(separator: ", ")
                    + "; test: " + test.remark)
            // The paper reports the largest displacement "at the time that the explosion wave reached
            // the slab": the probes' largest within 2 ms of the shock's arrival at the centre.
            let arrival = result.gaugeArrivals[0]
            let early = result.histories.map { history in
                history.filter { $0.x <= arrival + 0.002 }.map { abs($0.y) }.max() ?? 0
            }
            print(
                "      within 2 ms of the shock's arrival (\(format(Double(arrival) * 1000, 2)) ms), largest (mm): "
                    + early.map { format(Double($0) * 1000, 2) }.joined(separator: ", "))
            try report(result, label: "yao-\(test.name)")
        }
        return
    }
    if let names = option("wu").map({ $0.split(separator: ",").map(String.init) }) {
        print(
            "Wu et al. (2023): 2 x 2 x 0.1 m slabs, one layer of steel (S) or two (D), TNT in contact or at 0.43 m/kg^1/3"
        )
        print(
            "Air \(format(Double(cellSize), 3)) m refined by \(option("refine") ?? "2"), elements \(format(Double(elementSize), 4)) m, \(format(duration * 1000, 0)) ms"
        )
        print(
            "Displacement 300 mm from the centre of the underside (mm, down positive); rebound up past the start; areas cm2\n"
        )
        print(
            pad("test", 5) + pad("charge", 16) + pad("peak", 13) + pad("rebound", 13) + pad("residual", 13)
                + pad("along/centre", 14) + pad("top", 11) + pad("bottom", 11) + pad("hole cm", 11)
                + pad("failed", 8)
                + pad("s", 6))
        for test in TwoFaceSlabTests.wuTests where names.contains(test.name) {
            let result = try TwoFaceSlabTests.run(
                device: device, test: test, cellSize: cellSize,
                refinement: option("refine").flatMap { Int($0) } ?? 2, elementSize: elementSize,
                duration: duration,
                heldLengthwise: flag("held"), afterburning: burning, airModel: chosenGas(),
                openFaces: chosenFaces(), roomy: flag("roomy"), balloonStart: flag("balloon-start"),
                adjust: adjust,
                prepare: { solver in
                    prepareTrace(solver)
                    lastStructure = solver
                },
                progress: flag("progress")
                    ? {
                        print("  " + $0)
                        fflush(stdout)
                    } : nil,
                inspect: { solver, time in
                    // `--work --breakdown 6`: where hourglass control's work has gone by 6 ms.
                    guard solver.tracesWork, let at = breakdownAt, !shownBreakdown, time >= at else { return }
                    shownBreakdown = true
                    printHourglassBreakdown(
                        solver, label: "\(test.name) at \(format(time * 1000, 1)) ms", near: wuNear(solver))
                }, configure: applyChosenMask)
            shownBreakdown = false
            if let structure = lastStructure, structure.tracesWork, breakdownAt != nil {
                printHourglassBreakdown(structure, label: "\(test.name) at the end", near: wuNear(structure))
            }
            let charge =
                "\(format(Double(test.charge), 1)) kg "
                + (test.standoff.map { "@\(format(Double($0), 2))" } ?? "contact")
            print(
                pad(test.name, 5) + pad(charge, 16) + pad("\(mm(test.peak))/\(mm(result.peaks[0]))", 13)
                    + pad("\(mm(test.rebound))/\(mm(result.rebounds[0]))", 13)
                    + pad("\(mm(test.residual))/\(mm(result.residuals[0]))", 13)
                    + pad("\(mm(result.peaks[1]))/\(mm(result.peaks[2]))", 14)
                    + pad("\(cm2(test.damagedTop))/\(cm2(result.damagedFront))", 11)
                    + pad("\(cm2(test.damagedBottom))/\(cm2(result.damagedBack))", 11)
                    + pad(
                        "\(test.hole.map { format(Double($0) * 100, 1) } ?? "-")/\(format(Double(result.hole) * 100, 1))",
                        11)
                    + pad("\(result.summary.erodedElements)", 8) + pad(format(result.wallSeconds, 0), 6))
            try report(result, label: "wu-\(test.name)")
            if let structure = lastStructure { printRubble(structure) }
            if let structure = lastStructure {
                let h = structure.model.elementSize
                let c = TwoFaceSlabTests.wuCentre
                let i = Int(((c.x - structure.origin.x) / h).rounded(.down))
                let j = Int(((c.y - structure.origin.y) / h).rounded(.down))
                if flag("report") { columnReport(structure, i: i, j: j) }
                if flag("census") { removalCensus(structure, i: i, j: j) }
            }
        }
    }
    if let names = option("wang").map({ $0.split(separator: ",").map(String.init) }) {
        print(
            "Wang et al. (2022): 1.2 x 0.5 x 0.1 m slabs, steel both ways in both faces, 10 kg (TNT equivalent, assumed) at 1.2 m"
        )
        print(
            "Air \(format(Double(cellSize), 3)) m refined by \(option("refine") ?? "1"), elements \(format(Double(elementSize), 4)) m, \(format(duration * 1000, 0)) ms\n"
        )
        for test in TwoFaceSlabTests.wangTests where names.contains(test.name) {
            let result = try TwoFaceSlabTests.run(
                device: device, test: test, cellSize: cellSize,
                refinement: option("refine").flatMap { Int($0) } ?? 1,
                elementSize: elementSize, duration: duration,
                edges: option("edges").flatMap { TwoFaceSlabTests.WangEdges(rawValue: $0) }
                    ?? (flag("hinged") ? .hinged : .fixed),
                afterburning: burning, airModel: chosenGas(), openFaces: chosenFaces(), roomy: flag("roomy"),
                balloonStart: flag("balloon-start"),
                adjust: { scenario in
                    adjust(&scenario)
                    if let bond = chosenBondSlip(diameter: test.bar) { scenario.structure?.bondSlip = bond }
                }, prepare: prepareTrace,
                progress: flag("progress")
                    ? {
                        print("  " + $0)
                        fflush(stdout)
                    } : nil, configure: applyChosenMask)
            print("Slab \(test.name), \(format(Double(test.bar) * 1000, 0)) mm bars: \(test.remark)")
            print("  gauge   peak, measured/model (mm)   residual (mm)")
            for n in result.probes.indices {
                print(
                    "  " + pad(result.probes[n], 5) + pad("\(mm(test.peaks[n]))/\(mm(result.peaks[n]))", 18)
                        + pad("\(mm(test.residuals[n]))/\(mm(result.residuals[n]))", 22))
            }
            print("  reflected pressure: peak (MPa), arrival (ms), impulse (MPa ms), measured/model")
            for (n, gauge) in TwoFaceSlabTests.wangGauges.enumerated() {
                print(
                    "  \(gauge.name)  \(format(Double(gauge.peak) / 1e6, 1))/\(format(Double(result.gaugePeaks[n]) / 1e6, 1))"
                        + "   \(format(Double(gauge.arrival) * 1000, 2))/\(format(Double(result.gaugeArrivals[n]) * 1000, 2))"
                        + "   \(format(Double(gauge.impulse) / 1000, 2))/\(format(Double(result.gaugeImpulses[n]) / 1000, 2))"
                )
            }
            print(
                "  back face damaged \(cm2(result.damagedBack)) cm2, front \(cm2(result.damagedFront)) cm2; "
                    + "\(result.summary.erodedElements) elements failed; \(format(result.wallSeconds, 0)) s")
            try report(result, label: "wang-\(test.name)")
            print("")
        }
    }
}
