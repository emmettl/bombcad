import AcousticCore
import Foundation
import ImpulseResponseKit

/// Compares RoomCAD with the measured seminar room CR2 of the BRAS database.
///
///   acousticbench --bras-cr2 [--update-fixture] [--reuse-simulation]
///
/// With `--update-fixture`, the measured responses are read from the cache that
/// `RoomCAD/Scripts/fetch-bras-cr2.py` fills, and the parameters derived from them are written to
/// `RoomCAD/Validation/bras-cr2/measured.json`. Otherwise that file is used, so the comparison runs without
/// the download.
enum MeasuredRoom {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Validation/bras-cr2")
    static let cache = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".cache/bras-cr2/scene")

    /// Pairs measured with the dodecahedron.
    static let pairs = ["LS1", "LS2"].flatMap { s in (1...5).map { (s, "MP\($0)") } }
    /// What is simulated: a name, the material set and whether the wave solver is used.
    static let configurations = [
        ("initial", "initial", true), ("fitted", "fitted", true), ("fitted, no wave solver", "fitted", false),
    ]
    static var names: [String] { configurations.map(\.0) }

    /// The low-frequency comparison: levels from 30 Hz to the wave solver's crossover, 1/24 octave apart.
    static let lowFrequencies = (low: 30.0, high: 175.0, pointsPerOctave: 24)
    /// Frequency scales at which the simulated spectrum is also read, to find the one that matches best.
    static let scales = stride(from: -0.04, through: 0.0401, by: 0.005).map { $0 }

    struct Pair: Codable {
        var parameters: [RoomParameters]
        var lowFrequencyLevels: [Double]
        var early: [Double]
        /// For a simulated response, its levels with frequencies scaled by each of `scales`.
        var scaledLevels: [[Double]]?
    }

    struct Fixture: Codable {
        var description: String
        var bandCentres: [Double]
        var pairs: [String: Pair]
    }

    static func levels(_ samples: [Float], sampleRate: Int, scale: Double = 0) -> [Double] {
        ResponseComparison.spectrumLevels(
            samples, sampleRate: sampleRate, low: lowFrequencies.low / (1 + scale),
            high: lowFrequencies.high / (1 + scale), pointsPerOctave: lowFrequencies.pointsPerOctave,
            smoothing: 1.0 / 24
        ).levels
    }

    /// Everything compared, each band timed from its own onset.
    static func analyse(_ samples: [Float], sampleRate: Int, measured: Bool) -> Pair {
        Pair(
            parameters: OctaveBands.centres.indices.map {
                RoomParameters.measure(samples, sampleRate: sampleRate, band: $0, noiseCompensated: measured)
            },
            lowFrequencyLevels: levels(samples, sampleRate: sampleRate),
            early: ResponseComparison.earlyReflections(samples, sampleRate: sampleRate),
            scaledLevels: measured ? nil : scales.map { levels(samples, sampleRate: sampleRate, scale: $0) })
    }

    static func updateFixture() throws {
        var pairs: [String: Pair] = [:]
        for (source, receiver) in Self.pairs {
            let url = cache.appendingPathComponent("CR2_RIR_\(source)_\(receiver)_Dodecahedron.wav")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ImpulseResponseError.invalid(
                    "\(url.lastPathComponent) is missing; run python3 RoomCAD/Scripts/fetch-bras-cr2.py first."
                )
            }
            let audio = try WAVFile.decode(Data(contentsOf: url))
            pairs["\(source)-\(receiver)"] = analyse(
                audio.channels[0], sampleRate: audio.sampleRate, measured: true)
        }
        let fixture = Fixture(
            description: "Parameters derived by RoomCAD's acousticbench from the measured dodecahedron room "
                + "impulse responses of BRAS scene CR2 (Aspöck et al., TU Berlin and RWTH Aachen), "
                + "CC BY-SA 4.0. See README.md.",
            bandCentres: OctaveBands.centres, pairs: pairs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(to: directory.appendingPathComponent("measured.json"))
        print("Wrote \(directory.appendingPathComponent("measured.json").path)")
    }

    static func run(reuse: Bool) throws {
        let scene = try ValidationScene.load(directory.appendingPathComponent("scene.json"))
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("measured.json")))
        let receivers = (1...5).map { "MP\($0)" }
        var simulated: [String: [String: Pair]] = [:]
        // The simulated analysis is kept beside the download, so the report can be reworked without
        // simulating again (`--reuse-simulation`).
        let saved = cache.deletingLastPathComponent().appendingPathComponent("simulated.json")
        if reuse, let data = try? Data(contentsOf: saved) {
            simulated = try JSONDecoder().decode([String: [String: Pair]].self, from: data)
            report(fixture, simulated, scene: scene)
            return
        }
        for (set, materials, wave) in configurations {
            for source in ["LS1", "LS2"] {
                let start = Date()
                let result = try scene.generate(
                    set: materials, source: source, receivers: receivers, duration: 3.5,
                    lowFrequencyModel: wave)
                let responses = cache.deletingLastPathComponent().appendingPathComponent("simulated")
                try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
                for (receiver, channel) in zip(receivers, result.channels) {
                    simulated[set, default: [:]]["\(source)-\(receiver)"] = analyse(
                        channel, sampleRate: result.sampleRate, measured: false)
                    try WAVFile.encode(channels: [channel], sampleRate: result.sampleRate).write(
                        to: responses.appendingPathComponent("\(set)-\(source)-\(receiver).wav"))
                }
                let d = result.diagnostics
                print(
                    "Simulated \(set) \(source) in \(format(Date().timeIntervalSince(start), 1)) s; wave solver "
                        + "below \(format(d.waveCrossover, 0)) Hz, \(d.waveRuns ?? 0) runs")
            }
        }
        try? FileManager.default.createDirectory(
            at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(simulated).write(to: saved)
        report(fixture, simulated, scene: scene)
    }

    /// Mean and standard deviation over the pairs of a parameter that every pair has.
    static func statistics(_ values: [Double?]) -> (mean: Double, deviation: Double)? {
        let present = values.compactMap { $0 }
        guard present.count == values.count, !present.isEmpty else { return nil }
        let mean = present.reduce(0, +) / Double(present.count)
        let variance = present.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(present.count)
        return (mean, variance.squareRoot())
    }

    static func report(_ fixture: Fixture, _ simulated: [String: [String: Pair]], scene: ValidationScene) {
        let keys = pairs.map { "\($0.0)-\($0.1)" }
        let measured = keys.map { fixture.pairs[$0]! }
        // Parameter, its just-noticeable difference (ISO 3382-1, Table A.1), relative or absolute.
        let rows: [(String, (RoomParameters) -> Double?, Double, Bool)] = [
            ("EDT (s)", { $0.edt }, 0.05, true), ("T20 (s)", { $0.t20 }, 0.05, true),
            ("T30 (s)", { $0.t30 }, 0.05, true), ("C50 (dB)", { $0.c50 }, 1, false),
            ("C80 (dB)", { $0.c80 }, 1, false), ("D50", { $0.d50 }, 0.05, false),
            ("Ts (ms)", { $0.centreTime * 1000 }, 10, false),
        ]
        print("\nOctave-band parameters, mean over the 10 pairs (measured ± spread across them)")
        print(
            "| Parameter | Set | " + OctaveBands.centres.map { formatBand($0) }.joined(separator: " | ")
                + " |")
        print("|---|---|" + String(repeating: "---|", count: OctaveBands.count))
        for (name, value, jnd, relative) in rows {
            var line = "| \(name) | measured |"
            for band in OctaveBands.centres.indices {
                let s = statistics(measured.map { value($0.parameters[band]) })
                line += s.map { " \(format($0.mean, 2)) ± \(format($0.deviation, 2)) |" } ?? " — |"
            }
            print(line)
            for set in names {
                var line = "| | \(set) |"
                for band in OctaveBands.centres.indices {
                    let m = statistics(measured.map { value($0.parameters[band]) })
                    let s = statistics(keys.map { value(simulated[set]![$0]!.parameters[band]) })
                    if let m, let s {
                        let jnds = relative ? (s.mean / m.mean - 1) / jnd : (s.mean - m.mean) / jnd
                        line += " \(format(s.mean, 2)) (\(jnds >= 0 ? "+" : "")\(format(jnds, 1))) |"
                    } else {
                        line += " — |"
                    }
                }
                print(line)
            }
        }
        print("Simulated values are followed by their difference from the measured mean in JNDs.")

        let p = lowFrequencies.pointsPerOctave
        func fine(_ levels: [Double]) -> [Double] {
            ResponseComparison.fineStructure(levels, pointsPerOctave: p)
        }
        print(
            "\nLow-frequency fine structure, 30–175 Hz (correlation of 1/24-octave levels less their octave "
                + "mean; the simulated spectrum also read with its frequencies scaled)")
        for set in names {
            let matched = keys.map {
                ResponseComparison.correlation(
                    fine(fixture.pairs[$0]!.lowFrequencyLevels), fine(simulated[set]![$0]!.lowFrequencyLevels)
                )
            }
            let mismatched = keys.flatMap { m in
                keys.filter { $0 != m }.map {
                    ResponseComparison.correlation(
                        fine(fixture.pairs[m]!.lowFrequencyLevels),
                        fine(simulated[set]![$0]!.lowFrequencyLevels))
                }
            }
            let byScale = scales.indices.map { k in
                statistics(
                    keys.map {
                        ResponseComparison.correlation(
                            fine(fixture.pairs[$0]!.lowFrequencyLevels),
                            fine(simulated[set]![$0]!.scaledLevels![k]))
                    })!.mean
            }
            let best = byScale.indices.max { byScale[$0] < byScale[$1] }!
            let c = statistics(matched)!
            print(
                "  \(set): \(format(c.mean, 2)) ± \(format(c.deviation, 2)) at the same position, "
                    + "\(format(statistics(mismatched)!.mean, 2)) against other positions; best "
                    + "\(format(byScale[best], 2)) with simulated frequencies \(format(scales[best] * 100, 1))% higher"
            )
            print(
                "    by scale: "
                    + scales.indices.map { "\(format(scales[$0] * 100, 1))% \(format(byScale[$0], 2))" }
                    .joined(separator: ", "))
        }

        print(
            "\nEarly reflections above 500 Hz, 1.5–19.5 ms after the direct sound (correlation of levels in "
                + "1 ms bins)")
        for set in names {
            let matched = keys.map {
                ResponseComparison.correlation(fixture.pairs[$0]!.early, simulated[set]![$0]!.early)
            }
            let mismatched = keys.flatMap { m in
                keys.filter { $0 != m }.map {
                    ResponseComparison.correlation(fixture.pairs[m]!.early, simulated[set]![$0]!.early)
                }
            }
            let c = statistics(matched)!
            print(
                "  \(set): \(format(c.mean, 2)) ± \(format(c.deviation, 2)) at the same position, "
                    + "\(format(statistics(mismatched)!.mean, 2)) against other positions; per pair "
                    + matched.map { format($0, 2) }.joined(separator: ", "))
        }
    }

    static func formatBand(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz" }
}
