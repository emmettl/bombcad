import BlastCore
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Application preferences", .serialized)
struct AppPreferencesTests {
    private func withStore(_ body: (UserDefaults) throws -> Void) throws {
        let name = "dev.bombcad.preferences-test.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        try body(store)
    }

    @Test("Preferences round-trip and invalid stored choices fall back safely")
    func persistence() throws {
        try withStore { store in
            #expect(AppPreferences.load(from: store) == AppPreferences())
            var preferences = AppPreferences()
            preferences.resolution = .coarse
            preferences.detailedCharge = true
            preferences.sharpShocks = true
            preferences.playbackSpeed = .x25
            preferences.save(to: store)
            #expect(AppPreferences.load(from: store) == preferences)
            store.set("unknown-grid", forKey: AppPreferences.Key.resolution)
            store.set(-1, forKey: AppPreferences.Key.playbackSpeed)
            let fallback = AppPreferences.load(from: store)
            #expect(fallback.resolution == .medium && fallback.playbackSpeed == .x100)
            #expect(fallback.detailedCharge && fallback.sharpShocks)
        }
    }

    @Test("New-project defaults do not override a saved project's numerical settings")
    func savedProjects() throws {
        let existing = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        let saved = try existing.makeArchive()
        var preferences = AppPreferences()
        preferences.resolution = .coarse
        preferences.detailedCharge = true
        preferences.sharpShocks = true
        let newProject = ProjectDocument.newProject(preferences: preferences)
        #expect(newProject.runSettings?.resolution == "coarse")
        #expect(newProject.runSettings?.detailedCharge == true && newProject.runSettings?.sharpShocks == true)
        let reopened = try ProjectDocument(archive: saved)
        #expect(reopened.runSettings == existing.runSettings)
        #expect(reopened.runSettings?.resolution == "medium")
    }

    @Test("Playback defaults apply when a window opens and do not become saved project inputs")
    func playback() {
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        var preferences = AppPreferences()
        preferences.playbackSpeed = .x25
        let session = ProjectSession(document: document, preferences: preferences)
        #expect(session.model.speed == .x25)
        #expect(session.snapshot == document)
        preferences.playbackSpeed = .x1000
        #expect(session.model.speed == .x25)
        session.model.speed = .unlimited
        #expect(session.snapshot == document)
    }

    @Test("Sweep hosts are a list, and a single host saved before moves into it once")
    func sweepHosts() throws {
        #expect(AppPreferences.hosts(" mini \n\nstudio.local\nmini\n") == ["mini", "studio.local"])
        #expect(AppPreferences.text(["a", "b", "a", " "]) == "a\nb")
        try withStore { store in
            store.set("scrimply-ci-tb", forKey: AppPreferences.Key.legacySweepHost)
            store.set(true, forKey: AppPreferences.Key.sweepUsesRemote)
            var preferences = AppPreferences.load(from: store)
            #expect(preferences.sweepHosts == ["scrimply-ci-tb"])
            #expect(preferences.sweepRemoteHosts == ["scrimply-ci-tb"])
            #expect(store.string(forKey: AppPreferences.Key.legacySweepHost) == nil)
            preferences.sweepHosts = ["scrimply-ci-tb", "studio.local"]
            preferences.save(to: store)
            // An old host written again later does not replace the list.
            store.set("old", forKey: AppPreferences.Key.legacySweepHost)
            #expect(AppPreferences.load(from: store).sweepHosts == ["scrimply-ci-tb", "studio.local"])
            preferences.sweepUsesRemote = false
            #expect(preferences.sweepRemoteHosts.isEmpty)
        }
    }

    @Test("Restoring defaults changes only owned preference keys")
    func reset() throws {
        try withStore { store in
            store.set("keep", forKey: "unrelated")
            var custom = AppPreferences()
            custom.resolution = .fine
            custom.detailedCharge = true
            custom.save(to: store)
            AppPreferences().save(to: store)
            #expect(AppPreferences.load(from: store) == AppPreferences())
            #expect(store.string(forKey: "unrelated") == "keep")
        }
    }
}
