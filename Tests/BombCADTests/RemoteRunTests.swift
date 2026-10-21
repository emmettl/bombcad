import BlastCore
import DocumentKit
import Foundation
import Network
import Testing

@testable import BombCAD

/// The blast run on a Mac nearby and watched in the app (emmettl/bombcad-work#73), through a
/// sharing Mac in this process found at its port (Bonjour's answers never come to a test process),
/// with no deadlines anywhere: a step that never comes is the suite's hang limit's to catch.
@MainActor @Suite("Runs on a Mac nearby, watched here", .serialized, .hangLimit)
struct RemoteRunTests {
    /// A small charge in a 4 m box with a gauge: a run of a few frames.
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Remote", domainSize: SIMD3(repeating: 4),
            boxes: [Box(min: SIMD3(2.6, 1, 0), max: SIMD3(3, 3, 1.5))],
            charge: Charge(mass: 0.01, position: SIMD3(1.5, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.4, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        return document
    }

    /// A sharing Mac in this process, its sessions' workers in-process too, and a Mac paired with
    /// it (the key given to both, as pairing would leave them).
    @MainActor private struct Pair {
        let server: NearbyServer
        let serverStore: MemoryPairingStore
        let clientStore: MemoryPairingStore
        var host: String { NearbyWorkers.host(serverStore.me.name) }

        init() throws {
            serverStore = MemoryPairingStore(name: "Studio \(UUID().uuidString.prefix(8))")
            clientStore = MemoryPairingStore(name: "Laptop")
            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try clientStore.keep(.init(peer: serverStore.me, key: key))
            try serverStore.keep(.init(peer: clientStore.me, key: key))
            server = NearbyServer(store: serverStore) { _, _ in
                false
            } startWorker: { input, output, _ in
                Task { @MainActor in
                    await SweepWorker.serve(input: input, output: output)
                    try? output.close()
                }
            }
            server.limits = .none
            try server.start()
        }

        /// A session, or one resuming the held run `resume`.
        func connect(resume: UUID? = nil) async throws -> SweepWorkerClient {
            let server = server
            let store = serverStore
            return try await NearbyWorkers.connect(
                host: host, resume: resume, store: clientStore, discovery: .seconds(600),
                resolve: { id, service, _ in
                    guard id == store.me.id else { throw NearbyError.notFound("That Mac") }
                    let port = try await server.port(of: service)
                    return NearbyBrowser.Found(
                        name: store.me.name, advert: .mine(id),
                        endpoint: .hostPort(host: "127.0.0.1", port: port),
                        interfaces: [])
                }, limits: .none)
        }
    }

    private func job(_ document: ProjectDocument, name: String) throws -> WatchJob {
        WatchJob(
            id: UUID(), name: name, project: SweepWorkerArchive(try document.makeArchive()), frameInterval: 1,
            view: ViewSpec(sceneStride: 2, ackWait: 600), keepsRunning: true)
    }

    @Test("A run kept going when its connection drops is watched again, and its result fetched")
    func heldAcrossADrop() async throws {
        let pair = try Pair()
        defer { pair.server.stop() }
        let document = document()
        let inputs = try HeadlessRun.inputs(
            for: document, options: HeadlessRun.Options(project: URL(filePath: "/dev/null")))
        let job = try job(document, name: "Held")

        // The first frame arrives, and the link drops before it is acknowledged.
        let first = try await pair.connect()
        var setups = 0
        var frames = 0
        do {
            _ = try await first.watch(
                job, setup: { _ in setups += 1 },
                frame: { _, _ in
                    frames += 1
                    first.drop()
                })
            Issue.record("The watch went on after its connection dropped.")
        } catch {
            #expect(first.isClosed)
        }
        #expect(setups == 1 && frames == 1)

        // Another session takes it up: the view's setup again, then the rest, and the result.
        let second = try await pair.connect(resume: job.id)
        var again = 0
        let result = try await second.resumeWatch(
            job.id, setup: { _ in again += 1 },
            frame: { header, _ in second.writer.enqueue(.viewAck(job.id, header.frame)) })
        #expect(again == 1)
        let run = try second.checkedRun(result.archive, name: "Held", inputs: inputs)
        #expect(run.stepCount > 0 && !run.gauges.isEmpty)
        second.close()

        // Collected, it is let go: no session can take it up again.
        while pair.server.sessionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: NearbyError.self) { _ = try await pair.connect(resume: job.id) }
        // Nor one never held.
        await #expect(throws: NearbyError.self) { _ = try await pair.connect(resume: UUID()) }
    }

