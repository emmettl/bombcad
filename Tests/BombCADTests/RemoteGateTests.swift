import Foundation
import Testing

@testable import BombCAD

@Suite("Whether another Mac takes work now")
struct RemoteGateTests {
    private let gate = RemoteGate(
        runners: ["Developer/bombcad-runner"], quietUTC: ["01:30-04:30"], maxLoadPerCore: 1, what: "test")

    private func utc(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(year: 2026, month: 10, day: 11, hour: hour, minute: minute))!
    }

    @Test("A CI job, the quiet window or a high load each refuse it, as Scripts/remote.py does")
    func refusals() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let job = ["\(home)/Developer/bombcad-runner/bin/Runner.Worker spawnclient 1 2"]
        #expect(
            gate.refusal(now: utc(12, 0), load: 2, cores: 10, processes: job)?.contains("runners are busy")
                == true)
        #expect(
            gate.refusal(now: utc(2, 0), load: 2, cores: 10, processes: [])?.contains("quiet window") == true)
        #expect(gate.refusal(now: utc(12, 0), load: 12, cores: 10, processes: [])?.contains("load") == true)
        // Another runner's job is not this gate's business.
        let other = ["\(home)/Developer/roomcad-runner/bin/Runner.Worker spawnclient 1 2"]
        #expect(
            gate.refusal(now: utc(12, 0), load: 2, cores: 10, processes: other).map {
                !$0.contains("runners")
            } ?? true)
        #expect(
            RemoteGate.inWindow(["23:00-01:00"], now: utc(0, 30))
                && !RemoteGate.inWindow(["23:00-01:00"], now: utc(1, 0)))
    }

    @Test("The lock has one holder at a time, and a dead holder's is taken over")
    func lock() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = folder.appending(path: "lock")
        #expect(gate.acquire(at: lock))
        #expect(!gate.acquire(at: lock))
        #expect(RemoteGate.owner(at: lock) == "test")
        RemoteGate.release(at: lock)
        #expect(RemoteGate.owner(at: lock) == nil)
        // As Scripts/remote.py writes it, for a process that has gone.
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data(#"{"pid": 999999, "since": 0, "what": "gone"}"#.utf8).write(
            to: lock.appending(path: "owner"))
        #expect(RemoteGate.owner(at: lock) == nil)
        #expect(gate.acquire(at: lock))
    }

    @Test("The gate travels as one shell-safe word, and the config's missing keys take defaults")
    func encoding() throws {
        #expect(RemoteGate(argument: gate.argument) == gate)
        #expect(gate.argument.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        let config = try JSONDecoder().decode(
            RemoteConfig.self, from: Data(#"{"host": "mini", "workers": ["mini"]}"#.utf8))
        #expect(config.host == "mini" && config.workers == ["mini"] && config.quietUTC == ["01:30-04:30"])
        #expect(config.gate("x").maxLoadPerCore == 1)
    }
}
