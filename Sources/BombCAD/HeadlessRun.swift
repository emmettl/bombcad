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
                           [--duration <seconds>] [--usd <scene.usda>] [--vdb <folder>
                           [--vdb-fields overpressure,shock,peak,impulse]] [--frame-interval <ms>]
                           [--fragments <spec.json> [--fragment-results <file.json>]]
                           [--thermal <spec.json> [--thermal-results <file.json>]]
                           [--cloud <spec.json> [--sounding <sounding.csv>] [--cloud-results <file.json>]]
                           [--ground-shock <spec.json> [--ground-results <file.json>]]
                           [--envelope-results <file.json>]
                           [--consumer <ssh host> | fragments=<where>,thermal=<where>,ground=<where>]

        Runs the project's simulation to its duration and prints a summary. --out writes a copy of
        the project with the run added to its saved runs; --csv writes the gauge and deflection
        histories. --usd writes the scene for rendering elsewhere, with the structure's surface,
        and --vdb the air as OpenVDB volumes, a file a frame, both every --frame-interval
        milliseconds of simulated time (1 by default); --vdb-fields picks the volumes' grids,
        overpressure and shock unless it says otherwise. --fragments flies a cased charge's fragments
        and tracers through the blast, one way, frame by frame; they go into the USD scene and, with
        --fragment-results, a JSON file. --envelope-results writes individual stationary-building
        surface records as JSON; scenes with only envelopes collect compact surface summaries in kept
        runs and CSV too.
        --thermal reckons the fireball's thermal radiation on the ground and the scene's faces,
        frame by frame; the receivers go into the USD scene and, with --thermal-results, a JSON
        file. --cloud hands the hot gas left at the end of the run over to a model of the
        fireball's rise and cloud, followed for minutes after; the cloud goes into the USD scene,
        after the run's frames, and, with --cloud-results, a JSON file; --sounding reads a measured
        atmosphere for it, in the University of Wyoming archive's comma-separated values, in place
        of the standard one. --ground-shock estimates
        the ground's shaking under chosen points from the overpressure the run records on the
        ground, frame by frame; --ground-results writes it as JSON. Each of these three runs here
        unless --consumer places it on another Mac over SSH, <where> being local or an SSH host;
        models on one Mac share a connection to it, and a host alone places the fragments.
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
        /// A new folder for the air's volumes, one OpenVDB file a frame, and their grids.
        var vdb: URL?
        var vdbFields = BlastSolver.defaultVolumeFields
        /// A cased charge's fragments to fly through the blast, where, and where their results go.
        var fragments: FragmentSpec?
        /// Where each consumer runs, by name (fragments, thermal, ground): "local", or an SSH
        /// host; here unless named.
        var consumers: [String: String] = [:]
        var fragmentResults: URL?
        /// The fireball's thermal radiation on the scene, and where its results go.
        var thermal: ThermalSpec?
        var thermalResults: URL?
        /// The fireball's rise and cloud after the run, and where its results go.
        var cloud: CloudSpec?
        var cloudResults: URL?
        /// Ground points whose shaking to estimate from the air on the ground, and where the
        /// estimates go.
        var groundShock: GroundShockSpec?
        var envelopeResults: URL?
        var groundResults: URL?
        /// Whole milliseconds of simulated time between frames of `usd` and `vdb`.
        var frameInterval = 1

        /// The consumers `--consumer` can place.
        static let consumerNames = ["fragments", "thermal", "ground"]

        /// Where the consumer `name` runs: "local" or an SSH host.
        func place(_ name: String) -> String { consumers[name] ?? "local" }

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
                            "vdb-fields", "fragments",
                            "consumer", "fragment-results", "thermal", "thermal-results", "cloud",
                            "cloud-results", "sounding", "ground-shock", "ground-results", "envelope-results",
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
            options.envelopeResults = values["envelope-results"].map { URL(filePath: $0) }
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
            if let text = values["vdb-fields"] {
                guard options.vdb != nil else { throw ProjectFileError.invalid("--vdb-fields needs --vdb.") }
                let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !fields.isEmpty, Set(fields).count == fields.count,
                    fields.allSatisfy(BlastSolver.volumeFields.contains)
                else {
                    throw ProjectFileError.invalid(
                        "--vdb-fields takes some of "
                            + BlastSolver.volumeFields.joined(separator: ", ") + ", each once.")
                }
                options.vdbFields = fields
            }
            if let path = values["fragments"] {
                let spec = try JSONDecoder().decode(
                    FragmentSpec.self, from: Data(contentsOf: URL(filePath: path)))
                try spec.validate()
                options.fragments = spec
            }
            options.fragmentResults = values["fragment-results"].map { URL(filePath: $0) }
            if options.fragmentResults != nil, options.fragments == nil {
                throw ProjectFileError.invalid("--fragment-results needs --fragments.")
            }
            if let path = values["thermal"] {
                let spec = try JSONDecoder().decode(
                    ThermalSpec.self, from: Data(contentsOf: URL(filePath: path)))
                try spec.validate()
                options.thermal = spec
            }
            options.thermalResults = values["thermal-results"].map { URL(filePath: $0) }
            if options.thermalResults != nil, options.thermal == nil {
                throw ProjectFileError.invalid("--thermal-results needs --thermal.")
            }
            if let path = values["cloud"] {
                var spec = try JSONDecoder().decode(
                    CloudSpec.self, from: Data(contentsOf: URL(filePath: path)))
                if let sounding = values["sounding"] {
                    spec.sounding = try CloudSounding(
                        wyomingCSV: String(contentsOf: URL(filePath: sounding), encoding: .utf8))
                }
                try spec.validate()
                options.cloud = spec
            } else if values["sounding"] != nil {
                throw ProjectFileError.invalid("--sounding needs --cloud.")
            }
            options.cloudResults = values["cloud-results"].map { URL(filePath: $0) }
            if options.cloudResults != nil, options.cloud == nil {
                throw ProjectFileError.invalid("--cloud-results needs --cloud.")
            }
            if let path = values["ground-shock"] {
                let spec = try JSONDecoder().decode(
                    GroundShockSpec.self, from: Data(contentsOf: URL(filePath: path)))
                try spec.validate()
                options.groundShock = spec
            }
            options.groundResults = values["ground-results"].map { URL(filePath: $0) }
            if options.groundResults != nil, options.groundShock == nil {
                throw ProjectFileError.invalid("--ground-results needs --ground-shock.")
            }
            if let value = values["consumer"] {
                // A bare place is the fragments', as before there were others.
                let pairs =
                    value.contains("=")
                    ? value.split(separator: ",").map(String.init) : ["fragments=\(value)"]
                for pair in pairs {
                    let parts = pair.split(separator: "=", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard parts.count == 2, Self.consumerNames.contains(parts[0]),
                        options.consumers[parts[0]] == nil
                    else {
                        throw ProjectFileError.invalid(
                            "--consumer takes a place, or fragments=, thermal= and ground= each with one.")
                    }
                    let needed = [
                        "fragments": "--fragments", "thermal": "--thermal", "ground": "--ground-shock",
                    ]
                    guard
                        parts[0] == "fragments"
                            ? options.fragments != nil
                            : parts[0] == "thermal" ? options.thermal != nil : options.groundShock != nil
                    else {
                        throw ProjectFileError.invalid("--consumer \(parts[0])= needs \(needed[parts[0]]!).")
                    }
                    if parts[1] != "local" { try RemoteSweepWorker.validate(parts[1]) }
                    options.consumers[parts[0]] = parts[1]
                }
            }
            if let text = values["frame-interval"] {
                guard
                    options.usd != nil || options.vdb != nil || options.fragments != nil
                        || options.thermal != nil || options.groundShock != nil
                else {
                    throw ProjectFileError.invalid(
                        "--frame-interval needs --usd, --vdb, --fragments, --thermal or --ground-shock.")
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
            for url in [
                options.out, options.csv, options.usd, options.vdb, options.fragmentResults,
                options.thermalResults, options.cloudResults, options.groundResults, options.envelopeResults,
            ]
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
        run: SavedSimulationRun, fragments: FragmentResult?, streams: [String], thermal: ThermalResult?,
        cloud: CloudResult?, ground: GroundShockResult?, envelopes: Data?
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
        if let url = options.thermalResults, let thermal = result.thermal {
            try JSONEncoder().encode(thermal).write(to: url, options: .withoutOverwriting)
        }
        if let url = options.cloudResults, let cloud = result.cloud {
            try JSONEncoder().encode(cloud).write(to: url, options: .withoutOverwriting)
        }
        if let url = options.groundResults, let ground = result.ground {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ground).write(to: url, options: .withoutOverwriting)
        }
        if let url = options.envelopeResults, let data = result.envelopes {
            try data.write(to: url, options: .withoutOverwriting)
        }
        return (
            result.run, result.fragments, result.streams, result.thermal, result.cloud, result.ground,
            result.envelopes
        )
    }

    /// Runs `document` as `options` change it, with any `--usd` and `--vdb` exports, and returns
    /// the kept run and the document, its own inputs unchanged, with the run added to its saved
    /// runs. `progress` is told the fraction of the simulated time reached, now and then.
    /// `connect` starts a worker on a host named in `options.consumers`; tests stand in-process
    /// workers in for them. Cancelling the task stops the run.
    static func perform(
        _ document: ProjectDocument, options: Options, progress: ((Double) -> Void)? = nil,
        consumer injected: (any FrameConsumer)? = nil,
        connect: (String) async throws -> SweepWorkerClient = {
            try await RemoteSweepWorker.connect(host: $0)
        }
    ) async throws -> (
        run: SavedSimulationRun, document: ProjectDocument, fragments: FragmentResult?, streams: [String],
        thermal: ThermalResult?, cloud: CloudResult?, ground: GroundShockResult?, envelopes: Data?
    ) {
        var document = document
        let inputs = try inputs(for: document, options: options)
        if options.envelopeResults != nil {
            guard !inputs.scenario.envelopeObjects.isEmpty, inputs.scenario.structuralObjects.isEmpty else {
                throw ProjectFileError.invalid(
                    "--envelope-results requires a scene containing only stationary envelopes.")
            }
        }
        try options.groundShock?.validate(domain: inputs.scenario.domainSize)
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
        // A run here flies fragments as `options` says, not as the project's live view does.
        model.fragmentSpec = nil
        model.groundShockSpec = nil
        let interval = Double(options.frameInterval) * SimulationModel.structureSampleInterval
        // Frames fall on the samples every millisecond, where a run with a structure stops anyway,
        // so exporting does not change the run. Without a structure, only volumes, fragments, the
        // radiation and ground shock ask for frames, and the run then stops at each one, ending a
        // time step there.
        let framed =
            options.vdb != nil || options.fragments != nil || injected != nil || options.thermal != nil
            || options.groundShock != nil || (options.usd != nil && inputs.scenario.structure != nil)
        // Before the inputs load, which sets the first sample time. The cloud needs only the
        // last sample, at the end of the run, which then stops nowhere else.
        model.airSampleInterval = framed || options.cloud == nil ? interval : inputs.settings.duration
        model.applyExperimentInputs(inputs)
        try await waitUntil(model) { model.experimentIsReady }
        if options.envelopeResults != nil, model.envelopeExposure.isEmpty {
            throw ProjectFileError.invalid(model.envelopeExposureStatus)
        }
        let scene = try options.usd.map { url in
            try USDSceneWriter(
                url: url, scenario: inputs.scenario, frameInterval: interval,
                camera: .init(
                    eye: model.camera.eye, target: model.camera.target,
                    verticalFieldOfView: model.camera.fieldOfView),
                volumeFields: options.vdb == nil ? [] : options.vdbFields)
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
        // The models fed each frame, each here or on another Mac, those on the same Mac sharing
        // one connection to it.
        var clients: [String: SweepWorkerClient] = [:]
        defer { for client in clients.values { client.close() } }
        var feeds: [Feed] = []
        defer { if !finished { for feed in feeds { feed.consumer.cancel() } } }
        let consumerScene = FragmentScene(inputs.scenario)
        var kinds: [(name: String, kind: ConsumerKind)] = []
        if injected == nil, let spec = options.fragments {
            kinds.append(("fragments", .fragments(spec, consumerScene, live: false)))
        }
        if let spec = options.thermal {
            kinds.append(("thermal", .thermal(spec, consumerScene, live: false)))
        }
        if let spec = options.groundShock { kinds.append(("ground", .groundShock(spec, live: false))) }
        if let injected {
            feeds.append(Feed(injected, place: injected is RemoteFrameConsumer ? "on a worker" : "here"))
        }
        for (name, kind) in kinds {
            let place = options.place(name)
            if place == "local" {
                feeds.append(Feed(LocalFrameConsumer(kind), place: "here"))
            } else {
                if clients[place] == nil { clients[place] = try await connect(place) }
                // Should that Mac fail, the model carries on here from the frames kept.
                feeds.append(
                    Feed(
                        try ResilientFrameConsumer(client: clients[place]!, kind: kind, ownsClient: false),
                        place: "on \(place)"))
            }
        }
        let fragmentFeed = feeds.first { if case .fragments = $0.consumer.kind { true } else { false } }
        let streamStart = ContinuousClock.now
        if !feeds.isEmpty {
            // A consumer may fall up to four frames behind; then the run waits for it.
            model.holdBatches = {
                var hold = false
                for feed in feeds {
                    let behind = feed.consumer.sent - 1 - feed.consumer.report.frame > consumerLag
                    if behind, feed.heldSince == nil { feed.heldSince = .now }
                    if !behind, let since = feed.heldSince {
                        feed.held += since.duration(to: .now)
                        feed.heldSince = nil
                    }
                    hold = hold || behind
                }
                return hold
            }
        }
        if framed, fragmentFeed != nil || options.thermal != nil {
            // The GPU cuts out what a frame's consumers need at the end of the batch that lands on
            // it, as `onSample` will ask for it, rather than the CPU while the GPU waits.
            model.prepareBatch = { solver, limit in
                let index = (limit / interval).rounded()
                guard abs(limit - index * interval) < 1e-6 else {
                    solver.frameRequest = FrameRequest()
                    return
                }
                var request = FrameRequest(thermal: options.thermal)
                if let consumer = fragmentFeed?.consumer {
                    let frame = Int(index)
                    let basis = consumer.report(after: max(frame - consumerLag - 1, -1)) ?? consumer.report
                    let region = basis.region(
                        for: frame, interval: interval, domain: inputs.scenario.domainSize,
                        cellSize: solver.grid.cellSize)
                    request.airSlice = AirSliceRequest(region: region.box, stride: region.stride)
                }
                solver.frameRequest = request
            }
        }
        var handOver: CloudHandOver?
        let end = inputs.settings.duration
        if framed || options.cloud != nil {
            var frame = 0
            model.onSample = { solver in
                if let spec = options.cloud, solver.time >= end - 1e-9 {
                    handOver = solver.cloudHandOver(hotterThan: spec.handOverTemperature)
                    handOver?.chargeMass = Double(
                        ([inputs.scenario.charge] + (inputs.scenario.additionalCharges ?? [])).reduce(0) {
                            $0 + $1.mass
                        })
                }
                guard framed else { return }
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
                        try OpenVDBWriter.write(solver.volumeGrids(fields: options.vdbFields), to: file)
                        volume = options.usd.map { assetPath(of: file, from: $0) }
                    }
                    try scene?.append(solver.structureSurface(), volume: volume)
                    for feed in feeds {
                        let start = ContinuousClock.now
                        switch feed.consumer.kind {
                        case .fragments:
                            // From the report `lag` frames back, always in by now, so that the air
                            // sent, and the result, do not depend on how the two sides keep time.
                            let basis =
                                feed.consumer.report(after: max(frame - consumerLag - 1, -1))
                                ?? feed.consumer.report
                            let region = basis.region(
                                for: frame, interval: interval, domain: inputs.scenario.domainSize,
                                cellSize: solver.grid.cellSize)
                            feed.consumer.send(
                                .air(solver.airSlice(region: region.box, stride: region.stride)))
                        case .thermal(let spec, _, _):
                            feed.consumer.send(
                                .fireball(solver.fireball(for: spec)))
                        case .groundShock(let spec, _):
                            let region = GroundShockConsumer(spec: spec).region(
                                cellSize: solver.grid.cellSize)
                            feed.consumer.send(
                                .ground(solver.groundSlice(low: region.low, high: region.high)))
                        }
                        feed.cost += start.duration(to: .now)
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
        var fragments: FragmentResult?
        var thermalResult: ThermalResult?
        var groundResult: GroundShockResult?
        var streams: [String] = []
        for feed in feeds {
            switch try await feed.consumer.finish(frameInterval: interval) {
            case .fragments(let result): fragments = result
            case .thermal(let result): thermalResult = result
            case .groundShock(var result):
                // What feeding it cost the run.
                result.seconds = feed.cost.seconds
                groundResult = result
            }
            let consumer = feed.consumer
            let name = consumer.kind.name.prefix(1).uppercased() + consumer.kind.name.dropFirst()
            streams.append(
                String(
                    format:
                        "%@ %@: %d frames, %.1f MB (%.0f MB/s), %.2f ms a frame to feed and %.2f ms to run; the run waited %.2f s of %.2f s for it",
                    name, feed.place, consumer.sent, Double(consumer.bytes) / 1e6,
                    Double(consumer.bytes) / 1e6 / max(running.seconds, 1e-9),
                    1000 * feed.cost.seconds / Double(max(consumer.sent, 1)),
                    1000 * consumer.seconds / Double(max(consumer.sent, 1)), feed.held.seconds,
                    running.seconds)
                    + ((consumer as? ResilientFrameConsumer)?.fallback.map {
                        "; here after frame \($0.frame + 1), that Mac having failed: \($0.reason)"
                    } ?? ""))
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
        if let thermalResult {
            let spacing = min(thermalResult.spec.surfaceSpacing, thermalResult.spec.groundSpacing)
            scene?.addPoints(
                "Thermal", frames: [thermalResult.receivers.map(\.position)],
                widths: [Float](repeating: spacing / 2, count: thermalResult.receivers.count),
                colour: SIMD3(0.95, 0.55, 0.2),
                values: [
                    ("fluence", thermalResult.fluence.map { $0 / 1000 }),
                    ("peakIrradiance", thermalResult.peakIrradiance.map { $0 / 1000 }),
                ])
        }
        if let groundResult, let spec = options.groundShock {
            scene?.addGroundShock(groundResult, spec: spec)
        }
        var cloud: CloudResult?
        if let spec = options.cloud {
            guard let handOver else {
                throw ProjectFileError.invalid("The run ended before the cloud's hand-over.")
            }
            let result = CloudResult(spec: spec, handOver: handOver)
            scene?.addCloud(result.frames(), secondsPerFrame: spec.frameInterval)
            cloud = result
        }
        try scene?.finish()
        finished = true
        // The project's own inputs, with the new run among its saved ones.
        document.savedRuns = model.savedRuns
        let envelopeData = try options.envelopeResults.map { _ in try model.envelopeResultsData() }
        return (run, document, fragments, streams, thermalResult, cloud, groundResult, envelopeData)
    }

    /// A consumer the run feeds each frame, where it runs, and what it has cost the run: the time
    /// spent cutting out and handing over its frames, and waiting for it to catch up.
    @MainActor final class Feed {
        let consumer: any FrameConsumer
        let place: String
        var cost = Duration.zero
        var held = Duration.zero
        var heldSince: ContinuousClock.Instant?

        init(_ consumer: any FrameConsumer, place: String) {
            self.consumer = consumer
            self.place = place
        }
    }

    /// How many frames a consumer may fall behind before the run waits for it.
    static let consumerLag = 4

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
                + run.scenario.sourceDescription,
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
            for stream in result.streams { print("  " + stream) }
            for line in result.thermal?.summary ?? [] { print("  " + line) }
            for line in result.cloud?.summary ?? [] { print("  " + line) }
            if let ground = result.ground { print("  " + ground.summary) }
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
