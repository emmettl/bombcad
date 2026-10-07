import AcousticCore
import Foundation

/// What the editor shows about a generated response; computed off the main thread.
public struct ResponseSummary: Equatable, Sendable {
    public struct Channel: Equatable, Sendable {
        public var name: String
        /// Peak level in dB relative to the largest sample in any channel, per time bucket.
        public var envelope: [Double]
        /// Octave-band T30 in seconds, nil where the band's decay does not reach -35 dB.
        public var reverberationTime: [Double?]
    }

    public var channels: [Channel]
    public var duration: Double
    /// Lowest level drawn, in dB.
    public static let floor = -90.0

    public init(_ result: RoomResponse, buckets: Int = 400) {
        let response = result.response
        let peak = Double(max(response.peak, .leastNonzeroMagnitude))
        let rate = response.sampleRate
        duration = Double(response.frameCount) / Double(rate)
        channels = zip(response.metadata.channels, response.channels).map { description, samples in
            let size = max(1, (samples.count + buckets - 1) / buckets)
            let envelope = stride(from: 0, to: samples.count, by: size).map { start in
                let largest = samples[start..<min(samples.count, start + size)].reduce(Float(0)) {
                    max($0, abs($1))
                }
                return max(Self.floor, 20 * log10(max(Double(largest), 1e-12) / peak))
            }
            let times = (0..<OctaveBands.count).map { band in
                DecayAnalysis.reverberationTime(
                    DecayAnalysis.octaveBand(samples, sampleRate: rate, band: band), sampleRate: rate)
            }
            return Channel(name: description.name, envelope: envelope, reverberationTime: times)
        }
    }
}
