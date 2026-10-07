import Foundation

/// App-wide defaults. Saved projects retain their own numerical settings.
struct AppPreferences: Equatable, Sendable {
    enum Key {
        static let resolution = "newProject.resolution"
        static let detailedCharge = "newProject.detailedCharge"
        static let sharpShocks = "newProject.sharpShocks"
        static let playbackSpeed = "playback.defaultSpeed"
    }

    var resolution: Resolution = .medium
    var detailedCharge = false
    var sharpShocks = false
    var playbackSpeed: PlaybackSpeed = .x100

    static func load(from store: UserDefaults = .standard) -> Self {
        var preferences = Self()
        if let value = store.string(forKey: Key.resolution), let resolution = Resolution(rawValue: value) {
            preferences.resolution = resolution
        }
        preferences.detailedCharge = store.object(forKey: Key.detailedCharge) as? Bool ?? false
        preferences.sharpShocks = store.object(forKey: Key.sharpShocks) as? Bool ?? false
        if let value = store.object(forKey: Key.playbackSpeed) as? NSNumber,
            let speed = PlaybackSpeed(rawValue: value.doubleValue)
        {
            preferences.playbackSpeed = speed
        }
        return preferences
    }

    func save(to store: UserDefaults = .standard) {
        store.set(resolution.rawValue, forKey: Key.resolution)
        store.set(detailedCharge, forKey: Key.detailedCharge)
        store.set(sharpShocks, forKey: Key.sharpShocks)
        store.set(playbackSpeed.rawValue, forKey: Key.playbackSpeed)
    }
}
