import BlastCore
import Foundation
import Metal

// Langdon's quarter-scale corrugated blast wall panels under pulse pressure (Fixtures/Langdon2003;
// see LangdonPanelTest.swift), the profiled-sheet model against measured deflections:
//
//   blastbench langdon [--tests c622,c1212] [--h 0.0572] [--yield 356] [--skin 0.05]
//                      [--fixture Fixtures/Langdon2003/panels.json] [--out dir]
//
// Prints each test's measured and computed peak and permanent deflections, and writes them as
// summary.csv and each test's mid-span history as <name>.csv into --out (default
// /Volumes/StudioData/bombcad/profiled-sheeting/langdon-runs).
func runLangdon(device: MTLDevice) throws {
    let panels = try LangdonPanelTest.panels(
        from: URL(filePath: option("fixture") ?? "Fixtures/Langdon2003/panels.json"))
    let names = option("tests")?.split(separator: ",").map(String.init)
    var settings = LangdonPanelTest.Settings()
    if let h = option("h").flatMap({ Float($0) }) { settings.elementSize = h }
    if let yield = option("yield").flatMap({ Float($0) }) { settings.sheetYield = yield * 1e6 }
    if let skin = option("skin").flatMap({ Float($0) }) { settings.skinShare = skin }
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/profiled-sheeting/langdon-runs")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var summary =
        "name,flexible_mm,direction,peakBarg,riseMS,durationMS,measured_peak_mm,computed_peak_mm,measured_permanent_mm,computed_permanent_mm,seconds\n"
    func text(_ value: Float?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
    for panel in panels where names?.contains(panel.name) ?? true {
        let start = Date()
        let result = try LangdonPanelTest.run(panel, settings: settings, device: device)
        let seconds = Date().timeIntervalSince(start)
        let line = [
            panel.name, "\(Int(panel.flexibleLengthMM))", panel.direction, "\(panel.peakBarg)",
            panel.riseMS,
            text(panel.durationMS.milliseconds), text(panel.peakDeflectionMM), text(result.peak * 1000),
            panel.permanentDeflectionMM?.text ?? "", text(result.permanent * 1000),
            String(format: "%.0f", seconds),
        ]
        summary += line.joined(separator: ",") + "\n"
        print(
            "\(panel.name) (\(Int(panel.flexibleLengthMM)) mm, \(panel.direction) \(panel.peakBarg) barg): peak "
                + "\(text(panel.peakDeflectionMM)) measured, \(text(result.peak * 1000)) computed; permanent "
                + "\(panel.permanentDeflectionMM?.text ?? "-") measured, \(text(result.permanent * 1000)) computed "
                + "; foot moved \(text(result.pullIn * 1000)) mm up, \(result.failedShells) shells and "
                + "\(result.failedBeams) beams failed (\(String(format: "%.0f", seconds)) s)")
        let history =
            "time_s,deflection_m\n" + result.history.map { "\($0.x),\($0.y)" }.joined(separator: "\n")
        try history.write(to: out.appending(path: "\(panel.name).csv"), atomically: true, encoding: .utf8)
    }
    try summary.write(to: out.appending(path: "summary.csv"), atomically: true, encoding: .utf8)
}
