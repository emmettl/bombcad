import BlastCore
import Foundation
import Metal

// `blastbench envelope-regrade [--presets a,b] [--dx 0.5] [--time 0.2]`: every sample with envelope
// buildings run with venting on, as the app runs them, each building's components judged: their
// levels, which failed and when, which venting opened, the rooms' peaks. Run once as is and once
// with BOMBCAD_CONCRETE_INWARD_ONLY set, and compare, to see what judging concrete either way moves.
func runEnvelopeRegrade(device: MTLDevice) throws {
    let wanted = option("presets").map { Set($0.split(separator: ",").map(String.init)) }
    let dx = option("dx").flatMap { Float($0) }
    let duration = option("time").flatMap { Double($0) } ?? 0.2
    print(
        "Concrete judged "
            + (ProcessInfo.processInfo.environment["BOMBCAD_CONCRETE_INWARD_ONLY"] != nil
                ? "inward only" : "either way"))
    for preset in ScenarioPreset.allCases where wanted?.contains(preset.rawValue) ?? true {
        let scenario = preset.scenario
        guard !scenario.envelopeObjects.isEmpty else { continue }
        let cell = dx ?? max(0.25, Float(scenario.domainSize.max()) / 240)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cell)
        do {
            try solver.configureEnvelopeComponents(
                objects: scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
        } catch {
            print("\(preset.rawValue): not recorded (\(error))")
            continue
        }
        try solver.configureEnvelopeVenting(
            objects: scenario.envelopeObjects, constructions: { scenario.envelopeConstruction(for: $0) })
        let started = ContinuousClock.now
        while solver.time < duration {
            if solver.advance(steps: 32, timeLimit: duration).steps == 0 { break }
        }
        let vented = solver.envelopeVentingSnapshot()
        let loads = (solver.envelopeComponentHistories() ?? []).filter {
            !$0.invalid || vented?.keeps($0) == true
        }
        .map(EnvelopeComponentLoad.init)
        let rooms = Dictionary(
            uniqueKeysWithValues: scenario.envelopeObjects.map {
                ($0.id, EnvelopeDamageAssessment.roomVolume(of: $0.envelope!))
            })
        let damage = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { scenario.envelopeConstruction(for: $0) }, rooms: rooms,
            vented: vented)
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        print(
            "\(preset.rawValue): \(damage.count) buildings, \(cell) m cells, \(String(format: "%.0f", seconds)) s"
        )
        for building in damage {
            let name = scenario.object(id: building.id)?.name ?? "Building"
            var counts = [EnvelopeDamageLevel: Int]()
            for component in building.components where !component.material.isGlass {
                counts[component.levels.upperBound, default: 0] += 1
            }
            let levels = EnvelopeDamageLevel.allCases.compactMap { level in
                counts[level].map { "\(level.label) \($0)" }
            }.joined(separator: ", ")
            let failed = building.components.filter { !$0.material.isGlass && $0.failedAtS != nil }.map {
                "\($0.id.split(separator: "/").dropFirst().joined(separator: "/"))@\(String(format: "%.1f", $0.failedAtS! * 1000))ms"
            }
            let opened = (vented?.walls ?? []).filter { $0.owner == building.id && $0.failedAtS != nil }.count
            print(
                "  \(name) [\(building.construction.walls.rawValue)/\(building.construction.roof.rawValue)]: "
                    + "\(levels); failed \(failed.isEmpty ? "none" : failed.joined(separator: " ")); "
                    + "venting opened \(opened) walls; panes broken \(building.panesBroken) of \(building.panes); "
                    + String(format: "inside peak %.1f kPa", building.insidePeakPa / 1000))
        }
    }
}
