import Charts
import SwiftUI

/// Histories below the viewport: overpressure at the scenario's gauges, or the response of the
/// deformable structure, with a readout beside the plot.
struct GaugeChartView: View {
    let model: SimulationModel
    @State private var showsStructure = false
    @State private var export: ResultsDocument?
    @State private var exportError: String?
    @State private var isSweeping = false
    @State private var isNamingRun = false
    @State private var isComparingRuns = false
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
                    Button("Keep Run…") {
                        var number = model.savedRuns.count + 1
                        while model.savedRuns.contains(where: { $0.name == "Run \(number)" }) { number += 1 }
                        runName = "Run \(number)"
                        isNamingRun = true
                    }.disabled(model.sweep.isActive || !model.canKeepRun)
                        .help("Keep a completed run with its inputs and full measurement histories")
                    Button("Compare (\(model.savedRuns.count))…") { isComparingRuns = true }
                        .disabled(model.savedRuns.isEmpty)
                }.controlSize(.small)
                HStack {
                    ExportResultsButton(model: model, export: $export)
                    Button("Sweep…") { isSweeping = true }.controlSize(.small)
                }
                if model.sweep.isActive {
                    Text(model.sweep.message).font(.caption).lineLimit(2)
                    Button("Cancel sweep") { model.sweep.cancel() }.controlSize(.small)
                }
            }
            .frame(width: 230)
        }
        .padding(12)
        .sheet(isPresented: $isSweeping) { ParameterSweepView(model: model) }
        .sheet(isPresented: $isComparingRuns) { RunComparisonView(model: model) }
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
            }
            .font(.callout)
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
            row("Elements failed", String(format: "%.1f%%", summary.erodedFraction * 100))
            row("Worst damage", String(format: "%.0f%%", min(summary.maxDamage, 1) * 100))
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
            LinePlot(model.structureHistory, x: .value("Time", \.time), y: .value("Deflection", \.deflection))
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: 0...(model.duration * 1000))
        .chartXAxisLabel("Time since detonation (ms)")
        .chartYAxisLabel("Largest deflection of intact structure (mm)")
        .chartOverlay { proxy in NowLine.overlay(model: model, proxy: proxy) }
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
