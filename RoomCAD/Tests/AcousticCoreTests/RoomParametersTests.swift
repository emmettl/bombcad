import Foundation
import Testing

@testable import AcousticCore

@Suite("Room parameters")
struct RoomParametersTests {
    /// Exponentially decaying random-sign noise with reverberation time `t60`, optionally with steady
    /// background noise `noiseDecibels` below the start.
    private func decay(t60: Double, noiseDecibels: Double?, seconds: Double = 3) -> [Double] {
        let rate = 48_000.0
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        let delta = 3 * log(10) / t60
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var sample = random() * exp(-delta * t)
            if let noiseDecibels { sample += random() * pow(10, noiseDecibels / 20) }
            return sample * sample
        }
    }

    @Test("An exponential decay gives its reverberation time, clarity, definition and centre time")
    func exponential() throws {
        let t60 = 1.2
        let p = RoomParameters.measure(
            energy: decay(t60: t60, noiseDecibels: nil), sampleRate: 48_000, noiseCompensated: false)
        let k = 6 * log(10) / t60
        for value in [p.edt, p.t20, p.t30] {
            let measured = try #require(value)
            #expect(abs(measured / t60 - 1) < 0.03, "\(measured) s against \(t60) s")
        }
        let c80 = 10 * log10((1 - exp(-k * 0.08)) / exp(-k * 0.08))
        #expect(abs(p.c80 - c80) < 0.2)
        #expect(abs(p.d50 - (1 - exp(-k * 0.05))) < 0.01)
        #expect(abs(p.centreTime / (1 / k) - 1) < 0.03)
    }

    @Test("Background noise is cut off and the missing decay added back, as Lundeby's method does")
    func noise() throws {
        let t60 = 1.2
        let noisy = decay(t60: t60, noiseDecibels: -45)
        let compensated = RoomParameters.measure(energy: noisy, sampleRate: 48_000, noiseCompensated: true)
        let raw = RoomParameters.measure(energy: noisy, sampleRate: 48_000, noiseCompensated: false)
        let t30 = try #require(compensated.t30)
        #expect(abs(t30 / t60 - 1) < 0.05, "\(t30) s against \(t60) s")
        // Without compensation the noise flattens the decay curve.
        #expect(try #require(raw.t30) > 1.1 * t60)
        // Without noise, compensation changes nothing that matters.
        let clean = decay(t60: t60, noiseDecibels: nil)
        let both = [true, false].map {
            RoomParameters.measure(energy: clean, sampleRate: 48_000, noiseCompensated: $0)
        }
        #expect(abs(try #require(both[0].t30) / #require(both[1].t30) - 1) < 0.001)
    }
}
