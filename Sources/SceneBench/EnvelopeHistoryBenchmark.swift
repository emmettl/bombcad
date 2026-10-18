import BlastCore
import Foundation
import Metal

/// `SceneBench envelope-histories [--dx 0.25] [--rounds 5] [--out file.json]`: what recording each
/// envelope component's pressure history costs. The street's four buildings (120 ms) and the
/// 64-building neighbourhood (60 ms), each run with the surface recorder alone, as every
/// envelope-only run is, and with the histories too, in alternating order, `rounds` times; and the
/// surface recorder as it was before it skipped still air (`before`), to show what that saved; and
/// the histories with their components' governing bands (`bands`) against without (`histories`).
enum EnvelopeHistoryBenchmark {
    struct Run: Codable {
        var scene: String
        /// "before" (the surface recorder reading every face), "surfaces", "histories" (without
        /// bands) or "bands".
        var variant: String
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
                let variants = ["before", "surfaces", "histories", "bands"]
                let order = round.isMultiple(of: 2) ? variants : variants.reversed()
                for variant in order {
                    let histories = variant == "histories" || variant == "bands"
                    let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx)
                    try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                    let before = solver.memoryFootprint
                    if histories {
                        try solver.configureEnvelopeComponents(
                            objects: scene.envelopeObjects,
                            options: EnvelopeHistoryOptions(
                                windowS: duration, governingBands: variant == "bands"))
                    }
                    solver.envelopeStillTileSkipping = variant != "before"
                    let start = ContinuousClock.now
                    let result = solver.advance(until: duration)
                    let took = start.duration(to: .now)
                    let seconds =
                        Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
                    let run = Run(
                        scene: name, variant: variant, histories: histories, round: round, wallS: seconds,
                        steps: result.steps, solverBytes: solver.memoryFootprint,
                        components: solver.envelopeComponents()?.count ?? 0,
                        historyBytes: solver.memoryFootprint - before)
                    runs.append(run)
                    print(
                        "\(name) round \(round + 1) \(variant): "
                            + String(format: "%.3f s, %d steps", seconds, result.steps)
                            + (histories ? ", \(run.components) components, \(run.historyBytes) bytes" : ""))
                }
            }
        }
        for (name, _, _) in scenes {
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            func wall(_ variant: String) -> Double {
                median(runs.filter { $0.scene == name && $0.variant == variant }.map(\.wallS))
            }
            /// The median, over rounds, of `variant`'s time over `base`'s in the same round.
            func ratio(_ variant: String, _ base: String) -> (Double, [Double]) {
                let ratios = (0..<rounds).compactMap { round -> Double? in
                    guard
                        let a = runs.first(where: {
                            $0.scene == name && $0.round == round && $0.variant == base
                        }),
                        let b = runs.first(where: {
                            $0.scene == name && $0.round == round && $0.variant == variant
                        })
                    else { return nil }
                    return b.wallS / a.wallS
                }.sorted()
                return (ratios[ratios.count / 2], ratios)
            }
            let memory = runs.first { $0.scene == name && $0.variant == "histories" }
            let banded = runs.first { $0.scene == name && $0.variant == "bands" }
            let bands = ratio("bands", "histories")
            let skip = ratio("surfaces", "before")
            let histories = ratio("histories", "surfaces")
            let both = ratio("histories", "before")
            print(
                "\(name): median "
                    + String(
                        format: "%.3f / %.3f / %.3f s", wall("before"), wall("surfaces"), wall("histories"))
                    + " before / surfaces / with histories; surfaces over before "
                    + String(
                        format: "%.3f (%@)", skip.0,
                        skip.1.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                    + "; histories over surfaces "
                    + String(
                        format: "%.3f (%@)", histories.0,
                        histories.1.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                    + String(format: "; histories over before %.3f", both.0)
                    + "; \(memory?.components ?? 0) components, \(memory?.historyBytes ?? 0) bytes"
                    + String(
                        format: "; bands over histories %.3f (%@), %d bytes with them", bands.0,
                        bands.1.map { String(format: "%.3f", $0) }.joined(separator: ", "),
                        banded?.historyBytes ?? 0))
        }
        // The GPU's own seconds, by stage, summed over every batch, `rounds` times in alternating
        // order: the histories' kernel is part of the observation stage.
        for (name, scene, duration) in scenes {
            var stages: [Bool: [(air: Double, observation: Double)]] = [:]
            for round in 0..<rounds {
                for histories in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                    let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx)
                    try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                    if histories {
                        try solver.configureEnvelopeComponents(
                            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration)
                        )
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
                    stages[histories, default: []].append((total.airS, total.observationS))
                }
            }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            let without = stages[false] ?? []
            let with = stages[true] ?? []
            print(
                String(
                    format:
                        "%@ GPU stages, medians of %d: air %.3f / %.3f s, observation %.4f / %.4f s without / with",
                    name, rounds, median(without.map(\.air)), median(with.map(\.air)),
                    median(without.map(\.observation)), median(with.map(\.observation))))
        }
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(runs).write(to: URL(filePath: out))
        }
    }
}
