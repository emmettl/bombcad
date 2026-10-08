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

/// Magnitude response of each channel in dB against frequency on a log axis, with the wave solver's
/// crossover marked.
struct SpectrumChart: View {
    let summary: ResponseSummary
    var crossover: Double?
    static let range = (low: -60.0, high: 0.0)

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 36
            let bottom: CGFloat = 18
            let plot = CGRect(x: left, y: 4, width: size.width - left - 8, height: size.height - bottom - 4)
            let frequencies = ResponseSummary.spectrumFrequencies
            let span = log2(frequencies.last! / frequencies[0])
            func x(_ f: Double) -> CGFloat {
                plot.minX + CGFloat(log2(f / frequencies[0]) / span) * plot.width
            }
            func y(_ level: Double) -> CGFloat {
                let clamped = min(max(level, Self.range.low), Self.range.high)
                return plot.minY + CGFloat((Self.range.high - clamped) / (Self.range.high - Self.range.low))
                    * plot.height
            }
            var grid = Path()
            for db in stride(from: Self.range.high, through: Self.range.low, by: -20) {
                grid.move(to: CGPoint(x: plot.minX, y: y(db)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.draw(
                    Text("\(Int(db)) dB").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: plot.minX - 4, y: y(db)), anchor: .trailing)
            }
            for (f, label) in [(31.5, "31"), (125, "125"), (500, "500"), (2000, "2k"), (8000, "8k")] {
                grid.move(to: CGPoint(x: x(f), y: plot.minY))
                grid.addLine(to: CGPoint(x: x(f), y: plot.maxY))
                context.draw(
                    Text("\(label) Hz").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x(f), y: plot.maxY + 9))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            if let crossover {
                var line = Path()
                line.move(to: CGPoint(x: x(crossover), y: plot.minY))
                line.addLine(to: CGPoint(x: x(crossover), y: plot.maxY))
                context.stroke(
                    line, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                context.draw(
                    Text("wave solver below").font(.caption2).foregroundStyle(.orange),
                    at: CGPoint(x: x(crossover) - 4, y: plot.minY + 6), anchor: .trailing)
            }
            for (c, channel) in summary.channels.enumerated() {
                var path = Path()
                for (i, level) in channel.spectrum.enumerated() {
                    let point = CGPoint(x: x(frequencies[i]), y: y(level))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(
                    path, with: .color(EnvelopeChart.colors[c % EnvelopeChart.colors.count].opacity(0.8)),
                    lineWidth: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Magnitude response in decibels against frequency")
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
                if let dispersion = d.waveDispersion {
                    Text(
                        String(
                            format:
                                "Its waves travel within %.1f%% of the speed of sound there, so its modes are "
                                + "at most that much low.", abs(dispersion) * 100))
                }
                if let bare = Self.bareDecay(d) {
                    Text("Its decay is matched to Eyring's estimate; bare walls gave \(bare).")
                }
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

    /// The wave solver's bare T30 in each band it covers, such as "63 Hz 1.9 s, 125 Hz 1.6 s", or nil.
    static func bareDecay(_ d: RoomResponseDiagnostics) -> String? {
        let parts = OctaveBands.centres.indices.compactMap { band -> String? in
            guard let t = d.waveBareDecay?[band] ?? nil else { return nil }
            let f = OctaveBands.centres[band]
            return String(
                format: "%@ %.1f s", f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f.rounded())) Hz", t)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "2 runs on the GPU", "1 run on the CPU", or "3 runs, 1 on the GPU and 2 on the CPU".
    static func engines(runs: Int, gpu: Int) -> String {
        let count = runs == 1 ? "1 run" : "\(runs) runs"
        if gpu == runs { return "\(count) on the GPU" }
        if gpu == 0 { return "\(count) on the CPU" }
        return "\(count), \(gpu) on the GPU and \(runs - gpu) on the CPU"
    }
}
