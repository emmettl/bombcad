import BlastCore
import DocumentKit
import Foundation
import Metal

/// `BombCAD worker`: runs sweep cases sent to it over standard input, answering on standard
/// output (see `SweepWorkerMessage`), one at a time, until told to stop or its input closes, as
/// when the SSH connection that started it drops. Nothing else may be written to standard output.
@MainActor
enum SweepWorker {
    /// With `--gate <argument>` (see `RemoteGate`), it first decides whether this Mac should
    /// take work now, and says why not on standard error, exiting 75, before greeting; if it
    /// should, it holds this Mac's lock until it ends.
    static func main(_ arguments: [String] = []) async -> Int32 {
        // `--share <project>`, once a project: the kept runs a viewer nearby may fetch.
        var shared: [URL] = []
        for (n, argument) in arguments.enumerated() where argument == "--share" && n + 1 < arguments.count {
            shared.append(URL(filePath: arguments[n + 1], directoryHint: .isDirectory))
        }
        if let index = arguments.firstIndex(of: "--gate") {
            guard index + 1 < arguments.count, let gate = RemoteGate(argument: arguments[index + 1]) else {
                FileHandle.standardError.write(Data("The worker's gate could not be read.\n".utf8))
                return 2
            }
            if let reason = gate.refusal() ?? (gate.acquire() ? nil : "another BombCAD job took it first") {
                FileHandle.standardError.write(Data("Not taking work: \(reason).\n".utf8))
                return 75
            }
            // Let the lock go however the worker ends: its input closing ends `serve`; a signal
            // ends the process.
            for number in [SIGTERM, SIGHUP, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    RemoteGate.release()
                    exit(128 + number)
                }
                source.resume()
                signalSources.append(source)
            }
            defer { RemoteGate.release() }
            await serve(input: .standardInput, output: .standardOutput, shared: shared)
            return 0
        }
        await serve(input: .standardInput, output: .standardOutput, shared: shared)
        return 0
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// Serves until told to stop; `shared` names the project packages whose kept runs' recordings
    /// a viewer may list and fetch (`SharedTimelines`).
    static func serve(input: FileHandle, output: FileHandle, shared: [URL] = []) async {
        let writer = SweepWorkerWriter(output)
        let device = MTLCreateSystemDefaultDevice()?.name ?? "No Metal device"
        let hello = SweepWorkerHello(device: device, memory: AdvisorMachine.thisMac.memory)
        guard (try? writer.send(.hello(hello))) != nil else { return }
        let jobs = Jobs()
        do {
            for try await packet in SweepWorkerFrame.packets(from: input) {
                switch packet.message {
                case .run(let job):
                    if let running = jobs.current {
                        try? writer.send(.failed(job.id, "The worker is already running \(running.id)."))
                        continue
                    }
                    jobs.current = (
                        job.id,
                        Task {
                            await run(job, writer: writer)
                            if jobs.current?.id == job.id { jobs.current = nil }
                        }
                    )
                case .ensemble(let job):
                    if let running = jobs.current {
                        try? writer.send(.failed(job.id, "The worker is already running \(running.id)."))
                        continue
                    }
                    jobs.current = (
                        job.id,
                        Task {
                            await runEnsemble(job, writer: writer)
                            if jobs.current?.id == job.id { jobs.current = nil }
                        }
                    )
                case .watch(let job):
                    if let running = jobs.current {
                        try? writer.send(.failed(job.id, "The worker is already running \(running.id)."))
                        continue
                    }
                    var job = job
                    // The files a job in this session sent already, named by their digests rather
                    // than sent again (`WatchJob.reused`).
                    if let reused = job.reused {
                        let missing = reused.filter { jobs.files[$0.value] == nil }.keys.sorted()
                        guard missing.isEmpty else {
                            try? writer.send(.failed(job.id, SweepWorkerMessage.missingFiles))
                            continue
                        }
                        for (path, digest) in reused { job.project.files[path] = jobs.files[digest] }
                        job.reused = nil
                    }
                    jobs.files = Dictionary(
                        job.project.files.values.map { (WatchJob.digest($0), $0) },
                        uniquingKeysWith: { a, _ in a })
                    let sender = job.view.map { ViewSender(id: job.id, writer: writer, spec: $0) }
                    let paused = Locked(false)
                    jobs.viewers[job.id] = sender
                    jobs.pauses[job.id] = paused
                    jobs.current = (
                        job.id,
                        Task { [job] in
                            await watch(job, sender: sender, writer: writer, paused: paused)
                            jobs.viewers[job.id] = nil
                            jobs.pauses[job.id] = nil
                            if jobs.current?.id == job.id { jobs.current = nil }
                        }
                    )
                case .viewAck(let id, let frame):
                    jobs.viewers[id]?.acknowledge(frame)
                case .pause(let id, let on):
                    jobs.pauses[id]?.value = on
                case .cancel(let id):
                    if let running = jobs.current, running.id == id { running.task.cancel() }
                    jobs.fetches[id]?.cancelled.value = true
                    jobs.sessions.removeValue(forKey: id)?.cancel()
                case .shutdown:
                    await jobs.stop()
                    return
                case .consume(let session):
                    jobs.sessions[session.id] = ConsumerRunner(session, writer: writer)
                case .input(let id, let header):
                    jobs.sessions[id]?.consume(header, payload: packet.payload)
                case .finishConsumer(let id, let interval):
                    guard let runner = jobs.sessions.removeValue(forKey: id) else {
                        writer.enqueue(.failed(id, "No such consumer session."))
                        continue
                    }
                    runner.finish(frameInterval: interval)
                case .probe(let id, let count):
                    guard count >= 0, count <= SweepWorkerFrame.maximumBytes else {
                        writer.enqueue(.failed(id, "A probe of \(count) bytes cannot be sent."))
                        continue
                    }
                    writer.enqueue(.probed(id)) {
                        // A random megabyte over and over, so that nothing on the way could make it
                        // smaller, and making it costs the measurement little.
                        var block = Data(count: 1 << 20)
                        block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
                        var bytes = Data(capacity: count)
                        while bytes.count < count { bytes.append(block.prefix(count - bytes.count)) }
                        return bytes
                    }
                case .timelines(let id):
                    writer.enqueue(.timelineList(id)) {
                        (try? JSONEncoder().encode(SharedTimelines.list(shared))) ?? Data("[]".utf8)
                    }
                case .fetchTimeline(let fetch):
                    let wanted = URL(filePath: fetch.project, directoryHint: .isDirectory).standardizedFileURL
                    guard let package = shared.first(where: { $0.standardizedFileURL.path == wanted.path })
                    else {
                        writer.enqueue(.failed(fetch.id, "That project is not shared."))
                        continue
                    }
                    let preferred = Locked<[Int]>([])
                    let cancelled = Locked(false)
                    jobs.fetches[fetch.id] = (preferred, cancelled)
                    // Off the main actor, which keeps reading: each part waits for the link.
                    Thread {
                        do {
                            let stats = try SharedTimelines.send(
                                fetch, package: package, writer: writer, preferred: preferred,
                                cancelled: cancelled)
                            try writer.send(.timelineSent(fetch.id), payload: JSONEncoder().encode(stats))
                        } catch is CancellationError {
                            try? writer.send(.failed(fetch.id, SweepWorkerMessage.cancelled))
                        } catch {
                            try? writer.send(.failed(fetch.id, error.localizedDescription))
                        }
                    }.start()
                case .timelinePrefer(let id, let frame):
                    jobs.fetches[id]?.preferred.update { $0.append(frame) }
                default:
                    continue
                }
            }
        } catch {}
        // The input closed: nobody is waiting for the result.
        await jobs.stop()
    }

