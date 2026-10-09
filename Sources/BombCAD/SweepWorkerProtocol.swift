import BlastCore
import DocumentKit
import Foundation

/// Messages between the app and a worker (`BombCAD worker`). Each frame is a JSON message's
/// length as a big-endian 32-bit integer, the JSON, and then a binary payload's length the same
/// way and the payload, empty for most messages. The app starts a worker over SSH and talks to it
/// through the connection's standard input and output; tests talk to one in the same process
/// through pipes. A worker runs one sweep case at a time, and can run models fed by a run
/// elsewhere, frame by frame, several at once: consumer sessions of any kind (see
/// `ConsumerKind`), each on a queue of its own, and thermal sessions, which also send their
/// receivers back after each frame for the app to draw.
enum SweepWorkerMessage: Codable, Equatable, Sendable {
    /// Worker to app, once on starting.
    case hello(SweepWorkerHello)
    /// App to worker: run this case.
    case run(SweepWorkerJob)
    /// App to worker: stop this job; it answers `failed` with `cancelled`.
    case cancel(UUID)
    /// App to worker: finish and exit.
    case shutdown
    /// Worker to app: the fraction of the job's simulated time reached.
    case progress(UUID, Double)
    /// Worker to app: the job's project, its one saved run the result.
    case finished(UUID, SweepWorkerArchive)
    /// Worker to app: the job, or the consumer session, did not finish.
    case failed(UUID, String)
    /// App to worker: start a consumer session for a run.
    case consume(ConsumerSession)
    /// App to worker: a consumer session's next frame; any samples are the payload.
    case input(UUID, ConsumerInput.Header)
    /// Worker to app: where the session has got after a frame.
    case report(UUID, ConsumerReport)
    /// App to worker: no more frames; send the result, frames `interval` seconds apart.
    case finishConsumer(UUID, Double)
    /// Worker to app: the session's result, in the payload (see `ConsumerOutcome.encoded`).
    case outcome(UUID)
    /// Worker to app, for a live session after each frame: the particles' positions and speeds
    /// in the payload (see `FragmentLive.payload`), and the impacts new since the last.
    case live(UUID, LiveFrameHeader)
    /// App to worker: start reckoning a run's thermal radiation.
    case thermal(ThermalSession)
    /// App to worker: the fireball at the next frame of a thermal session.
    case fireball(UUID, FireballFrame)
    /// Worker to app, after each frame of a thermal session: every receiver's fluence and peak
    /// irradiance so far in the payload (see `ThermalLive.payload`).
    case thermalLive(UUID, ThermalLiveHeader)
    /// App to worker: no more frames; send the thermal session's result.
    case finishThermal(UUID)
    /// Worker to app: the thermal session's result, as JSON in the payload.
    case thermalResult(UUID)

    static let cancelled = "cancelled"
}

struct SweepWorkerHello: Codable, Equatable, Sendable {
    static let protocolVersion = 4
    var protocolVersion = Self.protocolVersion
    var solverVersion = SavedSimulationRun.solverVersion
    var device: String
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
}

struct SweepWorkerJob: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var project: SweepWorkerArchive
}

struct ConsumerSession: Codable, Equatable, Sendable {
    var id: UUID
    var kind: ConsumerKind
}

struct ThermalSession: Codable, Equatable, Sendable {
    var id: UUID
    var spec: ThermalSpec
    var scene: FragmentScene
}

struct ThermalLiveHeader: Codable, Equatable, Sendable {
    /// Frames consumed, this one included.
    var frames: Int
    var time: Double
}

struct LiveFrameHeader: Codable, Equatable, Sendable {
    var time: Double
    var fragmentCount: Int
    var impacts: [FragmentImpact]
}

/// A message and its payload.
struct SweepWorkerPacket: Sendable {
    var message: SweepWorkerMessage
    var payload = Data()
}

