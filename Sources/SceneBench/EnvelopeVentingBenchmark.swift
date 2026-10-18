import BlastCore
import Foundation
import Metal

/// `SceneBench envelope-venting [--dx 0.25] [--rounds 5] [--charge 50]`: what letting envelopes'
/// glazing break in the air costs (`BlastSolver.configureEnvelopeVenting`). The damage references'
/// street of four glazed buildings (120 ms) and 64 buildings with every opening glazed (60 ms), each
/// run with the component histories alone and with venting too, in alternating order, `rounds`
/// times: wall time, and the GPU's air and observation stages.
enum EnvelopeVentingBenchmark {
    /// 64 of the damage references' glazed buildings (a pane in each wall) on a 10 m grid.
    static func glazedNeighbourhood(count: Int, charge: Float) throws -> Scenario {
        let side = Int(ceil(sqrt(Double(count))))
        let extent = Float(side * 10 + 16)
        var scene = Scenario(
            name: "Glazed \(count) buildings", domainSize: SIMD3(extent, extent, 8), boxes: [],
            charge: Charge(mass: charge, position: SIMD3(4, 4, 1)),
            gauges: [Gauge("Near", at: SIMD3(7, 4, 1.5))])
        for index in 0..<count {
            let model = EnvelopeDamageBenchmark.building(
                x: 10 + Float(index % side) * 10 - 2, y: 10 + Float(index / side) * 10 - 2, wall: .glass)
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8200-%012d", index + 1))!
            try scene.addEnvelopeObject(
                BuildingEnvelope(structure: model), name: "Building \(index + 1)", id: id)
        }
        return scene
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let dx = value("dx").flatMap(Float.init) ?? 0.25
        let rounds = value("rounds").flatMap(Int.init) ?? 5
        let charge = value("charge").flatMap(Float.init) ?? 50
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        var street = try EnvelopeDamageBenchmark.scene(layout: .street, wall: .glass, charge: charge)
        for object in street.structuralObjects { try street.useEnvelope(id: object.id) }
        let scenes = [
            ("street", street, 0.12),
            ("neighbourhood", try glazedNeighbourhood(count: 64, charge: charge), 0.06),
        ]
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        for (name, scene, duration) in scenes {
            var wall: [Bool: [Double]] = [:]
            var stages: [Bool: [(air: Double, observation: Double)]] = [:]
            var broken = 0
            var panes = 0
            for round in 0..<rounds {
                for vented in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                    // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
                    var config = SolverConfiguration.recommended.balloonStart
                    config.airSleepThreshold = 0
                    let solver = try BlastSolver(
                        device: device, scenario: scene, cellSize: dx, configuration: config)
                    try solver.configureEnvelopeComponents(
                        objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
                    if vented {
                        try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) {
                            EnvelopeConstruction.assumed(objectID: $0)
                        }
                    }
                    try solver.enableGPUProfiling(true)
                    var total = BatchGPUProfile()
                    let start = ContinuousClock.now
                    while duration - solver.time > 1e-7 {
                        let result = solver.advance(steps: 64, timeLimit: duration)
                        if let profile = solver.lastBatchGPUProfile {
                            total.airS += profile.airS
                            total.observationS += profile.observationS
                        }
                        if result.steps == 0 { break }
                    }
                    let took = start.duration(to: .now)
                    wall[vented, default: []].append(
                        Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18)
                    stages[vented, default: []].append((total.airS, total.observationS))
                    if vented, let snapshot = solver.envelopeVentingSnapshot() {
                        panes = snapshot.panes.count
                        broken = snapshot.panes.filter { $0.brokenAtS != nil }.count
                    }
                }
            }
            let ratios = zip(wall[true] ?? [], wall[false] ?? []).map { $0 / $1 }
            print(
                String(
                    format:
                        "%@: wall %.3f / %.3f s without / with venting, ratio %.3f (%@); GPU air %.3f / %.3f s, observation %.4f / %.4f s; %d of %d panes broken",
                    name, median(wall[false] ?? []), median(wall[true] ?? []), median(ratios),
                    ratios.map { String(format: "%.3f", $0) }.joined(separator: ", "),
                    median((stages[false] ?? []).map(\.air)), median((stages[true] ?? []).map(\.air)),
                    median((stages[false] ?? []).map(\.observation)),
                    median((stages[true] ?? []).map(\.observation)),
                    broken, panes))
        }
    }
}
