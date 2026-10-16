import BlastCore
import Foundation
import Metal

/// `SceneBench envelope-histories [--dx 0.25] [--rounds 5] [--out file.json]`: what recording each
/// envelope component's pressure history costs. The street's four buildings (120 ms) and the
/// 64-building neighbourhood (60 ms), each run with the surface recorder alone, as every
/// envelope-only run is, and with the histories too, in alternating order, `rounds` times.
enum EnvelopeHistoryBenchmark {
    struct Run: Codable {
        var scene: String
        var histories: Bool
        var round: Int
        var wallS: Double
        var steps: Int
        var solverBytes: Int
        var components: Int
        var historyBytes: Int
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let dx = value("dx").flatMap(Float.init) ?? 0.25
        let rounds = value("rounds").flatMap(Int.init) ?? 5
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        let scenes = [
            ("street", try EnvelopeBenchmark.approximated(EnvelopeBenchmark.reference(.street)), 0.12),
            ("neighbourhood", try EnvelopeBenchmark.scaled(count: 64, detailed: false), 0.06),
        ]
        var runs: [Run] = []
        for round in 0..<rounds {
            for (name, scene, duration) in scenes {
                let order = round.isMultiple(of: 2) ? [false, true] : [true, false]
                for histories in order {
                    let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx)
                    try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                    let before = solver.memoryFootprint
                    if histories {
                        try solver.configureEnvelopeComponents(
                            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration)
                        )
                    }
                    let start = ContinuousClock.now
                    let result = solver.advance(until: duration)
                    let took = start.duration(to: .now)
                    let seconds =
                        Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
                    let run = Run(
                        scene: name, histories: histories, round: round, wallS: seconds, steps: result.steps,
                        solverBytes: solver.memoryFootprint,
                        components: solver.envelopeComponents()?.count ?? 0,
                        historyBytes: solver.memoryFootprint - before)
                    runs.append(run)
                    print(
                        "\(name) round \(round + 1) \(histories ? "with" : "without") histories: "
                            + String(format: "%.3f s, %d steps", seconds, result.steps)
                            + (histories ? ", \(run.components) components, \(run.historyBytes) bytes" : ""))
                }
            }
        }
        for (name, _, _) in scenes {
            let without = runs.filter { $0.scene == name && !$0.histories }.map(\.wallS).sorted()
            let with = runs.filter { $0.scene == name && $0.histories }.map(\.wallS).sorted()
            let ratios = (0..<rounds).compactMap { round -> Double? in
                guard let a = runs.first(where: { $0.scene == name && $0.round == round && !$0.histories }),
                    let b = runs.first(where: { $0.scene == name && $0.round == round && $0.histories })
                else { return nil }
                return b.wallS / a.wallS
            }.sorted()
            let memory = runs.first { $0.scene == name && $0.histories }
            print(
                "\(name): median \(String(format: "%.3f", without[without.count / 2])) s without, "
                    + "\(String(format: "%.3f", with[with.count / 2])) s with; median pair ratio "
                    + String(format: "%.3f", ratios[ratios.count / 2])
                    + " (\(ratios.map { String(format: "%.3f", $0) }.joined(separator: ", "))); "
                    + "\(memory?.components ?? 0) components, \(memory?.historyBytes ?? 0) bytes")
        }
        // The GPU's own seconds, by stage, summed over every batch: the histories' kernel is part
        // of the observation stage.
        for (name, scene, duration) in scenes {
            var line = "\(name) GPU stages:"
            for histories in [false, true] {
                let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx)
                try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                if histories {
                    try solver.configureEnvelopeComponents(
                        objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
                }
                try solver.enableGPUProfiling(true)
                var total = BatchGPUProfile()
                while duration - solver.time > 1e-7 {
                    let result = solver.advance(steps: 64, timeLimit: duration)
                    if let profile = solver.lastBatchGPUProfile {
                        total.airS += profile.airS
                        total.observationS += profile.observationS
                    }
                    if result.steps == 0 { break }
                }
                line += String(
                    format: " %@ air %.3f s, observation %.4f s;", histories ? "with" : "without", total.airS,
                    total.observationS)
            }
            print(line)
        }
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(runs).write(to: URL(filePath: out))
        }
    }
}
