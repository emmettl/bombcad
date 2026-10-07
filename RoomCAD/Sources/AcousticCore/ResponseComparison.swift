import Foundation

/// Measures for comparing a simulated response with a measured one beyond band parameters: the
/// low-frequency spectrum's modal structure and the early reflections' timing.
public enum ResponseComparison {
    /// Power spectrum of `samples`, |H(f)|², at every bin up to `high` Hz, with the bin spacing.
    static func powerSpectrum(_ samples: [Float], sampleRate: Int, high: Double) -> (
        spacing: Double, power: [Double]
    ) {
        var length = 2
        while length < samples.count { length <<= 1 }
        let padded = samples.map(Double.init) + [Double](repeating: 0, count: length - samples.count)
        let spectrum = RealFFT(length: length).forward(padded)
        let spacing = Double(sampleRate) / Double(length)
        let bins = min(Int(high / spacing) + 2, length / 2)
        return (
            spacing,
            (0..<bins).map { k in
                k == 0 ? 0 : spectrum.real[k] * spectrum.real[k] + spectrum.imag[k] * spectrum.imag[k]
            }
        )
    }

    /// Level in dB at `pointsPerOctave` log-spaced frequencies from `low` to `high` Hz, each the mean power
    /// over ±`smoothing`/2 octaves about it.
    public static func spectrumLevels(
        _ samples: [Float], sampleRate: Int, low: Double, high: Double, pointsPerOctave: Int,
        smoothing: Double
    ) -> (frequencies: [Double], levels: [Double]) {
        let (spacing, power) = powerSpectrum(samples, sampleRate: sampleRate, high: high * pow(2, smoothing))
        let count = Int((log2(high / low) * Double(pointsPerOctave)).rounded()) + 1
        let frequencies = (0..<count).map { low * pow(2, Double($0) / Double(pointsPerOctave)) }
        let levels = frequencies.map { f in
            let lower = max(Int((f * pow(2, -smoothing / 2) / spacing).rounded()), 1)
            let upper = min(max(Int((f * pow(2, smoothing / 2) / spacing).rounded()), lower), power.count - 1)
            let mean = power[lower...upper].reduce(0, +) / Double(upper - lower + 1)
            return 10 * log10(max(mean, 1e-300))
        }
        return (frequencies, levels)
    }

    /// Levels less their mean over the surrounding octave: the modal fine structure, without the source's
    /// and the room's broad spectral trends.
    public static func fineStructure(_ levels: [Double], pointsPerOctave: Int) -> [Double] {
        let half = pointsPerOctave / 2
        return levels.indices.map { i in
            let range = max(i - half, 0)...min(i + half, levels.count - 1)
            return levels[i] - range.map { levels[$0] }.reduce(0, +) / Double(range.count)
        }
    }

    /// Pearson correlation of two equally long series.
    public static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var sab = 0.0
        var saa = 0.0
        var sbb = 0.0
        for (x, y) in zip(a, b) {
            sab += (x - ma) * (y - mb)
            saa += (x - ma) * (x - ma)
            sbb += (y - mb) * (y - mb)
        }
        return sab / max((saa * sbb).squareRoot(), .leastNonzeroMagnitude)
    }

    /// Level in dB, relative to the total, of the energy above 500 Hz in 1 ms bins from 1.5 to 19.5 ms
    /// after the onset above 500 Hz: the timing and strength of the early reflections, without the direct
    /// sound.
    public static func earlyReflections(_ samples: [Float], sampleRate: Int) -> [Double] {
        let milliseconds = 20
        let highs = RealFFT.zeroPhaseFilter(samples, sampleRate: Double(sampleRate)) {
            OctaveBands.rise($0, crossover: 500)
        }
        let start = max(RoomParameters.onset(highs) - Int(0.0005 * Double(sampleRate)), 0)
        let bin = Double(sampleRate) / 1000
        let bins = milliseconds
        var energy = [Double](repeating: 0, count: bins)
        for i in start..<min(start + Int(Double(milliseconds) * bin), highs.count) {
            energy[min(Int(Double(i - start) / bin), bins - 1)] += Double(highs[i]) * Double(highs[i])
        }
        let total = energy.reduce(0, +)
        // The first bin is centred on the onset; the second holds the rest of the direct sound.
        return energy[2...].map { 10 * log10($0 / max(total, .leastNonzeroMagnitude) + 1e-6) }
    }
}
