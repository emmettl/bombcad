import Audition
import SwiftUI

/// The clip, dry and through the room, with a playhead. Click or drag to move the playhead; while
/// dragging it follows silently, and playback continues from where it is released.
struct AuditionWaveform: View {
    let player: AuditionPlayer
    @State private var scrubTime: Double?

    static let wetColor = Color.blue

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrubTime = time(at: $0.location.x, width: geometry.size.width) }
                    .onEnded {
                        player.seek(to: time(at: $0.location.x, width: geometry.size.width))
                        scrubTime = nil
                    }
            )
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel("Waveform of the clip, dry and in the room")
        .accessibilityValue(Self.format(player.playhead))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            player.seek(to: player.playhead + step)
        }
    }

    private var duration: Double { player.dryOverview?.duration ?? 0 }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width)), 1) * duration
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let dry = player.dryOverview, duration > 0 else {
            context.draw(
                Text("No clip").foregroundStyle(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        var lanes: [(name: String, overview: WaveformOverview, color: Color, emphasis: Double)] = [
            ("Dry", dry, .secondary, 1 - player.wetMix)
        ]
        if let wet = player.wetOverview {
            lanes.append(("Wet", wet, Self.wetColor, player.wetMix))
        }
        let laneHeight = size.height / CGFloat(lanes.count)
        // One scale for every lane, so the louder fills its lane and their relative levels show.
        let loudest =
            lanes.map { max($0.overview.maximum.max() ?? 0, -($0.overview.minimum.min() ?? 0)) }.max() ?? 0
        let scale = loudest > 0 ? CGFloat(1 / loudest) : 1
        for (index, lane) in lanes.enumerated() {
            let top = CGFloat(index) * laneHeight
            let middle = top + laneHeight / 2
            let count = lane.overview.maximum.count
            var bars = Path()
            for bucket in 0..<count {
                let x = (CGFloat(bucket) + 0.5) / CGFloat(count) * size.width
                let high = middle - CGFloat(lane.overview.maximum[bucket]) * scale * (laneHeight / 2 - 3)
                let low = middle - CGFloat(lane.overview.minimum[bucket]) * scale * (laneHeight / 2 - 3)
                bars.move(to: CGPoint(x: x, y: high))
                bars.addLine(to: CGPoint(x: x, y: max(low, high + 0.5)))
            }
            let opacity = 0.35 + 0.65 * lane.emphasis
            context.stroke(
                bars, with: .color(lane.color.opacity(opacity)),
                lineWidth: max(1, size.width / CGFloat(count)))
            context.draw(
                Text(lane.name).font(.caption2.bold()).foregroundStyle(lane.color),
                at: CGPoint(x: 6, y: top + 4), anchor: .topLeading)
            if index > 0 {
                var divider = Path()
                divider.move(to: CGPoint(x: 0, y: top))
                divider.addLine(to: CGPoint(x: size.width, y: top))
                context.stroke(divider, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            }
        }
        let now = scrubTime ?? player.currentTime()
        let x = CGFloat(now / duration) * size.width
        var playhead = Path()
        playhead.move(to: CGPoint(x: x, y: 0))
        playhead.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(playhead, with: .color(.red), lineWidth: 1.5)
        context.draw(
            Text("\(Self.format(now)) / \(Self.format(duration))").font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary),
            at: CGPoint(x: size.width - 6, y: 4), anchor: .topTrailing)
    }

    static func format(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}
