import BlastCore
import Foundation
import Metal

/// `blastbench checkpoint-check [--steps 192] [--at 128] [--out DIR] [--refine 2] [--refine-levels 2]
/// [--terrain ridge] [--recommended] [--gravity] [--case open] [--dx 0.25]`: for each of the digest's cases the
/// first checkpoints cover (the air and structures), the state after `--steps` steps run straight through
/// against the same steps run to `--at` (a multiple of 64), saved, taken back by a solver built
/// afresh and run on: equal to the bit, with the checkpoint's size and the time to save and take
/// it back.
func runCheckpointCheck(device: MTLDevice) throws {
    let steps = option("steps").flatMap { Int($0) } ?? 192
    let at = option("at").flatMap { Int($0) } ?? 128
    guard at % BlastSolver.checkpointInterval == 0, at > 0, at < steps else {
        print("--at must be a multiple of \(BlastSolver.checkpointInterval) below --steps")
        exit(2)
    }
    let folder = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/checkpoints/check")
    // The digest's cases, the walls among them (a structure in solids and in shells), or with
    // `--preset` that scene alone (on `--dx`, 0.25 m by default).
    var cases: [(String, Scenario, Float, Bool)] = [
        ("open", ScenarioPreset.openGround.scenario, 0.5, false),
        ("street", ScenarioPreset.streetCanyon.scenario, 0.5, false),
        ("street, afterburning", ScenarioPreset.streetCanyon.scenario, 0.5, true),
        ("wall", ScenarioPreset.blastWall.scenario, 0.25, false),
        (
            "wall as shells",
            {
                var s = ScenarioPreset.blastWall.scenario
                s.structure?.elementKind = .shell
                return s
            }(),
            0.25, false
        ),
    ]
    if let preset = option("preset") { cases = [(preset, chosenScenario(), 0.25, false)] }
    // `--street-envelopes`: the street study's four buildings as envelopes.
    if flag("street-envelopes") {
        var scenario = try StreetInteractionStudy.make(.street)
        for object in scenario.structuralObjects { try scenario.useEnvelope(id: object.id) }
        cases = [("street envelopes", scenario, 0.25, false)]
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    let trace = flag("trace")
    func note(_ text: String) { if trace { print("  [\(text)]") } }
    var failures = 0
    for (name, preset, presetCell, afterburning) in cases where option("case").map({ $0 == name }) ?? true {
        // `--dx` for larger grids (the size and time of a checkpoint at 1, 10 and 50 million cells).
        let cellSize = option("dx").flatMap { Float($0) } ?? presetCell
        var configuration = flag("recommended") ? SolverConfiguration.recommended : SolverConfiguration()
        configureRefinement(&configuration)
        configuration.afterburning = afterburning || flag("recommended")
        configuration.gravity = chosenGravity()
        var scenario = preset
        if let terrain = option("terrain") { applyTerrain(terrain, to: &scenario) }
        // Each solver configured alike: `--envelopes` records the envelopes' components and vents
        // their glazing, `--exposure-plane` records the plane at standing height.
        func solver() throws -> BlastSolver {
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
            if flag("envelopes"), !scenario.envelopeObjects.isEmpty {
                try solver.configureEnvelopeComponents(
                    objects: scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.1))
                try solver.configureEnvelopeVenting(objects: scenario.envelopeObjects) {
                    scenario.envelopeConstruction(for: $0)
                }
            }
            if flag("exposure-plane") {
                try solver.configureExposurePlane(heightM: 1.5, arrivalThresholdPa: 1_000)
            }
            return solver
        }
        let straight = try solver()
        if let reason = straight.checkpointUnsupported {
            print("\(name): not checkpointed (\(reason))")
            continue
        }
        note("built")
        straight.advance(steps: steps)
        note("advanced straight")
        let expected = straight.stateDigest()
        note("digest")

        let first = try solver()
        first.advance(steps: at)
        let place = folder.appending(path: name.replacingOccurrences(of: ", ", with: "-"))
        try? FileManager.default.removeItem(at: place)
        note("saving")
        let saved = try first.saveCheckpoint(to: place, scene: scenario)
        note("saved")
        let resumed = try solver()
        note("built again")
        let start = ContinuousClock.now
        try resumed.restoreCheckpoint(from: place, scene: scenario)
        note("restored")
        let elapsed = ContinuousClock.now - start
        let restoreSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        resumed.advance(steps: steps - at)
        let found = resumed.stateDigest()
        let same =
            found == expected && resumed.stepCount == straight.stepCount && resumed.time == straight.time
        if !same { failures += 1 }
        print(
            String(
                format:
                    "%@: %@ after %d steps (saved at %d): %llx %@ %llx; %d cells, %.1f MB raw, %.1f MB stored, save %.2f s, restore %.2f s",
                name, same ? "same" : "DIFFERENT", steps, at, expected, same ? "=" : "≠", found,
                straight.grid.cellCount, Double(saved.rawBytes) / 1e6, Double(saved.storedBytes) / 1e6,
                saved.seconds,
                restoreSeconds))
    }
    if failures > 0 { exit(1) }
}
