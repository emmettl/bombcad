import BlastCore
import DocumentKit
import Foundation
import simd

/// The particles as of the last frame consumed, for drawing.
struct FragmentLive: Sendable, Equatable {
    var time: Double = 0
    var positions: [SIMD3<Float>] = []
    var speeds: [Float] = []
    var landed: [Bool] = []
    /// The first `fragmentCount` particles are fragments, the rest tracers.
    var fragmentCount = 0
    var impacts: [FragmentImpact] = []

    /// Positions as little-endian floats, four a particle: x, y, z and the speed, negative once
    /// landed.
    var payload: Data {
        var values: [Float] = []
        values.reserveCapacity(4 * positions.count)
        for n in positions.indices {
            values += [
                positions[n].x, positions[n].y, positions[n].z, landed[n] ? -1 - speeds[n] : speeds[n],
            ]
        }
        return values.withUnsafeBytes { Data($0) }
    }

    mutating func read(_ payload: Data) throws {
        guard payload.count % 16 == 0 else {
            throw ProjectFileError.invalid("Fragment positions arrived cut short.")
        }
        let count = payload.count / 16
        positions = []
        speeds = []
        landed = []
        positions.reserveCapacity(count)
        payload.withUnsafeBytes { raw in
            for n in 0..<count {
                let x = raw.loadUnaligned(fromByteOffset: 16 * n, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: 16 * n + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: 16 * n + 8, as: Float.self)
                let s = raw.loadUnaligned(fromByteOffset: 16 * n + 12, as: Float.self)
                positions.append(SIMD3(x, y, z))
                speeds.append(s < 0 ? -1 - s : s)
                landed.append(s < 0)
            }
        }
    }

    init() {}

    init(_ consumer: FragmentConsumer, time: Double) {
        self.time = time
        positions = consumer.cloud.particles.map(\.position)
        speeds = consumer.cloud.particles.map { simd_length($0.velocity) }
        landed = consumer.cloud.particles.map(\.landed)
        fragmentCount = consumer.cloud.fragmentCount
        impacts = consumer.cloud.impacts
    }
}

/// The producer's side of a one-way consumer: each frame's input goes out, reports of where the
/// consumer has got come back, and its result at the end (see `ConsumerKind`). Here
/// (`LocalFrameConsumer`) or on another Mac (`RemoteFrameConsumer`), the same model gives the
/// same result.
protocol FrameConsumer: AnyObject, Sendable {
    var kind: ConsumerKind { get }
    /// Frames sent so far, and their input in bytes.
    var sent: Int { get }
    var bytes: Int { get }
    /// The consumer's latest report.
    var report: ConsumerReport { get }
    /// The seconds its model has spent on frames so far, on the Mac that runs it.
    var seconds: Double { get }
    /// Its report after `frame`, or before the first frame for a negative one; nil if not yet in.
    func report(after frame: Int) -> ConsumerReport?
    /// The model's state as of the last frame consumed, for a live kind.
    var live: ConsumerLive? { get }
    /// Sends the next frame's input.
    func send(_ input: ConsumerInput)
    /// Waits for every frame sent to be consumed, and returns what the consumer found.
    func finish(frameInterval: Double) async throws -> ConsumerOutcome
    /// Lets the consumer go without its result, as when the run fails.
    func cancel()
}

extension FrameConsumer {
    /// The particles as of the last frame consumed, for fragments flown live.
    var fragmentLive: FragmentLive? { live?.fragments }
    /// The receivers as of the last frame consumed, for thermal radiation reckoned live.
    var thermalLive: ThermalLive? { live?.thermal }
    /// The ground points' estimates as of the last frame consumed, for ground shock live.
    var groundShockLive: GroundShockResult? { live?.groundShock }
    /// Whether every frame sent has been consumed.
    var caughtUp: Bool { report.frame >= sent - 1 }

    /// The fragments' result, from a fragment consumer.
    func fragments(frameInterval: Double) async throws -> FragmentResult {
        guard case .fragments(let result) = try await finish(frameInterval: frameInterval) else {
            throw ProjectFileError.invalid("The \(kind.name) consumer has no fragments.")
        }
        return result
    }
}

/// A consumer on this Mac's CPU, on a queue of its own.
final class LocalFrameConsumer: FrameConsumer, @unchecked Sendable {
    let kind: ConsumerKind
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var engine: ConsumerEngine
    private var latest: ConsumerReport
    private var history: [ConsumerReport]
    private var count = 0
    private var total = 0
    private var spent = 0.0
    private var current: ConsumerLive?
    private var failure: Error?

