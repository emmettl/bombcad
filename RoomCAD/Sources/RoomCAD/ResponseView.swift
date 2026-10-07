import AcousticCore
import RoomDocument
import SwiftUI

/// Peak envelope of each channel in dB against time.
struct EnvelopeChart: View {
    let summary: ResponseSummary
    static let colors: [Color] = [.blue, .red, .green, .purple, .orange, .teal]

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 36
            let bottom: CGFloat = 18
            let plot = CGRect(x: left, y: 4, width: size.width - left - 8, height: size.height - bottom - 4)
            var grid = Path()
            for db in stride(from: 0.0, through: ResponseSummary.floor, by: -30) {
                let y = plot.minY + CGFloat(db / ResponseSummary.floor) * plot.height
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.draw(
                    Text("\(Int(db)) dB").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
            }
            let step = summary.duration > 2 ? 0.5 : 0.25
            for t in stride(from: 0.0, through: summary.duration, by: step) {
                let x = plot.minX + CGFloat(t / summary.duration) * plot.width
                grid.move(to: CGPoint(x: x, y: plot.minY))
                grid.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.draw(
                    Text(String(format: "%.2f s", t)).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x, y: plot.maxY + 9))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            for (c, channel) in summary.channels.enumerated() {
                guard channel.envelope.count > 1 else { continue }
                var path = Path()
                for (i, level) in channel.envelope.enumerated() {
                    let x = plot.minX + CGFloat(i) / CGFloat(channel.envelope.count - 1) * plot.width
                    let y = plot.minY + CGFloat(level / ResponseSummary.floor) * plot.height
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(
                    path, with: .color(Self.colors[c % Self.colors.count].opacity(0.8)), lineWidth: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Envelope of the response in decibels against time")
    }
}

/// Octave-band decay: statistical estimates beside the measured T30 of each channel.
struct DecayTable: View {
    let summary: ResponseSummary
    let diagnostics: RoomResponseDiagnostics

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text("Band")
                Text("Sabine")
                Text("Eyring")
                ForEach(summary.channels.indices, id: \.self) { c in
                    Text("T30 \(summary.channels[c].name)")
                        .foregroundStyle(EnvelopeChart.colors[c % EnvelopeChart.colors.count])
                }
            }
            .font(.caption.bold())
            ForEach(OctaveBands.nominalCentres.indices, id: \.self) { band in
                GridRow {
                    Text(MaterialEditor.bandName(band))
                    Text(Self.seconds(diagnostics.sabineReverberationTime[band]))
                    Text(Self.seconds(diagnostics.eyringReverberationTime[band]))
                    ForEach(summary.channels.indices, id: \.self) { c in
                        Text(Self.seconds(summary.channels[c].reverberationTime[band]))
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f s", $0) } ?? "—"
    }
}

/// Facts about the result that bear on how far to trust it.
struct DiagnosticsList: View {
    let result: RoomResponse

    var body: some View {
        let d = result.diagnostics
        VStack(alignment: .leading, spacing: 3) {
            Text(
                "\(d.arrivals.map { $0.formatted() }.joined(separator: " / ")) arrivals, generated in "
                    + String(format: "%.1f s", d.generationSeconds))
            if let wallOrder = d.planWallOrder, let totalOrder = d.planTotalOrder {
                Text(
                    "Image sources reach \(wallOrder) wall and \(totalOrder) total reflections; the ray tracer "
                        + "carries every later specular reflection.")
            } else if let limited = d.orderLimitedAfter.compactMap({ $0 }).min() {
                if (d.diffuseRays ?? 0) > 0 {
                    Text(
                        String(
                            format: "Specular reflections above order %d, from %.2f s, are carried by the "
                                + "ray tracer.",
                            result.settings.maximumReflectionOrder, limited))
                } else {
                    Label(
                        String(
                            format:
                                "Reflections above order %d are missing after %.2f s; raise the maximum order.",
                            result.settings.maximumReflectionOrder, limited),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            if let crossover = d.waveCrossover {
                Text(
                    String(
                        format: "Wave solver below %.0f Hz: %@ cells, %@, %.1f s.", crossover,
                        (d.waveCells ?? 0).formatted(),
                        Self.engines(runs: d.waveRuns ?? 1, gpu: d.waveGPURuns ?? 0),
                        d.waveSeconds ?? 0))
            } else if let note = d.waveNote {
                Text("Wave solver skipped: \(note)")
            }
            if d.waveCrossover == nil, let schroeder = d.schroederFrequency {
                Text(String(format: "Approximate below about %.0f Hz (Schroeder frequency).", schroeder))
            }
            if let scattered = d.scatteredFraction, let rays = d.diffuseRays, rays > 0 {
                Text(
                    "Ray-traced energy (scattered, or beyond the order limit), 500 Hz–4 kHz: "
                        + scattered.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " / ")
                        + " (\(rays.formatted()) rays)")
            } else {
                Text("Specular reflection only: decay is slower than in a real room, which scatters sound.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// "2 runs on the GPU", "1 run on the CPU", or "3 runs, 1 on the GPU and 2 on the CPU".
    static func engines(runs: Int, gpu: Int) -> String {
        let count = runs == 1 ? "1 run" : "\(runs) runs"
        if gpu == runs { return "\(count) on the GPU" }
        if gpu == 0 { return "\(count) on the CPU" }
        return "\(count), \(gpu) on the GPU and \(runs - gpu) on the CPU"
    }
}
