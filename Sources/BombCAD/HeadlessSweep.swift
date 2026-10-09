import DocumentKit
import Foundation

/// `BombCAD sweep`: runs a parameter sweep on a saved project without a window, as the app's
/// Sweep… does, optionally sharing cases with other Macs.
@MainActor
enum HeadlessSweep {
    static let usage = """
        Usage: BombCAD sweep <project.bombcad> (--masses <kg,kg,…> | --grids <coarse,medium,fine>)
                             [--prefix <name>] [--worker <ssh host>]… [--ratio <times slower>]
                             [--local-workers <n>] [--out <new.bombcad>]

        Runs each case to the project's duration, here and, with --worker (once per host), on other
        Macs reached over SSH (see docs/run-comparison.md), and prints each result and where it ran.
        --remote is the same as --worker. --local-workers adds workers on this Mac, sharing its GPU,
        to try the scheduling without another Mac. --out writes a copy of the project with the
        results added to its saved runs.
        """

    static func main(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        var positional: [String] = []
        var values: [String: String] = [:]
        var hosts: [String] = []
        var repeated = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count {
                let key = String(argument.dropFirst(2))
                if key == "worker" || key == "remote" {
                    hosts.append(arguments[index + 1])
                } else {
                    repeated = repeated || values[key] != nil
                    values[key] = arguments[index + 1]
                }
                index += 2
            } else {
                positional.append(argument)
                index += 1
            }
        }
        do {
            guard positional.count == 1, !repeated,
                Set(values.keys).isSubset(of: ["masses", "grids", "prefix", "ratio", "local-workers", "out"]),
                (values["masses"] == nil) != (values["grids"] == nil)
            else { throw ProjectFileError.invalid("Name one project, and either --masses or --grids.") }
            guard Set(hosts).count == hosts.count else {
                throw ProjectFileError.invalid("Name each --worker host once.")
            }
            for host in hosts { try RemoteSweepWorker.validate(host) }
            let localWorkers =
                try values["local-workers"].map { text in
                    guard let count = Int(text), (0...8).contains(count) else {
                        throw ProjectFileError.invalid("--local-workers takes a count from 0 to 8.")
                    }
                    return count
                } ?? 0
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
            for host in hosts {
                model.sweep.remoteWorkers.append { try await RemoteSweepWorker.connect(host: host) }
            }
            for number in 0..<localWorkers {
                model.sweep.remoteWorkers.append {
                    try await RemoteSweepWorker.connectHere(name: "local worker \(number + 1)")
                }
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
