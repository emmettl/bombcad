import Foundation

/// The other Macs this one shares work with, as every session reads them from
/// `~/.config/bombcad/remote.json` (see docs/continuous-integration.md): the one checks run on,
/// those `BombCAD sweep` and `BombCAD ensemble` take as workers when free, and what makes one
/// busy. `Scripts/remote.py` reads the same file.
struct RemoteConfig: Codable, Equatable, Sendable {
    var host: String?
    var workers: [String] = []
    var runners: [String] = [
        "Developer/bombcad-runner", "Developer/actions-runner", "Developer/actions-runner-2",
    ]
    var quietUTC: [String] = ["01:30-04:30"]
    var maxLoadPerCore = 1.0

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RemoteConfig()
        host = try values.decodeIfPresent(String.self, forKey: .host)
        workers = try values.decodeIfPresent([String].self, forKey: .workers) ?? defaults.workers
        runners = try values.decodeIfPresent([String].self, forKey: .runners) ?? defaults.runners
        quietUTC = try values.decodeIfPresent([String].self, forKey: .quietUTC) ?? defaults.quietUTC
        maxLoadPerCore =
            try values.decodeIfPresent(Double.self, forKey: .maxLoadPerCore) ?? defaults.maxLoadPerCore
    }

    static var url: URL {
        ProcessInfo.processInfo.environment["BOMBCAD_REMOTE_CONFIG"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/bombcad/remote.json")
    }

    /// The file's settings, or none: no other Mac is used unless named.
    static func load() -> RemoteConfig {
        guard let data = try? Data(contentsOf: url) else { return RemoteConfig() }
        return (try? JSONDecoder().decode(RemoteConfig.self, from: data)) ?? RemoteConfig()
    }

    /// The gate a worker taken by default passes on its Mac before taking work.
    func gate(_ what: String) -> RemoteGate {
        RemoteGate(runners: runners, quietUTC: quietUTC, maxLoadPerCore: maxLoadPerCore, what: what)
    }
}

/// Whether a Mac should take work from another now, decided on that Mac as `Scripts/remote.py`
/// decides it: not while its CI runners have a job, in its quiet window, above a load, or while
/// another BombCAD job holds its lock, `~/bombcad-remote/lock`, which a worker that passes holds
/// until it ends.
struct RemoteGate: Codable, Equatable, Sendable {
    var runners: [String]
    var quietUTC: [String]
    var maxLoadPerCore: Double
    /// What the work is, for whoever finds the lock held.
    var what: String

    static var lock: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "bombcad-remote/lock")
    }

    /// As the worker's argument, base64 JSON, which the shell passes untouched.
    var argument: String { (try? JSONEncoder().encode(self))?.base64EncodedString() ?? "" }

    init(runners: [String], quietUTC: [String], maxLoadPerCore: Double, what: String) {
        self.runners = runners
        self.quietUTC = quietUTC
        self.maxLoadPerCore = maxLoadPerCore
        self.what = what
    }

    init?(argument: String) {
        guard let data = Data(base64Encoded: argument),
            let gate = try? JSONDecoder().decode(RemoteGate.self, from: data)
        else { return nil }
        self = gate
    }

    /// Why this Mac should not take the work now, or nil.
    func refusal(now: Date = .now, load: Double? = nil, cores: Int? = nil, processes: [String]? = nil)
        -> String?
    {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commands = processes ?? Self.processes()
        let busy = runners.filter { runner in
            commands.contains { $0.hasPrefix("\(home)/\(runner)/bin/Runner.Worker") }
        }
        if !busy.isEmpty { return "its CI runners are busy (\(busy.joined(separator: ", ")))" }
        if Self.inWindow(quietUTC, now: now) {
            return "it is the quiet window (\(quietUTC.joined(separator: ", ")) UTC)"
        }
        var averages = [0.0, 0, 0]
        let load = load ?? (getloadavg(&averages, 3) > 0 ? averages[0] : 0)
        let cores = cores ?? ProcessInfo.processInfo.activeProcessorCount
        if load / Double(max(cores, 1)) > maxLoadPerCore {
            return String(format: "its load is %.1f on %d cores", load, cores)
        }
        if let owner = Self.owner() { return "another BombCAD job holds it (\(owner))" }
        return nil
    }

    /// Whether UTC `now` falls in one of `windows`, "HH:MM-HH:MM", which may cross midnight.
    static func inWindow(_ windows: [String], now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return windows.contains { window in
            let ends = window.split(separator: "-").map { text -> Int in
                let numbers = text.split(separator: ":").compactMap { Int($0) }
                return numbers.count == 2 ? numbers[0] * 60 + numbers[1] : 0
            }
            guard ends.count == 2 else { return false }
            return ends[0] <= ends[1]
                ? (ends[0] <= minute && minute < ends[1]) : (minute >= ends[0] || minute < ends[1])
        }
    }

    private static func processes() -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-Ao", "command"]
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private struct Owner: Codable {
        var pid: Int32
        var since: Double
        var what: String
    }

    /// What holds the lock, if a live process does, for under six hours.
    static func owner(at lock: URL = lock) -> String? {
        guard FileManager.default.fileExists(atPath: lock.path) else { return nil }
        guard let data = try? Data(contentsOf: lock.appending(path: "owner")),
            let owner = try? JSONDecoder().decode(Owner.self, from: data)
        else { return "starting" }
        guard kill(owner.pid, 0) == 0, Date().timeIntervalSince1970 - owner.since < 6 * 3600 else {
            return nil
        }
        return owner.what
    }

    /// Takes the lock for this process, if it is free or its holder gone.
    func acquire(at lock: URL = lock) -> Bool {
        let manager = FileManager.default
        if Self.owner(at: lock) == nil { try? manager.removeItem(at: lock) }
        try? manager.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? manager.createDirectory(at: lock, withIntermediateDirectories: false)) != nil else {
            return false
        }
        let owner = Owner(pid: getpid(), since: Date().timeIntervalSince1970, what: what)
        try? JSONEncoder().encode(owner).write(to: lock.appending(path: "owner"))
        return true
    }

    /// Lets the lock go, if this process holds it.
    static func release(at lock: URL = lock) {
        guard let data = try? Data(contentsOf: lock.appending(path: "owner")),
            let owner = try? JSONDecoder().decode(Owner.self, from: data), owner.pid == getpid()
        else { return }
        try? FileManager.default.removeItem(at: lock)
    }
}
