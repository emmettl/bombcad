import AcousticCore
import Foundation
import simd

/// The wave solver's travelling-wave accuracy, for the benchmark report that roadmap milestone M3 asks
/// for: amplitude and phase error against distance, direction and points per wavelength.
///
///   acousticbench --wave-accuracy
///
/// A pulse travels from the centre of a large anechoic box to receivers along an axis and along the body
/// diagonal. Below the crossover, the hybrid response is the wave solver's, weighted by 1 - rise(f); the
/// geometrical model's direct sound is exact, so the wave part's transfer function is recovered from the
/// two responses and divided by the exact one. Each response is windowed about its direct sound, before
/// any reflection from the box's walls arrives.
enum WaveBenchmark {
    static func run() throws {
        print(dispersionTable())
        for (crossover, size, half) in [(100.0, 30.0, 0.025), (250.0, 20.0, 0.012)] {
            try travellingWave(crossover: crossover, size: size, windowHalfWidth: half)
        }
    }

    /// The scheme's phase-velocity error at fractions of the top of the crossover's transition, where
    /// the grid has 10 or more points per wavelength.
    static func dispersionTable() -> String {
        let room = ShoeboxRoom(size: [12, 10, 8], material: .anechoic)
        let crossover = 250.0
        let grid = WaveAccuracy.grid(
            room: room, sampleRate: 48_000, crossover: crossover, atmosphere: .standard)
        let c = Atmosphere.standard.soundSpeed
        var lines = [
            "Phase-velocity error of the grid for a 250 Hz crossover (cells \(format(grid.spacing.x * 100, 1)) cm, "
                + "time step \(format(grid.timeStep * 1e6, 1)) µs)",
            "| Frequency | Points per wavelength | Axis | Face diagonal | Body diagonal |",
            "|---|---|---|---|---|",
        ]
        for fraction in [0.25, 0.5, 0.71, 1.0, 1.41] {
            let f = crossover * fraction
            let errors = [SIMD3<Double>(1, 0, 0), [1, 1, 0], [1, 1, 1]].map {
                WaveAccuracy.phaseVelocityError(
                    frequency: f, direction: $0, spacing: grid.spacing, timeStep: grid.timeStep, soundSpeed: c
                )
            }
            lines.append(
                "| \(format(f, 0)) Hz | \(format(c / f / grid.spacing.max(), 1)) | "
                    + errors.map { "\(format(($0 ?? .nan) * 100, 2))%" }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func travellingWave(crossover: Double, size: Double, windowHalfWidth: Double) throws {
        let centre = SIMD3<Double>(repeating: size / 2)
        let distances = [1.0, 2.0, 3.5, 5.0]
        let directions: [(String, SIMD3<Double>)] = [
            ("axis", [1, 0, 0]), ("diagonal", simd_normalize([1, 1, 1])),
        ]
        let receivers = directions.flatMap { name, u in
            distances.map { RoomPoint(name: "\(name) \($0) m", position: centre + $0 * u) }
        }
        var settings = RoomResponseSettings(
            room: ShoeboxRoom(size: SIMD3(repeating: size), material: .anechoic),
            source: RoomPoint(name: "Source", position: centre), receivers: receivers, airAbsorption: false,
            duration: (distances.max()! + 1) / Atmosphere.standard.soundSpeed + 2 * windowHalfWidth,
            maximumReflectionOrder: 0, lowFrequencyCutoff: 0, lowFrequencyModel: true,
            crossoverFrequency: crossover)
        let start = Date()
        let hybrid = try RoomResponseGenerator.generate(settings)
        settings.lowFrequencyModel = false
        let exact = try RoomResponseGenerator.generate(settings)
        let c = settings.atmosphere.soundSpeed
        let rate = Double(settings.sampleRate)
        let dispersion = hybrid.diagnostics.waveDispersion ?? 0
        print(
            "\nTravelling wave, crossover \(Int(crossover)) Hz, \(format(size, 0)) m box, "
                + "\(hybrid.diagnostics.waveCells ?? 0) cells, \(format(Date().timeIntervalSince(start), 1)) s; "
                + "worst phase-velocity error at the crossover \(format(dispersion * 100, 2))%")
        print("| Receiver | Frequency | Amplitude error | Phase error | Predicted phase error |")
        print("|---|---|---|---|---|")
        let grid = WaveAccuracy.grid(
            room: settings.room, sampleRate: settings.sampleRate, crossover: crossover,
            atmosphere: settings.atmosphere)
        for (index, receiver) in receivers.enumerated() {
            let distance = simd_distance(receiver.position, centre)
            let arrival = distance / c * rate
            let half = windowHalfWidth * rate
            let window = max(Int(arrival - half), 0)..<Int(arrival + half)
            for fraction in [0.25, 0.5, 0.71, 1.0] {
                let f = crossover * fraction
                // The wave solver's share of the hybrid response at f.
                let w = 1 - riseWeight(f, crossover: crossover)
                let mixed = transform(
                    hybrid.response.channels[index], window: window, frequency: f, rate: rate)
                let reference = transform(
                    exact.response.channels[index], window: window, frequency: f, rate: rate)
                let wave = (mixed - (1 - w) * reference) / w
                let ratio = wave / reference
                let direction = receiver.position - centre
                let predicted =
                    WaveAccuracy.phaseVelocityError(
                        frequency: f, direction: direction, spacing: grid.spacing, timeStep: grid.timeStep,
                        soundSpeed: c) ?? .nan
                // A wave slower by ε arrives late by d/c · (1/(1 + ε) - 1).
                let lag = -360 * f * distance / c * (1 / (1 + predicted) - 1)
                print(
                    "| \(receiver.name) | \(format(f, 0)) Hz | \(format(20 * log10(ratio.magnitude), 2)) dB | "
                        + "\(format(ratio.phase * 180 / .pi, 1))° | \(format(lag, 1))° |")
            }
        }
    }

    /// The half-cosine crossover RoomCAD uses, rising from 0 half an octave below to 1 half an octave
    /// above.
    static func riseWeight(_ f: Double, crossover: Double) -> Double {
        let x = log2(f / crossover)
        if x <= -0.5 { return 0 }
        if x >= 0.5 { return 1 }
        return 0.5 - 0.5 * cos(Double.pi * (x + 0.5))
    }

    struct Complex {
        var re: Double
        var im: Double
        var magnitude: Double { (re * re + im * im).squareRoot() }
        var phase: Double { atan2(im, re) }
        static func - (a: Complex, b: Complex) -> Complex { Complex(re: a.re - b.re, im: a.im - b.im) }
        static func * (s: Double, a: Complex) -> Complex { Complex(re: s * a.re, im: s * a.im) }
        static func / (a: Complex, s: Double) -> Complex { Complex(re: a.re / s, im: a.im / s) }
        static func / (a: Complex, b: Complex) -> Complex {
            let d = b.re * b.re + b.im * b.im
            return Complex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
        }
    }

    /// The discrete-time Fourier transform at `frequency` of `samples` in `window`, tapered by a Tukey
    /// window whose cosine ends take a quarter of it each.
    static func transform(_ samples: [Float], window: Range<Int>, frequency: Double, rate: Double) -> Complex
    {
        var re = 0.0
        var im = 0.0
        let count = Double(window.count)
        for n in window where n < samples.count {
            let x = Double(n - window.lowerBound) / count
            let taper =
                x < 0.25 ? 0.5 - 0.5 * cos(4 * .pi * x) : x > 0.75 ? 0.5 - 0.5 * cos(4 * .pi * (1 - x)) : 1
            let phase = -2 * Double.pi * frequency * Double(n) / rate
            re += Double(samples[n]) * taper * cos(phase)
            im += Double(samples[n]) * taper * sin(phase)
        }
        return Complex(re: re, im: im)
    }
}
