import CryptoKit
import Foundation

/// Fetching the learned field model's weights (`LearnedField.Release`): only when the user has
/// clicked Download. The file is fetched to a temporary place, checked against the SHA-256 the app
/// pins and read as weights, and only then moved into place, so a failed, cancelled or wrong
/// download leaves nothing behind (emmettl/bombcad-work#67).
public enum LearnedFieldDownload {
    /// Downloads `source` (the release's URL; a `file://` one in tests) and keeps it at
    /// `destination` if its SHA-256 is `sha256`. Cancelling the task cancels the download.
    @discardableResult
    public static func install(
        from source: URL = LearnedField.Release.url, to destination: URL = LearnedField.defaultWeightsURL,
        sha256: String = LearnedField.Release.sha256, session: URLSession = .shared
    ) async throws -> URL {
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
        guard found == sha256.lowercased() else {
            throw LearnedFieldError.checksum(expected: sha256, found: found)
        }
        // The right bytes are the right weights, but read them once so a bad pin cannot keep a file
        // the app then refuses at every estimate.
        _ = try LearnedField.Weights(contentsOf: downloaded)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: downloaded, to: staged)
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
