import BlastCore
import DocumentKit
import Foundation

/// `BombCAD ensemble`: reruns validation cases with their uncertain inputs sampled from stated
/// distributions, here and on other Macs, as `BombCAD sweep` shares its cases, and reports each
/// output's spread against what was measured (see `ValidationEnsemble`).
@MainActor
enum HeadlessEnsemble {
    static let usage = """
        Usage: BombCAD ensemble <case>[,<case>…] [--samples <n>] [--seed <n>] [--worker <ssh host>]…
                                [--local-workers <n>] [--no-default-workers] [--ratio <times slower>]
                                [--out <folder>] [--rounding-ensemble] [--design <file.json>]
               BombCAD ensemble --list

        Samples each case's uncertain inputs by a Latin hypercube, seeded so that the same seed
        gives the same samples, and runs the case once with every input at its middle value and
        once for each sample (16 by default; 0 runs the middle alone), here and, with --worker (once per host), on other
        Macs reached over SSH; --local-workers adds workers on this Mac. Without --worker, the Macs
        named as "workers" in ~/.config/bombcad/remote.json are taken when free, unless
        --no-default-workers. Prints each output's
        mean, spread and percentiles, and whether the measurement falls within the 5th to 95th
        percentiles; --out writes each case's samples and results as JSON into a new folder, each
        result as it comes in, and given a folder an ensemble cut short was writing, carries on
        from the results already there.
        --rounding-ensemble runs each case with every input at its middle value instead, once
        with the kernels' default rounding, once without fused multiply-adds and once with relaxed
        math, and prints each output's lowest to highest with the default's value: results after
        failure spread by about that between any two builds whose arithmetic rounds differently.
        --design runs each case once at each point of a JSON list of values (such as
        [{"afterburnTime": 0.01, "ft": 1, "glassK": 1}]), its own inputs at their middle values,
        and prints each run's outputs as a line "DESIGN {json}": the runs a calibration's
        emulators are fitted to (docs/calibration.md).
        --list names the cases and their inputs.
        """

    static func main(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if arguments == ["--list"] {
            for line in ValidationEnsemble.listing { print(line) }
            return 0
        }
        do {
            var options = try Options.parse(arguments.filter { $0 != "--no-default-workers" })
            if options.workers.isEmpty, !arguments.contains("--no-default-workers") {
                options.defaultWorkers = RemoteConfig.load().workers
            }
            // Unbuffered, so that each case shows as it finishes, also when written to a file.
            let report = try await run(options) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            if let folder = options.out {
                try write(report, to: folder)
                print("Written to \(folder.path)")
            }
            return report.failures.isEmpty ? 0 : 1
        } catch {
            FileHandle.standardError.write(
                Data("Ensemble failed: \(error.localizedDescription)\n\n\(usage)\n".utf8))
            return 2
        }
    }

    struct Options: Equatable {
        var cases: [String] = []
        var samples = 16
        var seed: UInt64 = 1
        var workers: [String] = []
        /// Macs taken only if free when the ensemble starts (see `RemoteGate`).
        var defaultWorkers: [String] = []
        var localWorkers = 0
        var ratio: Double?
        var out: URL?
        /// Each case's middle run with each of the kernels' roundings, in place of the samples.
        var roundingEnsemble = false
        /// Points whose values each case runs at, its own inputs at their middle values, in place of
        /// the samples.
        var design: [[String: Double]]?

