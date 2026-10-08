import BlastCore
import CryptoKit
import DocumentKit
import Foundation

/// The app's side of a sweep worker: sends it one case at a time and checks what comes back.
@MainActor
final class SweepWorkerClient {
    /// The worker's host, or what stands for it.
    let name: String
    private(set) var hello: SweepWorkerHello?
    /// Safe from any thread: frames go out in the order given.
    nonisolated let writer: SweepWorkerWriter
    private var reports: [UUID: @Sendable (ConsumerReport) -> Void] = [:]
    private var fragmentWaiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    private let onClose: () -> Void
    private var reader: Task<Void, Never>?
    private var helloWaiter: CheckedContinuation<SweepWorkerHello, Error>?
    private var waiting: [UUID: CheckedContinuation<SweepWorkerArchive, Error>] = [:]
    private var progress: [UUID: (Double) -> Void] = [:]
    private var closedError: Error?
    /// Why the worker stopped, for messages: what it last wrote to standard error, if anything.
    var diagnostics: () -> String = { "" }

    /// Talks to a worker that reads `output` and writes `input`, and waits for its greeting.
    init(name: String, input: FileHandle, output: FileHandle, onClose: @escaping () -> Void = {}) {
        self.name = name
        writer = SweepWorkerWriter(output)
        self.onClose = onClose
        reader = Task { [weak self] in
            do {
                for try await packet in SweepWorkerFrame.packets(from: input) {
                    self?.receive(packet.message, payload: packet.payload)
                }
                self?.closed(ProjectFileError.invalid("The worker on \(name) stopped."))
            } catch {
                self?.closed(error)
            }
        }
    }

