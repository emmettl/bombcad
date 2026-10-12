import BlastCore
import Foundation
import Metal

// blastbench buildings [--dx 0.5] [--duration 0.12] [--mass 50] [--out f.json]
// blastbench buildings --terraced [--dx 0.25] [--duration 0.05] [--mass 20] [--out f.json]
//
// The "Three buildings across a street" layout, each building its own structure, run with all
// three together and with each alone on the same air grid: how much the far building's
// reflections load the near one, how much the far one shelters the one behind it, and what
// several structures cost against one.
//
// `--terraced`: two buildings 0.1 m apart, a charge inside the first; its party wall bulges into
// the second. Run together, in contact; with the second taken away; and with contact between
// bodies switched off, which stops the run when they come close.

struct BuildingsRun: Codable {
    struct Building: Codable {
        let name: String
        let elements: Int
        /// Largest and final displacement of any node (mm), elements broken.
        let peakDisplacement: Double
        let finalDisplacement: Double
        let erodedElements: Int
        let maxDamage: Double
    }

    struct Gauge: Codable {
        let name: String
        /// Peak overpressure (kPa) and positive impulse (kPa ms).
        let peak: Double
        let impulse: Double
    }

    let variant: String
    let buildings: [Building]
    let gauges: [Gauge]
    let time: Double
    let steps: Int
    let cells: Int
    let wallSeconds: Double
    /// When the structures came within reach of each other and met through contact (s).
    let contactFrom: Double?
    let failure: String?
}

func runBuildings() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw BlastError.missingShader("no Metal device")
    }
    let terraced = flag("terraced")
    let cellSize = option("dx").flatMap(Float.init) ?? (terraced ? 0.25 : 0.5)
    let duration = option("duration").flatMap(Double.init) ?? (terraced ? 0.05 : 0.12)
    var layout = terraced ? terracedLayout() : ScenarioPreset.buildingsAcrossStreet.scenario
    if let mass = option("mass").flatMap(Float.init) { layout.charge.mass = mass }
    let names = layout.structuralObjects.map(\.name)
    let variants: [(String, [String], Bool)] =
        terraced
        ? [
            ("together", names, true), ("\(names[0]) alone", [names[0]], true),
            ("without contact", names, false),
        ]
        : [("together", names, true)] + names.map { ("\($0) alone", [$0], true) }
    var runs: [BuildingsRun] = []
    for (variant, kept, contact) in variants {
        var scenario = layout
        for object in scenario.structuralObjects where !kept.contains(object.name) {
            try scenario.removeObject(id: object.id)
        }
        var configuration = SolverConfiguration()
        configuration.airSleepThreshold = 0
        configuration.airSleepCrossings = 0
        configuration.interBodyContact = contact
        let started = Date()
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        let bodies = solver.bodies.map { body in
            (body, scenario.structuralObjects.first { $0.id == body.id }!.name)
        }
        var peak = [Double](repeating: 0, count: bodies.count)
        var contactFrom: Double?
        var failure: String?
        while solver.time < duration - 1e-9 {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if contactFrom == nil, solver.bodiesInContact { contactFrom = solver.time }
            for (n, body) in bodies.enumerated() {
                peak[n] = max(peak[n], Double(body.0.summary()?.maxDisplacement ?? 0) * 1000)
            }
            if !result.isStable || result.unsupportedInteraction || result.couplingCapacityExceeded {
                failure = !result.isStable ? "unstable" : "stopped: \(result)"
                break
            }
            if result.steps == 0 { break }
        }
        let buildings = bodies.enumerated().map { n, pair in
            let summary = pair.0.summary() ?? StructureSummary()
            return BuildingsRun.Building(
                name: pair.1, elements: summary.activeElements + summary.erodedElements,
                peakDisplacement: peak[n], finalDisplacement: Double(summary.maxDisplacement) * 1000,
                erodedElements: summary.erodedElements, maxDamage: Double(summary.maxDamage))
        }
        let ambient = Double(configuration.ambientPressure)
        let gauges = zip(scenario.gauges, solver.gaugeHistories).map { gauge, history in
            var impulse = 0.0
            for (a, b) in zip(history, history.dropFirst()) {
                impulse += max(Double(a.pressure) - ambient, 0) * (b.time - a.time)
            }
            return BuildingsRun.Gauge(
                name: gauge.name, peak: (Double(history.map(\.pressure).max() ?? 0) - ambient) / 1000,
                impulse: impulse)
        }
        let run = BuildingsRun(
            variant: variant, buildings: buildings, gauges: gauges, time: solver.time,
            steps: solver.stepCount,
            cells: solver.grid.cellCount, wallSeconds: Date().timeIntervalSince(started),
            contactFrom: contactFrom,
            failure: failure)
        runs.append(run)
        print(
            String(
                format: "%@: %.3f s in %d steps, %.0f s%@%@", variant, run.time, run.steps, run.wallSeconds,
                contactFrom.map { String(format: "; in contact from %.3f s", $0) } ?? "",
                failure.map { "; \($0)" } ?? ""))
        for building in buildings {
            print(
                String(
                    format: "  %@ (%d elements): peak %.1f mm, final %.1f mm, %d broken, damage %.2f",
                    building.name, building.elements, building.peakDisplacement, building.finalDisplacement,
                    building.erodedElements, building.maxDamage))
        }
        for gauge in gauges {
            print(String(format: "  %@: %.1f kPa, %.1f kPa ms", gauge.name, gauge.peak, gauge.impulse))
        }
        fflush(stdout)
    }
    if let out = option("out") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runs).write(to: URL(fileURLWithPath: out), options: .atomic)
        print("Wrote \(out)")
    }
}

/// Two single-storey buildings side by side, 6 m square and 3 m high with 200 mm reinforced
/// concrete walls and roof, 0.1 m apart, and 20 kg 1 m up and 1 m from the first's party wall.
func terracedLayout() -> Scenario {
    func building(_ x: Float) -> StructureModel {
        let walls: [(box: Box, axis: Int)] = [
            (Box(min: SIMD3(x, 4, 0), max: SIMD3(x + 0.2, 10, 3)), 0),
            (Box(min: SIMD3(x + 5.8, 4, 0), max: SIMD3(x + 6, 10, 3)), 0),
            (Box(min: SIMD3(x, 4, 0), max: SIMD3(x + 6, 4.2, 3)), 1),
            (Box(min: SIMD3(x, 9.8, 0), max: SIMD3(x + 6, 10, 3)), 1),
            (Box(min: SIMD3(x, 4, 2.8), max: SIMD3(x + 6, 10, 3)), 2),
        ]
        var model = StructureModel(solids: walls.map(\.box), elementSize: 0.25)
        model.elementKind = .shell
        for wall in walls {
            model.addMat(to: wall.box, thicknessAxis: wall.axis, areaPerMetre: 565e-6, depth: 0.04)
        }
        return model
    }
    var scenario = Scenario(
        name: "Terraced buildings", domainSize: SIMD3(20, 14, 6), boxes: [],
        charge: Charge(mass: 20, position: SIMD3(8, 7, 1)),
        gauges: [Gauge("Inside", at: SIMD3(5, 7, 1.5)), Gauge("Outside", at: SIMD3(2, 2, 1.5))],
        structure: building(3))
    _ = try? scenario.addStructureObject(building(9.1), name: "Neighbour")
    return scenario
}