        static func parse(_ arguments: [String]) throws -> Options {
            var options = Options()
            var positional: [String] = []
            var seen: Set<String> = []
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--rounding-ensemble" {
                    guard !options.roundingEnsemble else {
                        throw ProjectFileError.invalid("Give \(argument) once.")
                    }
                    options.roundingEnsemble = true
                    index += 1
                    continue
                }
                guard argument.hasPrefix("--") else {
                    positional.append(argument)
                    index += 1
                    continue
                }
                let key = String(argument.dropFirst(2))
                guard index + 1 < arguments.count else {
                    throw ProjectFileError.invalid("Give \(argument) a value.")
                }
                let value = arguments[index + 1]
                index += 2
                guard key == "worker" || seen.insert(key).inserted else {
                    throw ProjectFileError.invalid("Give \(argument) once.")
                }
                switch key {
                case "worker":
                    try RemoteSweepWorker.validate(value)
                    guard !options.workers.contains(value) else {
                        throw ProjectFileError.invalid("Name each --worker host once.")
                    }
                    options.workers.append(value)
                case "samples":
                    guard let count = Int(value), (0...1000).contains(count) else {
                        throw ProjectFileError.invalid("--samples takes a count from 0 to 1,000.")
                    }
                    options.samples = count
                case "seed":
                    guard let seed = UInt64(value) else {
                        throw ProjectFileError.invalid("--seed takes a whole number.")
                    }
                    options.seed = seed
                case "design":
                    let data = try Data(contentsOf: URL(filePath: value))
                    guard let points = try? JSONDecoder().decode([[String: Double]].self, from: data),
                        !points.isEmpty
                    else {
                        throw ProjectFileError.invalid(
                            "--design takes a JSON list of points, each its values.")
                    }
                    options.design = points
                case "local-workers":
                    guard let count = Int(value), (0...8).contains(count) else {
                        throw ProjectFileError.invalid("--local-workers takes a count from 0 to 8.")
                    }
                    options.localWorkers = count
                case "ratio":
                    guard let ratio = Double(value), ratio > 0 else {
                        throw ProjectFileError.invalid("--ratio takes a positive number.")
                    }
                    options.ratio = ratio
                case "out":
                    let url = URL(filePath: value, directoryHint: .isDirectory)
                    guard
                        !FileManager.default.fileExists(atPath: url.path)
                            || FileManager.default.fileExists(
                                atPath: url.appending(path: "progress.jsonl").path)
                    else {
                        throw ProjectFileError.invalid(
                            "--out must be a new folder, or one an ensemble was writing.")
                    }
                    options.out = url
                default:
                    throw ProjectFileError.invalid("Unknown option \(argument).")
                }
            }
            guard positional.count == 1 else { throw ProjectFileError.invalid("Name the cases to run.") }
            if options.design != nil,
                options.roundingEnsemble || seen.contains("samples") || seen.contains("seed")
            {
                throw ProjectFileError.invalid(
                    "--design runs its own points; leave out --samples, --seed and --rounding-ensemble.")
            }
            if options.roundingEnsemble, seen.contains("samples") || seen.contains("seed") {
                throw ProjectFileError.invalid(
                    "--rounding-ensemble runs each case's middle inputs; leave out --samples and --seed.")
            }
            options.cases = positional[0].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let known = Set(ValidationEnsemble.cases.map(\.id))
            for name in options.cases where !known.contains(name) {
                throw ProjectFileError.invalid(
                    "No case \(name); the cases are \(ValidationEnsemble.cases.map(\.id).joined(separator: ", "))."
                )
            }
            guard Set(options.cases).count == options.cases.count else {
                throw ProjectFileError.invalid("Name each case once.")
            }
            return options
        }
    }

    /// Every case's samples and what they came to.
    struct Report: Codable, Sendable {
        struct Case: Codable, Sendable {
            var id: String
            var samples: [EnsembleSample]
            /// By sample, in order; nil where the sample failed everywhere.
            var outcomes: [EnsembleOutcome?]
            /// Where each sample ran: "here" or a host.
            var places: [String?]
        }
        var seed: UInt64
        var cases: [Case]
        var failures: [String] = []
        /// Default workers that were not free.
        var notes: [String] = []
        var seconds = 0.0
    }

    /// Runs `options`' cases, here and on its workers (`connect` starts one; tests stand
    /// in-process workers in), and reports each case as it finishes to `log`.
    static func run(
        _ options: Options, log: @escaping (String) -> Void = { _ in },
        connect: @escaping @MainActor @Sendable (String, RemoteGate?) async throws -> SweepWorkerClient = {
            try await RemoteSweepWorker.connect(host: $0, gate: $1)
        },
        runHere: @escaping @Sendable (EnsembleSample) throws -> EnsembleOutcome = {
            try ValidationEnsemble.run($0)
        }
    ) async throws -> Report {
        var jobs: [(caseIndex: Int, sample: EnsembleSample)] = []
        var report = Report(seed: options.seed, cases: [])
        // Samples already run into the same folder, by an ensemble cut short, are not run again.
        let progress = try options.out.map { try Progress(folder: $0) }
        let done = progress?.done ?? []
        for (caseIndex, id) in options.cases.enumerated() {
            let samples =
                try options.design.map { try ValidationEnsemble.designSamples(case: id, points: $0) }
                ?? (options.roundingEnsemble
                    ? try ValidationEnsemble.roundingSamples(case: id)
                    : try ValidationEnsemble.samples(case: id, count: options.samples, seed: options.seed))
            var item = Report.Case(
                id: id, samples: samples, outcomes: Array(repeating: nil, count: samples.count),
                places: Array(repeating: nil, count: samples.count))
            for sample in samples {
                if let entry = done.first(where: { $0.sample == sample }) {
                    item.outcomes[sample.index] = entry.outcome
                    item.places[sample.index] = entry.place
                } else {
                    jobs.append((caseIndex, sample))
                }
            }
            report.cases.append(item)
        }
        // What each case's outputs are compared with, for the calibration's script.
        if options.design != nil {
            for id in options.cases {
                guard let info = ValidationEnsemble.cases.first(where: { $0.id == id }) else { continue }
                var measured: [String: [Double]] = [:]
                for output in info.outputs {
                    if let value = output.measured {
                        measured[output.key] = [value] + (output.measuredVariation.map { [$0] } ?? [])
                    }
                }
                if let data = try? JSONEncoder().encode([id: measured]),
                    let text = String(data: data, encoding: .utf8)
                {
                    log("MEASURED " + text)
                }
            }
        }
        let costs = jobs.map { ValidationEnsemble.estimatedSeconds(case: report.cases[$0.caseIndex].id) }
        var schedule = SweepSchedule(
            costs: costs, workers: options.workers.count + options.defaultWorkers.count + options.localWorkers
        )
        if let ratio = options.ratio { schedule.ratio = ratio }
        let shared = Shared(schedule, report: report)
        let start = ContinuousClock.now
        for (caseIndex, item) in report.cases.enumerated() {
            let left = jobs.filter { $0.caseIndex == caseIndex }.count
            shared.remaining[caseIndex] = left
            if left == 0 { for line in summary(item) { log(line) } }
        }

        /// The job is done, here or elsewhere, with `outcome` or without; a case is reported
        /// once every sample of it is.
        func finished(_ job: Int, _ outcome: EnsembleOutcome?, at place: String) {
            let (caseIndex, sample) = jobs[job]
            shared.report.cases[caseIndex].outcomes[sample.index] = outcome
            shared.report.cases[caseIndex].places[sample.index] = outcome == nil ? nil : place
            if let outcome {
                progress?.append(Progress.Entry(sample: sample, outcome: outcome, place: place))
                if options.design != nil,
                    let data = try? JSONEncoder().encode(
                        Progress.Entry(sample: sample, outcome: outcome, place: place)),
                    let text = String(data: data, encoding: .utf8)
                {
                    log("DESIGN " + text)
                }
            }
            shared.remaining[caseIndex, default: 0] -= 1
            if shared.remaining[caseIndex] == 0 {
                for line in summary(shared.report.cases[caseIndex]) { log(line) }
            }
        }

        // Each worker: a host, gated if taken by default, or none for one on this Mac.
        let gate = RemoteConfig.load().gate("BombCAD ensemble from \(ProcessInfo.processInfo.hostName)")
        let places: [(host: String?, gate: RemoteGate?)] =
            options.workers.map { ($0, nil) } + options.defaultWorkers.map { ($0, gate) }
            + Array(repeating: (nil, nil), count: options.localWorkers)
        let remotes = places.enumerated().map { number, place in
            Task { @MainActor in
                let worker: SweepWorkerClient
                do {
                    if let host = place.host {
                        worker = try await connect(host, place.gate)
                    } else {
                        worker = try await RemoteSweepWorker.connectHere(
                            name:
                                "local worker \(number - options.workers.count - options.defaultWorkers.count + 1)"
                        )
                    }
                    _ = try await worker.start()
                } catch {
                    if let host = place.host, place.gate != nil {
                        shared.report.notes.append("\(host) not used: \(error.localizedDescription)")
                        log("\(host) not used: \(error.localizedDescription)")
                    } else {
                        shared.report.failures.append("A worker did not start: \(error.localizedDescription)")
                    }
                    return
                }
                defer { worker.close() }
                shared.schedule.join(number)
                defer { shared.schedule.leave(number) }
                while !Task.isCancelled {
                    guard let job = shared.schedule.next(.worker(number)) else {
                        if shared.schedule.workersBusy || !shared.schedule.isEmpty && shared.localBusy {
                            try? await Task.sleep(for: .milliseconds(50))
                            continue
                        }
                        break
                    }
                    let begun = ContinuousClock.now
                    do {
                        // A worker that never answers gives its job back, however slow its Mac.
                        let sample = jobs[job].sample
                        let limit = 300 + 30 * ValidationEnsemble.estimatedSeconds(case: sample.caseID)
                        let outcome = try await withThrowingTaskGroup(of: EnsembleOutcome?.self) { group in
                            group.addTask { try await worker.run(sample) }
                            group.addTask {
                                try await Task.sleep(for: .seconds(limit))
                                return nil
                            }
                            defer { group.cancelAll() }
                            guard let first = try await group.next(), let outcome = first else {
                                throw ProjectFileError.invalid("No answer in \(Int(limit)) s.")
                            }
                            return outcome
                        }
                        shared.schedule.finish(.worker(number), seconds: begun.duration(to: .now).seconds)
                        finished(job, outcome, at: worker.name)
                    } catch {
                        // Back to the queue, for this Mac or another worker; this one takes no more.
                        shared.schedule.fail(number)
                        shared.report.failures.append("\(worker.name) stopped: \(error.localizedDescription)")
                        return
                    }
                }
            }
        }
        // This Mac takes cases too, one at a time, off the main actor.
        while true {
            guard let job = shared.schedule.next(.local) else {
                if !shared.schedule.isEmpty || shared.schedule.workersBusy {
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                break
            }
            shared.localBusy = true
            let sample = jobs[job].sample
            let begun = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) { Result { try runHere(sample) } }
                .value
            shared.localBusy = false
            shared.schedule.finish(.local, seconds: begun.duration(to: .now).seconds)
            switch result {
            case .success(let outcome): finished(job, outcome, at: "here")
            case .failure(let error):
                shared.report.failures.append(
                    "\(sample.caseID) sample \(sample.index): \(error.localizedDescription)")
                finished(job, nil, at: "here")
            }
        }
        for remote in remotes { await remote.value }
        shared.report.seconds = start.duration(to: .now).seconds
        return shared.report
    }

    /// Each sample's outcome, kept in `progress.jsonl` in the output folder as it comes in.
    final class Progress {
        struct Entry: Codable {
            var sample: EnsembleSample
            var outcome: EnsembleOutcome
            var place: String
        }
        let url: URL
        private(set) var done: [Entry] = []

        init(folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appending(path: "progress.jsonl")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                done = text.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(Entry.self, from: Data($0.utf8))
                }
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }

        func append(_ entry: Entry) {
            guard let data = try? JSONEncoder().encode(entry), let handle = try? FileHandle(forWritingTo: url)
            else {
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
            done.append(entry)
        }
    }

    @MainActor private final class Shared {
        var schedule: SweepSchedule
        var report: Report
        var remaining: [Int: Int] = [:]
        var localBusy = false
        init(_ schedule: SweepSchedule, report: Report) {
            self.schedule = schedule
            self.report = report
        }
    }

    /// Lines for a case: each output's measurement, the run with every input at its middle, and
    /// the samples' mean, spread and 5th to 95th percentiles.
    static func summary(_ item: Report.Case) -> [String] {
        guard let info = ValidationEnsemble.cases.first(where: { $0.id == item.id }) else { return [] }
        if item.samples.contains(where: { $0.rounding != nil }) { return roundingSummary(item, info) }
        let ran = item.outcomes.compactMap { $0 }
        var lines = [
            "\(info.title): \(ran.count) of \(item.samples.count) runs, "
                + "\(item.places.compactMap { $0 }.filter { $0 != "here" }.count) on other Macs"
        ]
        for output in info.outputs {
            let middle = item.outcomes.first.flatMap { $0 }?.outputs[output.key]
            let values = item.outcomes.dropFirst().compactMap { $0?.outputs[output.key] }
            guard let stats = EnsembleStatistics(values) else {
                lines.append(
                    "  \(output.name): middle inputs \(middle.map { String(format: "%.3g", $0) } ?? "–") \(output.unit)"
                        + (output.measured.map { String(format: ", measured %.3g", $0) } ?? ""))
                continue
            }
            var line = String(
                format: "  %@: %.3g %@ (middle inputs %@), mean %.3g ± %.2g (%.0f%%), 5–95%% %.3g–%.3g",
                output.name, stats.p50, output.unit, middle.map { String(format: "%.3g", $0) } ?? "–",
                stats.mean,
                stats.deviation, 100 * stats.variation, stats.p5, stats.p95)
            let runs = item.outcomes.dropFirst().compactMap { $0 }.count
            if values.count < runs { line += " (in \(values.count) of \(runs) runs)" }
            if let measured = output.measured {
                let inside = measured >= stats.p5 && measured <= stats.p95
                line += String(
                    format: "; measured %.3g, %@", measured,
                    inside ? "within the spread" : measured < stats.p5 ? "below it" : "above it")
                if let scatter = output.measuredVariation {
                    line += String(
                        format: "; the tests' scatter %.0f%% against the model's %.0f%%", 100 * scatter,
                        100 * stats.variation)
                }
            }
            // The inputs the output follows most closely, by rank; with tens of samples, weaker
            // correlations than 0.5 are within chance.
            let pairs = zip(item.samples.dropFirst(), item.outcomes.dropFirst()).compactMap {
                sample, outcome in
                outcome?.outputs[output.key].flatMap { $0.isFinite ? (sample, $0) : nil }
            }
            let drivers = info.inputs.compactMap { input -> (String, Double)? in
                rankCorrelation(pairs.map { $0.0.values[input.key] ?? 0 }, pairs.map(\.1)).map {
                    (input.key, $0)
                }
            }
            .filter { abs($0.1) >= 0.5 }.sorted { abs($0.1) > abs($1.1) }.prefix(3)
            if !drivers.isEmpty {
                line +=
                    "; follows "
                    + drivers.map { String(format: "%@ (%+.2f)", $0.0, $0.1) }.joined(separator: ", ")
            }
            lines.append(line)
        }
        return lines
    }

    /// Lines for a case run with each of the kernels' roundings: each output's lowest to highest,
    /// the default's value and the others', and half the range against the default.
    static func roundingSummary(_ item: Report.Case, _ info: EnsembleCase) -> [String] {
        let ran = zip(item.samples, item.outcomes).compactMap { sample, outcome in
            outcome.map { (rounding: sample.rounding ?? .standard, outcome: $0) }
        }
        var lines = [
            "\(info.title): \(ran.count) of \(item.samples.count) roundings, "
                + "\(item.places.compactMap { $0 }.filter { $0 != "here" }.count) on other Macs"
        ]
        func format(_ value: Double) -> String { String(format: "%.3g", value) }
        for output in info.outputs {
            let values = ran.compactMap { run in run.outcome.outputs[output.key].map { (run.rounding, $0) } }
            guard let low = values.map(\.1).min(), let high = values.map(\.1).max() else {
                lines.append("  \(output.name): –")
                continue
            }
            let standard = values.first { $0.0 == .standard }?.1
            var line = "  \(output.name): \(format(low))–\(format(high)) \(output.unit) ("
            line += values.map { "\($0.0 == .standard ? "default" : $0.0.name) \(format($0.1))" }
                .joined(separator: ", ")
            line += ")"
            if let standard, standard != 0 {
                line += String(format: ", ±%.1f%% of the default", 50 * (high - low) / abs(standard))
            }
            if values.count < ran.count { line += " (in \(values.count) of \(ran.count) runs)" }
            if let measured = output.measured { line += "; measured \(format(measured))" }
            lines.append(line)
        }
        return lines
    }

    static func write(_ report: Report, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for item in report.cases {
            try encoder.encode(item).write(to: folder.appending(path: "\(item.id).json"))
            let lines = summary(item).joined(separator: "\n") + "\n"
            try Data(lines.utf8).write(to: folder.appending(path: "\(item.id).txt"))
        }
        try encoder.encode(report).write(to: folder.appending(path: "ensemble.json"))
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
