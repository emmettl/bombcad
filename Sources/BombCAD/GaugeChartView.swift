import Charts
import SwiftUI

/// Histories below the viewport: overpressure at the scenario's gauges, or the response of the
/// deformable structure, with a readout beside the plot.
struct GaugeChartView: View {
    let model: SimulationModel
    @State private var showsStructure = false
    @State private var export: ResultsDocument?
    @State private var exportError: String?

    private var hasStructure: Bool { model.structureSummary != nil }
    private var plotsStructure: Bool { showsStructure && hasStructure }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if plotsStructure {
                structureChart
            } else {
                pressureChart
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
                if plotsStructure {
                    structureReadout
                } else {
                    pressureReadout
                }
                Button("Export CSV…", systemImage: "square.and.arrow.up") {
                    export = ResultsDocument(text: model.resultsCSV())
                }
                .controlSize(.small)
                .disabled(model.stepCount == 0)
                .help("Save every gauge sample and the deflection history as a spreadsheet")
            }
            .frame(width: 230)
        }
        .padding(12)
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }), document: export,
            contentType: .commaSeparatedText, defaultFilename: "BombCAD results"
        ) { result in
            if case .failure(let error) = result {
                exportError = "Could not save the results: \(error.localizedDescription)"
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Air

    private var pressureChart: some View {
        Chart {
            ForEach(model.traces) { trace in
                ForEach(trace.points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Overpressure", point.overpressure),
                        series: .value("Gauge", trace.name)
                    )
                    .foregroundStyle(by: .value("Gauge", trace.name))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            nowMark
        }
        .chartXScale(domain: 0...(model.duration * 1000))
        .chartXAxisLabel("Time since detonation (ms)")
        .chartYAxisLabel("Overpressure at gauge (kPa)")
        .chartLegend(.hidden)
        .chartForegroundStyleScale(domain: model.traces.map(\.name), range: Self.palette)
    }

    private var pressureReadout: some View {
        Group {
            Text("Peak overpressure")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.traces) { trace in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.palette[trace.id % Self.palette.count])
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

    // MARK: Structure

    private var structureChart: some View {
        Chart {
            ForEach(model.structureHistory) { sample in
                LineMark(x: .value("Time", sample.time), y: .value("Deflection", sample.deflection))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            nowMark
        }
        .chartXScale(domain: 0...(model.duration * 1000))
        .chartXAxisLabel("Time since detonation (ms)")
        .chartYAxisLabel("Largest deflection of intact structure (mm)")
    }

    private var structureReadout: some View {
        Group {
            Text("Structure")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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

    private var nowMark: some ChartContent {
        RuleMark(x: .value("Now", model.time * 1000))
            .foregroundStyle(.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .mint]
}
