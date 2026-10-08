import BlastCore
import Foundation

/// The producer's side of a one-way consumer: the air goes out a frame at a time, reports of
/// where the particles have got come back, and the result at the end.
protocol LiveConsumer: AnyObject, Sendable {
    /// Frames sent so far, and their air in bytes.
    var sent: Int { get }
    var bytes: Int { get }
    /// The consumer's latest report.
    var report: ConsumerReport { get }
    /// Its report after `frame`, or before the first frame for a negative one; nil if not yet in.
    func report(after frame: Int) -> ConsumerReport?
    /// Sends the next frame's air.
    func send(_ slice: AirSlice)
    /// Waits for every frame sent to be consumed, and returns what the consumer found.
    func finish(frameInterval: Double) async throws -> FragmentResult
    /// Lets the consumer go without its result, as when the run fails.
    func cancel()
}

/// A consumer on this Mac's CPU, on a queue of its own.
final class LocalLiveConsumer: LiveConsumer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.bombcad.fragments")
    private let lock = NSLock()
    private var consumer: FragmentConsumer
    private var latest: ConsumerReport
    private var history: [ConsumerReport]
    private var count = 0
    private var total = 0

    init(spec: FragmentSpec, scene: FragmentScene) {
        consumer = FragmentConsumer(spec: spec, scene: scene)
        latest = consumer.report
        history = [latest]
    }

    func report(after frame: Int) -> ConsumerReport? {
        lock.withLock { history.indices.contains(frame + 1) ? history[frame + 1] : nil }
    }

    var sent: Int { lock.withLock { count } }
    var bytes: Int { lock.withLock { total } }
    var report: ConsumerReport { lock.withLock { latest } }

    func send(_ slice: AirSlice) {
        lock.withLock {
            count += 1
            total += 2 * slice.values.count
        }
        queue.async { [self] in
            consumer.consume(slice)
            let report = consumer.report
            lock.withLock {
                latest = report
                history.append(report)
            }
        }
    }

    func finish(frameInterval: Double) async throws -> FragmentResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: consumer.result(frameInterval: frameInterval))
            }
        }
    }

    func cancel() {}
}

/// A consumer on another Mac, through a worker: frames go out over its connection as they come,
/// and its reports come back after each.
final class RemoteLiveConsumer: LiveConsumer, @unchecked Sendable {
    let id = UUID()
    private let client: SweepWorkerClient
    private let writer: SweepWorkerWriter
    private let lock = NSLock()
    private var latest: ConsumerReport
    private var history: [ConsumerReport]
    private var count = 0
    private var total = 0

    @MainActor
    init(client: SweepWorkerClient, spec: FragmentSpec, scene: FragmentScene) {
        self.client = client
        writer = client.writer
        // The particles' starting place, worked out here as the worker will.
        latest = FragmentConsumer(spec: spec, scene: scene).report
        history = [latest]
        client.startConsumer(ConsumerSession(id: id, spec: spec, scene: scene)) { [weak self] report in
            guard let self else { return }
            self.lock.withLock {
                self.latest = report
                self.history.append(report)
            }
        }
    }

    func report(after frame: Int) -> ConsumerReport? {
        lock.withLock { history.indices.contains(frame + 1) ? history[frame + 1] : nil }
    }

    var sent: Int { lock.withLock { count } }
    var bytes: Int { lock.withLock { total } }
    var report: ConsumerReport { lock.withLock { latest } }

    func send(_ slice: AirSlice) {
        let payload = slice.payload
        lock.withLock {
            count += 1
            total += payload.count
        }
        writer.enqueue(.air(id, slice.header), payload: payload)
    }

    func finish(frameInterval: Double) async throws -> FragmentResult {
        defer { cancel() }
        return try await client.finishConsumer(id, frameInterval: frameInterval)
    }

    func cancel() {
        let client = client
        Task { @MainActor in client.close() }
    }
}
