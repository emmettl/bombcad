import BlastCore
import Foundation

/// How this Mac's runs have compared with `RunCost`'s estimate for an unloaded M4 Max: each
/// finished headless run's wall time over its estimate, the last 16 kept in the user's caches,
/// shared by the app and `BombCAD run`. Their median scales the advisor's estimates to this Mac
/// as it has been running.
struct RunCostStore: Sendable {
    let url: URL

    static var standard: RunCostStore {
        RunCostStore(url: URL.cachesDirectory.appending(path: "BombCAD/run-costs.json"))
    }

    static let kept = 16

    private struct Record: Codable {
        var estimate: Double
        var measured: Double
        var date: Date
    }

    private func records() -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// Notes a run estimated at `estimate` seconds that took `measured`; runs under a second
    /// are left out, being mostly the cost of starting.
    func record(estimate: Double, measured: Double, date: Date = Date()) {
        guard estimate >= 1, measured > 0, estimate.isFinite, measured.isFinite else { return }
        var list = records()
        list.append(Record(estimate: estimate, measured: measured, date: date))
        list = Array(list.suffix(Self.kept))
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
    }

    /// The median of measured over estimated, or nil before three runs have been noted.
    var factor: Double? {
        let ratios = records().map { $0.measured / $0.estimate }.sorted()
        guard ratios.count >= 3 else { return nil }
        let middle = ratios.count / 2
        return ratios.count % 2 == 1 ? ratios[middle] : (ratios[middle - 1] + ratios[middle]) / 2
    }
}
