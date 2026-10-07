import Foundation

/// The smallest and largest sample in each of a fixed number of time buckets, for drawing.
public struct WaveformOverview: Equatable, Sendable {
    public var minimum: [Float]
    public var maximum: [Float]
    /// Seconds covered by all the buckets together.
    public var duration: Double

    /// Summarizes `channels` together, scaled by `gain`, over `buckets` equal spans.
    public init(_ channels: [[Float]], sampleRate: Int, buckets: Int, gain: Float = 1) {
        let frames = channels.first?.count ?? 0
        let count = max(1, min(buckets, max(frames, 1)))
        minimum = Array(repeating: 0, count: count)
        maximum = Array(repeating: 0, count: count)
        duration = Double(frames) / Double(sampleRate)
        guard frames > 0 else { return }
        for channel in channels {
            for bucket in 0..<count {
                let start = bucket * frames / count
                let end = max(start + 1, (bucket + 1) * frames / count)
                for value in channel[start..<min(end, frames)] {
                    minimum[bucket] = min(minimum[bucket], value * gain)
                    maximum[bucket] = max(maximum[bucket], value * gain)
                }
            }
        }
    }
}

/// Where playback is, given where it started and how far the player has run.
public enum PlaybackPosition {
    /// The frame being heard after `elapsed` frames of a run that began at `start` in a signal of
    /// `length` frames. A looping run plays from `start` to the end and then the whole signal again.
    public static func frame(start: Int, elapsed: Int, length: Int, loops: Bool) -> Int {
        guard length > 0 else { return 0 }
        let position = start + max(0, elapsed)
        if position < length { return position }
        return loops ? (position - length) % length : length
    }
}

extension AuditionPreview {
    /// Overviews of the dry and wet signals at the levels they are played with full balance to each.
    public func overviews(buckets: Int, matchLoudness: Bool) -> (dry: WaveformOverview, wet: WaveformOverview)
    {
        let output = outputGain(matchLoudness: matchLoudness)
        return (
            WaveformOverview(dry, sampleRate: sampleRate, buckets: buckets, gain: output),
            WaveformOverview(
                wet, sampleRate: sampleRate, buckets: buckets,
                gain: output * wetGain(matchLoudness: matchLoudness))
        )
    }
}
