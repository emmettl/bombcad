import AppKit
import Audition
import SwiftUI
import UniformTypeIdentifiers

/// Clip choice, transport and wet/dry balance for hearing the room.
struct AuditionBar: View {
    @Bindable var player: AuditionPlayer
    let sampleRate: Int
    /// Starts playback, generating a response first if needed.
    let play: () -> Void
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    player.isPlaying || player.isPreparing ? player.stop() : play()
                } label: {
                    Label(
                        player.isPlaying || player.isPreparing ? "Stop" : "Play",
                        systemImage: player.isPlaying || player.isPreparing ? "stop.fill" : "play.fill")
                }
                .disabled(busy && !player.isPlaying)
                .help("Play the clip through the room, generating the response first if it is out of date")

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
            if let message = player.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let clip = player.clip {
                Text(clip.credit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onAppear { player.prepareClips(sampleRate: sampleRate) }
        .onChange(of: sampleRate) { player.prepareClips(sampleRate: sampleRate) }
        .onChange(of: player.clipID) {
            if player.isPlaying { play() }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a dry recording. It is mixed to mono and played through the room."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.addFile(url, sampleRate: sampleRate)
    }
}
