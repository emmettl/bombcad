import BlastCore
import Foundation
import Metal

/// `SceneBench venting-checks [--case office|street] [--dx 0.25] [--duration 0.12]`: envelope damage as
/// the app judges it, with the glazing vented (the default) and with the one-way fill, on the
/// office tower preset's two glazed neighbours (beside the detailed tower) and on the damage
/// references' glazed street, uniform and with the shocks sharpened (refined once by 2). Each
/// building's panes broken, the first, its inside, and the run's wall time.
enum VentingChecks {
    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let which = value("case") ?? "street"
        let dx = value("dx").flatMap(Float.init) ?? 0.25
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        var scene: Scenario
        var duration: Double
        var runs: [(name: String, vented: Bool, refined: Bool)]
        switch which {
        case "office":
            scene = ScenarioPreset.officeTower.scenario
            duration = value("duration").flatMap(Double.init) ?? 0.12
            runs = [("fill", false, false), ("vented", true, false)]
        default:
            scene = try EnvelopeDamageBenchmark.scene(layout: .street, wall: .glass, charge: 50)
            for object in scene.structuralObjects { try scene.useEnvelope(id: object.id) }
            duration = value("duration").flatMap(Double.init) ?? 0.12
            runs = [
                ("fill", false, false), ("vented", true, false), ("fill, refined", false, true),
                ("vented, refined", true, true),
            ]
        }
        for (name, vented, refined) in runs {
            var config = SolverConfiguration.recommended
            if refined {
                config.refinement = 2
                config.refinementLevels = 1
            }
            let start = ContinuousClock.now
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx, configuration: config)
            solver.settleStructures()
            try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
            if vented {
                try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) {
                    scene.envelopeConstruction(for: $0)
                }
            }
            while duration - solver.time > 1e-7 {
                if solver.advance(steps: 64, timeLimit: duration).steps == 0 { break }
            }
            let took = start.duration(to: .now)
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            let snapshot = solver.envelopeVentingSnapshot()
            let histories = solver.envelopeComponentHistories() ?? []
            let loads = histories.filter { !$0.invalid || snapshot?.keeps($0) == true }
                .map(EnvelopeComponentLoad.init)
            let rooms = Dictionary(
                uniqueKeysWithValues: scene.envelopeObjects.map {
                    ($0.id, EnvelopeDamageAssessment.roomVolume(of: $0.envelope!))
                })
            let damage = EnvelopeDamageAssessment.assess(
                loads: loads, constructions: { scene.envelopeConstruction(for: $0) }, rooms: rooms,
                vented: snapshot)
            print(String(format: "%@ (%.0f s, %d steps):", name, seconds, solver.stepCount))
            for building in damage {
                let label = scene.object(id: building.id)?.name ?? "Building"
                print(
                    String(
                        format:
                            "  %@: %d of %d panes broken, first at %.1f ms; inside %.2f kPa, %.0f Pa s%@; walls %@",
                        label, building.panesBroken, building.panes,
                        (building.firstPaneBrokenAtS ?? .nan) * 1000,
                        building.insidePeakPa / 1000, building.insideImpulsePaS,
                        building.vented == true ? " (the air's)" : " (fill)",
                        building.structuralLevels.upperBound.label))
            }
        }
    }
}
