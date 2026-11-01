import BlastCore
import BlastRender
import SwiftUI

/// Under the view, with the live blast wave shown (Simulation ▸ Show Live Blast Wave): play and
/// scrub the estimate's front over the scene, at a speed to suit it, as the charge is placed or
/// dragged (docs/live-wave.md). It is an estimate before a run; a run's own wave replaces it.
struct LiveWaveControls: View {
    let model: SimulationModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.liveWavePlaying ? model.pauseLiveWave() : model.playLiveWave()
            } label: {
                Image(systemName: model.liveWavePlaying ? "pause.fill" : "play.fill")
            }
            .disabled(model.liveWave == nil)
            .accessibilityLabel(model.liveWavePlaying ? "Pause blast wave" : "Play blast wave")
            Slider(
                value: Binding(
                    get: { model.liveWaveTime },
                    set: { model.scrubLiveWave(to: $0) }),
                in: 0...max(model.liveWaveEnd, 1e-3)
            )
            .disabled(model.liveWave == nil)
            .accessibilityLabel("Blast wave time")
            .accessibilityValue(model.liveWaveSummary ?? SimulationModel.liveWaveTimeText(model.liveWaveTime))
            Text(
                "\(SimulationModel.liveWaveTimeText(model.liveWaveTime)) of \(SimulationModel.liveWaveTimeText(model.liveWaveEnd))"
            )
            .font(.caption.monospacedDigit()).frame(minWidth: 110, alignment: .trailing)
            Picker(
                "Speed",
                selection: Binding(get: { model.liveWaveSpeed }, set: { model.setLiveWaveSpeed($0) })
            ) {
                ForEach(LiveWaveSpeed.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help("How fast the front plays: a district's crosses it in seconds, a street's in hundredths.")
            LiveWaveKey(top: model.renderSettings.pressureScale)
            Text(liveWaveCaption)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .help(([model.liveWaveStatus] + LiveWave.standing).joined(separator: "\n\n"))
            Spacer(minLength: 0)
            Button("Done") { model.liveWaveShown = false }
                .accessibilityLabel("Hide the live blast wave")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var liveWaveCaption: String {
        if model.liveWave == nil { return "Working out the blast wave…" }
        if !model.drawsLiveWave { return "The live blast wave is shown before a run: reset to see it." }
        return model.isDraggingCharge
            ? "Live blast wave following the charge: an estimate, not a run."
            : "Live blast wave: an estimate, not a run. Drag the charge with Place Charge on."
    }
}

/// The live wave's colours: overpressure on a log scale from 1 kPa to the surfaces' top.
private struct LiveWaveKey: View {
    let top: Float

    var body: some View {
        HStack(spacing: 4) {
            Text("1").font(.caption2.monospacedDigit())
            LinearGradient(colors: Self.stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 70, height: 8).clipShape(.rect(cornerRadius: 2))
            Text(String(format: "%.0f kPa", top)).font(.caption2.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(format: "Colour key: peak overpressure, 1 to %.0f kPa, on a log scale", top))
    }

    /// The renderer's heat scale (`heat` in Render.metal), from 0.15 of it where the colours start.
    static let stops: [Color] = [
        Color(red: 0.24, green: 0.06, blue: 0.43), Color(red: 0.67, green: 0.14, blue: 0.42),
        Color(red: 0.92, green: 0.33, blue: 0.16), Color(red: 0.99, green: 0.68, blue: 0.10),
        Color(red: 0.99, green: 0.98, blue: 0.70),
    ]
}