    /// The job running, if one is, and the consumer sessions.
    private final class Jobs {
        var current: (id: UUID, task: Task<Void, Never>)?
        var sessions: [UUID: ConsumerRunner] = [:]
        /// Watched runs' senders, for their acknowledgements.
        var viewers: [UUID: ViewSender] = [:]
        /// Watched runs' pauses.
        var pauses: [UUID: Locked<Bool>] = [:]
        /// The last watched job's files, by digest, for the next to name rather than send again.
        var files: [String: Data] = [:]
        /// Recordings sent to a viewer this session: the frames it asked for next, and whether to
        /// stop. A few bytes each, kept until the session ends.
        var fetches: [UUID: (preferred: Locked<[Int]>, cancelled: Locked<Bool>)] = [:]

        func stop() async {
            for fetch in fetches.values { fetch.cancelled.value = true }
            guard let task = current?.task else { return }
            task.cancel()
            await task.value
        }
    }

    /// Runs one sample of a validation case away from the main actor, which keeps reading
    /// messages; a cancelled one still finishes, but its result is not sent.
    private static func runEnsemble(_ job: EnsembleJob, writer: SweepWorkerWriter) async {
        let sample = job.sample
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ValidationEnsemble.run(sample) }
        }.value
        guard !Task.isCancelled else {
            try? writer.send(.failed(job.id, SweepWorkerMessage.cancelled))
            return
        }
        switch result {
        case .success(let outcome):
            do {
                try writer.send(.ensembleFinished(job.id, outcome))
            } catch {
                try? writer.send(
                    .failed(job.id, "The result could not be sent: \(error.localizedDescription)"))
            }
        case .failure(let error): try? writer.send(.failed(job.id, error.localizedDescription))
        }
    }

    /// Runs a watched project, sending its frames as `sender` allows, then what that cost and
    /// the result.
    private static func watch(
        _ job: WatchJob, sender: ViewSender?, writer: SweepWorkerWriter, paused: Locked<Bool>
    ) async {
        do {
            var document = try ProjectDocument(archive: job.project.archive())
            document.savedRuns = []
            var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
            options.name = job.name
            options.frameInterval = job.frameInterval
            options.asApp = job.asApp
            let start = ContinuousClock.now
            let result = try await HeadlessRun.perform(
                document, options: options,
                progress: { fraction in writer.enqueue(.progress(job.id, fraction)) },
                view: sender.map { sender in
                    { solver, frame, last, overlay in
                        sender.frame(solver, number: frame, last: last, overlay: overlay)
                    }
                },
                viewRequest: sender.map { sender in { sender.frameRequest($0) } },
                paused: { paused.value }
            )
            let took = start.duration(to: .now)
            if let sender {
                let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
                writer.enqueue(.viewStats(job.id, await sender.finish(runSeconds: seconds)))
            }
            let archive = SweepWorkerArchive(try result.document.makeArchive())
            try writer.send(.finished(job.id, archive))
        } catch is CancellationError {
            try? writer.send(.failed(job.id, SweepWorkerMessage.cancelled))
        } catch {
            try? writer.send(.failed(job.id, error.localizedDescription))
        }
    }

    private static func run(_ job: SweepWorkerJob, writer: SweepWorkerWriter) async {
        do {
            var document = try ProjectDocument(archive: job.project.archive())
            document.savedRuns = []
            var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
            options.name = job.name
            let result = try await HeadlessRun.perform(document, options: options) { fraction in
                try? writer.send(.progress(job.id, fraction))
            }
            try writer.send(.finished(job.id, SweepWorkerArchive(result.document.makeArchive())))
        } catch is CancellationError {
            try? writer.send(.failed(job.id, SweepWorkerMessage.cancelled))
        } catch {
            try? writer.send(.failed(job.id, error.localizedDescription))
        }
    }
}

