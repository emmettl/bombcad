import Foundation

/// Room-acoustic parameters of an impulse response in one octave band, after ISO 3382-1.
///
/// Times are measured from the direct sound's onset in the band, so that a multi-way source whose drivers
/// are delayed differently by its crossovers is timed in each band from its own driver. A measured response ends
/// in background noise, which would flatten the decay curve; with `noiseCompensated`, the response is cut
/// where its decay meets the noise and the energy beyond is added back from the decay's slope, after
/// Lundeby et al. (1995). A simulated response has no noise and is integrated as it is.
public struct RoomParameters: Codable, Equatable, Sendable {
    /// Early decay time: 0 to -10 dB of the decay curve, extrapolated to 60 dB.
    public var edt: Double?
    /// Reverberation times from -5 to -25 dB and -5 to -35 dB, extrapolated to 60 dB.
    public var t20: Double?
    public var t30: Double?
    /// Clarity: early (to 50 or 80 ms) to late energy, in dB.
    public var c50: Double
    public var c80: Double
    /// Definition: the fraction of the energy in the first 50 ms.
    public var d50: Double
    /// Centre time: the energy's first moment, in seconds.
    public var centreTime: Double

    public init(
        edt: Double?, t20: Double?, t30: Double?, c50: Double, c80: Double, d50: Double, centreTime: Double
    ) {
        self.edt = edt
        self.t20 = t20
        self.t30 = t30
        self.c50 = c50
        self.c80 = c80
        self.d50 = d50
        self.centreTime = centreTime
    }

    /// The sample where the direct sound starts: the first whose energy is within 20 dB of the peak's.
    public static func onset(_ samples: [Float]) -> Int {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        return samples.firstIndex { abs($0) >= 0.1 * peak } ?? 0
    }

    /// The parameters of `samples` in `band` of `OctaveBands`, timed from the band's onset.
    public static func measure(_ samples: [Float], sampleRate: Int, band: Int, noiseCompensated: Bool)
        -> RoomParameters
    {
        let filtered = DecayAnalysis.octaveBand(samples, sampleRate: sampleRate, band: band)
        let energy = filtered[onset(filtered)...].map { Double($0) * Double($0) }
        return measure(energy: energy, sampleRate: sampleRate, noiseCompensated: noiseCompensated)
    }

    /// The parameters of a squared response that starts at the direct sound.
    static func measure(energy: [Double], sampleRate: Int, noiseCompensated: Bool) -> RoomParameters {
        let rate = Double(sampleRate)
        var end = energy.count
        var tail = 0.0
        if noiseCompensated, let cut = noiseCut(energy, sampleRate: sampleRate) {
            end = cut.index
            tail = cut.tail
        }
        // Schroeder's backward integral, with the energy beyond the cut added back.
        var curve = [Double](repeating: 0, count: end)
        var sum = tail
        for i in stride(from: end - 1, through: 0, by: -1) {
            sum += energy[i]
            curve[i] = sum
        }
        let total = sum
        let decibels = curve.map { 10 * log10(max($0, .leastNonzeroMagnitude) / total) }
        func time(_ upper: Double, _ lower: Double) -> Double? {
            guard let first = decibels.firstIndex(where: { $0 <= upper }),
                let last = decibels.firstIndex(where: { $0 <= lower }), last > first + 1
            else { return nil }
            let slope = slopePerSecond(decibels, first...last, sampleRate: rate)
            return slope < 0 ? -60 / slope : nil
        }
        func early(_ milliseconds: Double) -> Double {
            let n = min(Int(milliseconds / 1000 * rate), end)
            return energy[..<n].reduce(0, +)
        }
        let e50 = early(50)
        let e80 = early(80)
        let moment = energy[..<end].enumerated().reduce(0) { $0 + Double($1.offset) / rate * $1.element }
        return RoomParameters(
            edt: time(0, -10), t20: time(-5, -25), t30: time(-5, -35),
            c50: 10 * log10(e50 / max(total - e50, .leastNonzeroMagnitude)),
            c80: 10 * log10(e80 / max(total - e80, .leastNonzeroMagnitude)),
            d50: e50 / total, centreTime: moment / max(total - tail, .leastNonzeroMagnitude))
    }

    /// Where the decay meets the background noise, and the energy the decay would have had beyond it.
    ///
    /// After Lundeby et al.: the noise level is the mean of the last tenth; a line is fitted to the
    /// smoothed decay from 5 dB below its start to 10 dB above the noise and extended to meet the noise;
    /// the fit and the crossing are refined a few times with the noise taken after the crossing. Nil if
    /// the response does not reach a noise floor.
    static func noiseCut(_ energy: [Double], sampleRate: Int) -> (index: Int, tail: Double)? {
        let rate = Double(sampleRate)
        let block = max(Int(0.01 * rate), 1)
        let blocks = energy.count / block
        guard blocks > 20 else { return nil }
        let levels = (0..<blocks).map { b in
            10 * log10(max(energy[(b * block)..<((b + 1) * block)].reduce(0, +) / Double(block), 1e-300))
        }
        func noise(from index: Int) -> Double {
            let start = max(min(index, blocks - blocks / 10), blocks / 2)
            let mean = energy[(start * block)...].reduce(0, +) / Double(energy.count - start * block)
            return 10 * log10(max(mean, 1e-300))
        }
        var floor = noise(from: blocks - blocks / 10)
        let top = levels.max() ?? 0
        guard top - floor > 20 else { return nil }
        var crossing = blocks - 1
        var slope = 0.0
        var intercept = 0.0
        for _ in 0..<5 {
            guard let first = levels.firstIndex(where: { $0 <= top - 5 }),
                let last = levels.lastIndex(where: { $0 >= floor + 10 }), last > first + 2
            else { return nil }
            let fit = line(Array(levels[first...last]), offset: first)
            slope = fit.slope
            intercept = fit.intercept
            guard slope < 0 else { return nil }
            crossing = min(max(Int((floor - intercept) / slope), last), blocks - 1)
            floor = noise(from: crossing + Int(5 / -slope) + 1)
        }
        // Mean energy per sample on the fitted line at the crossing, decaying with time constant τ.
        let index = crossing * block
        let level = intercept + slope * Double(crossing)
        let perSample = pow(10, level / 10)
        let tau = 10 / (log(10) * -slope) * Double(block)
        return (index, perSample * tau)
    }

    private static func line(_ values: [Double], offset: Int) -> (slope: Double, intercept: Double) {
        let n = Double(values.count)
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        for (i, y) in values.enumerated() {
            let x = Double(i + offset)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        return (slope, (sy - slope * sx) / n)
    }

    private static func slopePerSecond(_ curve: [Double], _ range: ClosedRange<Int>, sampleRate: Double)
        -> Double
    {
        let fit = line(Array(curve[range]), offset: range.lowerBound)
        return fit.slope * sampleRate
    }
}
