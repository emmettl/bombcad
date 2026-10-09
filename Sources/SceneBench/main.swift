import BlastCore
import BlastRender
import Foundation
import ImageIO
import Metal

struct Observation: Codable {
    var bodies: Int
    var spacingM: Float
    var refinement: Int
    var layout: String
    var coupling: CouplingStatistics
    var solverBytes: Int
    var couplingGPUMedianS: Double
    var couplingGPUSamplesS: [Double]
    var batchGPUS: Double
    var steps: Int
    var refinedPatches: Int
    var sweptFraction: Double
    var maxRelativePressureError: Float
    var stable: Bool
}

func fixture(count: Int, spacing: Float) throws -> Scenario {
    let side = Int(ceil(sqrt(Double(count))))
    let extent = Float(side - 1) * spacing + 16
    var scene = Scenario(
        name: "Scaling \(count) bodies at \(spacing) m", domainSize: SIMD3(extent, extent, 8), boxes: [],
        charge: Charge(mass: 0.02, position: SIMD3(3, 3, 1)),
        gauges: [Gauge("Near", at: SIMD3(4, 3, 1))])
    for index in 0..<count {
        let x = 8 + Float(index % side) * spacing
        let y = 8 + Float(index / side) * spacing
        let box = Box(min: SIMD3(x, y, 0), max: SIMD3(x + 0.5, y + 2, 3))
        var body = StructureModel(
            solids: [box], material: .plainConcrete,
            elementSize: index.isMultiple(of: 2) ? 0.25 : 0.5, fixedBase: true)
        if index % 3 == 1 { body.elementKind = .shell }
        if index % 3 == 2 {
            body.solids.append(Box(min: SIMD3(x, y + 2, 2.5), max: SIMD3(x + 2, y + 2.5, 3)))
            body.solidElementKind = [nil, .shell]
        }
        body.supports = [Box(min: body.bounds.min - 0.01, max: body.bounds.max + 0.01)]
        try scene.addStructureObject(body, name: "Body \(index + 1)")
    }
    return scene
}

@main
enum SceneBench {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "envelopes" {
            try EnvelopeBenchmark.run(Array(args.dropFirst()))
            return
        }
        if args.first == "street" {
            try StreetBenchmark.run(Array(args.dropFirst()))
            return
        }
        if args.first == "--example", args.count == 2 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(NeighborhoodExample.make()).write(to: URL(filePath: args[1]))
            return
        }
        if args.first == "--preview", args.count == 2 {
            let scene = try NeighborhoodExample.make()
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
            else { throw BlastError.allocationFailed("preview Metal device") }
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
            let renderer = try SceneRenderer(device: device)
            renderer.setScene(scene, solver: solver)
            guard
                let frame = renderer.snapshot(
                    commandQueue: queue, width: 1280, height: 900, camera: .framing(scene)),
                let destination = CGImageDestinationCreateWithURL(
                    URL(filePath: args[1]) as CFURL, "public.png" as CFString, 1, nil)
            else { throw BlastError.allocationFailed("neighborhood preview") }
            CGImageDestinationAddImage(destination, frame.image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw BlastError.allocationFailed("PNG output")
            }
            return
        }
        guard let output = args.first else {
            print(
                "Usage: scenebench <output.json> [--quick] [--layouts=dense,tiled,automatic]\n       scenebench --example <layout.json>\n       scenebench street <directory> [--quick] [--source-revision=<sha>]\n       scenebench envelopes <directory> [--quick] [--source-revision=<sha>]"
            )
            return
        }
        let quick = args.contains("--quick")
        let requested = args.first { $0.hasPrefix("--layouts=") }?.dropFirst(10) ?? "dense,tiled,automatic"
        let layouts = requested.split(separator: ",").compactMap { BodyCouplingLayout(rawValue: String($0)) }
        guard !layouts.isEmpty, layouts.count == requested.split(separator: ",").count else {
            throw BlastError.allocationFailed("valid benchmark layouts")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        var observations: [Observation] = []
        for count in [2, 4, 8, 16] {
            for spacing: Float in quick ? [24] : [12, 28] {
                let scene = try fixture(count: count, spacing: spacing)
                for refinement in quick ? [1] : [1, 2] {
                    let solvers = try layouts.map { layout in
                        var configuration = SolverConfiguration()
                        configuration.bodyCouplingLayout = layout
                        configuration.refinement = refinement
                        configuration.refinementMemory = 16 << 20
                        configuration.airSleepThreshold = 0
                        configuration.airSleepCrossings = 0
                        return try BlastSolver(
                            device: device, scenario: scene, cellSize: 0.5, configuration: configuration)
                    }
                    for solver in solvers { _ = try solver.measureCouplingGPU(repetitions: 2) }
                    var samples = Array(repeating: [Double](), count: solvers.count)
                    // Keep the competing layouts live and interleave measurements so order,
                    // thermal drift and background GPU work do not favor a whole case.
                    for round in 0..<5 {
                        for offset in solvers.indices {
                            let index = (round + offset) % solvers.count
                            samples[index].append(try solvers[index].measureCouplingGPU(repetitions: 8))
                        }
                    }
                    var reference: [CellState]?
                    for (index, solver) in solvers.enumerated() {
                        let layout = layouts[index]
                        let times = samples[index]
                        let command = solver.encodeBatch(steps: 8, updateVisualization: false)!
                        command.commit()
                        command.waitUntilCompleted()
                        let result = solver.completeBatch()
                        let states = solver.withState { Array($0) }
                        var pressureError: Float = 0
                        if let reference {
                            for (a, b) in zip(reference, states) {
                                let p = a.primitive(gamma: solver.configuration.gamma).pressure
                                let q = b.primitive(gamma: solver.configuration.gamma).pressure
                                pressureError = max(pressureError, abs(p - q) / max(abs(p), 1))
                            }
                        } else {
                            reference = states
                        }
                        let observation = Observation(
                            bodies: count, spacingM: spacing, refinement: refinement,
                            layout: layout.rawValue,
                            coupling: solver.couplingStatistics, solverBytes: solver.memoryFootprint,
                            couplingGPUMedianS: times.sorted()[2], couplingGPUSamplesS: times,
                            batchGPUS: command.gpuEndTime - command.gpuStartTime,
                            steps: result.steps, refinedPatches: result.refinedTiles,
                            sweptFraction: result.sweptFraction, maxRelativePressureError: pressureError,
                            stable: result.isStable && !result.unsupportedInteraction
                                && !result.couplingCapacityExceeded && command.error == nil
                                && pressureError < 1e-5)
                        observations.append(observation)
                        print(
                            "\(count) bodies, \(spacing) m, refine \(refinement), \(layout.rawValue): \(observation.coupling.bytes) boundary bytes, \(observation.couplingGPUMedianS * 1000) ms GPU"
                        )
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Codable {
            var schemaVersion = 1
            var sourceRevision: String
            var device: String
            var system: String
            var cellSizeM: Float = 0.5
            var timingOrder = "interleaved layouts, rotated each round"
            var timingSamples = 5
            var repetitionsPerTimingSample = 8
            var observations: [Observation]
        }
        try encoder.encode(
            Report(
                sourceRevision: args.first { $0.hasPrefix("--source-revision=") }.map {
                    String($0.dropFirst(18))
                } ?? "working-tree",
                device: device.name, system: ProcessInfo.processInfo.operatingSystemVersionString,
                observations: observations)
        )
        .write(to: URL(filePath: output))
    }
}
