import BlastCore
import Foundation
import Metal
import simd

/// `scenebench district <district-scene's inputs> [--radii 250,500,1000] [--steps 40] [--window 5]
/// [--from-arrival] [--budget MB] [--until seconds] [--staircase] [--bare] [--out file.json]`: what a district of map buildings costs
/// as it grows. For each radius, `district-scene`'s square scene of twice it about the centre; the time to place the buildings, build the
/// solver, configure the surface recorder and the components' histories, the memory each takes,
/// and the time a step takes with the surface recorder alone and with the histories too. With
/// `--until`, the whole event to that time is run once more with both recorders, and timed.
enum DistrictBenchmark {
    struct Row: Codable {
        var radiusM: Float
        var cellSizeM: Float
        var cells: Int
        var buildings: Int
        var boxes: Int
        var placeS: Double
        var solverS: Double
        var exposureS: Double
        var faces: Int
        var componentsS: Double
        var components: Int
        var solverBytes: Int
        var exposureBytes: Int
        var historyBytes: Int
        var stepS: Double
        var stepWithHistoriesS: Double
        var eventS: Double?
        var eventWithHistoriesS: Double?
        var eventSteps: Int?
        var eventTimeS: Double?
        var binS: Double?
    }

    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let took = start.duration(to: .now)
        return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func numbers(_ name: String, _ fallback: [Double]) -> [Double] {
            value(name).map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("a Metal device")
        }
        let inputs = try DistrictInputs.read(args)
        let dx = inputs.cellSize
        let steps = value("steps").flatMap(Int.init) ?? 40
        let options = EnvelopeHistoryOptions(
            windowS: value("window").flatMap(Double.init) ?? 5,
            memoryBudget: (value("budget").flatMap(Int.init) ?? 256) << 20,
            windowFromArrival: args.contains("--from-arrival"))
        let until = value("until").flatMap(Double.init)
        var rows: [Row] = []
        for radius in numbers("radii", [250, 500, 1000]).map(Float.init) {
            var clock = ContinuousClock.now
            let (scene, report) = try inputs.scene(radius: radius)
            let place = seconds(clock)
            let boxes = scene.envelopeObjects.reduce(0) { $0 + $1.envelope!.blocks.count }
            print(
                "r \(Int(radius)) m: \(report.placed.count) buildings, \(boxes) boxes, placed in "
                    + String(format: "%.2f s", place))
            var row = Row(
                radiusM: radius, cellSizeM: dx, cells: 0, buildings: report.placed.count, boxes: boxes,
                placeS: place,
                solverS: 0, exposureS: 0, faces: 0, componentsS: 0, components: 0, solverBytes: 0,
                exposureBytes: 0,
                historyBytes: 0, stepS: 0, stepWithHistoriesS: 0)
            for histories in [false, true] {
                clock = .now
                // The mapped start since its rerun on 20 October 2026; `--balloon-start` for the balloon it was first run on.
                var configuration =
                    args.contains("--bare")
                    ? SolverConfiguration()
                    : args.contains("--balloon-start") ? .recommended.balloonStart : .recommended
                configuration.terrainCutCells = !args.contains("--staircase")
                let solver = try BlastSolver(
                    device: device, scenario: scene, cellSize: dx, configuration: configuration)
                if !histories {
                    row.solverS = seconds(clock)
                    row.cells = solver.grid.cellCount
                    row.solverBytes = solver.memoryFootprint
                }
                clock = .now
                try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                if !histories {
                    row.exposureS = seconds(clock)
                    row.exposureBytes = solver.memoryFootprint - row.solverBytes
                    row.faces = solver.envelopeExposureSnapshot()?.reduce(0) { $0 + $1.surfaces.count } ?? 0
                }
                if histories {
                    let before = solver.memoryFootprint
                    clock = .now
                    try solver.configureEnvelopeComponents(
                        objects: scene.envelopeObjects, options: options)
                    row.componentsS = seconds(clock)
                    row.components = solver.envelopeComponents()?.count ?? 0
                    row.historyBytes = solver.memoryFootprint - before
                }
                // A few steps to warm up, then the timed ones.
                _ = solver.advance(steps: 4)
                clock = .now
                _ = solver.advance(steps: steps)
                let perStep = seconds(clock) / Double(steps)
                if histories { row.stepWithHistoriesS = perStep } else { row.stepS = perStep }
                if let until {
                    clock = .now
                    var taken = 0
                    while solver.time < until {
                        let batch = solver.advance(until: until)
                        taken += batch.steps
                        guard batch.steps > 0, batch.isStable else { break }
                    }
                    let took = seconds(clock)
                    if !histories {
                        row.eventS = took
                        print(
                            String(format: "  event to %.3f s: %d steps in %.1f s", solver.time, taken, took))
                        continue
                    }
                    row.eventWithHistoriesS = took
                    row.eventSteps = taken
                    row.eventTimeS = solver.time
                    let recorded = solver.envelopeComponentHistories() ?? []
                    row.binS = recorded.first?.binS
                    print(
                        String(
                            format:
                                "  with histories: %d steps in %.1f s; bins %.2f ms; %d of %d components loaded, %d truncated",
                            taken, took, (row.binS ?? 0) * 1000,
                            recorded.filter { $0.peakOuterPa > 1000 || $0.peakInnerPa > 1000 }.count,
                            recorded.count, recorded.filter(\.truncated).count))
                }
            }
            print(
                String(
                    format:
                        "  %d cells, solver %.1f s, surfaces %.1f s (%d faces), components %.1f s (%d), memory %.0f / %.1f / %.1f MB, step %.1f / %.1f ms",
                    row.cells, row.solverS, row.exposureS, row.faces, row.componentsS, row.components,
                    Double(row.solverBytes) / 1e6, Double(row.exposureBytes) / 1e6,
                    Double(row.historyBytes) / 1e6,
                    row.stepS * 1000, row.stepWithHistoriesS * 1000))
            rows.append(row)
            if let out = value("out") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(filePath: out))
            }
        }
    }
}
