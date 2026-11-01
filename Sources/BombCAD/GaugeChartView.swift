import Charts
import SwiftUI

/// Histories below the viewport: overpressure at the scenario's gauges, or the response of the
/// deformable structure, with a readout beside the plot.
struct GaugeChartView: View {
    @Bindable var model: SimulationModel
    @State private var showsStructure = false
    @State private var export: ResultsDocument?
    @State private var exportError: String?
    @State private var isNamingRun = false
    @State private var runName = ""

    private var hasStructure: Bool { model.structureSummary != nil }
    private var plotsStructure: Bool { showsStructure && hasStructure }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Charts of their own, which read only the histories: drawing a few thousand points
            // after every batch kept the main thread from committing the next.
            if plotsStructure {
                StructureChart(model: model)
            } else {
                PressureChart(model: model)
            }

            VStack(alignment: .leading, spacing: 6) {
                if hasStructure {
                    Picker("Plot", selection: $showsStructure) {
                        Text("Air").tag(false)
                        Text("Structure").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if plotsStructure {
                            StructureReadout(model: model)
                        } else {
                            PressureReadout(model: model)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Keep Run…") { nameRun() }
                        .disabled(model.sweep.isActive || !model.canKeepRun)
                        .help("Keep a completed run with its inputs and full measurement histories (⌘K)")
                    Button("Compare (\(model.savedRuns.count))…") { model.showsRunComparison = true }
                        .disabled(model.savedRuns.isEmpty)
                        .help("Compare the kept runs (⇧⌘K)")
                }.controlSize(.small)
                HStack {
                    ExportResultsButton(model: model, export: $export)
                    Button("Sweep…") { model.showsParameterSweep = true }.controlSize(.small)
                }
                if model.sweep.isActive {
                    Text(model.sweep.message).font(.caption).lineLimit(2)
                    Button("Cancel sweep") { model.sweep.cancel() }.controlSize(.small)
                }
            }
            .frame(width: 230)
        }
        .padding(12)
        .sheet(isPresented: $model.showsParameterSweep) { ParameterSweepView(model: model) }
        .sheet(isPresented: $model.showsRunComparison) { RunComparisonView(model: model) }
        // From the Simulation and File menus.
        .onChange(of: model.requestsKeptRun) {
            guard model.requestsKeptRun else { return }
            model.requestsKeptRun = false
            if model.canKeepRun, !model.sweep.isActive { nameRun() }
        }
        .onChange(of: model.requestsResultsExport) {
            guard model.requestsResultsExport else { return }
            model.requestsResultsExport = false
            if model.stepCount > 0 { export = ResultsDocument(text: model.resultsCSV()) }
        }
        .alert("Keep completed run", isPresented: $isNamingRun) {
            TextField("Run name", text: $runName)
            Button("Keep") {
                do { try model.keepRun(named: runName) } catch { exportError = error.localizedDescription }
            }
            .disabled(
                runName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runName.count > 120)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Keep up to \(SavedSimulationRun.maximumRuns) named runs in this project. Results are saved when you choose Keep."
            )
        }
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }), document: export,
            contentType: .commaSeparatedText, defaultFilename: "BombCAD results"
        ) { result in
            if case .failure(let error) = result {
                exportError = "Could not save the results: \(error.localizedDescription)"
            }
        }
        .alert(
            "Results error",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .mint]

    /// Asks for the kept run's name, the next "Run n" not yet taken.
    private func nameRun() {
        var number = model.savedRuns.count + 1
        while model.savedRuns.contains(where: { $0.name == "Run \(number)" }) { number += 1 }
        runName = "Run \(number)"
        isNamingRun = true
    }
}

/// Disabled until the run has taken a step; on its own so that the step count, which changes as
/// the run goes, draws only this button again.
private struct ExportResultsButton: View {
    let model: SimulationModel
    @Binding var export: ResultsDocument?

    var body: some View {
        Button("Export CSV…", systemImage: "square.and.arrow.up") {
            export = ResultsDocument(text: model.resultsCSV())
        }
        .controlSize(.small)
        .disabled(model.stepCount == 0)
        .help("Save every gauge sample and the deflection history as a spreadsheet")
    }
}

