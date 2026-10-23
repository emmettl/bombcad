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
            .disabled(playback.position == 0)
            .accessibilityLabel("Previous frame")
            Button {
                playback.step(1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .disabled(playback.position >= playback.positions - 1)
            .accessibilityLabel("Next frame")
            // By how far through it is as it plays, so that a crater's tail after the run takes
            // the share of the slider it takes to play, past a mark where the run ends.
            Slider(
                value: Binding(
                    get: { playback.progress },
                    set: { progress in
                        playback.pause()
                        playback.seek(toProgress: progress)
                    }),
                in: 0...1
            )
            .overlay(alignment: .leading) { SavedStateMarks(playback: playback) }
            .accessibilityLabel("Replay time")
            .accessibilityValue(Self.timeText(playback.time))
            let saved = model.checkpointToContinue(playback)
            Button(saved.map { "Continue from \(Self.timeText($0.time))" } ?? "Continue") {
                model.continueFromReplay()
            }
            .disabled(saved == nil)
            .help(
                saved == nil
                    ? "No saved state at or before this time."
                    : "Run on from the state saved at this time or just before, the same to the bit as the run had it."
            )
            Text("\(Self.timeText(playback.time)) of \(Self.timeText(playback.endTime))")
                .font(.caption.monospacedDigit()).frame(minWidth: 130, alignment: .trailing)
            if playback.isInTail {
                // Past the run's last frame, which stays shown, while its craters finish forming.
                Text("Crater forming, run ended at \(Self.timeText(playback.runEndTime))")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help(
                        "The air and the structures stay as the run left them while the crater finishes forming, in real time."
                    )
            }
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

/// Ticks under the replay's slider where the run saved its state, to continue from, and a taller
/// one where the run ends and a crater's tail begins.
private struct SavedStateMarks: View {
    let playback: TimelinePlayback

    var body: some View {
        GeometryReader { geometry in
            let span = max(playback.runEndTime - playback.startTime, 1e-9)
            let share = playback.runEndProgress
            // The slider's knob keeps half its width in from each end.
            let inset: CGFloat = 10
            let width = max(geometry.size.width - 2 * inset, 1)
            ForEach(playback.player.manifest.entries(.checkpoint), id: \.path) { entry in
                Rectangle()
                    .fill(entry.pinned == true ? Color.accentColor : Color.secondary)
                    .frame(width: 2, height: 6)
                    .position(
                        x: inset + width * CGFloat(share * (entry.time - playback.startTime) / span),
                        y: geometry.size.height - 2)
            }
            if playback.tailSteps > 0 {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: 12)
                    .position(x: inset + width * CGFloat(share), y: geometry.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
