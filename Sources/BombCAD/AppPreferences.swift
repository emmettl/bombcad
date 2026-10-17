import BlastCore
import Foundation

/// App-wide defaults. Saved projects retain their own numerical settings.
struct AppPreferences: Equatable, Sendable {
    enum Key {
        static let resolution = "newProject.resolution"
        /// Afterburning and hot air for new projects. On by default since 15 October 2026, under a
        /// key of its own: the earlier key held the old default, written back by every save, so
        /// it cannot say whether anyone chose to leave it off.
        static let detailedCharge = "newProject.afterburningAndHotAir"
        static let sharpShocks = "newProject.sharpShocks"
        static let playbackSpeed = "playback.defaultSpeed"
        /// The other Macs to share sweeps with, one SSH host per line.
        static let sweepHosts = "sweep.workerHosts"
        static let sweepUsesRemote = "sweep.usesRemote"
        /// The one other Mac, before there could be several; read once, into `sweepHosts`.
        static let legacySweepHost = "sweep.remoteHost"
        /// The GPU memory each sweep host lets the air take, in bytes, as it said when it last
        /// connected: for the advisor (`AdvisorMachine.workers`).
        static let workerMemory = "sweep.workerMemory"
    }

    /// Notes the GPU memory `host` lets the air take.
    static func recordMemory(_ memory: Int, of host: String, in store: UserDefaults = .standard) {
        var known = store.dictionary(forKey: Key.workerMemory) as? [String: Int] ?? [:]
        known[host] = memory
        store.set(known, forKey: Key.workerMemory)
    }

    /// The sweep hosts whose memory is known, as the advisor weighs them.
    static func workerMachines(in store: UserDefaults = .standard) -> [AdvisorMachine] {
        let known = store.dictionary(forKey: Key.workerMemory) as? [String: Int] ?? [:]
        return hosts(store.string(forKey: Key.sweepHosts) ?? "").compactMap { host in
            known[host].map { AdvisorMachine(name: host, memory: $0) }
        }
    }

    var resolution: Resolution = .medium
    var detailedCharge = true
    var sharpShocks = false
    var playbackSpeed: PlaybackSpeed = .x100
    /// Other Macs to share sweeps with, as SSH host names or aliases, and whether to use them.
    var sweepHosts: [String] = []
    var sweepUsesRemote = false

    /// The hosts sweeps should share cases with: none unless sharing is on.
    var sweepRemoteHosts: [String] { sweepUsesRemote ? sweepHosts : [] }

    /// The hosts in a stored list, one per line, without blanks or repeats.
    static func hosts(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// A list of hosts as stored.
    static func text(_ hosts: [String]) -> String {
        Self.hosts(hosts.joined(separator: "\n")).joined(separator: "\n")
    }

    /// Moves a single host saved by an earlier version into the list, once.
    static func migrate(_ store: UserDefaults = .standard) {
        guard store.object(forKey: Key.sweepHosts) == nil else { return }
        let host =
            store.string(forKey: Key.legacySweepHost)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return }
        store.set(host, forKey: Key.sweepHosts)
        store.removeObject(forKey: Key.legacySweepHost)
    }

    static func load(from store: UserDefaults = .standard) -> Self {
        migrate(store)
        var preferences = Self()
        if let value = store.string(forKey: Key.resolution), let resolution = Resolution(rawValue: value) {
            preferences.resolution = resolution
        }
        preferences.detailedCharge = store.object(forKey: Key.detailedCharge) as? Bool ?? true
        preferences.sharpShocks = store.object(forKey: Key.sharpShocks) as? Bool ?? false
        if let value = store.object(forKey: Key.playbackSpeed) as? NSNumber,
            let speed = PlaybackSpeed(rawValue: value.doubleValue)
        {
            preferences.playbackSpeed = speed
        }
        preferences.sweepHosts = hosts(store.string(forKey: Key.sweepHosts) ?? "")
        preferences.sweepUsesRemote = store.object(forKey: Key.sweepUsesRemote) as? Bool ?? false
        return preferences
    }

    func save(to store: UserDefaults = .standard) {
        store.set(resolution.rawValue, forKey: Key.resolution)
        store.set(detailedCharge, forKey: Key.detailedCharge)
        store.set(sharpShocks, forKey: Key.sharpShocks)
        store.set(playbackSpeed.rawValue, forKey: Key.playbackSpeed)
        store.set(Self.text(sweepHosts), forKey: Key.sweepHosts)
        store.set(sweepUsesRemote, forKey: Key.sweepUsesRemote)
    }
}
