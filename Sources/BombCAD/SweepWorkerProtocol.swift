import DocumentKit
import Foundation

/// Messages between the app and a sweep worker (`BombCAD worker`), one JSON object a frame, each
/// frame its length as a big-endian 32-bit integer and then the JSON. The app starts a worker
/// over SSH and talks to it through the connection's standard input and output; tests talk to
/// one in the same process through pipes. One job runs at a time.
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
    /// Worker to app: the job did not finish.
    case failed(UUID, String)

    static let cancelled = "cancelled"
}

struct SweepWorkerHello: Codable, Equatable, Sendable {
    static let protocolVersion = 1
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
    /// Larger frames are refused: projects and results are limited to 256 MiB, and base64 adds a
    /// third.
    static let maximumBytes = 512 << 20

    static func encode(_ message: SweepWorkerMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Reads frames from `handle` on a thread of their own until it closes or fails.
    static func messages(from handle: FileHandle) -> AsyncThrowingStream<SweepWorkerMessage, Error> {
        AsyncThrowingStream { continuation in
            let thread = Thread {
                do {
                    while let length = try read(4, from: handle) {
                        let count = Int(
                            length.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
                        guard count <= maximumBytes else {
                            throw ProjectFileError.invalid("A worker message of \(count) bytes is too large.")
                        }
                        guard let body = try read(count, from: handle) else {
                            throw ProjectFileError.invalid("A worker message was cut short.")
                        }
                        continuation.yield(try JSONDecoder().decode(SweepWorkerMessage.self, from: body))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.start()
        }
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

/// Writes frames to a handle, one at a time.
final class SweepWorkerWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) { self.handle = handle }

    func send(_ message: SweepWorkerMessage) throws {
        let frame = try SweepWorkerFrame.encode(message)
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: frame)
    }
}
