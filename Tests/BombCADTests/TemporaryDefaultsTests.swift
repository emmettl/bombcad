import Foundation
import Testing

@Suite("Temporary preferences")
struct TemporaryDefaultsTests {
    @Test("A test's preferences live in its own folder and leave no plist behind")
    func leavesNoPlist() throws {
        let temporary = try TemporaryDefaults()
        let tag = temporary.folder.lastPathComponent
        temporary.defaults.set(["scale": 0.001], forKey: "profile")
        #expect(
            UserDefaults(suiteName: temporary.suite)?.dictionary(forKey: "profile")?["scale"] as? Double
                == 0.001)
        CFPreferencesAppSynchronize(temporary.suite as CFString)
        #expect(FileManager.default.fileExists(atPath: temporary.suite + ".plist"))

        temporary.remove()
        CFPreferencesAppSynchronize(temporary.suite as CFString)
        #expect(!FileManager.default.fileExists(atPath: temporary.folder.path))
        let preferences = URL.libraryDirectory.appending(path: "Preferences")
        let leaked = try FileManager.default.contentsOfDirectory(atPath: preferences.path).filter {
            $0.contains(tag)
        }
        #expect(leaked.isEmpty)
    }

}
