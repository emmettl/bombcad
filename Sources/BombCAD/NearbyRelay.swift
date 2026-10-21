import Foundation
import Network

/// A nearby session's worker, relayed a message at a time (emmettl/bombcad-work#73), so that a
/// watched run the app asked to keep going (`WatchJob.keepsRunning`) outlives its connection: when
/// the connection drops, the worker carries on, the relay acknowledging its frames itself and
/// keeping its view's setup, its latest progress and its end (the result, or why it failed); a
/// later session that asks to resume the run (`NearbyWorkers.SessionRequest.resume`) is handed
/// those, then the run's frames again if it is still going. What a run held this way keeps is let
/// go only when the app says it is done (`shutdown`), or the sharing Mac stops sharing. Other
/// sessions, sweeps among them, end with their connection as before.
final class SessionRelay: @unchecked Sendable {
    private let lock = NSLock()
    /// The worker's input, written here on `writes`, and its output, read on a thread of its own.
    private let toWorker: FileHandle
    private let fromWorker: FileHandle
    private let writes = DispatchQueue(label: "dev.bombcad.nearby.relay")
    private var connection: NWConnection?
    /// The worker's greeting, as sent.
    private var hello: Data?
    /// Runs to keep going should the connection drop, those still running, and for each what a
    /// session resuming it is handed, as sent.
    private var held: Set<UUID> = []
    private var running: Set<UUID> = []
    private var kept: [UUID: Kept] = [:]
    /// Frames sent on and not yet acknowledged, which the relay acknowledges itself if the
    /// connection drops, so that the worker goes on building them.
    private var unacknowledged: [UUID: Set<Int>] = [:]
    private var workerInputClosed = false
    private var workerEnded = false
    private var ended = false
    /// Told once, when the relay has nothing more to do: the worker gone, and nothing held.
    var onEnd: @Sendable (SessionRelay) -> Void = { _ in }
    /// Told what happens, for the sharing Mac's log.
    var log: @Sendable (String) -> Void = { _ in }

    private struct Kept {
        var setup: Data?
        var progress: Data?
        var stats: Data?
        var end: Data?
    }

    init(toWorker: FileHandle, fromWorker: FileHandle) {
        self.toWorker = toWorker
        self.fromWorker = fromWorker
    }

    /// Starts relaying between the worker and `connection`, which is ready.
    func start(_ connection: NWConnection) {
        lock.withLock { self.connection = connection }
        receive(from: connection, buffer: Data())
        Thread { [self] in readWorker() }.start()
    }

    /// Whether this relay holds the run `id`, running or ended, for a session to resume.
    func holds(_ id: UUID) -> Bool { lock.withLock { held.contains(id) && !ended } }

    /// Whether it has no connection now.
    var isDetached: Bool { lock.withLock { connection == nil } }

