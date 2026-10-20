import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's export of a run's results. Split from SimulationModel.swift
// (emmettl/bombcad-work#52).
extension SimulationModel {
    /// The run's histories as comma-separated values: every recorded sample of every gauge,
    /// then the structure's largest deflection at each sample, one row per sample.
    func resultsCSV() -> String {
        var lines = ["series,time (ms),value,unit"]
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        if let solver {
            let ambient = Double(scenario.atmosphere.pressure)
            for (index, history) in solver.gaugeHistories.enumerated() where index < scenario.gauges.count {
                let name = field(scenario.gauges[index].name)
                for sample in history {
                    lines.append(
                        "\(name),\(String(format: "%.4f", sample.time * 1000)),"
                            + "\(String(format: "%.4f", (Double(sample.pressure) - ambient) / 1000)),kPa")
                }
            }
        }
        for sample in structureRecord {
            lines.append(
                "Largest deflection,\(String(format: "%.4f", sample.time)),\(String(format: "%.3f", sample.deflection)),mm"
            )
        }
        if scenario.structuralObjects.count > 1 {
            for object in scenario.structuralObjects {
                let label = field("\(object.name) [\(object.id.uuidString)] deflection")
                for sample in bodyRecords[object.id] ?? [] {
                    lines.append("\(label),\(sample.time),\(sample.deflection),mm")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var canKeepRun: Bool {
        guard let completed = completedRunSettings else { return false }
        var current = ProjectRunSettings(model: self)
        current.duration = completed.duration
        return !isRunning && !batchInFlight && !rebuildPending && !isPreparingImports && !isLoadingInputs
            && errorMessage == nil && stepCount > 0 && current == completed
            && settings.scenario == scenario && savedRuns.count < SavedSimulationRun.maximumRuns
    }

    func keepRun(named name: String) throws {
        guard canKeepRun, let solver, let inputs = completedRunSettings else {
            throw ProjectFileError.invalid("Complete a stable run before keeping its results.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedRuns.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame })
        else {
            throw ProjectFileError.invalid("Choose a unique name for this run.")
        }
        let keys = SavedSimulationRun.Gauge.keys(Array(scenario.gauges.prefix(BlastSolver.maxGauges)))
        let gauges = zip(keys, solver.gaugeHistories).map { key, history in
            SavedSimulationRun.Gauge(
                key: key,
                points: history.map {
                    .init(
                        time: $0.time,
                        value: (Double($0.pressure) - Double(scenario.atmosphere.pressure)) / 1000)
                })
        }
        let response = structureSummary.map { summary in
            SavedSimulationRun.Structure(
                points: structureRecord.map {
                    .init(time: $0.time / 1000, value: $0.deflection)
                }, failedFraction: Double(summary.erodedFraction),
                maximumDamage: Double(summary.maxDamage))
        }
        var flown: SavedSimulationRun.Fragments?
        if let fragments, let spec = flownSpec {
            guard fragments.caughtUp, let live = fragments.fragmentLive else {
                throw ProjectFileError.invalid("The fragments are still landing; keep the run in a moment.")
            }
            flown = SavedSimulationRun.Fragments(
                spec: spec, launchSpeed: Double(fragmentLaunchSpeed), impacts: live.impacts,
                airborne: (0..<live.fragmentCount).filter { !live.landed[$0] }.count, hazard: fragmentHazard)
        }
        var reckoned: ThermalResult?
        if let thermal, let spec = reckonedSpec {
            guard thermal.caughtUp, let live = thermal.thermalLive else {
                throw ProjectFileError.invalid(
                    "The thermal radiation is still being reckoned; keep the run in a moment.")
            }
            reckoned = ThermalResult(
                spec: spec, receivers: thermalReceivers, peakIrradiance: live.peakIrradiance,
                fluence: live.fluence, fireball: fireballFrames,
                chargeEnergy: ThermalExposure.chargeEnergy(FragmentScene(scenario)),
                heating: heatingResult(live, spec: spec))
        }
        var run = SavedSimulationRun(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            solverVersion: scenario.structuralObjects.count > 1
                ? SavedSimulationRun.multiBodySolverVersion : SavedSimulationRun.solverVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "development",
            deviceName: device?.name ?? "Unknown Metal device", scenario: scenario, settings: inputs,
            inputSHA256: try SavedSimulationRun.fingerprint(scenario, settings: inputs),
            elapsedTime: time, stepCount: stepCount, gauges: gauges, structure: response,
            bodyResponses: scenario.structuralObjects.count > 1
                ? scenario.structuralObjects.map { object in
                    let summary = bodySummaries[object.id]!
                    return SavedSimulationRun.BodyResponse(
                        id: object.id, name: object.name,
                        response: .init(
                            points: (bodyRecords[object.id] ?? []).map {
                                .init(time: $0.time / 1000, value: $0.deflection)
                            },
                            failedFraction: Double(summary.erodedFraction),
                            maximumDamage: Double(summary.maxDamage)))
                } : nil)
        run.fragments = flown
        run.envelopeExposure = solver.envelopeExposureSummaries()
        if let groundShock, let spec = estimatedGroundSpec {
            guard groundShock.caughtUp, var result = groundShock.groundShockLive else {
                throw ProjectFileError.invalid(
                    "The ground's shaking is still being estimated; keep the run in a moment.")
            }
            result.place(on: scenario.terrain)
            // What is drawn, as what is kept.
            updateGroundShockStatus()
            result.frameTimes = nil
            for n in result.points.indices {
                result.points[n].history = []
                for d in result.points[n].responses.indices { result.points[n].responses[d].history = nil }
            }
            run.groundShock = SavedSimulationRun.GroundShock(spec: spec, result: result)
        }
        run.thermal = reckoned
        if followingCloud {
            throw ProjectFileError.invalid("The cloud is still being followed; keep the run in a moment.")
        }
        run.cloud = cloud
        run.standing = run.derivedStanding()
        try run.validate()
        // Reject an oversized capture before it can make the document unsavable.
        var document = ProjectDocument(model: self)
        document.savedRuns.append(run)
        _ = try document.makeArchive()
        savedRuns.append(run)
        if let recentTimeline { runFolders[run.id] = recentTimeline }
    }

    /// Keeps a run made elsewhere, as by a sweep worker on another Mac, with the checks
    /// `keepRun` makes.
    func addRun(_ run: SavedSimulationRun) throws {
        guard savedRuns.count < SavedSimulationRun.maximumRuns,
            !savedRuns.contains(where: {
                $0.id == run.id || $0.name.localizedCaseInsensitiveCompare(run.name) == .orderedSame
            })
        else {
            throw ProjectFileError.invalid("There is no room for \(run.name), or its name is taken.")
        }
        try run.validate()
        var document = ProjectDocument(model: self)
        document.savedRuns.append(run)
        _ = try document.makeArchive()
        savedRuns.append(run)
    }

    /// Puts the runs named in `names` in that order, in the places they already take.
    func orderRuns(_ names: [String]) {
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let places = savedRuns.indices.filter { rank[savedRuns[$0].name] != nil }
        let ordered = places.map { savedRuns[$0] }.sorted { rank[$0.name]! < rank[$1.name]! }
        for (place, run) in zip(places, ordered) { savedRuns[place] = run }
    }

    func renameRun(id: UUID, name: String) throws {
        guard !sweep.isActive else {
            throw ProjectFileError.invalid("Wait for the sweep to finish before renaming a run.")
        }
        guard let index = savedRuns.firstIndex(where: { $0.id == id }) else {
            throw ProjectFileError.invalid("This saved run is no longer available.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectFileError.invalid("Enter a run name.") }
        guard trimmed.count <= 120 else {
            throw ProjectFileError.invalid("Run names must be 120 characters or fewer.")
        }
        guard
            !savedRuns.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            })
        else {
            throw ProjectFileError.invalid("A saved run already uses that name. Choose a unique name.")
        }
        savedRuns[index].name = trimmed
    }

    func removeRun(id: UUID) {
        guard !sweep.isActive else { return }
        savedRuns.removeAll { $0.id == id }
    }

    func restoreRun(_ run: SavedSimulationRun) {
        guard !sweep.isActive else { return }
        guard savedRuns.count < SavedSimulationRun.maximumRuns,
            !savedRuns.contains(where: {
                $0.id == run.id || $0.name.localizedCaseInsensitiveCompare(run.name) == .orderedSame
            })
        else { return }
        savedRuns.append(run)
    }
}
