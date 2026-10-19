import BlastCore
import SwiftUI

/// Under the view: replay a recorded run, the last one or a kept one, and scrub through it with
/// no physics: play, pause, step and drag (`TimelinePlayback`).
struct TimelineBar: View {
    let model: SimulationModel

    var body: some View {
        if let playback = model.playback {
            PlaybackControls(model: model, playback: playback)
        } else if !model.isRunning, model.recentTimeline != nil || !model.replayableRuns.isEmpty {
            HStack(spacing: 8) {
                Menu("Replay") {
                    if model.recentTimeline != nil {
                        Button("This Run") { model.replay(nil) }
                    }
                    let kept = model.replayableRuns
                    if !kept.isEmpty {
                        Section("Kept runs") {
                            ForEach(kept) { run in Button(run.name) { model.replay(run) } }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Replay a recorded run")
                Text("Scrub a recorded run without running it again.").font(.caption).foregroundStyle(
                    .secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

private struct PlaybackControls: View {
    let model: SimulationModel
    let playback: TimelinePlayback

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.isPlaying ? playback.pause() : playback.play()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(playback.isPlaying ? "Pause replay" : "Play replay")
            Button {
                playback.step(-1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .disabled(playback.index == 0)
            .accessibilityLabel("Previous frame")
            Button {
                playback.step(1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .disabled(playback.index >= playback.count - 1)
            .accessibilityLabel("Next frame")
            Slider(
                value: Binding(
                    get: { playback.time },
                    set: { time in
                        playback.pause()
                        playback.seek(to: time)
                    }),
                in: playback.startTime...max(playback.endTime, playback.startTime + 1e-6)
            )
            .accessibilityLabel("Replay time")
            .accessibilityValue(Self.timeText(playback.time))
            Text("\(Self.timeText(playback.time)) of \(Self.timeText(playback.endTime))")
                .font(.caption.monospacedDigit()).frame(minWidth: 130, alignment: .trailing)
            Text(playback.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("Done") { model.stopReplay() }
                .accessibilityLabel("Stop replaying")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// Simulated time in milliseconds below a second, else seconds.
    static func timeText(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.1f ms", seconds * 1000) : String(format: "%.3f s", seconds)
    }
}
