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
                           [--frame-interval <ms>] [--fragments <spec.json> [--consumer local|<ssh host>]
                           [--fragment-results <file.json>]]

        Runs the project's simulation to its duration and prints a summary. --out writes a copy of
        the project with the run added to its saved runs; --csv writes the gauge and deflection
        histories. --usd writes the scene for rendering elsewhere, with the structure's surface,
        and --vdb the air as OpenVDB volumes, a file a frame, both every --frame-interval
        milliseconds of simulated time (1 by default). --fragments flies a cased charge's fragments
        and tracers through the blast, one way, on this Mac's CPU or on another Mac over SSH, frame
        by frame; they go into the USD scene and, with --fragment-results, a JSON file.
        --resolution and --mass change the inputs as a sweep case would; the project itself is
        never modified.
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
        /// A cased charge's fragments to fly through the blast, where, and where their results go.
        var fragments: FragmentSpec?
        var consumer = "local"
        var fragmentResults: URL?
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
                            "name", "out", "csv", "resolution", "mass", "duration", "usd", "vdb", "fragments",
                            "consumer", "fragment-results",
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
            if let path = values["fragments"] {
                let spec = try JSONDecoder().decode(
                    FragmentSpec.self, from: Data(contentsOf: URL(filePath: path)))
                try spec.validate()
                options.fragments = spec
            }
            if let consumer = values["consumer"] {
                guard options.fragments != nil else {
                    throw ProjectFileError.invalid("--consumer needs --fragments.")
                }
                if consumer != "local" { try RemoteSweepWorker.validate(consumer) }
                options.consumer = consumer
            }
            options.fragmentResults = values["fragment-results"].map { URL(filePath: $0) }
            if options.fragmentResults != nil, options.fragments == nil {
                throw ProjectFileError.invalid("--fragment-results needs --fragments.")
            }
            if let text = values["frame-interval"] {
                guard options.usd != nil || options.vdb != nil || options.fragments != nil else {
                    throw ProjectFileError.invalid("--frame-interval needs --usd, --vdb or --fragments.")
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
            for url in [options.out, options.csv, options.usd, options.vdb, options.fragmentResults]
                .compactMap({ $0 })
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
    static func execute(_ options: Options) async throws -> (
        run: SavedSimulationRun, fragments: FragmentResult?, stream: String?
    ) {
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
        if let url = options.fragmentResults, let fragments = result.fragments {
            try JSONEncoder().encode(fragments).write(to: url, options: .withoutOverwriting)
        }
        return (result.run, result.fragments, result.stream)
    }

    /// Runs `document` as `options` change it, with any `--usd` and `--vdb` exports, and returns
    /// the kept run and the document, its own inputs unchanged, with the run added to its saved
    /// runs. `progress` is told the fraction of the simulated time reached, now and then.
    /// Cancelling the task stops the run.
    static func perform(
        _ document: ProjectDocument, options: Options, progress: ((Double) -> Void)? = nil,
        consumer injected: (any LiveConsumer)? = nil
    ) async throws -> (
        run: SavedSimulationRun, document: ProjectDocument, fragments: FragmentResult?, stream: String?
    ) {
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
        var consumer = injected
        if consumer == nil, let spec = options.fragments {
            consumer = try await makeConsumer(options.consumer, spec: spec, scenario: inputs.scenario)
        }
        defer { if !finished { consumer?.cancel() } }
        var heldSince: ContinuousClock.Instant?
        var held = Duration.zero
        let streamStart = ContinuousClock.now
        if let consumer {
            // The consumer may fall up to four frames behind; then the run waits for it.
            model.holdBatches = {
                let hold = consumer.sent - 1 - consumer.report.frame > consumerLag
                if hold, heldSince == nil { heldSince = .now }
                if !hold, let since = heldSince {
                    held += since.duration(to: .now)
                    heldSince = nil
                }
                return hold
            }
        }
        // Frames fall on the samples every millisecond, where a run with a structure stops anyway,
        // so exporting does not change the run. Without a structure, only volumes and fragments
        // ask for frames, and the run then stops at each one, ending a time step there.
        if options.vdb != nil || consumer != nil || (scene != nil && inputs.scenario.structure != nil) {
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
                    if let consumer {
                        // From the report `lag` frames back, always in by now, so that the air
                        // sent, and the result, do not depend on how the two sides keep time.
                        let basis =
                            consumer.report(after: max(frame - consumerLag - 1, -1)) ?? consumer.report
                        let region = basis.region(
                            for: frame, interval: interval, domain: inputs.scenario.domainSize,
                            cellSize: solver.grid.cellSize)
                        consumer.send(solver.airSlice(region: region.box, stride: region.stride))
                    }
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
        let running = streamStart.duration(to: .now)
        let fragments = try await consumer?.finish(frameInterval: interval)
        let stream = consumer.map { consumer in
            String(
                format:
                    "%d frames, %.1f MB of air (%.0f MB/s); the run waited %.2f s of %.2f s for the consumer",
                consumer.sent, Double(consumer.bytes) / 1e6,
                Double(consumer.bytes) / 1e6 / max(running.seconds, 1e-9), held.seconds, running.seconds)
        }
        if let fragments {
            let edges = fragments.masses.map { cbrt($0 / (options.fragments?.fragmentDensity ?? 7850)) }
            let count = fragments.fragmentCount
            scene?.addPoints(
                "Fragments", frames: fragments.frames.map { Array($0.prefix(count)) }, widths: edges,
                colour: SIMD3(0.15, 0.15, 0.17))
            let tracers = (fragments.frames.first?.count ?? count) - count
            if tracers > 0 {
                scene?.addPoints(
                    "Tracers", frames: fragments.frames.map { Array($0.dropFirst(count)) },
                    widths: [Float](repeating: 0.1, count: tracers), colour: SIMD3(0.9, 0.9, 0.95))
            }
        }
        try scene?.finish()
        finished = true
        // The project's own inputs, with the new run among its saved ones.
        document.savedRuns = model.savedRuns
        return (run, document, fragments, stream)
    }

    /// How many frames a consumer may fall behind before the run waits for it.
    static let consumerLag = 4

    /// The consumer to fly fragments: on this Mac's CPU, or on another Mac over SSH.
    static func makeConsumer(_ placement: String, spec: FragmentSpec, scenario: Scenario) async throws
        -> any LiveConsumer
    {
        let scene = FragmentScene(scenario)
        guard placement != "local" else { return LocalLiveConsumer(spec: spec, scene: scene) }
        let client = try await RemoteSweepWorker.connect(host: placement)
        return RemoteLiveConsumer(client: client, spec: spec, scene: scene)
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
            let result = try await execute(options)
            let wall = start.duration(to: .now)
            print(
                summary(
                    result.run,
                    wallSeconds: Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18
                ))
            if let fragments = result.fragments { print("  " + fragments.summary) }
            if let stream = result.stream { print("  " + stream) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Run failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
