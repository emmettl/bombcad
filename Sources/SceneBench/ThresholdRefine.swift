import BlastCore
import BlastModel
import Foundation
import Metal
import simd

/// `scenebench threshold-refine <district-scene's inputs> [--radius 1000] [--move dx,dy]
/// [--within 1.5] [--buildings 8] [--max-cells 40000000] [--budget 300] [--no-refine] [--terms clear-top|fitted]`: the
/// quick estimate with the charge moved by `--move` (where a drag let it go), its close calls
/// refined by the solver as the app refines them (`ThresholdRefinement`, emmettl/bombcad-work#34),
/// and the time to each refined answer; each building's estimate beside its refined result.
enum ThresholdRefine {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("a Metal device")
        }
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1000)
        var (scene, report) = try inputs.scene(radius: radius)
        print(report.summary)
        let dx = inputs.cellSize
        let move = (value("move") ?? "0,0").split(separator: ",").compactMap { Float($0) }
        if move.count == 2 {
            scene.charge.position.x += move[0]
            scene.charge.position.y += move[1]
        }
        let mass = Double(scene.charge.mass)
        let within = value("within").flatMap(Double.init) ?? 1.5
        let constructions = { (id: UUID) in scene.envelopeConstruction(for: id) }

        // The quick estimate, as the app's full look makes it when a drag is let go.
        var clock = ContinuousClock.now
        var layout = scene
        layout.charge.position = .zero
        let prepared = FacadeLoadSurrogate.Prepared(scene: layout, cellSize: dx)
        // `--terms clear-top|fitted`: the façade terms and scatter (the adopted ones without it).
        let terms = try SurrogateBench.termSet(args)
        let look = prepared.look(
            charge: scene.charge.position, mass: mass, constructions: constructions,
            uncertainty: FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(within) / 1.645, loadScatter: terms.loadScatter, samples: 100),
            terms: terms)
        print(
            String(
                format: "Quick estimate of %d buildings in %.1f s (prepared and looked)",
                scene.envelopeObjects.count, DistrictBenchmark.seconds(clock)))

        // The close calls and the near scene round them.
        clock = .now
        // `--quantity blownOut` and so on: the doubt of one of the view's chances, not the damage's.
        let quantities: Set<ThresholdRefinement.Quantity> =
            value("quantity").flatMap { name in
                ThresholdRefinement.Quantity.allCases.first { "\($0)" == name }.map { [$0] }
            } ?? ThresholdRefinement.Quantity.damage
        let doubts = ThresholdRefinement.doubts(
            glass: look.glass, structure: look.structure, quantities: quantities)
        let calls = doubts.values.filter { $0 >= ThresholdRefinement.closeCall }.count
        let plan = try ThresholdRefinement.plan(
            scene: scene, cellSize: dx, doubts: doubts,
            maxBuildings: value("buildings").flatMap(Int.init) ?? 8,
            maxCells: value("max-cells").flatMap(Int.init) ?? 40_000_000)
        let size = plan.scene.domainSize
        print(
            String(
                format:
                    "%d close calls of %d buildings; refining the nearest %d on a near scene %.0f × %.0f m (%d buildings, %.1f million cells), to %.3f s, planned in %.2f s",
                calls, doubts.count, plan.buildings.count, size.x, size.y, plan.scene.envelopeObjects.count,
                Double(plan.cells) / 1e6, plan.untilS, DistrictBenchmark.seconds(clock)))

        var configuration = SolverConfiguration.recommended
        if !args.contains("--no-refine") {
            configuration.refinement = 2
            configuration.refinementMemory = 8 << 30
        }
        let refinement = ThresholdRefinementRun(
            plan: plan, budgetS: value("budget").flatMap(Double.init) ?? 300)
        // A line every ten seconds, and one each time buildings are judged.
        final class Printed: @unchecked Sendable {
            let lock = NSLock()
            var wallS = -1.0
            var refined = 0
        }
        let printed = Printed()
        let count = plan.buildings.count
        let (ending, final) = refinement.run(device: device, cellSize: dx, configuration: configuration) {
            progress in
            printed.lock.lock()
            defer { printed.lock.unlock() }
            guard progress.wallS - printed.wallS >= 10 || progress.refined.buildings.count > printed.refined
            else { return }
            printed.wallS = progress.wallS
            printed.refined = progress.refined.buildings.count
            print(
                String(
                    format: "  %.1f s: %.3f of %.3f s simulated, %d of %d buildings refined", progress.wallS,
                    progress.simulatedS, progress.untilS, progress.refined.buildings.count, count))
        }
        print(
            String(
                format: "Ended %@ after %.0f s: %d of %d buildings refined", "\(ending)", final.wallS,
                final.refined.buildings.count, plan.buildings.count))

        // Each building: when its answer came, and the estimate's chances beside the run's.
        let objects = Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, $0) })
        let charge = SIMD2(scene.charge.position.x, scene.charge.position.y)
        func worst(
            _ sides: [FacadeLoadSurrogate.SideGlass], _ chance: (FacadeLoadSurrogate.SideGlass) -> Double
        )
            -> Double
        {
            sides.map(chance).max() ?? 0
        }
        var settled = 0
        for id in plan.buildings {
            let box = objects[id]?.bounds
            let distance =
                box.map { simd_distance(SIMD2($0.min.x + $0.max.x, $0.min.y + $0.max.y) / 2, charge) } ?? 0
            let estimateGlass = look.glass.filter { $0.owner == id }
            let estimateWalls = look.structure.first { $0.owner == id }
            var line = String(
                format:
                    "  %@ at %4.0f m, doubt %.2f; estimate: glass some %.2f, blown %.2f, walls %.2f, roof %.2f",
                String((objects[id]?.name ?? "?").prefix(20)), distance, doubts[id] ?? 0,
                worst(estimateGlass, \.someBroken), worst(estimateGlass, \.blownOut),
                estimateWalls?.wallsModerate ?? 0, estimateWalls?.roofModerate ?? 0)
            if let at = final.readyWallS[id] {
                let glass = final.refined.glass.filter { $0.owner == id }
                let walls = final.refined.structure.first { $0.owner == id }
                let after =
                    ThresholdRefinement.doubts(
                        glass: glass, structure: walls.map { [$0] } ?? [], quantities: quantities)[id] ?? 0
                if after < ThresholdRefinement.closeCall { settled += 1 }
                let level = final.refined.damage.first { $0.id == id }?.structuralLevels.upperBound
                line += String(
                    format:
                        "; refined at %.0f s: glass some %.2f, blown %.2f, walls %.2f, roof %.2f, damage %@, doubt %.2f",
                    at, worst(glass, \.someBroken), worst(glass, \.blownOut), walls?.wallsModerate ?? 0,
                    walls?.roofModerate ?? 0, level.map { "\($0)" } ?? "none", after)
            } else {
                line += "; not refined"
            }
            print(line)
        }
        print(
            "\(settled) of \(final.refined.buildings.count) refined buildings settled (no chance left between 0.2 and 0.8)"
        )
    }
}
