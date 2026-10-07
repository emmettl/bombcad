import Accelerate

/// Power-of-two real FFT in vDSP's packed format: element 0 of a spectrum holds the DC term in its real
/// part and the Nyquist term in its imaginary part.
final class RealFFT {
    let length: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    init(length: Int) {
        precondition(length >= 2 && length & (length - 1) == 0, "FFT length must be a power of two")
        self.length = length
        log2n = vDSP_Length(length.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Could not create an FFT of length \(length)")
        }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// Spectrum of `signal`, which must have `length` samples. vDSP scales it by 2.
    func forward(_ signal: [Double]) -> (real: [Double], imag: [Double]) {
        precondition(signal.count == length)
        let half = length / 2
        var real = [Double](repeating: 0, count: half)
        var imag = [Double](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                signal.withUnsafeBytes { raw in
                    vDSP_ctozD(
                        raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1,
                        vDSP_Length(half))
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (real, imag)
    }

    /// Signal whose `forward` spectrum is given, so `inverse(forward(x)) == x`.
    func inverse(real: [Double], imag: [Double]) -> [Double] {
        let half = length / 2
        var real = real
        var imag = imag
        var output = [Double](repeating: 0, count: length)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                output.withUnsafeMutableBytes { raw in
                    vDSP_ztocD(
                        &split, 1, raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2,
                        vDSP_Length(half))
                }
            }
        }
        // A forward and inverse transform together scale by 2n.
        let scale = 1 / Double(2 * length)
        return output.map { $0 * scale }
    }

    /// Adds `spectrum` weighted by a real, zero-phase frequency response into `sum`.
    static func accumulate(
        _ spectrum: (real: [Double], imag: [Double]), into sum: inout (real: [Double], imag: [Double]),
        sampleRate: Double, response: (Double) -> Double
    ) {
        let half = spectrum.real.count
        let binWidth = sampleRate / Double(2 * half)
        sum.real[0] += spectrum.real[0] * response(0)
        sum.imag[0] += spectrum.imag[0] * response(sampleRate / 2)
        for k in 1..<half {
            let w = response(Double(k) * binWidth)
            sum.real[k] += spectrum.real[k] * w
            sum.imag[k] += spectrum.imag[k] * w
        }
    }

    /// Filters `signal` by a real, zero-phase frequency response, padding to avoid wrap-around within
    /// `padding` samples of either end.
    static func zeroPhaseFilter(
        _ signal: [Float], sampleRate: Double, padding: Int = 1 << 14, response: (Double) -> Double
    ) -> [Float] {
        var length = 2
        while length < signal.count + padding { length <<= 1 }
        let fft = RealFFT(length: length)
        var padded = [Double](repeating: 0, count: length)
        for (i, value) in signal.enumerated() { padded[i] = Double(value) }
        var filtered = (
            real: [Double](repeating: 0, count: length / 2), imag: [Double](repeating: 0, count: length / 2)
        )
        accumulate(fft.forward(padded), into: &filtered, sampleRate: sampleRate, response: response)
        let output = fft.inverse(real: filtered.real, imag: filtered.imag)
        return (0..<signal.count).map { Float(output[$0]) }
    }
}
