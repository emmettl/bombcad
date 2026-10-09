import BlastCore
import DocumentKit
import Foundation

/// Every receiver's fluence and peak irradiance as of the last frame consumed, for drawing and
/// for keeping the run.
struct ThermalLive: Sendable, Equatable {
    /// Frames consumed so far.
    var frames = 0
    var time: Double = 0
    /// In joules a square metre, one a receiver.
    var fluence: [Float] = []
    /// In watts a square metre, one a receiver.
    var peakIrradiance: [Float] = []

    init(receivers: Int) {
        fluence = [Float](repeating: 0, count: receivers)
        peakIrradiance = fluence
    }

    init(_ exposure: ThermalExposure) {
        frames = exposure.frames.count
        time = exposure.frames.last?.time ?? 0
        // As `ThermalExposure.result` rounds them, so a run kept from these is the same.
        fluence = exposure.fluence.map { Float($0) }
        peakIrradiance = exposure.peakIrradiance
    }

    /// The fluences then the peak irradiances, as little-endian floats.
    var payload: Data {
        (fluence + peakIrradiance).withUnsafeBytes { Data($0) }
    }

    mutating func read(_ payload: Data, header: ThermalLiveHeader) throws {
        let count = fluence.count
        guard payload.count == 8 * count else {
            throw ProjectFileError.invalid("The thermal radiation arrived cut short.")
        }
        payload.withUnsafeBytes { raw in
            for n in 0..<count {
                fluence[n] = raw.loadUnaligned(fromByteOffset: 4 * n, as: Float.self)
                peakIrradiance[n] = raw.loadUnaligned(fromByteOffset: 4 * (count + n), as: Float.self)
            }
        }
        frames = header.frames
        time = header.time
    }
}

/// The producer's side of a thermal study: the fireball goes out a frame at a time, a few
/// numbers each, and the receivers' fluence comes back.
protocol ThermalConsumer: AnyObject, Sendable {
    var receivers: [ThermalReceiver] { get }
    /// Frames sent so far.
    var sent: Int { get }
    /// The receivers as of the last frame consumed.
    var live: ThermalLive { get }
    /// Sends the fireball at the next frame.
    func send(_ frame: FireballFrame)
    /// Waits for every frame sent to be consumed, and returns what the study found.
    func finish() async throws -> ThermalResult
    /// Lets the study go without its result.
    func cancel()
}

/// A thermal study on this Mac's CPU, on a queue of its own.
final class LocalThermalConsumer: ThermalConsumer, @unchecked Sendable {
    let receivers: [ThermalReceiver]
    private let queue = DispatchQueue(label: "dev.bombcad.thermal")
    private let lock = NSLock()
    private var exposure: ThermalExposure
    private var count = 0
    private var current: ThermalLive

    init(spec: ThermalSpec, scene: FragmentScene) {
        exposure = ThermalExposure(spec: spec, scene: scene)
        receivers = exposure.receivers
        current = ThermalLive(receivers: receivers.count)
    }

    var sent: Int { lock.withLock { count } }
    var live: ThermalLive { lock.withLock { current } }

    func send(_ frame: FireballFrame) {
        lock.withLock { count += 1 }
        queue.async { [self] in
            exposure.add(frame)
            let live = ThermalLive(exposure)
            lock.withLock { current = live }
        }
    }

    func finish() async throws -> ThermalResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: exposure.result) }
        }
    }

    func cancel() {}
}

/// A thermal study on another Mac, through a worker: the fireball goes out over its connection
/// frame by frame, and the receivers come back after each.
final class RemoteThermalConsumer: ThermalConsumer, @unchecked Sendable {
    let id = UUID()
    let receivers: [ThermalReceiver]
    private let client: SweepWorkerClient
    private let writer: SweepWorkerWriter
    private let lock = NSLock()
    private var count = 0
    private var current: ThermalLive
    /// Whether the connection is this study's to close when done, or shared, as by the app.
    private let ownsClient: Bool

    @MainActor
    init(client: SweepWorkerClient, spec: ThermalSpec, scene: FragmentScene, ownsClient: Bool = true) {
        self.client = client
        self.ownsClient = ownsClient
        writer = client.writer
        // Laid out here as the worker will.
        receivers = ThermalExposure.receivers(scene: scene, spec: spec)
        current = ThermalLive(receivers: receivers.count)
        client.startThermal(ThermalSession(id: id, spec: spec, scene: scene)) { [weak self] header, payload in
            guard let self else { return }
            var live = self.lock.withLock { self.current }
            guard (try? live.read(payload, header: header)) != nil else { return }
            self.lock.withLock { self.current = live }
        }
    }

    var sent: Int { lock.withLock { count } }
    var live: ThermalLive { lock.withLock { current } }

    func send(_ frame: FireballFrame) {
        lock.withLock { count += 1 }
        writer.enqueue(.fireball(id, frame))
    }

    func finish() async throws -> ThermalResult {
        defer { cancel() }
        return try await client.finishThermal(id)
    }

    func cancel() {
        let client = client
        if ownsClient {
            Task { @MainActor in client.close() }
        } else {
            writer.enqueue(.cancel(id))
        }
    }
}
