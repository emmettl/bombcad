import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// What recording a run's timeline costs, on the office tower and the made-up district: each
/// frame's size, and the main thread's time capturing it against the run's. Capturing happens
/// between batches, so it delays the run by exactly that much. Set `BOMBCAD_TIMELINE_STUDY` to a
/// folder for the report; long, so not part of the suite.
@MainActor @Suite("What recording a timeline costs", .serialized)
struct RunTimelineCostStudyTests {
    nonisolated static let output = ProcessInfo.processInfo.environment["BOMBCAD_TIMELINE_STUDY"]

    private func measure(_ name: String, _ document: ProjectDocument) async throws -> String {
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.recordsTimelines = true
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(20)) }
        model.run()
        while model.isRunning || model.hasPendingGPUWork || model.recentTimeline == nil {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(20))
        }
        let cost = try #require(model.timelineCost)
        let recent = try #require(model.recentTimeline)
        defer { try? FileManager.default.removeItem(at: recent) }
        // On a Mac doing nothing else, recording must not slow a run by more than a few per cent.
        #expect(cost.seconds / cost.wall < 0.05, "\(name): \(cost.seconds) s of \(cost.wall) s")
        let grid = try #require(model.solver).grid
        // The layers: what they add to the frames, before compression, and how many frames hold each.
        let manifest = try RunTimelineManifest.decode(Data(contentsOf: recent.appending(path: "run.json")))
        var layerBytes = 0
        var held = [0, 0, 0, 0]
        for entry in manifest.entries(.frames) {
            let raw = try TimelineCodec.decompress(Data(contentsOf: recent.appending(path: entry.path)))
            let frame = try TimelineCodec.decode(raw)
            layerBytes += raw.count - TimelineCodec.encode(frame, version: 1).count
            let layers = frame.layers
            for (n, stored) in [
                layers.vents.value != nil, layers.envelopeCodes.value != nil, layers.thermal.value != nil,
                layers.cloud.value != nil,
            ].enumerated() where stored {
                held[n] += 1
            }
        }
        return String(
            format:
                "%@ (%.1f M cells): %.3f s simulated in %.0f s; %d frames, %.2f MB each (%.0f MB in all), captured in %.2f ms each on the main thread, %.2f ms after the first, %.2f%% of the run",
            name, Double(grid.cellCount) / 1e6, model.time, cost.wall, cost.frames,
            Double(cost.bytes) / Double(max(cost.frames, 1)) / 1e6, Double(cost.bytes) / 1e6,
            1000 * cost.seconds / Double(max(cost.frames, 1)),
            1000 * cost.afterFirst / Double(max(cost.frames - 1, 1)),
            100 * cost.seconds / cost.wall)
            + String(
                format:
                    "; layers %.1f kB in all before compression, held by %d, %d, %d and %d frames (vents, envelope codes, thermal, cloud)",
                Double(layerBytes) / 1e3, held[0], held[1], held[2], held[3])
    }

    private func report(_ line: String, _ name: String) throws {
        print(line)
        let folder = URL(filePath: try #require(Self.output), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (line + "\n").write(
            to: folder.appending(path: "timeline-cost-\(name).txt"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: output != nil))
    func office() async throws {
        var office = ProjectDocument(scenario: ScenarioPreset.officeTower.scenario)
        office.runSettings?.duration = 0.05
        try report(try await measure("Office tower to 0.05 s", office), "office")
    }

    @Test(.enabled(if: output != nil))
    func district() async throws {
        let district = try NewDistrictTests().model()
        district.airChoice = .uniform
        await district.lay()
        let preview = try #require(district.preview)
        try report(
            try await measure("Made-up district, \(preview.within) buildings", preview.document), "district")
    }
}