    /// Waits for the worker's greeting, and checks it runs this solver.
    func start(timeout: Duration = .seconds(60)) async throws -> SweepWorkerHello {
        if let hello { return hello }
        let timer = Task { [weak self] in
            // Cancelled once the greeting arrives.
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.closed(ProjectFileError.invalid("The worker on \(self?.name ?? "") did not answer."))
        }
        defer { timer.cancel() }
        let hello = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SweepWorkerHello, Error>) in
            if let closedError {
                continuation.resume(throwing: closedError)
            } else {
                helloWaiter = continuation
            }
        }
        guard hello.protocolVersion == SweepWorkerHello.protocolVersion,
            hello.solverVersion == SavedSimulationRun.solverVersion
        else {
            close()
            throw ProjectFileError.invalid("The worker on \(name) runs a different version of BombCAD.")
        }
        return hello
    }

    /// Runs a sweep case on the worker and returns its result, checked against the case's inputs.
    func run(_ item: ParameterSweepPlan.Case, progress: @escaping (Double) -> Void = { _ in }) async throws
        -> SavedSimulationRun
    {
        var document = ProjectDocument(scenario: item.inputs.scenario)
        document.runSettings = item.inputs.settings
        let job = SweepWorkerJob(
            id: UUID(), name: item.name, project: SweepWorkerArchive(try document.makeArchive()))
        let writer = self.writer
        let result: SweepWorkerArchive = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SweepWorkerArchive, Error>) in
                if let closedError {
                    continuation.resume(throwing: closedError)
                    return
                }
                waiting[job.id] = continuation
                self.progress[job.id] = progress
                do {
                    try writer.send(.run(job))
                } catch {
                    waiting[job.id] = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            try? writer.send(.cancel(job.id))
        }
        let returned = try ProjectDocument(archive: result.archive())
        guard var run = returned.savedRuns.first(where: { $0.name == item.name }) else {
            throw ProjectFileError.invalid("The worker on \(name) returned no result for \(item.name).")
        }
        // The worker must have run exactly this case.
        guard
            run.inputSHA256
                == (try SavedSimulationRun.fingerprint(item.inputs.scenario, settings: item.inputs.settings))
        else {
            throw ProjectFileError.invalid("The worker on \(name) ran different inputs for \(item.name).")
        }
        // A worker runs a copy of this app's own executable, outside its bundle.
        if run.appVersion == "development",
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        {
            run.appVersion = version
        }
        try run.validate()
        return run
    }

    /// Tells the worker to finish, and lets it go.
    func close() {
        try? writer.send(.shutdown)
        closed(CancellationError())
        reader?.cancel()
        onClose()
    }

    /// Starts a consumer session, whose reports go to `report`.
    func startConsumer(_ session: ConsumerSession, report: @escaping @Sendable (ConsumerReport) -> Void) {
        reports[session.id] = report
        writer.enqueue(.consume(session))
    }

    /// Asks for a consumer session's result, after every frame sent.
    func finishConsumer(_ id: UUID, frameInterval: Double) async throws -> FragmentResult {
        let payload = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            if let closedError {
                continuation.resume(throwing: closedError)
                return
            }
            fragmentWaiters[id] = continuation
            writer.enqueue(.finishConsumer(id, frameInterval))
        }
        reports[id] = nil
        guard payload.count >= 4 else {
            throw ProjectFileError.invalid("The fragments' result was cut short.")
        }
        let length = Int(payload.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard payload.count >= 4 + length else {
            throw ProjectFileError.invalid("The fragments' result was cut short.")
        }
        var result = try JSONDecoder().decode(FragmentResult.self, from: payload.subdata(in: 4..<4 + length))
        try result.setTrajectories(payload.subdata(in: 4 + length..<payload.count))
        return result
    }

    private func receive(_ message: SweepWorkerMessage, payload: Data) {
        switch message {
        case .report(let id, let report):
            reports[id]?(report)
        case .fragments(let id):
            fragmentWaiters.removeValue(forKey: id)?.resume(returning: payload)
        case .hello(let hello):
            self.hello = hello
            helloWaiter?.resume(returning: hello)
            helloWaiter = nil
        case .progress(let id, let fraction):
            progress[id]?(fraction)
        case .finished(let id, let archive):
            progress[id] = nil
            waiting.removeValue(forKey: id)?.resume(returning: archive)
        case .failed(let id, let reason):
            fragmentWaiters.removeValue(forKey: id)?.resume(
                throwing: ProjectFileError.invalid("On \(name): \(reason)"))
            progress[id] = nil
            waiting.removeValue(forKey: id)?.resume(
                throwing: reason == SweepWorkerMessage.cancelled
                    ? CancellationError() : ProjectFileError.invalid("On \(name): \(reason)"))
        default:
            break
        }
    }

    private func closed(_ error: Error) {
        guard closedError == nil else { return }
        let detail = diagnostics()
        let error =
            error is CancellationError || detail.isEmpty
            ? error : ProjectFileError.invalid("\(error.localizedDescription) \(detail)")
        closedError = error
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        for continuation in waiting.values { continuation.resume(throwing: error) }
        waiting = [:]
        for continuation in fragmentWaiters.values { continuation.resume(throwing: error) }
        fragmentWaiters = [:]
        progress = [:]
    }
}

/// Starts sweep workers on other Macs over SSH. The worker is a copy of this app's own executable
/// and resource bundles, sent once per build to `~/Library/Caches/BombCAD/remote/<hash>` on the
/// other Mac, so it always runs this solver. SSH must log in without a password (a key, as for
/// any `BatchMode` connection).
enum RemoteSweepWorker {
    static let ssh = "/usr/bin/ssh"
    static let rsync = "/usr/bin/rsync"
    static let options = [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o",
        "ServerAliveCountMax=4",
    ]
    static let buildsKept = 3

