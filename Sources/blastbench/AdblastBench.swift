import BlastCore
import Foundation
import Metal

// ADBLAST's single-span cladding tests (Fixtures/ADBLAST2015; see AdblastCladdingTest.swift):
//
//   blastbench adblast [--tests 3,7] [--h 0.123] [--no-buckling] [--held] [--collapse] [--air [--dx 0.05]]
//                      [--envelope]   (the one-way model, in the air's load on an envelope and under the measured pulse)
//                      [--fixture Fixtures/ADBLAST2015/tests.json] [--out dir]
//
// Prints each test's measured and computed first peak and final deflection at mid-span, and writes
// summary.csv and each test's history into --out (default
// /Volumes/StudioData/bombcad/profiled-sheeting/adblast-runs).
func runAdblast(device: MTLDevice) throws {
    let tests = try AdblastCladdingTest.tests(
        from: URL(filePath: option("fixture") ?? "Fixtures/ADBLAST2015/tests.json"))
    let chosen = option("tests")?.split(separator: ",").compactMap { Int($0) }
    var settings = AdblastCladdingTest.Settings()
    if let h = option("h").flatMap({ Float($0) }) { settings.elementSize = h }
    if flag("no-buckling") { settings.buckles = false }
    if flag("collapse") { settings.postBuckling = .collapse }
    if flag("effective-width") { settings.postBuckling = .effectiveWidth }
    if flag("held") { settings.releases = false }
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/profiled-sheeting/adblast-runs")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    func text(_ value: Float?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
    var summary =
        "test,charge_kg,thickness_mm,peak_kpa,impulse_kpa_ms,measured_first_mm,computed_first_mm,measured_plastic_mm,computed_final_mm,released\n"
    if flag("envelope") {
        // The rigid envelope's load depends only on the charge: one run serves every test of it.
        var loads: [Float: [EnvelopeComponentLoad]] = [:]
        func mm(_ value: Double) -> String { String(format: "%.0f", value * 1000) }
        func line(_ result: AdblastCladdingTest.EnvelopeResult) -> String {
            "\(mm(result.peak)) mm, \(result.level.label)\(result.screwsPulled ? ", screws pulled" : "")"
        }
        for test in tests where chosen?.contains(test.test) ?? true {
            if loads[test.chargeKgC4] == nil {
                loads[test.chargeKgC4] = try AdblastCladdingTest.envelopeLoadsInAir(
                    test, along: 5, across: 3, cellSize: option("dx").flatMap { Float($0) } ?? 0.05,
                    device: device)
            }
            let air = AdblastCladdingTest.envelope(test, loads: loads[test.chargeKgC4]!, along: 5, across: 3)
            let measured = AdblastCladdingTest.envelopeOnMeasured(test)
            print(
                "Test \(test.test) (\(test.chargeKgC4) kg, \(test.thicknessMM) mm): first \(text(test.firstDynamicDeflectionMM)) "
                    + "measured; one-way in the air's load on the middle band \(line(air.middle)), on the whole panel "
                    + "\(line(air.whole)); under the measured pulse \(line(measured))")
        }
        return
    }
    let inAir = flag("air")
    let cell = option("dx").flatMap { Float($0) } ?? 0.05
    for test in tests where chosen?.contains(test.test) ?? true {
        var air: AdblastCladdingTest.AirResult?
        if inAir {
            air = try AdblastCladdingTest.runInAir(test, settings: settings, cellSize: cell, device: device)
        }
        let result = try air?.structure ?? AdblastCladdingTest.run(test, settings: settings, device: device)
        if let air {
            print(
                "  air at the middle: \(String(format: "%.0f", air.reflectedPeak / 1000)) kPa, "
                    + "\(String(format: "%.0f", air.reflectedImpulse)) kPa ms (measured \(text(test.reflectedPeakKPa)), "
                    + "\(text(test.reflectedImpulseKPaMS)))")
        }
        let line = [
            "\(test.test)", "\(test.chargeKgC4)", "\(test.thicknessMM)", text(test.reflectedPeakKPa),
            text(test.reflectedImpulseKPaMS), text(test.firstDynamicDeflectionMM),
            text(result.firstPeak * 1000),
            text(test.plasticDeformationMM), text(result.final * 1000), "\(result.released)",
        ]
        summary += line.joined(separator: ",") + "\n"
        print(
            "Test \(test.test) (\(test.chargeKgC4) kg, \(test.thicknessMM) mm, \(text(test.reflectedPeakKPa)) kPa, "
                + "\(text(test.reflectedImpulseKPaMS)) kPa ms): first \(text(test.firstDynamicDeflectionMM)) measured, "
                + "\(text(result.firstPeak * 1000)) computed; final \(text(test.plasticDeformationMM)) measured, "
                + "\(text(result.final * 1000)) computed\(result.released ? "; screws pulled through" : "")")
        let history =
            "time_s,deflection_m\n" + result.history.map { "\($0.x),\($0.y)" }.joined(separator: "\n")
        try history.write(to: out.appending(path: "test\(test.test).csv"), atomically: true, encoding: .utf8)
    }
    try summary.write(to: out.appending(path: "summary.csv"), atomically: true, encoding: .utf8)
}
