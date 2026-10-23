import BlastCore
import DocumentKit
import Foundation
import Metal
import Testing

@testable import BombCAD

/// A kept run's recording sent to a viewer nearby (emmettl/bombcad-work#43): listed from the
/// projects a Mac shares, fetched file by file into a copy the player reads, a frame asked for
/// sent ahead of its turn, and nothing outside the shared projects.
@MainActor @Suite("Shared timelines", .serialized, .hangLimit)
struct SharedTimelineTests {
    @Test func framesGoFirstAndLastThenFillingTheGaps() {
        #expect(SharedTimelines.order(0) == [])
        #expect(SharedTimelines.order(1) == [0])
        #expect(SharedTimelines.order(5) == [0, 4, 2, 1, 3])
        for count in [2, 3, 7, 64, 237, 240] {
            let order = SharedTimelines.order(count)
            #expect(order.sorted() == Array(0..<count))
            #expect(order.prefix(2) == [0, count - 1])
        }
    }

    @Test func pathsStayInsideTheRunsFolder() {
        #expect(SharedTimelines.isSafe("frames/f-000001.lzfse") && SharedTimelines.isSafe("run.json"))
        for path in ["", "/etc/passwd", "../x", "frames/../../x", "frames\\x"] {
            #expect(!SharedTimelines.isSafe(path))
        }
    }

    /// A small run recorded and kept, its project saved in a folder of its own.
    private func savedProject() async throws -> (URL, SavedSimulationRun) {
        let fixture = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: fixture.scenario)
        document.runSettings = fixture.settings
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.recordsTimelines = true
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        model.run()
        while model.isRunning || model.hasPendingGPUWork || model.recentTimeline == nil {
            try #require(model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        try model.keepRun(named: "Recorded")
        let run = try #require(model.savedRuns.last)
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "shared-timeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appending(path: "Wall.bombcad", directoryHint: .isDirectory)
        try ProjectDocument(model: model).packageWrapper(existing: nil).write(
            to: package, options: .atomic, originalContentsURL: nil)
        if let recent = model.recentTimeline { try? FileManager.default.removeItem(at: recent) }
        return (package, run)
    }

    @Test func aSharedRecordingIsListedFetchedAndPlayed() async throws {
        let (package, run) = try await savedProject()
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let (client, server) = localWorker(shared: [package])
        _ = try await client.start()

        let listed = try await client.timelines()
        let shared = try #require(listed.first)
        #expect(listed.count == 1 && shared.run == run.id && shared.name == "Recorded")
        let manifest = try SharedTimelines.manifest(package, run.id)
        #expect(shared.frames == manifest.entries(.frames).count && shared.frames > 2)
        #expect(shared.projectName == "Wall" && shared.encodingVersion == TimelineCodec.version)

        // Fetched whole, the last frame asked for as soon as the setup is in.
        let cache = package.deletingLastPathComponent().appending(path: "cache", directoryHint: .isDirectory)
        let download = try TimelineDownload(shared, cache: cache)
        let fetch = TimelineFetch(id: UUID(), project: shared.project, run: shared.run)
        var kinds: [TimelinePart.Kind] = []
        var frames: [Int] = []
        let wanted = shared.frames / 2 + 1
        let stats = try await client.fetchTimeline(fetch) { part, payload in
            kinds.append(part.kind)
            if part.kind == .frame { frames.append(part.index) }
            if part.kind == .setup { client.preferTimelineFrame(fetch.id, wanted) }
            try? download.receive(part, payload)
        }
        download.finish()
        #expect(Array(kinds.prefix(3)) == [.run, .manifest, .setup])
        #expect(frames.sorted() == Array(0..<shared.frames))
        #expect(stats.parts == shared.frames + 3 && stats.bytes == download.bytes)
        // It went ahead of where the order would have put it.
        let turn = try #require(SharedTimelines.order(shared.frames).firstIndex(of: wanted))
        #expect(try #require(frames.firstIndex(of: wanted)) <= turn)
        #expect(download.run == run && download.isComplete && download.isPlayable)

        // The copy is the run's own folder, byte for byte, and plays.
        let original = SharedTimelines.folder(package, run.id)
        for entry in manifest.entries where entry.kind != .checkpoint {
            #expect(
                try Data(contentsOf: download.folder.appending(path: entry.path))
                    == Data(contentsOf: original.appending(path: entry.path)))
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let player = try RunTimelinePlayer(folder: download.folder, device: device)
        try player.show(player.entries.count - 1)
        #expect(player.frame?.time == manifest.entries(.frames).last?.time)

        // Nothing but the projects shared: another path is refused, and so is a run not kept there.
        await #expect(throws: ProjectFileError.self) {
            _ = try await client.fetchTimeline(
                TimelineFetch(id: UUID(), project: "/etc", run: run.id)
            ) { _, _ in }
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await client.fetchTimeline(
                TimelineFetch(id: UUID(), project: shared.project, run: UUID())
            ) { _, _ in }
        }
        client.close()
        await server.value
    }

    @Test func aWorkerSharingNothingListsNothing() async throws {
        let (client, server) = localWorker()
        _ = try await client.start()
        #expect(try await client.timelines().isEmpty)
        client.close()
        await server.value
    }

    @Test func aWorkerOfTheProtocolBeforeIsRefused() async throws {
        let toWorker = Pipe()
        let fromWorker = Pipe()
        var hello = SweepWorkerHello(device: "Old GPU")
        hello.protocolVersion = 17
        try SweepWorkerWriter(fromWorker.fileHandleForWriting).send(.hello(hello))
        let client = SweepWorkerClient(
            name: "old worker", input: fromWorker.fileHandleForReading, output: toWorker.fileHandleForWriting)
        client.helloTimeout = nil
        await #expect(throws: ProjectFileError.self) { _ = try await client.start() }
        #expect(
            !NearbyWorkers.Advert(
                id: UUID(), version: "0.7", protocolVersion: 17,
                solverVersion: SavedSimulationRun.solverVersion,
                device: "Old GPU"
            ).compatible)
    }
}