/// The peak at each gauge.
private struct PressureReadout: View {
    let model: SimulationModel

    var body: some View {
        HStack {
            Text("Peak overpressure")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            LiveStandingBadge(model: model, kinds: [.peakOverpressure, .impulse])
        }
        ForEach(model.traces) { trace in
            HStack(spacing: 6) {
                Circle()
                    .fill(GaugeChartView.palette[trace.id % GaugeChartView.palette.count])
                    .frame(width: 8, height: 8)
                Text(trace.name)
                Spacer(minLength: 12)
                Text(trace.peak > 0 ? String(format: "%.1f kPa", trace.peak) : "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        trace.peak > 0 ? String(format: "%.1f kPa", trace.peak) : "no peak yet")
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            GaugeExpectationLine(model: model, name: trace.name, peak: trace.peak)
        }
        Spacer(minLength: 0)
        Text("Gauges are the cyan markers in the view.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// The deformable structure's state now and its largest deflection so far.
private struct StructureReadout: View {
    let model: SimulationModel

    var body: some View {
        HStack {
            Text("Structure")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            LiveStandingBadge(model: model, kinds: [.structuralResponse, .structuralDamage])
        }
        if let summary = model.structureSummary {
            row("Deflection now", String(format: "%.0f mm", summary.maxDisplacement * 1000))
            row("Largest so far", String(format: "%.0f mm", model.peakDeflection))
            if summary.selfWeightSag > 0 {
                row("Sag under own weight", String(format: "%.0f mm", summary.selfWeightSag * 1000))
            }
            ExpectedRangeLine(
                model: model,
                value: ShownValue(measure: .peakDeflection, value: model.peakDeflection, unit: "mm"))
            row("Elements failed", String(format: "%.1f%%", summary.erodedFraction * 100))
            row("Worst damage", String(format: "%.0f%%", min(summary.maxDamage, 1) * 100))
        }
        // Several structures: each its own deflection now and largest so far.
        let structures = model.settings.scenario.structuralObjects
        if structures.count > 1 {
            ForEach(structures, id: \.id) { object in
                let history = model.bodyHistories[object.id] ?? []
                row(
                    object.name,
                    String(
                        format: "%.0f mm, largest %.0f mm", history.last?.deflection ?? 0,
                        history.map(\.deflection).max() ?? 0))
            }
            if let from = model.structuresInContactFrom {
                Text(String(format: "In contact with each other from %.1f ms.", from * 1000))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 0)
        Text("Deflection is of the part still attached; debris is not counted.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private struct PressureChart: View {
    let model: SimulationModel

    var body: some View {
        // One plot of every point rather than a mark per point, which Charts lays out far faster.
        Chart {
            LinePlot(
                points, x: .value("Time", \.time), y: .value("Overpressure", \.overpressure),
                series: .value("Gauge", \.gauge)
            )
            .foregroundStyle(by: .value("Gauge", \.gauge))
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: 0...(model.duration * 1000))
        .chartXAxisLabel("Time since detonation (ms)")
        .chartYAxisLabel("Overpressure at gauge (kPa)")
        .chartLegend(.hidden)
        .chartForegroundStyleScale(domain: model.traces.map(\.name), range: GaugeChartView.palette)
        .chartOverlay { proxy in NowLine.overlay(model: model, proxy: proxy) }
        // Drawn as one plot, which assistive apps cannot read: a summary, and the histories as an
        // audio graph.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overpressure at the gauges against time")
        .accessibilityValue(summary)
        .accessibilityChartDescriptor(
            HistoryChartDescriptor(
                title: "Overpressure at the gauges", quantity: "Overpressure", unit: "kPa",
                duration: model.duration,
                series: model.traces.map { trace in
                    (trace.name, trace.points.map { ($0.time, $0.overpressure) })
                }
            ))
    }

    /// The gauges and the highest peak among them.
    private var summary: String {
        let sampled = model.traces.filter { !$0.points.isEmpty }
        guard let highest = sampled.max(by: { $0.peak < $1.peak }) else { return "No samples yet" }
        return String(
            format: "%d gauges to %.0f ms; the highest peak %.1f kPa, at %@", sampled.count,
            sampled.compactMap(\.points.last?.time).max() ?? 0, highest.peak, highest.name)
    }

    private struct Point {
        var gauge: String
        var time: Double
        var overpressure: Double
    }

    private var points: [Point] {
        model.traces.flatMap { trace in
            trace.points.map { Point(gauge: trace.name, time: $0.time, overpressure: $0.overpressure) }
        }
    }
}

private struct StructureChart: View {
    let model: SimulationModel

    var body: some View {
        Chart {
            if model.settings.scenario.structuralObjects.count > 1 {
                // A line for each structure.
                LinePlot(
                    points, x: .value("Time", \.time), y: .value("Deflection", \.deflection),
                    series: .value("Structure", \.name)
                )
                .foregroundStyle(by: .value("Structure", \.name))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            } else {
                LinePlot(
                    model.structureHistory, x: .value("Time", \.time), y: .value("Deflection", \.deflection)
                )
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: 0...(model.duration * 1000))
        .chartXAxisLabel("Time since detonation (ms)")
        .chartYAxisLabel("Largest deflection of intact structure (mm)")
        .chartOverlay { proxy in NowLine.overlay(model: model, proxy: proxy) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Largest deflection of the intact structure against time")
        .accessibilityValue(String(format: "Largest so far %.0f mm", model.peakDeflection))
        .accessibilityChartDescriptor(
            HistoryChartDescriptor(
                title: "Largest deflection of the intact structure", quantity: "Deflection", unit: "mm",
                duration: model.duration,
                series: model.settings.scenario.structuralObjects.count > 1
                    ? model.settings.scenario.structuralObjects.map { object in
                        (object.name, (model.bodyHistories[object.id] ?? []).map { ($0.time, $0.deflection) })
                    }
                    : [("Structure", model.structureHistory.map { ($0.time, $0.deflection) })]))
    }

    private struct Point {
        var name: String
        var time: Double
        var deflection: Double
    }

    private var points: [Point] {
        model.settings.scenario.structuralObjects.flatMap { object in
            (model.bodyHistories[object.id] ?? []).map {
                Point(name: object.name, time: $0.time, deflection: $0.deflection)
            }
        }
    }
}

/// The run's time across the plot, drawn over the chart so that it alone follows every batch.
/// The time axis is fixed, from 0 to the run's duration, so the line is placed without asking the
/// chart, which would lay it out again.
private struct NowLine: View {
    let model: SimulationModel
    let plot: CGRect

    static func overlay(model: SimulationModel, proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame { NowLine(model: model, plot: geometry[anchor]) }
        }
        .allowsHitTesting(false)
    }

    var body: some View {
        let fraction = model.duration > 0 ? min(max(model.time / model.duration, 0), 1) : 0
        let x = plot.minX + plot.width * fraction
        Path { path in
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}

/// A chart's histories as VoiceOver's audio graph reads them: time across, one series a line, at
/// most a few hundred points each.
struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let quantity: String
    let unit: String
    /// The run's length, in seconds.
    let duration: Double
    /// Each line's name and its points, time in milliseconds.
    let series: [(String, [(Double, Double)])]

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = unit
        let values = series.flatMap { $0.1.map(\.1) }
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 1, low + 1)
        let x = AXNumericDataAxisDescriptor(
            title: "Time since detonation", range: 0...max(duration * 1000, 1), gridlinePositions: []
        ) { String(format: "%.1f ms", $0) }
        let y = AXNumericDataAxisDescriptor(
            title: "\(quantity) (\(unit))", range: low...high, gridlinePositions: []
        ) { String(format: "%.1f %@", $0, unit) }
        let lines = series.map { name, points in
            let stride = max(1, points.count / 300)
            let kept = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
            return AXDataSeriesDescriptor(
                name: name, isContinuous: true, dataPoints: kept.map { AXDataPoint(x: $0.0, y: $0.1) })
        }
        return AXChartDescriptor(
            title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: lines)
    }
}
