import DocumentKit
import Foundation

/// `BombCAD sweep`: runs a parameter sweep on a saved project without a window, as the app's
/// Sweep… does, optionally sharing cases with another Mac.
@MainActor
enum HeadlessSweep {
    static let usage = """
        Usage: BombCAD sweep <project.bombcad> (--masses <kg,kg,…> | --grids <coarse,medium,fine>)
                             [--prefix <name>] [--remote <ssh host>] [--ratio <times slower>]
                             [--out <new.bombcad>]

        Runs each case to the project's duration, here and, with --remote, on another Mac reached
        over SSH (see docs/run-comparison.md), and prints each result and where it ran. --out
        writes a copy of the project with the results added to its saved runs.
        """

    static func main(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        var positional: [String] = []
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count {
                values[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                positional.append(argument)
                index += 1
            }
        }
        do {
            guard positional.count == 1,
                Set(values.keys).isSubset(of: ["masses", "grids", "prefix", "remote", "ratio", "out"]),
                (values["masses"] == nil) != (values["grids"] == nil)
            else { throw ProjectFileError.invalid("Name one project, and either --masses or --grids.") }
            let parameter: ParameterSweepPlan.Parameter
            if let masses = values["masses"] {
                let list = masses.split(separator: ",").compactMap {
                    Float($0.trimmingCharacters(in: .whitespaces))
                }
                parameter = .chargeMass(list)
            } else {
                let list = values["grids"]!.split(separator: ",").compactMap {
                    Resolution(rawValue: $0.trimmingCharacters(in: .whitespaces))
                }
                parameter = .grid(list)
            }
            let out = values["out"].map { URL(filePath: $0) }
            if let out, FileManager.default.fileExists(atPath: out.path) || out.pathExtension != "bombcad" {
                throw ProjectFileError.invalid("--out must be a new .bombcad path.")
            }

            let document = try ProjectDocument.read(from: URL(filePath: positional[0]))
            let model = SimulationModel(document: document, playbackSpeed: .unlimited)
            model.applyExperimentInputs(model.currentInputs)
            try await waitUntil(model) { model.experimentIsReady }
            if let host = values["remote"] {
                try RemoteSweepWorker.validate(host)
                model.sweep.remoteWorker = { try await RemoteSweepWorker.connect(host: host) }
            }
            if let ratio = values["ratio"].flatMap(Double.init) { model.sweep.remoteRatio = ratio }
            let before = Set(model.savedRuns.map(\.id))
            let start = ContinuousClock.now
            try model.sweep.start(
                ParameterSweepPlan(prefix: values["prefix"] ?? "Sweep", parameter: parameter))
            try await waitUntil(model) { !model.sweep.isActive && model.experimentIsReady }
            let wall = start.duration(to: .now)
            for run in model.savedRuns where !before.contains(run.id) {
                print("\(run.name): \(run.stepCount) steps on \(run.deviceName)")
            }
            print(
                model.sweep.message
                    + String(
                        format: " in %.1f s",
                        Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18))
            if let out {
                try ProjectDocument(model: model).makeArchive().fileWrapper().write(
                    to: out, originalContentsURL: nil)
            }
            return model.sweep.completed == model.sweep.total ? 0 : 1
        } catch {
            FileHandle.standardError.write(
                Data("Sweep failed: \(error.localizedDescription)\n\n\(usage)\n".utf8))
            return 1
        }
    }

    private static func waitUntil(_ model: SimulationModel, _ condition: () -> Bool) async throws {
        while !condition() {
            if !model.sweep.isActive, let error = model.errorMessage { throw ProjectFileError.invalid(error) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