    /// Hands a resuming session what the held runs have sent that it needs, then relays as before.
    func resume(_ connection: NWConnection) {
        let frames: [(UUID, Int)] = lock.withLock {
            self.connection?.cancel()
            self.connection = connection
            // Frames sent to a connection replaced will never be acknowledged by it.
            let frames = unacknowledged.flatMap { id, frames in frames.map { (id, $0) } }
            unacknowledged = [:]
            var replay: [Data] = hello.map { [$0] } ?? []
            for id in held.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let kept = kept[id] else { continue }
                replay += [kept.setup, kept.progress, kept.stats, kept.end].compactMap { $0 }
            }
            for raw in replay { connection.send(content: raw, completion: .idempotent) }
            log("Session resumed: \(held.count) held run\(held.count == 1 ? "" : "s").")
            return frames
        }
        for (id, frame) in frames { acknowledge(id, frame) }
        receive(from: connection, buffer: Data())
    }

    /// Ends the relay: the worker's input closed, the connection cancelled, whatever is held.
    func stop() {
        lock.withLock {
            held = []
            kept = [:]
            connection?.cancel()
            connection = nil
        }
        writes.async { [self] in closeWorkerInput() }
    }

    // MARK: - The worker's messages

    private func readWorker() {
        do {
            while let (raw, message) = try SweepWorkerFrame.rawPacket(from: fromWorker) {
                let sent: DispatchSemaphore? = lock.withLock {
                    guard let target = route(message, raw: raw) else { return nil }
                    let done = DispatchSemaphore(value: 0)
                    target.send(content: raw, completion: .contentProcessed { _ in done.signal() })
                    return done
                }
                // One message on the wire at a time, as the bridge before it sent a chunk at a time.
                sent?.wait()
            }
        } catch {
            log("A worker's message could not be read: \(error.localizedDescription)")
        }
        lock.withLock {
            workerEnded = true
            settle()
        }
    }

    /// Keeps what a resuming session would need of `message`, and says where it goes now: the
    /// connection, or nowhere (a frame no one is there to see, acknowledged here).
    private func route(_ message: SweepWorkerMessage, raw: Data) -> NWConnection? {
        switch message {
        case .hello: hello = raw
        case .viewSetup(let id): if held.contains(id) { kept[id, default: Kept()].setup = raw }
        case .progress(let id, _): if held.contains(id) { kept[id, default: Kept()].progress = raw }
        case .viewStats(let id, _): if held.contains(id) { kept[id, default: Kept()].stats = raw }
        case .finished(let id, _), .failed(let id, _):
            running.remove(id)
            unacknowledged[id] = nil
            if held.contains(id) {
                kept[id, default: Kept()].end = raw
                log("A held run ended\(connection == nil ? " with no one connected; kept for its Mac" : "").")
            }
            settle()
        case .view(let id, let header):
            guard connection != nil else {
                acknowledge(id, header.frame)
                return nil
            }
            if held.contains(id) { unacknowledged[id, default: []].insert(header.frame) }
        default: break
        }
        return connection
    }

    // MARK: - The connection's messages

    private func receive(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [self] data, _, complete, error in
            writes.async { [self] in
                var buffer = buffer
                if let data { buffer.append(data) }
                do {
                    while let (raw, message) = try SweepWorkerFrame.rawPacket(from: &buffer) {
                        lock.withLock { inspect(message) }
                        writeToWorker(raw)
                    }
                } catch {
                    log("A session's message could not be read: \(error.localizedDescription)")
                    connection.cancel()
                    dropped(connection)
                    return
                }
                if complete || error != nil {
                    dropped(connection)
                } else {
                    receive(from: connection, buffer: buffer)
                }
            }
        }
    }

    /// Notes what the app asks of the worker that the relay must know.
    private func inspect(_ message: SweepWorkerMessage) {
        switch message {
        case .watch(let job):
            running.insert(job.id)
            if job.keepsRunning {
                held.insert(job.id)
                kept[job.id] = Kept()
            }
        case .viewAck(let id, let frame): unacknowledged[id]?.remove(frame)
        case .shutdown:
            // The app has what it was waiting for, or no longer wants it.
            held = []
            kept = [:]
            settle()
        default: break
        }
    }

    /// The connection ended: with a held run still going, or ended and not yet collected, the
    /// worker carries on; otherwise it is told to stop, as its input closing always told it.
    private func dropped(_ connection: NWConnection) {
        let frames: [(UUID, Int)] = lock.withLock {
            guard self.connection === connection else { return [] }
            self.connection = nil
            connection.cancel()
            let going = !held.intersection(running).isEmpty
            if going || !kept.isEmpty { log("Connection dropped; holding \(held.count) run(s).") }
            let frames = unacknowledged.flatMap { id, frames in frames.map { (id, $0) } }
            unacknowledged = [:]
            settle()
            return frames
        }
        for (id, frame) in frames { acknowledge(id, frame) }
    }

    /// Acts on where things stand, under the lock: with no connection and nothing held still
    /// running, the worker's input closes and it exits; with the worker gone and nothing held for
    /// anyone, the relay ends.
    private func settle() {
        if connection == nil, held.intersection(running).isEmpty {
            writes.async { [self] in closeWorkerInput() }
        }
        let collected = held.allSatisfy { kept[$0]?.end == nil } || held.isEmpty
        guard workerEnded, !ended else { return }
        if let connection, collected {
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
        if connection == nil ? held.isEmpty || collected : collected {
            ended = true
            let onEnd = onEnd
            DispatchQueue.global().async { onEnd(self) }
        }
    }

    private func acknowledge(_ id: UUID, _ frame: Int) {
        guard let raw = try? SweepWorkerFrame.encode(.viewAck(id, frame)) else { return }
        writes.async { [self] in writeToWorker(raw) }
    }

    /// On `writes`.
    private func writeToWorker(_ raw: Data) {
        guard !workerInputClosed else { return }
        do { try toWorker.write(contentsOf: raw) } catch { closeWorkerInput() }
    }

    /// On `writes`.
    private func closeWorkerInput() {
        guard !workerInputClosed else { return }
        workerInputClosed = true
        try? toWorker.close()
    }
}
