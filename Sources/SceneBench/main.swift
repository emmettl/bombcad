import BlastCore
import Foundation
import Metal

struct Observation: Codable {
    var bodies: Int
    var spacingM: Float
    var refinement: Int
    var layout: String
    var coupling: CouplingStatistics
    var solverBytes: Int
    var couplingGPUMedianS: Double
    var batchGPUS: Double
    var steps: Int
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
        guard let output = args.first else {
            print("Usage: scenebench <output.json> [--quick]")
            return
        }
        let quick = args.contains("--quick")
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        var observations: [Observation] = []
        for count in [2, 4, 8, 16] {
            for spacing: Float in quick ? [24] : [12, 28] {
                let scene = try fixture(count: count, spacing: spacing)
                for refinement in quick ? [1] : [1, 2] {
                    var configuration = SolverConfiguration()
                    configuration.refinement = refinement
                    configuration.refinementMemory = 16 << 20
                    configuration.airSleepThreshold = 0
                    configuration.airSleepCrossings = 0
                    let solver = try BlastSolver(
                        device: device, scenario: scene, cellSize: 0.5, configuration: configuration)
                    _ = try solver.measureCouplingGPU(repetitions: 2)
                    var times: [Double] = []
                    for _ in 0..<5 { times.append(try solver.measureCouplingGPU(repetitions: 8)) }
                    let command = solver.encodeBatch(steps: 8, updateVisualization: false)!
                    command.commit()
                    command.waitUntilCompleted()
                    let result = solver.completeBatch()
                    let observation = Observation(
                        bodies: count, spacingM: spacing, refinement: refinement,
                        layout: solver.couplingStatistics.layout,
                        coupling: solver.couplingStatistics, solverBytes: solver.memoryFootprint,
                        couplingGPUMedianS: times.sorted()[2],
                        batchGPUS: command.gpuEndTime - command.gpuStartTime,
                        steps: result.steps,
                        stable: result.isStable && !result.unsupportedInteraction && command.error == nil)
                    observations.append(observation)
                    print(
                        "\(count) bodies, \(spacing) m, refine \(refinement): \(observation.coupling.bytes) boundary bytes, \(observation.couplingGPUMedianS * 1000) ms GPU"
                    )
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Codable {
            var device: String
            var system: String
            var observations: [Observation]
        }
        try encoder.encode(
            Report(
                device: device.name, system: ProcessInfo.processInfo.operatingSystemVersionString,
                observations: observations)
        )
        .write(to: URL(filePath: output))
    }
}
