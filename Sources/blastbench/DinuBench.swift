import BlastCore
import Foundation
import Metal

// A HEB260 column's web under 1.815 kg close in, the CODEC bunker tests (see DinuColumnTest.swift):
//
//   blastbench dinu [--shots m4,m5,E5,E6] [--dx 0.02] [--refine 2 --refine-levels 2] [--h 0.01]
//                   [--ms 5] [--flange 0.16] [--failure 0.27] [--no-rate] [--layers 8]
//                   [--clamped] [--no-joint] [--frame [--rigid]] [--gauges] [--axial 0.3 --after 0.3]
//                   [--size-scaled-tearing]
//
// --clamped: the bunker's column clamped at both ends (no joint) rather than pinned with its joint;
// --no-joint: pinned, without the beams' joint.
// --frame: the longitudinal beams as members on extended end plates (--rigid: welded rigid);
// --gauges: the web's strain gauges S1-S8 read every way, against Fixtures/Dinu2017/frame.json;
// --axial: a weight on the column's top of this fraction of its squash load (3.27 MN), then the
//   column alone for --after seconds (the paper's parametric study, shots A1.8, A1.0, A0.5);
// --size-scaled-tearing: the proposed tearing strain 23% - 12.5% ln(h / 10 mm), for comparison
//   only (not adopted).
// --histories DIR: each shot's gauge histories as DIR/<shot>-gauges.csv.

func runDinu(device: MTLDevice) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let wanted = (option("shots") ?? "m4,m5,E5,E6").split(separator: ",").map(String.init)
    var settings = DinuColumnTest.Settings()
    if let h = option("h").flatMap({ Float($0) }) { settings.elementSize = h }
    let flanges = option("flange").flatMap { Float($0) }
    if let failure = option("failure").flatMap({ Float($0) }) { settings.failureStrain = failure }
    if let layers = option("layers").flatMap({ Int($0) }) { settings.shellLayers = layers }
    if flag("no-rate") { settings.rateLaw = false }
    if flag("clamped") { settings.pinnedEnds = false }
    if flag("clamped") || flag("no-joint") { settings.joint = false }
    if flag("frame") { settings.beams = true }
    if flag("rigid") { settings.connection = nil }
    if flag("size-scaled-tearing") {
        settings.failureStrain = DinuColumnTest.sizeScaledTearingStrain(elementSize: settings.elementSize)
    }
    let axialRatio = option("axial").flatMap { Float($0) } ?? 0
    settings.axialLoad = axialRatio * DinuColumnTest.squashLoad()
    let afterBlast = option("after").flatMap { Double($0) } ?? (axialRatio > 0 ? 0.3 : 0)
    let readsGauges = flag("gauges")
    let reference = try? DinuColumnTest.frameReference(from: URL(filePath: "Fixtures/Dinu2017/frame.json"))
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.02
    let duration = (option("ms").flatMap { Double($0) } ?? 5) / 1000
    var refinement = SolverConfiguration.recommended
    refinement.refinement = 2
    refinement.refinementLevels = 2
    configureRefinement(&refinement)
    print(
        "HEB260, shells of "
            + "\(format(Double(settings.elementSize * 1000), 1)) mm; air \(format(Double(cellSize * 1000), 0)) mm "
            + "refined \(refinement.refinementLevels) x \(refinement.refinement); \(format(duration * 1000, 1)) ms"
            + (settings.beams ? "; the frame's beams on \(settings.connection?.name ?? "rigid joints")" : "")
            + String(format: "; tearing at %.1f%%", (settings.failureStrain ?? 0.27) * 100)
            + (axialRatio > 0
                ? String(format: "; axial load %.2f of 3.27 MN, then %.2f s alone", axialRatio, afterBlast)
                : "")
    )
    for shot in DinuColumnTest.shots where wanted.contains(shot.name) {
        var settings = DinuColumnTest.settings(settings, for: shot)
        if let flanges { settings.section.flangeWidth = flanges }
        let r = try DinuColumnTest.run(
            device: device, shot: shot, settings: settings, cellSize: cellSize,
            refinement: refinement.refinement, levels: refinement.refinementLevels, duration: duration,
            readsGauges: readsGauges, afterBlast: afterBlast, configure: { configureRefinement(&$0) },
            progress: { print("  " + $0) })
        print(
            String(
                format:
                    "%@ %.3f kg at %.2f m (Z %.3f), flanges %.0f mm: web %@; %d web shells removed, breach %.0f mm along "
                    + "%@x %.0f mm across (measured %@); %d flange shells removed",
                shot.name, shot.charge, shot.standoff, shot.scaledDistance,
                settings.section.flangeWidth * 1000,
                r.webRemoved > 0 ? "breached" : "held",
                r.webRemoved, r.breachLength * 1000,
                r.webRemoved > 0
                    ? String(
                        format: "(%.0f above the charge, %.0f below) ", r.breachAbove * 1000,
                        r.breachBelow * 1000)
                    : "",
                r.breachWidth * 1000,
                DinuColumnTest.reportedBreachLength(shot).map {
                    "\(format(Double($0.lowerBound * 1000), 0))-\(format(Double($0.upperBound * 1000), 0)) mm"
                } ?? "none", r.flangeRemoved))
        print(
            String(
                format:
                    "   web at the charge: peak %.1f mm, end %.1f mm; plastic strain web %.3f, flanges %.3f; "
                    + "flange tips out %.1f mm; sway %.1f mm; at gauge S6 %@",
                r.webPeak * 1000, r.webFinal * 1000, r.webPlasticStrain, r.flangePlasticStrain,
                r.flangeSpread * 1000,
                r.columnSway * 1000,
                r.gaugeS6PlasticStrain.map { String(format: "%.4f plastic", $0) } ?? "torn away"))
        print(
            String(
                format: "   reflected at the web: %.1f MPa, %.0f Pa s; %@ the test (%@); %.0f s",
                r.reflectedPeak / 1e6, r.reflectedImpulse, r.agrees ? "agrees with" : "differs from",
                shot.outcome,
                r.wallSeconds))
        if settings.beams {
            print(
                String(
                    format: "   end-plate hinges: %d let go, largest turn %.4f rad", r.hingesReleased,
                    r.largestHingeTurn))
        }
        if axialRatio > 0 {
            let at = { (t: Float) -> String in
                r.topDrop.last(where: { $0.x <= t + 1e-4 }).map { String(format: "%.1f", $0.y * 1000) } ?? "-"
            }
            let verdict =
                DinuColumnTest.collapsed(r.topDrop).map { $0 ? "collapses" : "holds" } ?? "undecided"
            let paper =
                DinuColumnTest.axialThresholds[shot.name].map {
                    String(
                        format: "the paper's model holds at %.2f, collapses at %.2f", $0.holds, $0.collapses)
                } ?? ""
            print(
                String(
                    format:
                        "   axial %.2f: shortened %.2f mm under the load; top dropped %@ mm at 0.05 s, %@ at 0.1 s, "
                        + "%@ at 0.2 s, %@ at the end (%.3f s): %@ (%@)",
                    axialRatio, r.settledShortening * 1000, at(0.05), at(0.1), at(0.2),
                    String(format: "%.1f", (r.topDrop.last?.y ?? 0) * 1000), r.topDrop.last?.x ?? 0, verdict,
                    paper))
        }
        if readsGauges { printGauges(r, reference: reference?.shots.first { $0.name == shot.name }) }
        if let folder = option("histories"), !r.gauges.isEmpty {
            var csv = "time_s," + r.gauges.map { "\"\($0.label)\"" }.joined(separator: ",") + "\n"
            for (i, t) in r.gaugeTimes.enumerated() {
                csv +=
                    String(format: "%.7f", t) + ","
                    + r.gaugeHistories.map { String(format: "%.7f", $0[i]) }.joined(separator: ",") + "\n"
            }
            try csv.write(toFile: "\(folder)/\(shot.name)-gauges.csv", atomically: true, encoding: .utf8)
        }
    }
}