    @Test("A run not asked to keep going stops with its connection, as before")
    func notHeld() async throws {
        let pair = try Pair()
        defer { pair.server.stop() }
        var job = try job(document(), name: "Not held")
        job.keepsRunning = false
        let first = try await pair.connect()
        _ = try? await first.watch(job) { _, _ in first.drop() }
        while pair.server.sessionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: NearbyError.self) { _ = try await pair.connect(resume: job.id) }
    }

    /// A model sending its runs to the pair's sharing Mac.
    private func model(_ pair: Pair) async throws -> SimulationModel {
        let model = SimulationModel(document: document(), playbackSpeed: .unlimited)
        model.remoteConnect = { _, resume in try await pair.connect(resume: resume) }
        model.remoteSilenceLimit = nil
        model.runHost = pair.host
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        return model
    }

    private func waitWhileActive(_ remote: RemoteRun) async throws {
        while remote.isActive { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Run on a Mac nearby draws its frames here and comes back kept, to replay and compare")
    func appRun() async throws {
        let pair = try Pair()
        defer { pair.server.stop() }
        let model = try await model(pair)
        model.toggleRun()
        let remote = try #require(model.remoteRun)
        #expect(!model.isRunning)
        try await waitWhileActive(remote)
        #expect(remote.phase == .finished && remote.framesShown > 0 && remote.bytesReceived > 0)
        let run = try #require(model.savedRuns.last)
        #expect(run.name == remote.name && run.stepCount > 0)
        // Its recording replays as a run here does, its last frame shown.
        #expect(model.replayableRuns.map(\.id) == [run.id])
        let playback = try #require(model.playback)
        #expect(playback.index == playback.count - 1 && playback.count >= 2)
        playback.seek(to: 0)
        #expect(playback.index == 0)
        // Its histories are on the charts.
        #expect(model.traces.first?.points.isEmpty == false)
        // The same job watched through a worker here, with no relay, comes to the same run: the
        // other Mac ran exactly these inputs, and relaying them changed nothing.
        let (local, localServer) = localWorker()
        _ = try await local.start()
        var job = remote.job
        job.id = UUID()
        job.keepsRunning = false
        let here = try await local.watch(job) { header, _ in
            local.writer.enqueue(.viewAck(job.id, header.frame))
        }
        let same = try local.checkedRun(here.archive, name: remote.name, inputs: remote.inputs)
        #expect(same.gauges == run.gauges && same.stepCount == run.stepCount)
        local.close()
        await localServer.value
    }

    @Test("A dropped link says so, and the run is watched again or its result fetched later")
    func appDrop() async throws {
        let pair = try Pair()
        defer { pair.server.stop() }
        let model = try await model(pair)
        // The link drops at the first frame.
        var dropped = false
        model.onRemoteFrame = { remote in
            guard !dropped else { return }
            dropped = true
            remote.client?.drop()
        }
        model.toggleRun()
        let remote = try #require(model.remoteRun)
        try await waitWhileActive(remote)
        #expect(dropped)
        do {
            guard case .lost(let reason) = remote.phase else {
                Issue.record("Not lost but \(remote.phase)")
                return
            }
            #expect(reason.contains("carries on"))
            // Later, then fetched.
            model.fetchRemoteResultLater()
            #expect(remote.phase == .waiting && remote.canResume)
            model.resumeRemoteRun()
        }
        while remote.phase != .finished {
            if case .failed(let reason) = remote.phase {
                Issue.record("Failed: \(reason)")
                return
            }
            if case .lost(let reason) = remote.phase {
                Issue.record("Lost again: \(reason)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.savedRuns.last?.name == remote.name)
    }

    @Test("Stopped, the run ends there and nothing is kept")
    func appStop() async throws {
        let pair = try Pair()
        defer { pair.server.stop() }
        let model = try await model(pair)
        model.toggleRun()
        let remote = try #require(model.remoteRun)
        while remote.phase == .connecting { try await Task.sleep(for: .milliseconds(2)) }
        model.stopRemoteRun()
        try await waitWhileActive(remote)
        // It may have finished before the stop reached it.
        #expect(remote.phase == .stopped || remote.phase == .finished)
        if remote.phase == .stopped { #expect(model.savedRuns.isEmpty) }
        while pair.server.sessionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
    }
}
