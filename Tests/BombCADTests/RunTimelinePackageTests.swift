import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// Kept runs' frames and checkpoints live in `runs/<run id>/` beside the project's archive: the
/// archive never reads them, a save carries a kept run's folder over and drops a forgotten one's,
/// and a staged folder joins the package when the project is saved.
@Suite("Run timelines in the project package", .hangLimit)
struct RunTimelinePackageTests {
    private func folder(_ files: [String: Data]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "timeline-\(UUID().uuidString)")
        for (path, data) in files {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return url
    }

    @Test func runsLieBesideTheArchive() throws {
        let kept = try SavedRunTests().fixture(name: "Kept")
        let dropped = try SavedRunTests().fixture(name: "Dropped")
        var document = ProjectDocument(scenario: kept.scenario)
        document.savedRuns = [kept, dropped]
        var manifest = RunTimelineManifest(
            sceneFingerprint: "a", settingsFingerprint: "b", budgetBytes: 1 << 20)
        manifest.add(.init(kind: .setup, time: 0, step: 0, path: "frames/setup.lzfse", bytes: 3))
        // More files than the archive takes, which it must never be asked to read.
        var files: [String: Data] = [RunTimelineManifest.fileName: try manifest.encoded()]
        for n in 0..<4100 { files[String(format: "frames/chunk-%04d.lzfse", n)] = Data([1, 2, 3]) }
        let staged = try folder(files)
        defer { try? FileManager.default.removeItem(at: staged) }
        let other = try folder([RunTimelineManifest.fileName: Data("{}".utf8)])
        defer { try? FileManager.default.removeItem(at: other) }
        document.runFolders = [kept.id: staged, dropped.id: other]

        let package = try document.packageWrapper(existing: nil)
        let runs = try #require(package.fileWrappers?[RunTimelineManifest.folder]?.fileWrappers)
        #expect(
            Set(runs.keys)
                == [kept.id, dropped.id].map { $0.uuidString.lowercased() }.reduce(into: []) { $0.insert($1) }
        )
        // Written and read back from disk, past the archive's 4,096 entries.
        let disk = FileManager.default.temporaryDirectory.appending(
            path: "package-\(UUID().uuidString).bombcad")
        defer { try? FileManager.default.removeItem(at: disk) }
        try package.write(to: disk, options: [], originalContentsURL: nil)
        #expect(
            FileManager.default.fileExists(
                atPath: disk.appending(
                    path: "runs/\(kept.id.uuidString.lowercased())/frames/chunk-4099.lzfse"
                ).path))
        #expect(try ProjectDocument(fileWrapper: FileWrapper(url: disk)).savedRuns.count == 2)
        let reopened = try ProjectDocument(fileWrapper: package)
        #expect(reopened.savedRuns.map(\.id) == [kept.id, dropped.id])
        #expect(reopened.archive?.files.keys.contains { $0.hasPrefix("runs/") } == false)

        // Forgetting a run drops its folder; the kept one's comes over from the package as it was.
        var resaved = reopened
        resaved.savedRuns = [kept]
        let next = try resaved.packageWrapper(existing: package)
        let nextRuns = try #require(next.fileWrappers?[RunTimelineManifest.folder]?.fileWrappers)
        #expect(Array(nextRuns.keys) == [kept.id.uuidString.lowercased()])
        let carried = try #require(nextRuns[kept.id.uuidString.lowercased()]?.fileWrappers)
        let read = try RunTimelineManifest.decode(
            try #require(carried[RunTimelineManifest.fileName]?.regularFileContents))
        #expect(read == manifest && read.usedBytes == 3)
        // With no run kept, no folder.
        resaved.savedRuns = []
        #expect(try resaved.packageWrapper(existing: next).fileWrappers?[RunTimelineManifest.folder] == nil)
    }

    @Test func theManifestKeepsTimeOrderAndThinsCheckpointsAcrossTheRun() throws {
        var manifest = RunTimelineManifest(sceneFingerprint: "s", settingsFingerprint: "t", budgetBytes: 100)
        for n in [3, 0, 1, 4, 2] {
            manifest.add(.init(kind: .checkpoint, time: Double(n), step: 64 * n, path: "c\(n)", bytes: 30))
        }
        #expect(manifest.entries.map(\.time) == [0, 1, 2, 3, 4])
        #expect(manifest.usedBytes == 150 && manifest.isOverBudget)
        #expect(manifest.checkpointsToThin.map(\.time) == [1, 3])
        manifest.add(.init(kind: .checkpoint, time: 1, step: 64, path: "c1", bytes: 10))
        #expect(manifest.usedBytes == 130 && manifest.entries.count == 5)
        manifest.remove(path: "c1")
        manifest.remove(path: "c3")
        #expect(manifest.usedBytes == 90 && !manifest.isOverBudget)
        var bad = manifest
        bad.add(.init(kind: .frames, time: 0, step: 0, path: "../escape", bytes: 1))
        #expect(throws: (any Error).self) { try RunTimelineManifest.decode(bad.encoded()) }
        #expect(try RunTimelineManifest.decode(manifest.encoded()) == manifest)
    }
}