/// Each gauge read every way: its largest and smallest strain, what it kept over the last
/// millisecond, its fastest rate and its ringing's period; then the paper's peaks beside the
/// model's readings at the same station.
private func printGauges(_ r: DinuColumnTest.Result, reference: DinuColumnTest.FrameReference.Shot?) {
    var readings: [(gauge: DinuColumnTest.StrainGauge, reading: DinuColumnTest.Reading, period: Float?)] = []
    for (gauge, history) in zip(r.gauges, r.gaugeHistories) {
        let reading = DinuColumnTest.reading(times: r.gaugeTimes, strains: history)
        readings.append((gauge, reading, DinuColumnTest.period(times: r.gaugeTimes, values: history)))
        print(
            String(
                format: "   %@: max %6.0f, min %6.0f, kept %6.0f microstrain; fastest %5.1f /s; period %@",
                gauge.label, reading.maximum * 1e6, reading.minimum * 1e6, reading.kept * 1e6,
                reading.fastestRate,
                DinuColumnTest.period(times: r.gaugeTimes, values: history).map {
                    String(format: "%.2f ms", $0 * 1000)
                }
                    ?? "-"))
    }
    guard let reference else { return }
    for peak in reference.peaks {
        let here = readings.filter { $0.gauge.station == peak.station }
        let back = here.filter { $0.gauge.face < 0 }.map { $0.reading.maximum * 1e6 }
        let loaded = here.filter { $0.gauge.face > 0 }.map { $0.reading.maximum * 1e6 }
        print(
            String(
                format:
                    "   measured S%d %.0f microstrain: the model at its station %.0f-%.0f on the back face, %.0f-%.0f on the loaded",
                peak.gauge, peak.microstrain, back.min() ?? 0, back.max() ?? 0, loaded.min() ?? 0,
                loaded.max() ?? 0))
    }
    if let period = reference.periodMS { print(String(format: "   measured period %.2f ms", period)) }
    if let kept = reference.keptMicrostrain {
        print(String(format: "   measured S6 kept %.0f microstrain", kept))
    }
    if let rate = reference.fastestRate { print(String(format: "   measured S6 fastest rate %.1f /s", rate)) }
}