/// A consumer session on a worker: its model, fed on a queue of its own, so that sessions run
/// side by side and the connection's reader never waits for one; the frames in the order sent.
private final class ConsumerRunner: @unchecked Sendable {
    private let id: UUID
    private let writer: SweepWorkerWriter
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var engine: ConsumerEngine
    /// Why the session failed, if it has; it then takes no more frames.
    private var failure: String?
    private var cancelled = false
    /// For a live session, the impacts sent so far.
    private var impactsSent = 0
    /// The model's time on frames so far.
    private var seconds = 0.0

    init(_ session: ConsumerSession, writer: SweepWorkerWriter) {
        id = session.id
        self.writer = writer
        engine = ConsumerEngine(session.kind)
        queue = DispatchQueue(label: "dev.bombcad.consumer.\(session.kind.name)")
    }

    func consume(_ header: ConsumerInput.Header, payload: Data) {
        queue.async { [self] in
            guard failure == nil, !cancelled else { return }
            do {
                let input = try ConsumerInput(header: header, payload: payload)
                let start = ContinuousClock.now
                try engine.consume(input)
                let took = start.duration(to: .now)
                seconds += Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
                // The live state before the report, so that a session reported caught up has its
                // last frame's state in.
                if let live = engine.live(time: input.time) {
                    let (header, payload) = live.encoded(impactsSent: impactsSent)
                    impactsSent = live.fragments?.impacts.count ?? 0
                    writer.enqueue(.live(id, header), payload: payload)
                }
                writer.enqueue(.report(id, engine.report, seconds))
            } catch {
                failure = error.localizedDescription
                writer.enqueue(.failed(id, error.localizedDescription))
            }
        }
    }

    /// Sends the result once every frame before has been taken, or, if the session failed, why
    /// again: the app may not have been waiting for it the first time.
    func finish(frameInterval: Double) {
        queue.async { [self] in
            if let failure {
                writer.enqueue(.failed(id, failure))
                return
            }
            guard !cancelled else {
                writer.enqueue(.failed(id, SweepWorkerMessage.cancelled))
                return
            }
            do {
                let outcome = engine.outcome(frameInterval: frameInterval)
                writer.enqueue(.outcome(id), payload: try outcome.encoded())
            } catch {
                writer.enqueue(.failed(id, "The result could not be sent: \(error.localizedDescription)"))
            }
        }
    }

    func cancel() { queue.async { [self] in cancelled = true } }
}
