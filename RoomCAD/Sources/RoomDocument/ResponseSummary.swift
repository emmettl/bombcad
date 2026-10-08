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
        /// Magnitude response in dB relative to the loudest point of any channel's, at
        /// `spectrumFrequencies`, each the mean power over a sixth of an octave.
        public var spectrum: [Double]
        /// Energy above 500 Hz in `earlyBin` bins over the first `earlyDuration` seconds, in dB relative to
        /// the loudest bin of any channel: the direct sound and early reflections one by one.
        public var early: [Double]
    }

    public var channels: [Channel]
    public var duration: Double
    /// Lowest level drawn, in dB.
    public static let floor = -90.0
    /// Frequencies of the spectrum, 12 to an octave from 20 Hz to 20 kHz.
    public static let spectrumFrequencies = (0...120).map { 20 * pow(2, Double($0) / 12) }
    /// The early view's bin width and how long it runs: 80 ms after the first channel's direct sound.
    public static let earlyBin = 0.00025
    public var earlyDuration: Double

    public init(_ result: RoomResponse, buckets: Int = 400) {
        let response = result.response
        let peak = Double(max(response.peak, .leastNonzeroMagnitude))
        let rate = response.sampleRate
        duration = Double(response.frameCount) / Double(rate)
        let earlyDuration = min((result.diagnostics.directDelay.min() ?? 0) + 0.08, duration)
        self.earlyDuration = earlyDuration
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
            let spectrum = ResponseComparison.spectrumLevels(
                samples, sampleRate: rate, low: Self.spectrumFrequencies[0],
                high: Self.spectrumFrequencies.last!,
                pointsPerOctave: 12, smoothing: 1.0 / 6
            ).levels
            let early = ResponseComparison.energyTimeCurve(
                samples, sampleRate: rate, duration: earlyDuration, bin: Self.earlyBin)
            return Channel(
                name: description.name, envelope: envelope, reverberationTime: times, spectrum: spectrum,
                early: early)
        }
        let loudestEarly = channels.flatMap(\.early).max() ?? 0
        let loudest = channels.flatMap(\.spectrum).max() ?? 0
        for c in channels.indices {
            channels[c].spectrum = channels[c].spectrum.map { max($0 - loudest, Self.floor) }
            channels[c].early = channels[c].early.map {
                max(
                    10 * log10(max($0, .leastNonzeroMagnitude) / max(loudestEarly, .leastNonzeroMagnitude)),
                    Self.floor)
            }
        }
    }
}
