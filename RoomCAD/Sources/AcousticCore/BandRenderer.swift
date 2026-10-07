import Foundation

/// Turns arrivals with per-band gains into one sampled channel.
///
/// Each arrival is a windowed-sinc impulse at its exact, fractional delay, accumulated into one signal
/// per octave band. Each band signal is then filtered by its zero-phase band weight in the frequency
/// domain and the bands are summed. Because the weights sum to one, an arrival with equal gains in all
/// bands passes through unchanged, apart from the optional high-pass.
struct BandRenderer {
    /// Half-length of the fractional-delay kernel in samples.
    static let kernelHalfWidth = 32
    /// Kernel cutoff as a fraction of the sample rate (0.9 of the Nyquist frequency).
    static let cutoffFraction = 0.45
    /// Highest frequency the kernel passes essentially unchanged, as a fraction of the sample rate.
    static let passbandFraction = 0.42
    /// Silent padding after the response, which absorbs the band filters' ringing in both directions.
    static let margin = 1 << 14

    let sampleRate: Double
    let frames: Int
    /// High-pass edge: content above this frequency is kept, content below half of it removed, with a
    /// half-cosine transition in log frequency. Zero disables it.
    let lowFrequencyCutoff: Double
    let fftLength: Int
    private var bands: [[Double]]
    private var kernel = [Double](repeating: 0, count: 2 * kernelHalfWidth)

    init(sampleRate: Int, frames: Int, lowFrequencyCutoff: Double = 0) {
        self.sampleRate = Double(sampleRate)
        self.frames = frames
        self.lowFrequencyCutoff = lowFrequencyCutoff
        var length = 1
        while length < frames + Self.kernelHalfWidth + Self.margin { length <<= 1 }
        fftLength = length
        bands = Array(repeating: Array(repeating: 0, count: length), count: OctaveBands.count)
    }

    /// Adds an arrival `delay` seconds after emission with the given gain in each band.
    mutating func add(delay: Double, gains: [Double]) {
        let position = delay * sampleRate
        let base = Int(position.rounded(.down))
        let k = Self.kernelHalfWidth
        let bandwidth = 2 * Self.cutoffFraction
        for i in 0..<(2 * k) {
            let x = Double(base - k + 1 + i) - position
            let arg = Double.pi * bandwidth * x
            let sinc = abs(arg) < 1e-12 ? 1 : sin(arg) / arg
            let window = abs(x) < Double(k) ? 0.5 + 0.5 * cos(Double.pi * x / Double(k)) : 0
            kernel[i] = bandwidth * sinc * window
        }
        let length = fftLength
        for b in 0..<gains.count where gains[b] != 0 {
            let g = gains[b]
            bands[b].withUnsafeMutableBufferPointer { signal in
                for i in 0..<(2 * k) {
                    // Negative indices wrap into the discarded margin.
                    let index = (base - k + 1 + i + length) % length
                    signal[index] += g * kernel[i]
                }
            }
        }
    }

    /// Filters and sums the bands, returning the first `frames` samples.
    func render() -> [Float] {
        let fft = RealFFT(length: fftLength)
        let half = fftLength / 2
        var sum = (real: [Double](repeating: 0, count: half), imag: [Double](repeating: 0, count: half))
        for (b, signal) in bands.enumerated() where signal.contains(where: { $0 != 0 }) {
            RealFFT.accumulate(fft.forward(signal), into: &sum, sampleRate: sampleRate) { frequency in
                let highPass =
                    lowFrequencyCutoff > 0
                    ? OctaveBands.rise(frequency, crossover: lowFrequencyCutoff / 2.squareRoot()) : 1
                return highPass * OctaveBands.weight(band: b, frequency: frequency)
            }
        }
        let output = fft.inverse(real: sum.real, imag: sum.imag)
        return (0..<frames).map { Float(output[$0]) }
    }
}
