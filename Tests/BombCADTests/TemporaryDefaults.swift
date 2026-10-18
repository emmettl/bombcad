import Foundation

/// A preferences store for one test that never reaches ~/Library/Preferences.
///
/// A suite made with `UserDefaults(suiteName:)` and a plain name leaves a plist in ~/Library/Preferences even
/// after `removePersistentDomain(forName:)`: cfprefsd writes the emptied domain back later, after the test
/// process has exited, so deleting the file does not help either. A suite named by an absolute path keeps its
/// plist at that path, so these live in a temporary folder that `remove()` deletes with the domain.
struct TemporaryDefaults {
    let folder: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "BombCAD-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = folder.appending(path: "defaults").path
        guard let defaults = UserDefaults(suiteName: suite) else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileWriteUnknown)
        }
        self.defaults = defaults
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Runs `body` with a fresh `TemporaryDefaults` store and removes it afterwards.
func withTemporaryDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let temporary = try TemporaryDefaults()
    defer { temporary.remove() }
    return try body(temporary.defaults)
}
