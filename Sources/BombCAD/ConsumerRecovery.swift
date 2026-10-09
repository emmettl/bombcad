import BlastCore
import DocumentKit
import Foundation

/// Every frame's input to a consumer, kept in a file as it is sent, so that the consumer can be
/// run again from the start elsewhere: as on the wire, the header's length and JSON, then the
/// payload's length and the payload. Written, and read back, on a queue of its own, which is also
/// where frames are handed on once a replacement is reading them (see
/// `ResilientFrameConsumer`), so that they reach it in the order sent.
final class ConsumerSpool: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.bombcad.consumer-spool")
    private let url: URL
    private var handle: FileHandle?
    private var error: Error?
    /// Frames written, and their bytes; touched only on `queue`.
    private(set) var frames = 0
    private(set) var bytes = 0

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "BombCAD-consumer-\(UUID().uuidString).spool")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ProjectFileError.invalid("Cannot keep a consumer's frames in \(url.path).")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { discard() }

    /// Writes `input` after those before it; on `queue`.
    func write(_ input: ConsumerInput) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard error == nil, let handle else { return }
        do {
            let header = try JSONEncoder().encode(input.header)
            let payload = input.payload
            try handle.write(
                contentsOf: Self.length(header.count) + header + Self.length(payload.count) + payload)
            frames += 1
            bytes += 8 + header.count + payload.count
        } catch {
            self.error = error
        }
    }

    /// Reads every frame written so far, in order, handing each to `body`; on `queue`.
    func replay(_ body: (ConsumerInput) -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if let error { throw error }
        try handle?.synchronize()
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        for _ in 0..<frames {
            let header = try JSONDecoder().decode(
                ConsumerInput.Header.self, from: try Self.read(Self.readLength(reader), from: reader))
            let payload = try Self.read(Self.readLength(reader), from: reader)
            body(try ConsumerInput(header: header, payload: payload))
        }
    }

    /// Removes the file.
    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    private static func length(_ count: Int) -> Data {
        var length = UInt32(count).bigEndian
        return Data(bytes: &length, count: 4)
    }

    private static func readLength(_ reader: FileHandle) throws -> Int {
        Int(try read(4, from: reader).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
    }

    private static func read(_ count: Int, from reader: FileHandle) throws -> Data {
        guard count > 0 else { return Data() }
        guard let data = try reader.read(upToCount: count), data.count == count else {
            throw ProjectFileError.invalid("A consumer's kept frames were cut short.")
        }
        return data
    }
}

/// A consumer on another Mac that carries on here if that Mac fails it, or the connection drops:
/// it keeps every frame sent (`ConsumerSpool`), and on failure a consumer on this Mac takes them
/// all again from the start, then the frames that follow. The model and its inputs are the same,
/// so the result is the same as if the other Mac had finished; the run waits while this one
/// catches up, as for any consumer behind.
final class ResilientFrameConsumer: FrameConsumer, @unchecked Sendable {
    let kind: ConsumerKind
    private let remote: RemoteFrameConsumer
    private let spool: ConsumerSpool
    private let lock = NSLock()
    private var count = 0
    private var total = 0
    /// The consumer here once the other Mac has failed, and why it failed, after which frame.
    private var local: LocalFrameConsumer?
    private var failure: (frame: Int, reason: String)?
    /// Waiting for the consumer here to have taken every frame kept.
    private var takeoverWaiters: [CheckedContinuation<Void, Never>] = []
    private var tookOver = false

    @MainActor
    init(client: SweepWorkerClient, kind: ConsumerKind, ownsClient: Bool = true) throws {
        self.kind = kind
        let spool = try ConsumerSpool()
        self.spool = spool
        // The failure is told on the main actor; the takeover then runs on the spool's queue.
        let this = Reference()
        remote = RemoteFrameConsumer(client: client, kind: kind, ownsClient: ownsClient) { error in
            this.consumer?.takeOver(after: error)
        }
        this.consumer = self
    }

    /// The consumer, for its other Mac's failure to reach once it exists.
    private final class Reference: @unchecked Sendable {
        weak var consumer: ResilientFrameConsumer?
    }

    /// Why the other Mac failed, after which frame it had reported, if it has.
    var fallback: (frame: Int, reason: String)? { lock.withLock { failure } }

    private var active: any FrameConsumer { lock.withLock { local } ?? remote }

    var sent: Int { lock.withLock { count } }
    var bytes: Int { lock.withLock { total } }
    var report: ConsumerReport { active.report }
    func report(after frame: Int) -> ConsumerReport? { active.report(after: frame) }
    var live: ConsumerLive? { active.live }

    func send(_ input: ConsumerInput) {
        let failed = lock.withLock {
            count += 1
            total += input.byteCount
            return failure != nil
        }
        if !failed { remote.send(input) }
        spool.queue.async { [self] in
            spool.write(input)
            // Once the consumer here has the frames kept, the rest go to it in order.
            if let local = lock.withLock({ local }) { local.send(input) }
        }
    }

    /// Starts the consumer here on every frame kept so far, then on those to come.
    private func takeOver(after error: Error) {
        let started = lock.withLock {
            guard failure == nil else { return false }
            failure = (remote.report.frame, error.localizedDescription)
            return true
        }
        guard started else { return }
        spool.queue.async { [self] in
            let consumer = LocalFrameConsumer(kind)
            do {
                try spool.replay { consumer.send($0) }
            } catch {
                // Unreadable frames leave the consumer short of them; its result says so.
                lock.withLock {
                    failure?.reason += " The frames kept could not be read: \(error.localizedDescription)"
                }
            }
            let waiters = lock.withLock {
                local = consumer
                tookOver = true
                defer { takeoverWaiters = [] }
                return takeoverWaiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    func finish(frameInterval: Double) async throws -> ConsumerOutcome {
        if lock.withLock({ failure == nil }) {
            do {
                let outcome = try await remote.finish(frameInterval: frameInterval)
                spool.queue.async { [spool] in spool.discard() }
                return outcome
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // It failed at the end: take its frames here.
                takeOver(after: error)
            }
        }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if !tookOver { takeoverWaiters.append(continuation) }
                return tookOver
            }
            if ready { continuation.resume() }
        }
        // After every frame handed on.
        await withCheckedContinuation { continuation in spool.queue.async { continuation.resume() } }
        let local = lock.withLock { self.local }!
        // The other Mac's session is gone; let its connection go if it is this consumer's.
        remote.cancel()
        defer { spool.queue.async { [spool] in spool.discard() } }
        return try await local.finish(frameInterval: frameInterval)
    }

    func cancel() {
        remote.cancel()
        lock.withLock { local }?.cancel()
        spool.queue.async { [spool] in spool.discard() }
    }
}

extension FrameConsumer {
    /// Where the consumer runs, for a status line: " on <host>", or " here after frame <n>: <why>"
    /// once another Mac failed it; empty here.
    func placement(host: String?) -> String {
        if let resilient = self as? ResilientFrameConsumer, let fallback = resilient.fallback {
            return
                " here after frame \(fallback.frame + 1), \(host ?? "the other Mac") having failed: \(fallback.reason)"
        }
        guard self is RemoteFrameConsumer || self is ResilientFrameConsumer else { return "" }
        return " on \(host ?? "another Mac")"
    }
}