    /// A live fragment consumer keeps the particles' latest positions to draw, and only those: a
    /// run in the app, with a frame each batch, would not hold every frame's.
    init(_ kind: ConsumerKind) {
        self.kind = kind
        queue = DispatchQueue(label: "dev.bombcad.consumer.\(kind.name)")
        engine = ConsumerEngine(kind)
        latest = engine.report
        history = [latest]
        current = engine.live(time: 0)
    }

    func report(after frame: Int) -> ConsumerReport? {
        lock.withLock { history.indices.contains(frame + 1) ? history[frame + 1] : nil }
    }

    var sent: Int { lock.withLock { count } }
    var bytes: Int { lock.withLock { total } }
    var seconds: Double { lock.withLock { spent } }
    var report: ConsumerReport { lock.withLock { latest } }
    var live: ConsumerLive? { lock.withLock { current } }

    func send(_ input: ConsumerInput) {
        lock.withLock {
            count += 1
            total += input.byteCount
        }
        queue.async { [self] in
            guard failure == nil else { return }
            let start = ContinuousClock.now
            do {
                try engine.consume(input)
            } catch {
                failure = error
                return
            }
            let report = engine.report
            let live = engine.live(time: input.time)
            let took = start.duration(to: .now)
            lock.withLock {
                spent += Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
                latest = report
                history.append(report)
                if let live { current = live }
            }
        }
    }

    func finish(frameInterval: Double) async throws -> ConsumerOutcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(returning: engine.outcome(frameInterval: frameInterval))
                }
            }
        }
    }

    func cancel() {}
}

/// A consumer on another Mac, through a worker: frames go out over its connection as they come,
/// and its reports, and for a live kind its model's state, come back after each.
/// Several may share one worker, which runs each on a queue of its own.
final class RemoteFrameConsumer: FrameConsumer, @unchecked Sendable {
    let id = UUID()
    let kind: ConsumerKind
    /// The other Mac's host, as the connection names it.
    let host: String
    private let client: SweepWorkerClient
    private let writer: SweepWorkerWriter
    private let lock = NSLock()
    private var latest: ConsumerReport
    private var history: [ConsumerReport]
    private var count = 0
    private var total = 0
    private var spent = 0.0
    private var current: ConsumerLive?
    /// Whether the connection is this consumer's to close when done, or shared, as by the app.
    private let ownsClient: Bool

    /// `failed` is told why, if the session or its connection fails before the result.
    @MainActor
    init(
        client: SweepWorkerClient, kind: ConsumerKind, ownsClient: Bool = true,
        failed: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.client = client
        self.kind = kind
        host = client.name
        self.ownsClient = ownsClient
        writer = client.writer
        // Where it starts, worked out here as the worker will.
        let start = ConsumerEngine(kind)
        latest = start.report
        history = [latest]
        current = start.live(time: 0)
        client.startConsumer(
            ConsumerSession(id: id, kind: kind),
            report: { [weak self] report, seconds in
                guard let self else { return }
                self.lock.withLock {
                    self.latest = report
                    self.history.append(report)
                    self.spent = seconds
                }
            },
            live: { [weak self] header, payload in
                guard let self, let live = self.lock.withLock({ self.current }),
                    let next = try? live.updated(by: header, payload: payload)
                else { return }
                self.lock.withLock { self.current = next }
            }, failed: failed)
    }

    func report(after frame: Int) -> ConsumerReport? {
        lock.withLock { history.indices.contains(frame + 1) ? history[frame + 1] : nil }
    }

    var sent: Int { lock.withLock { count } }
    var bytes: Int { lock.withLock { total } }
    var seconds: Double { lock.withLock { spent } }
    var report: ConsumerReport { lock.withLock { latest } }
    var live: ConsumerLive? { lock.withLock { current } }

    func send(_ input: ConsumerInput) {
        lock.withLock {
            count += 1
            total += input.byteCount
        }
        // The samples are copied out on the writer's queue, not here.
        writer.enqueue(.input(id, input.header)) { input.payload }
    }

    func finish(frameInterval: Double) async throws -> ConsumerOutcome {
        defer { cancel() }
        return try await client.finishConsumer(id, frameInterval: frameInterval)
    }

    func cancel() {
        let client = client
        if ownsClient {
            Task { @MainActor in client.close() }
        } else {
            // The worker drops the session; the connection stays for the next.
            writer.enqueue(.cancel(id))
        }
    }
}
