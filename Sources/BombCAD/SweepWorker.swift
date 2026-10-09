import BlastCore
import DocumentKit
import Foundation
import Metal

/// `BombCAD worker`: runs sweep cases sent to it over standard input, answering on standard
/// output (see `SweepWorkerMessage`), one at a time, until told to stop or its input closes, as
/// when the SSH connection that started it drops. Nothing else may be written to standard output.
@MainActor
enum SweepWorker {
    static func main() async -> Int32 {
        await serve(input: .standardInput, output: .standardOutput)
        return 0
    }

    static func serve(input: FileHandle, output: FileHandle) async {
        let writer = SweepWorkerWriter(output)
        let device = MTLCreateSystemDefaultDevice()?.name ?? "No Metal device"
        guard (try? writer.send(.hello(SweepWorkerHello(device: device)))) != nil else { return }
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
                case .cancel(let id):
                    if let running = jobs.current, running.id == id { running.task.cancel() }
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

        func stop() async {
            guard let task = current?.task else { return }
            task.cancel()
            await task.value
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
                try engine.consume(input)
                // The live state before the report, so that a session reported caught up has its
                // last frame's state in.
                if let live = engine.live(time: input.time) {
                    let (header, payload) = live.encoded(impactsSent: impactsSent)
                    impactsSent = live.fragments?.impacts.count ?? 0
                    writer.enqueue(.live(id, header), payload: payload)
                }
                writer.enqueue(.report(id, engine.report))
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