/// A project archive as it travels: the manifest and every file.
struct SweepWorkerArchive: Codable, Equatable, Sendable {
    var manifest: ProjectManifest
    var files: [String: Data]

    init(_ archive: ProjectArchive) {
        manifest = archive.manifest
        files = archive.files
    }

    func archive() throws -> ProjectArchive { try ProjectArchive(manifest: manifest, files: files) }
}

enum SweepWorkerFrame {
    /// Larger messages or payloads are refused: projects and results are limited to 256 MiB, and
    /// base64 adds a third.
    static let maximumBytes = 512 << 20

    static func encode(_ message: SweepWorkerMessage, payload: Data = Data()) throws -> Data {
        let body = try JSONEncoder().encode(message)
        return length(body.count) + body + length(payload.count) + payload
    }

    private static func length(_ count: Int) -> Data {
        var length = UInt32(count).bigEndian
        return Data(bytes: &length, count: 4)
    }

    /// Reads frames from `handle` on a thread of their own until it closes or fails.
    static func packets(from handle: FileHandle) -> AsyncThrowingStream<SweepWorkerPacket, Error> {
        AsyncThrowingStream { continuation in
            let thread = Thread {
                do {
                    while let count = try readLength(from: handle, atStart: true) {
                        guard let body = try read(count, from: handle) else {
                            throw ProjectFileError.invalid("A worker message was cut short.")
                        }
                        let message = try JSONDecoder().decode(SweepWorkerMessage.self, from: body)
                        guard let size = try readLength(from: handle, atStart: false) else {
                            throw ProjectFileError.invalid("A worker message was cut short.")
                        }
                        var payload = Data()
                        if size > 0 {
                            guard let data = try read(size, from: handle) else {
                                throw ProjectFileError.invalid("A worker message was cut short.")
                            }
                            payload = data
                        }
                        continuation.yield(SweepWorkerPacket(message: message, payload: payload))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.start()
        }
    }

    /// The messages alone.
    static func messages(from handle: FileHandle) -> AsyncThrowingStream<SweepWorkerMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await packet in packets(from: handle) { continuation.yield(packet.message) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func readLength(from handle: FileHandle, atStart: Bool) throws -> Int? {
        guard let bytes = try read(4, from: handle) else {
            if atStart { return nil }
            throw ProjectFileError.invalid("A worker message was cut short.")
        }
        let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard count <= maximumBytes else {
            throw ProjectFileError.invalid("A worker message of \(count) bytes is too large.")
        }
        return count
    }

    /// Exactly `count` bytes, or nil at the end of the stream before any arrive.
    private static func read(_ count: Int, from handle: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                if data.isEmpty { return nil }
                throw ProjectFileError.invalid("A worker message was cut short.")
            }
            data.append(chunk)
        }
        return data
    }
}

/// Writes frames to a handle in order, from a queue of its own.
final class SweepWorkerWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.bombcad.worker-writer")

    init(_ handle: FileHandle) { self.handle = handle }

    /// Writes a frame, waiting until it is written.
    func send(_ message: SweepWorkerMessage, payload: Data = Data()) throws {
        let frame = try SweepWorkerFrame.encode(message, payload: payload)
        try queue.sync { try handle.write(contentsOf: frame) }
    }

    /// Writes a frame after any before it, without waiting. A failure is lost, and shows as the
    /// worker going quiet.
    func enqueue(_ message: SweepWorkerMessage, payload: Data = Data()) {
        enqueue(message) { payload }
    }

    /// The same, the payload made, and the frame put together, on the writer's queue: for a large
    /// payload, so that the caller, such as the thread driving the GPU, does not wait for copies.
    func enqueue(_ message: SweepWorkerMessage, payload: @escaping @Sendable () -> Data) {
        queue.async { [handle] in
            guard let frame = try? SweepWorkerFrame.encode(message, payload: payload()) else { return }
            try? handle.write(contentsOf: frame)
        }
    }
}
