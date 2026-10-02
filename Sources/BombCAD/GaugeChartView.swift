import Charts
import SwiftUI

/// Overpressure histories at the scenario's gauges, with a peak readout beside the plot.
struct GaugeChartView: View {
    let model: SimulationModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
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
                RuleMark(x: .value("Now", model.time * 1000))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: 0...(model.duration * 1000))
            .chartXAxisLabel("Time since detonation (ms)")
            .chartYAxisLabel("Overpressure at gauge (kPa)")
            .chartLegend(.hidden)
            .chartForegroundStyleScale(domain: model.traces.map(\.name), range: Self.palette)

            VStack(alignment: .leading, spacing: 6) {
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
            .frame(width: 230)
        }
        .padding(12)
    }

    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .mint]
}
