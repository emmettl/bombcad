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
                           [--duration <seconds>] [--usd <scene.usda>] [--vdb <folder>]
                           [--frame-interval <ms>]

        Runs the project's simulation to its duration and prints a summary. --out writes a copy of
        the project with the run added to its saved runs; --csv writes the gauge and deflection
        histories. --usd writes the scene for rendering elsewhere, with the structure's surface,
        and --vdb the air as OpenVDB volumes, a file a frame, both every --frame-interval
        milliseconds of simulated time (1 by default). --resolution and
        --mass change the inputs as a sweep case would; the project itself is never modified.
        """

    struct Options: Equatable {
        var project: URL
        var name: String?
        var out: URL?
        var csv: URL?
        var resolution: Resolution?
        var mass: Float?
        var duration: Double?
        var usd: URL?
        /// A new folder for the air's volumes, one OpenVDB file a frame.
        var vdb: URL?
        /// Whole milliseconds of simulated time between frames of `usd` and `vdb`.
        var frameInterval = 1

        static func parse(_ arguments: [String]) throws -> Options {
            var positional: [String] = []
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument.hasPrefix("--") {
                    let key = String(argument.dropFirst(2))
                    guard
                        [
                            "name", "out", "csv", "resolution", "mass", "duration", "usd", "vdb",
                            "frame-interval",
                        ]
                        .contains(key)
                    else {
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
            options.usd = values["usd"].map { URL(filePath: $0) }
            options.vdb = values["vdb"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            if let text = values["frame-interval"] {
                guard options.usd != nil || options.vdb != nil else {
                    throw ProjectFileError.invalid("--frame-interval needs --usd or --vdb.")
                }
                guard let interval = Int(text), interval > 0 else {
                    throw ProjectFileError.invalid(
                        "The frame interval must be a whole number of milliseconds.")
                }
                options.frameInterval = interval
            }
            if let usd = options.usd, usd.pathExtension != "usda" {
                throw ProjectFileError.invalid("The USD scene must end in .usda.")
            }
            for url in [options.out, options.csv, options.usd, options.vdb].compactMap({ $0 })
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
        // Without --out the earlier runs are not needed, and must not use up the run limit.
        if options.out == nil { document.savedRuns = [] }
        let result = try await perform(document, options: options)
        if let out = options.out {
            try result.document.makeArchive().fileWrapper().write(to: out, originalContentsURL: nil)
        }
        if let csv = options.csv {
            try Data(result.run.csv().utf8).write(to: csv, options: .withoutOverwriting)
        }
        return result.run
    }

    /// Runs `document` as `options` change it, with any `--usd` and `--vdb` exports, and returns
    /// the kept run and the document, its own inputs unchanged, with the run added to its saved
    /// runs. `progress` is told the fraction of the simulated time reached, now and then.
    /// Cancelling the task stops the run.
    static func perform(
        _ document: ProjectDocument, options: Options, progress: ((Double) -> Void)? = nil
    ) async throws -> (run: SavedSimulationRun, document: ProjectDocument) {
        var document = document
        let inputs = try inputs(for: document, options: options)
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
        let interval = Double(options.frameInterval) * SimulationModel.structureSampleInterval
        // Before the inputs load, which sets the first sample time.
        model.airSampleInterval = interval
        model.applyExperimentInputs(inputs)
        try await waitUntil(model) { model.experimentIsReady }
        let scene = try options.usd.map { url in
            try USDSceneWriter(
                url: url, scenario: inputs.scenario, frameInterval: interval,
                camera: .init(
                    eye: model.camera.eye, target: model.camera.target,
                    verticalFieldOfView: model.camera.fieldOfView),
                volumeFields: options.vdb == nil ? [] : ["overpressure", "shock"])
        }
        defer { scene?.discard() }
        var finished = false
        if let folder = options.vdb {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        defer {
            if !finished, let folder = options.vdb { try? FileManager.default.removeItem(at: folder) }
        }
        var exportError: Error?
        // Frames fall on the samples every millisecond, where a run with a structure stops anyway,
        // so exporting does not change the run. Without a structure, only volumes ask for frames,
        // and the run then stops at each one, ending a time step there.
        if options.vdb != nil || (scene != nil && inputs.scenario.structure != nil) {
            var frame = 0
            model.onSample = { solver in
                // The last sample, at the end of the run, can fall between frames.
                let index = (solver.time / interval).rounded()
                guard exportError == nil, abs(solver.time - index * interval) < 1e-6, Int(index) == frame
                else {
                    return
                }
                defer { frame += 1 }
                do {
                    var volume: String?
                    if let folder = options.vdb {
                        let file = folder.appending(path: String(format: "blast.%04d.vdb", frame))
                        try OpenVDBWriter.write(solver.volumeGrids(), to: file)
                        volume = options.usd.map { assetPath(of: file, from: $0) }
                    }
                    try scene?.append(solver.structureSurface(), volume: volume)
                } catch {
                    exportError = error
                }
            }
        }
        model.run()
        var reported = ContinuousClock.now
        try await waitUntil(model) {
            if let progress, ContinuousClock.now - reported > .milliseconds(500) {
                reported = .now
                progress(min(model.time / model.duration, 1))
            }
            return !model.isRunning && !model.hasPendingGPUWork
        }
        if let exportError { throw exportError }
        try model.keepRun(named: name)
        let run = model.savedRuns.last!
        try scene?.finish()
        finished = true
        // The project's own inputs, with the new run among its saved ones.
        document.savedRuns = model.savedRuns
        return (run, document)
    }

    /// `file` as the USD file at `scene` should name it: relative where it lies beside or below it.
    nonisolated static func assetPath(of file: URL, from scene: URL) -> String {
        let base = scene.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let path = file.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? "./" + path.dropFirst(prefix.count) : path
    }

    private static func waitUntil(_ model: SimulationModel, _ condition: () -> Bool) async throws {
        while !condition() {
            if let error = model.errorMessage { throw ProjectFileError.invalid(error) }
            if Task.isCancelled {
                if model.isRunning { model.toggleRun() }
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(5))
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
