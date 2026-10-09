import BlastCore
import BlastRender
import Charts
import SwiftUI

/// The Run tab's Rise and cloud section: the hot gas left at a run's end followed as a rising
/// cloud for minutes after, its path drawn over the scene and charted here.
struct CloudSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Section("Rise and cloud") {
            Toggle("Fireball's rise and cloud", isOn: enabled)
                .help(
                    "Hands the hot gas left at the end of the run over to a model of a rising buoyant "
                        + "cloud, and follows it for minutes after in a standard atmosphere. Illustrative: "
                        + "its top is within 4% on average of those measured over 22 TNT detonations for "
                        + "their first two minutes, with afterburning.")
            if let spec = model.cloudSpec {
                if spec.sounding == nil {
                    LabeledSlider(
                        title: "Wind 10 m up",
                        value: Binding(
                            get: { spec.windSpeed },
                            set: { model.cloudSpec?.windSpeed = ($0 * 2).rounded() / 2 }),
                        range: 0...20, text: String(format: "%.1f m/s", spec.windSpeed)
                    )
                    .help("Grows with height as the seventh power, up to 1,000 m.")
                    if spec.windSpeed > 0 {
                        LabeledSlider(
                            title: "Blowing towards",
                            value: Binding(
                                get: { spec.windDirection },
                                set: { model.cloudSpec?.windDirection = ($0 / 15).rounded() * 15 }),
                            range: 0...345, text: "\(Int(spec.windDirection))°"
                        )
                        .help("Anticlockwise from the scene's x axis towards its y axis.")
                    }
                    LabeledSlider(
                        title: "Relative humidity",
                        value: Binding(
                            get: { spec.relativeHumidity },
                            set: { model.cloudSpec?.relativeHumidity = ($0 * 20).rounded() / 20 }),
                        range: 0...1, text: "\(Int((spec.relativeHumidity * 100).rounded()))%"
                    )
                    .help(
                        "The same at every height up to the tropopause; saturated air lets the cloud rise for kilometres."
                    )
                } else {
                    Text("The project's measured sounding sets the air, its wind and its humidity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledSlider(
                    title: "Followed for",
                    value: Binding(
                        get: { spec.duration / 60 },
                        set: { model.cloudSpec?.duration = $0.rounded() * 60 }),
                    range: 1...60, text: "\(Int((spec.duration / 60).rounded())) min")
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cloud = model.cloud, cloud.handOver.mass > 0 {
                    CloudReadout(cloud: cloud)
                    CloudChart(cloud: cloud)
                    HStack {
                        Button("Frame the Cloud") { model.frameCloud() }
                            .help(
                                "Turns the view to the cloud's path, or, if that is too far to see whole, to where it stopped."
                            )
                        Button("Frame the Scene") { model.resetCamera() }
                    }
                }
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.cloudSpec != nil },
            set: { model.cloudSpec = $0 ? CloudSpec() : nil })
    }

    private var status: String {
        if model.followingCloud { return "Following the cloud…" }
        guard let cloud = model.cloud else {
            return "Followed from the hot gas left at a run's end, once a run reaches it. "
                + "Changes take effect from the next run; afterburning leaves more heat in the air."
        }
        let handOver = cloud.handOver
        guard handOver.mass > 0 else {
            return String(
                format: "No gas at least %.0f K was left at the run's end to hand over.",
                Double(cloud.spec.handOverTemperature))
        }
        return String(
            format:
                "Handed over at %.0f ms: %.0f kg of gas, %.1f m across at %.0f K, %.0f%% of the warm gas's buoyancy.",
            handOver.time * 1000, handOver.mass, 2 * handOver.radius, handOver.temperature,
            100 * handOver.buoyancy / max(handOver.warmBuoyancy, 1e-30))
    }
}

/// Where the cloud stopped rising, or where it was at the end.
private struct CloudReadout: View {
    let cloud: CloudResult

    var body: some View {
        let sample = cloud.stabilised ?? cloud.samples.last!
        LabeledContent(
            cloud.stabilised == nil ? "Still rising at" : "Stopped rising",
            value: String(format: "%.0f s", sample.time))
        LabeledContent("Centre then", value: String(format: "%.0f m up", sample.height))
        LabeledContent("Top", value: String(format: "%.0f m, %.0f m across", sample.top, 2 * sample.radius))
        if cloud.drift(cloud.samples.last!) > 1 {
            LabeledContent(
                "Downwind",
                value: String(
                    format: "%.1f km then, %.1f km at %.0f min", cloud.drift(sample) / 1000,
                    cloud.drift(cloud.samples.last!) / 1000, cloud.samples.last!.time / 60))
        }
    }
}

/// The cloud's height against time, or against its distance downwind: its centre, the band from
/// its bottom to its top, and where it stopped rising.
private struct CloudChart: View {
    let cloud: CloudResult
    @State private var downwind = false

    private struct Point {
        var x: Double
        var centre: Double
        var bottom: Double
        var top: Double
    }

    private var points: [Point] {
        cloud.samples.map { sample in
            Point(
                x: downwind ? cloud.drift(sample) / 1000 : sample.time / 60, centre: sample.height,
                bottom: max(sample.height - sample.radius, 0), top: sample.top)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if cloud.drift(cloud.samples.last!) > 10 {
                Picker("Height against", selection: $downwind) {
                    Text("Time").tag(false)
                    Text("Downwind").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Chart {
                // One plot of every point rather than a mark per point, as for the gauges.
                AreaPlot(
                    points, x: .value("X", \.x), yStart: .value("Bottom", \.bottom),
                    yEnd: .value("Top", \.top)
                )
                .foregroundStyle(.gray.opacity(0.25))
                LinePlot(points, x: .value("X", \.x), y: .value("Centre", \.centre))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                if let stopped = cloud.stabilised {
                    // Orange, as the view draws where it stopped.
                    PointMark(
                        x: .value("X", downwind ? cloud.drift(stopped) / 1000 : stopped.time / 60),
                        y: .value("Centre", stopped.height)
                    )
                    .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.12))
                    .annotation(position: .bottom, alignment: .center) {
                        Text("stopped").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .chartXScale(domain: 0...max(points.map(\.x).max() ?? 0, 1e-3))
            .chartYScale(domain: 0...max(points.map(\.top).max() ?? 0, 1) * 1.05)
            .chartXAxisLabel(downwind ? "Downwind (km)" : "Time since detonation (min)")
            .chartYAxisLabel("Height (m)")
            .frame(height: 150)
            Text("The line is the cloud's centre, the band its bottom to its top.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
