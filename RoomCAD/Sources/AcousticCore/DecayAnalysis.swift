import Foundation

/// Energy decay of a sampled response by Schroeder backward integration (ISO 3382-1).
public enum DecayAnalysis {
    /// Energy decay curve in dB relative to the total energy, one value per sample.
    public static func decayCurve(_ samples: [Float]) -> [Double] {
        var remaining = [Double](repeating: 0, count: samples.count)
        var sum = 0.0
        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            sum += Double(samples[i]) * Double(samples[i])
            remaining[i] = sum
        }
        guard sum > 0 else { return remaining.map { _ in -.infinity } }
        let total = remaining[0]
        return remaining.map { 10 * log10(max($0, .leastNonzeroMagnitude) / total) }
    }

    /// The part of `samples` in one octave band of `OctaveBands`, by the same zero-phase weights used to
    /// render responses.
    public static func octaveBand(_ samples: [Float], sampleRate: Int, band: Int) -> [Float] {
        RealFFT.zeroPhaseFilter(samples, sampleRate: Double(sampleRate)) {
            OctaveBands.weight(band: band, frequency: $0)
        }
    }

    /// Reverberation time in seconds from a least-squares line fitted to the decay curve between `from`
    /// and `to` dB, extrapolated to 60 dB (T30 for -5 to -35 dB). Nil if the curve does not reach `to`.
    public static func reverberationTime(
        _ samples: [Float], sampleRate: Int, from upper: Double = -5, to lower: Double = -35
    ) -> Double? {
        let curve = decayCurve(samples)
        guard let first = curve.firstIndex(where: { $0 <= upper }),
            let last = curve.firstIndex(where: { $0 <= lower }), last > first + 1
        else { return nil }
        let n = Double(last - first + 1)
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        for i in first...last {
            let t = Double(i) / Double(sampleRate)
            sx += t
            sy += curve[i]
            sxx += t * t
            sxy += t * curve[i]
        }
        let slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        return slope < 0 ? -60 / slope : nil
    }
}
