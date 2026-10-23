import CryptoKit
import Foundation

/// Fetching the learned field model's weights (`LearnedField.Release`): only when the user has
/// clicked Download. Each file is fetched to a temporary place, checked against the SHA-256 the app
/// pins and read as weights; only once every file has passed are they moved into place, so a
/// failed, cancelled or wrong download leaves nothing new behind (emmettl/bombcad-work#67, #69).
public enum LearnedFieldDownload {
    /// One file to fetch: from `source` (the release's URL; a `file://` one in tests) to
    /// `destination`, if its SHA-256 is `sha256`; `bytes` long, as the app says it.
    public struct Item: Sendable, Equatable {
        public var source: URL
        public var destination: URL
        public var sha256: String
        public var bytes: Int

        public init(source: URL, destination: URL, sha256: String, bytes: Int = 0) {
            self.source = source
            self.destination = destination
            self.sha256 = sha256
            self.bytes = bytes
        }

        /// The release's `asset`, to be kept at `destination`.
        public init(_ asset: LearnedField.Release.Asset, to destination: URL) {
            self.init(source: asset.url, destination: destination, sha256: asset.sha256, bytes: asset.bytes)
        }

        /// Whether `destination` already holds the file: there, with the pinned hash.
        public var isInPlace: Bool {
            FileManager.default.fileExists(atPath: destination.path)
                && (try? LearnedFieldDownload.digest(of: destination)) == sha256.lowercased()
        }
    }

    /// The files of `items` not already in place (`Item.isInPlace`).
    public static func missing(_ items: [Item]) -> [Item] { items.filter { !$0.isInPlace } }

    /// Downloads each of `items` not already in place, checks every one, and only then keeps them
    /// all. Cancelling the task cancels the download. Returns the files kept.
    @discardableResult
    public static func install(_ items: [Item], session: URLSession = .shared) async throws -> [URL] {
        var staged: [(file: URL, destination: URL)] = []
        do {
            for item in missing(items) {
                staged.append((try await stage(item, session: session), item.destination))
            }
        } catch {
            for file in staged { try? FileManager.default.removeItem(at: file.file) }
            throw error
        }
        for (n, file) in staged.enumerated() {
            do {
                if FileManager.default.fileExists(atPath: file.destination.path) {
                    _ = try FileManager.default.replaceItemAt(file.destination, withItemAt: file.file)
                } else {
                    try FileManager.default.moveItem(at: file.file, to: file.destination)
                }
            } catch {
                for rest in staged[n...] { try? FileManager.default.removeItem(at: rest.file) }
                throw LearnedFieldError.download(
                    "it could not be kept at \(file.destination.path): \(reason(error))")
            }
        }
        return staged.map(\.destination)
    }

    /// Downloads `source` and keeps it at `destination` if its SHA-256 is `sha256` (one file).
    @discardableResult
    public static func install(
        from source: URL, to destination: URL, sha256: String, session: URLSession = .shared
    ) async throws -> URL {
        let item = Item(source: source, destination: destination, sha256: sha256)
        let staged = try await stage(item, session: session)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw LearnedFieldError.download(
                "it could not be kept at \(destination.path): \(reason(error))")
        }
        return destination
    }

    /// `item` fetched, checked and read as weights, then copied beside its destination under a
    /// hidden name: the staged file, for the caller to move into place or remove.
    static func stage(_ item: Item, session: URLSession) async throws -> URL {
        let source = item.source
        let downloaded: URL
        do {
            let (file, response) = try await session.download(from: source)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: file)
                throw LearnedFieldError.download("\(source.absoluteString) answered \(http.statusCode)")
            }
            downloaded = file
        } catch let error as LearnedFieldError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw LearnedFieldError.cancelled
            }
            throw LearnedFieldError.download(reason(error))
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if Task.isCancelled { throw LearnedFieldError.cancelled }
        let found = try digest(of: downloaded)
        guard found == item.sha256.lowercased() else {
            throw LearnedFieldError.checksum(expected: item.sha256, found: found)
        }
        // The right bytes are the right weights, but read them once so a bad pin cannot keep a file
        // the app then refuses at every estimate.
        _ = try LearnedField.Weights(contentsOf: downloaded)
        let folder = item.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appending(path: ".\(item.destination.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: downloaded, to: staged)
        return staged
    }
    /// A system error's sentence as a clause after a colon: its own full stop dropped, and its
    /// first letter lowered unless it begins a word in capitals ("URL").
    static func reason(_ error: Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        let start = text.prefix(2)
        if start.count == 2, start.first!.isUppercase, start.last!.isLowercase {
            text = text.prefix(1).lowercased() + text.dropFirst()
        }
        return text
    }

    /// A file's SHA-256, in lower-case hex, read a megabyte at a time.
    public static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
