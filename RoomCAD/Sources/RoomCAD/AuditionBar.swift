import AcousticCore
import AppKit
import Audition
import SwiftUI
import UniformTypeIdentifiers

/// Clip choice, transport, waveform and wet/dry balance for hearing the room.
struct AuditionBar: View {
    @Bindable var player: AuditionPlayer
    let sampleRate: Int
    /// The response the clip is played through, if any.
    let result: RoomResponse?
    /// Starts playback, generating a response first if there is none.
    let play: () -> Void
    /// Whether Play cannot work: there is no response and none can be generated.
    let busy: Bool

    private var active: Bool { player.isPlaying || player.isPreparing }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    active ? player.pause() : play()
                } label: {
                    Label(active ? "Pause" : "Play", systemImage: active ? "pause.fill" : "play.fill")
                }
                .disabled(busy && !player.isPlaying)
                .help("Play the clip through the room; a response being updated takes over when it is ready")
                Button("Back to Start", systemImage: "backward.end.fill") { player.seek(to: 0) }
                    .labelStyle(.iconOnly)

                Picker("Clip", selection: $player.clipID) {
                    ForEach(player.clips) { clip in Text(clip.name).tag(Optional(clip.id)) }
                }
                .frame(maxWidth: 220)
                Button("Choose File…") { chooseFile() }

                HStack(spacing: 4) {
                    Text("Dry").font(.caption)
                    Slider(value: $player.wetMix, in: 0...1).frame(width: 110)
                    Text("Wet").font(.caption)
                }
                .help("Balance between the clip as recorded and the clip in the room")
                Toggle("Match loudness", isOn: $player.matchLoudness)
                    .help(
                        "Give the dry and wet sounds equal energy. Off, levels are physical: the dry sound is "
                            + "the source heard 1 m away in open air.")
                Toggle("Loop", isOn: $player.loops)
            }
            .controlSize(.small)
            AuditionWaveform(player: player)
                .frame(height: player.wetOverview == nil ? 56 : 96)
            if let message = player.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let clip = player.clip {
                Text(clip.credit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onAppear { player.prepareClips(sampleRate: sampleRate) }
        .onChange(of: sampleRate) { player.prepareClips(sampleRate: sampleRate) }
        .onChange(of: player.clipID) { player.clipSelected(result) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a dry recording. It is mixed to mono and played through the room."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.addFile(url, sampleRate: sampleRate)
    }
}