    /// Connects to `host`, an SSH host name or alias, sending this build first if it is not
    /// there yet.
    @MainActor
    static func connect(host: String) async throws -> SweepWorkerClient {
        try validate(host)
        let directory = try await Task.detached(priority: .userInitiated) { try install(on: host) }.value

        let process = Process()
        process.executableURL = URL(filePath: ssh)
        process.arguments = options + [host, "exec \(directory)/BombCAD worker"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let log = ErrorLog()
        errors.fileHandleForReading.readabilityHandler = { handle in log.append(handle.availableData) }
        try process.run()
        let client = SweepWorkerClient(
            name: host, input: output.fileHandleForReading, output: input.fileHandleForWriting
        ) {
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
        client.diagnostics = { log.tail }
        do {
            _ = try await client.start()
        } catch {
            client.close()
            throw error
        }
        return client
    }

    /// A host name or alias that SSH cannot take for an option or a list.
    nonisolated static func validate(_ host: String) throws {
        guard !host.isEmpty, !host.hasPrefix("-"),
            host.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "._-@:[]".unicodeScalars.contains($0)
            })
        else {
            throw ProjectFileError.invalid("Enter an SSH host name or alias, such as my-mac.local.")
        }
    }

    /// This build's executable and resource bundles, and a short hash of them all.
    nonisolated static func payload() throws -> (hash: String, files: [URL]) {
        guard let executable = Bundle.main.executableURL else {
            throw ProjectFileError.invalid("Cannot find BombCAD's own executable.")
        }
        let folders = Set(
            [Bundle.main.resourceURL, executable.deletingLastPathComponent()].compactMap { $0 })
        var bundles: [URL] = []
        for folder in folders {
            let contents =
                (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
                ?? []
            bundles += contents.filter {
                $0.pathExtension == "bundle"
                    && ($0.lastPathComponent.hasPrefix("BombCAD_")
                        || $0.lastPathComponent.hasPrefix("ContinuumKit_"))
            }
        }
        bundles.sort { $0.lastPathComponent < $1.lastPathComponent }
        var hash = SHA256()
        hash.update(data: try Data(contentsOf: executable))
        for bundle in bundles {
            let files =
                FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path } ?? []
            for file in files {
                hash.update(data: Data(file.path.dropFirst(bundle.path.count).utf8))
                hash.update(data: try Data(contentsOf: file))
            }
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return (String(hex.prefix(16)), [executable] + bundles)
    }

    /// Makes sure this build is on `host`, and returns its folder there, relative to home.
    nonisolated static func install(on host: String) throws -> String {
        let (hash, files) = try payload()
        let root = "Library/Caches/BombCAD/remote"
        let directory = "\(root)/\(hash)"
        let check = try command(
            ssh, options + [host, "test -x \(directory)/BombCAD && echo present; uname -m"])
        guard check.status == 0 || check.status == 1 else {
            throw ProjectFileError.invalid("Cannot reach \(host) over SSH. \(check.errors)")
        }
        guard check.output.contains("arm64") else {
            throw ProjectFileError.invalid("\(host) is not an Apple silicon Mac.")
        }
        if !check.output.contains("present") {
            _ = try command(ssh, options + [host, "mkdir -p \(directory)"], require: true)
            _ = try command(
                rsync,
                ["-a", "-e", ([ssh] + options).joined(separator: " ")] + files.map(\.path) + [
                    "\(host):\(directory)/"
                ],
                require: true)
            // The executable has left its app bundle, so it is signed afresh on its own; and only
            // the newest builds are kept.
            _ = try command(
                ssh,
                options + [
                    host,
                    "codesign --force --sign - \(directory)/BombCAD 2>/dev/null; cd \(root) && ls -t | tail -n +\(buildsKept + 1) | while read old; do rm -rf -- \"$old\"; done",
                ], require: true)
        }
        return directory
    }

    nonisolated private static func command(_ path: String, _ arguments: [String], require: Bool = false)
        throws
        -> (status: Int32, output: String, errors: String)
    {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = (
            process.terminationStatus, String(decoding: out, as: UTF8.self),
            String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if require, result.0 != 0 {
            throw ProjectFileError.invalid("\(URL(filePath: path).lastPathComponent) failed: \(result.2)")
        }
        return result
    }

    /// The last few lines a worker wrote to standard error.
    private final class ErrorLog: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            text = String((text + String(decoding: data, as: UTF8.self)).suffix(2000))
        }

        var tail: String {
            lock.lock()
            defer { lock.unlock() }
            return text.split(separator: "\n").suffix(3).joined(separator: " ")
        }
    }
}
