import BlastCore
import DocumentKit
import Foundation

/// `BombCAD run`: runs a saved project to completion without a window and keeps the result as a
/// saved run. It drives the same `SimulationModel` as the app and its sweeps, so a run here gives
/// the same answer as one in the app.
@MainActor
enum HeadlessRun {
    static let usage = """
        Usage: BombCAD run <project.bombcad | layout.json> [--name <name>] [--out <new.bombcad>]
                           [--csv <file.csv>] [--resolution coarse|medium|fine] [--mass <kg TNT>]
                           [--duration <seconds>]

        Runs the project's simulation to its duration and prints a summary. --out writes a copy of
        the project with the run added to its saved runs; --csv writes the gauge and deflection
        histories. --resolution and --mass change the inputs as a sweep case would; the project
        itself is never modified.
        """

    struct Options: Equatable {
        var project: URL
        var name: String?
        var out: URL?
        var csv: URL?
        var resolution: Resolution?
        var mass: Float?
        var duration: Double?

        static func parse(_ arguments: [String]) throws -> Options {
            var positional: [String] = []
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument.hasPrefix("--") {
                    let key = String(argument.dropFirst(2))
                    guard ["name", "out", "csv", "resolution", "mass", "duration"].contains(key) else {
                        throw ProjectFileError.invalid("Unknown option \(argument).")
                    }
                    guard index + 1 < arguments.count, values[key] == nil else {
                        throw ProjectFileError.invalid("Give \(argument) one value.")
                    }
                    values[key] = arguments[index + 1]
                    index += 2
                } else {
                    positional.append(argument)
                    index += 1
                }
            }
            guard positional.count == 1 else { throw ProjectFileError.invalid("Name one project to run.") }
            var options = Options(project: URL(filePath: positional[0]))
            options.name = values["name"]
            options.out = values["out"].map { URL(filePath: $0) }
            options.csv = values["csv"].map { URL(filePath: $0) }
            if let text = values["resolution"] {
                guard let resolution = Resolution(rawValue: text) else {
                    throw ProjectFileError.invalid("Resolution must be coarse, medium or fine.")
                }
                options.resolution = resolution
            }
            if let text = values["mass"] {
                guard let mass = Float(text) else { throw ProjectFileError.invalid("Mass must be a number.") }
                options.mass = mass
            }
            if let text = values["duration"] {
                guard let duration = Double(text), duration.isFinite, duration > 0 else {
                    throw ProjectFileError.invalid("Duration must be a positive number of seconds.")
                }
                options.duration = duration
            }
            for url in [options.out, options.csv].compactMap({ $0 })
            where FileManager.default.fileExists(atPath: url.path) {
                throw ProjectFileError.invalid("\(url.path) already exists; choose a new path.")
            }
            if let out = options.out, out.pathExtension != "bombcad" {
                throw ProjectFileError.invalid("The output project must end in .bombcad.")
            }
            return options
        }
    }

    /// The run's inputs: the project's, changed as a sweep case would change them.
    nonisolated static func inputs(for document: ProjectDocument, options: Options) throws -> SimulationInputs
    {
        guard let settings = document.runSettings else {
            throw ProjectFileError.invalid("The project has no simulation settings.")
        }
        var inputs = SimulationInputs(scenario: document.scenario, settings: settings)
        if let resolution = options.resolution {
            inputs = try ParameterSweepPlan(prefix: "Run", parameter: .grid([resolution])).prepare(
                from: inputs)[0]
                .inputs
        }
        if let mass = options.mass {
            inputs = try ParameterSweepPlan(prefix: "Run", parameter: .chargeMass([mass])).prepare(
                from: inputs)[0]
                .inputs
        }
        if let duration = options.duration {
            inputs.settings.duration = duration
        }
        try inputs.validate()
        return inputs
    }

    /// The first of "Headless run", "Headless run 2", … not already among the saved runs.
    nonisolated static func defaultName(avoiding runs: [SavedSimulationRun]) -> String {
        let taken = Set(runs.map { $0.name.lowercased() })
        return (1...).lazy.map { $0 == 1 ? "Headless run" : "Headless run \($0)" }
            .first { !taken.contains($0.lowercased()) }!
    }

    /// Runs the project, writes any requested outputs and returns the kept run.
    static func execute(_ options: Options) async throws -> SavedSimulationRun {
        var document = try ProjectDocument.read(from: options.project)
        let inputs = try inputs(for: document, options: options)
        // Without --out the earlier runs are not needed, and must not use up the run limit.
        if options.out == nil { document.savedRuns = [] }
        guard document.savedRuns.count < SavedSimulationRun.maximumRuns else {
            throw ProjectFileError.invalid(
                "The project already keeps \(SavedSimulationRun.maximumRuns) runs; remove one first.")
        }
        let name = options.name ?? defaultName(avoiding: document.savedRuns)

        // Start from the case's inputs, so the project's own grid is never allocated first.
        var start = document
        start.scenario = inputs.scenario
        start.runSettings = inputs.settings
        let model = SimulationModel(document: start, playbackSpeed: .unlimited)
        model.applyExperimentInputs(inputs)
        try await waitUntil(model) { model.experimentIsReady }
        model.run()
        try await waitUntil(model) { !model.isRunning && !model.hasPendingGPUWork }
        try model.keepRun(named: name)
        let run = model.savedRuns.last!

        if let out = options.out {
            // The project's own inputs, with the new run among its saved ones.
            document.savedRuns = model.savedRuns
            try document.makeArchive().fileWrapper().write(to: out, originalContentsURL: nil)
        }
        if let csv = options.csv {
            try Data(run.csv().utf8).write(to: csv, options: .withoutOverwriting)
        }
        return run
    }

    private static func waitUntil(_ model: SimulationModel, _ condition: () -> Bool) async throws {
        while !condition() {
            if let error = model.errorMessage { throw ProjectFileError.invalid(error) }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let error = model.errorMessage { throw ProjectFileError.invalid(error) }
    }

    nonisolated static func summary(_ run: SavedSimulationRun, wallSeconds: Double) -> String {
        func format(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
        var lines = [
            "\(run.name): \(run.scenario.name), \(run.settings.resolution) grid, "
                + "\(format(Double(run.scenario.charge.mass), 2)) kg TNT",
            "\(run.stepCount) steps to \(format(run.elapsedTime * 1000, 1)) ms on \(run.deviceName), "
                + "in \(format(wallSeconds, 1)) s",
        ]
        for gauge in run.gauges {
            lines.append("  \(gauge.key.name): peak \(format(gauge.peak, 1)) kPa")
        }
        if let structure = run.structure {
            lines.append(
                "  Structure: largest deflection \(format(structure.peak, 1)) mm, "
                    + "\(format(structure.failedFraction * 100, 1))% of elements failed")
        }
        return lines.joined(separator: "\n")
    }

    /// The command's entry point; returns the process's exit status.
    static func main(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let options: Options
        do {
            options = try Options.parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n\n\(usage)\n".utf8))
            return 2
        }
        let start = ContinuousClock.now
        do {
            let run = try await execute(options)
            let wall = start.duration(to: .now)
            print(
                summary(
                    run,
                    wallSeconds: Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18
                ))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Run failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
