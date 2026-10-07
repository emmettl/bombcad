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

    /// Phase steps of the sinc and window between kernel taps, as (cos, sin).
    private static let sincStep = (cos(Double.pi * 2 * cutoffFraction), sin(Double.pi * 2 * cutoffFraction))
    private static let windowStep = (
        cos(Double.pi / Double(kernelHalfWidth)), sin(Double.pi / Double(kernelHalfWidth))
    )

    /// Adds an arrival `delay` seconds after emission with the given gain in each band.
    mutating func add(delay: Double, gains: [Double]) {
        let position = delay * sampleRate
        let base = Int(position.rounded(.down))
        let k = Self.kernelHalfWidth
        let bandwidth = 2 * Self.cutoffFraction
        // Successive taps advance both cosines by a fixed angle, so rotate rather than call sin and cos
        // for each tap: four calls per arrival instead of 128.
        let x0 = Double(base - k + 1) - position
        var sincPhase = (cos(Double.pi * bandwidth * x0), sin(Double.pi * bandwidth * x0))
        var windowPhase = (cos(Double.pi * x0 / Double(k)), sin(Double.pi * x0 / Double(k)))
        let (sc, ss) = Self.sincStep
        let (wc, ws) = Self.windowStep
        for i in 0..<(2 * k) {
            let x = x0 + Double(i)
            let arg = Double.pi * bandwidth * x
            let sinc = abs(arg) < 1e-12 ? 1 : sincPhase.1 / arg
            let window = abs(x) < Double(k) ? 0.5 + 0.5 * windowPhase.0 : 0
            kernel[i] = bandwidth * sinc * window
            sincPhase = (sincPhase.0 * sc - sincPhase.1 * ss, sincPhase.1 * sc + sincPhase.0 * ss)
            windowPhase = (windowPhase.0 * wc - windowPhase.1 * ws, windowPhase.1 * wc + windowPhase.0 * ws)
        }
        let length = fftLength
        let first = base - k + 1
        kernel.withUnsafeBufferPointer { kernel in
            for b in 0..<gains.count where gains[b] != 0 {
                let g = gains[b]
                bands[b].withUnsafeMutableBufferPointer { signal in
                    if first >= 0 && first + 2 * k <= length {
                        for i in 0..<(2 * k) { signal[first + i] += g * kernel[i] }
                    } else {
                        // Negative indices wrap into the discarded margin.
                        for i in 0..<(2 * k) { signal[(first + i + length) % length] += g * kernel[i] }
                    }
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
