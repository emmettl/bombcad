import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Sweep scheduling")
struct SweepScheduleTests {
    @Test("This Mac takes the largest cases, the other the smallest it will finish in time")
    func assignment() {
        var schedule = SweepSchedule(costs: [1, 16, 1, 4])
        schedule.ratio = 3
        #expect(schedule.nextLocal() == 1)
        // The 16 running here, about to start: a small case fits in the other Mac's 3 times.
        #expect(schedule.nextRemote(localRemaining: 16) == 2)
        #expect(schedule.nextLocal() == 3)
        // Left: the case of cost 1, and 2 of the 4 running here; 3 times 1 would finish last.
        #expect(schedule.nextRemote(localRemaining: 2) == nil)
        // With 3 of the 4 still to run, it would not.
        #expect(schedule.nextRemote(localRemaining: 3) == 0)
        #expect(schedule.isEmpty)
    }

    @Test("A slow Mac is given nothing it would finish after this one")
    func slowMac() {
        var schedule = SweepSchedule(costs: [1, 1, 1])
        schedule.ratio = 3.5
        #expect(schedule.nextLocal() == 0)
        // 3.5 times one case against the two left: it would hold the sweep up.
        #expect(schedule.nextRemote(localRemaining: 1) == nil)
        #expect(schedule.nextLocal() == 1)
        #expect(schedule.nextLocal() == 2)
    }

    @Test("A failed case comes back for this Mac only, and the ratio is measured")
    func requeueAndRatio() {
        var schedule = SweepSchedule(costs: [2, 1])
        schedule.ratio = 1
        #expect(schedule.nextRemote(localRemaining: 0) == 1)
        schedule.requeue(1, cost: 1)
        // The failed case is not offered again; the other still is.
        #expect(schedule.nextRemote(localRemaining: 100) == 0)
        #expect(schedule.nextRemote(localRemaining: 100) == nil)
        #expect(schedule.nextLocal() == 1)
        #expect(schedule.isEmpty)
        schedule.record(seconds: 2, cost: 2, remote: false)
        schedule.record(seconds: 4, cost: 1, remote: true)
        #expect(schedule.ratio == 4)
    }

    @Test("A case's cost goes as its cells over its cell size, and its duration")
    func cost() throws {
        let run = try SavedRunTests().fixture()
        var inputs = SimulationInputs(scenario: run.scenario, settings: run.settings)
        inputs.settings.resolution = "coarse"
        let coarse = SweepSchedule.cost(inputs)
        inputs.settings.resolution = "medium"
        #expect(abs(SweepSchedule.cost(inputs) / coarse - 16) < 1.5)
        inputs.settings.duration *= 2
        #expect(abs(SweepSchedule.cost(inputs) / coarse - 32) < 3)
    }
}

@Suite("Sweep worker messages")
struct SweepWorkerFrameTests {
    @Test("Messages survive framing, split across reads")
    func frames() async throws {
        let pipe = Pipe()
        let messages: [SweepWorkerMessage] = [
            .hello(SweepWorkerHello(device: "Test GPU")), .progress(UUID(), 0.5), .cancel(UUID()), .shutdown,
        ]
        let bytes = try messages.reduce(Data()) { $0 + (try SweepWorkerFrame.encode($1)) }
        // A byte at a time, so that every length and body arrives in pieces.
        let writer = pipe.fileHandleForWriting
        Thread {
            for byte in bytes { try? writer.write(contentsOf: Data([byte])) }
            try? writer.close()
        }.start()
        var received: [SweepWorkerMessage] = []
        for try await message in SweepWorkerFrame.messages(from: pipe.fileHandleForReading) {
            received.append(message)
        }
        #expect(received == messages)
    }
}

/// A worker in this process, on pipes, as `BombCAD worker` would be at the far end of SSH.
@MainActor
func localWorker(name: String = "test worker") -> (SweepWorkerClient, Task<Void, Never>) {
    let toWorker = Pipe()
    let fromWorker = Pipe()
    let server = Task {
        await SweepWorker.serve(input: toWorker.fileHandleForReading, output: fromWorker.fileHandleForWriting)
        try? fromWorker.fileHandleForWriting.close()
    }
    let client = SweepWorkerClient(
        name: name, input: fromWorker.fileHandleForReading, output: toWorker.fileHandleForWriting
    ) { try? toWorker.fileHandleForWriting.close() }
    return (client, server)
}

/// A worker that greets and then fails every case.
@MainActor
private func failingWorker() -> SweepWorkerClient {
    let toWorker = Pipe()
    let fromWorker = Pipe()
    let writer = SweepWorkerWriter(fromWorker.fileHandleForWriting)
    try? writer.send(.hello(SweepWorkerHello(device: "Broken GPU")))
    Task {
        for try await message in SweepWorkerFrame.messages(from: toWorker.fileHandleForReading) {
            if case .run(let job) = message { try? writer.send(.failed(job.id, "out of memory")) }
        }
    }
    return SweepWorkerClient(
        name: "broken worker", input: fromWorker.fileHandleForReading, output: toWorker.fileHandleForWriting
    ) { try? toWorker.fileHandleForWriting.close() }
}

@MainActor @Suite("Sweeps shared with a worker", .serialized)
struct SweepWorkerTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Shared sweep", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        return document
    }

    private func sweep(
        _ model: SimulationModel, worker: (@MainActor () async throws -> SweepWorkerClient)?,
        ratio: Double = 1
    ) async throws {
        model.sweep.remoteWorker = worker
        model.sweep.remoteRatio = ratio
        try model.sweep.start(.init(prefix: "Mass", parameter: .chargeMass([0.01, 0.02, 0.03])))
        let deadline = ContinuousClock.now + .seconds(120)
        while model.sweep.isActive || !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A worker runs a case to the same answer, and its result is checked")
    func workerRun() async throws {
        let (worker, server) = localWorker()
        let hello = try await worker.start()
        #expect(hello.solverVersion == SavedSimulationRun.solverVersion)
        let inputs = SimulationInputs(scenario: document().scenario, settings: document().runSettings!)
        let item = try ParameterSweepPlan(prefix: "Case", parameter: .chargeMass([0.02])).prepare(
            from: inputs)[0]
        var fractions: [Double] = []
        let run = try await worker.run(item) { fractions.append($0) }
        #expect(run.name == item.name && run.scenario.charge.mass == 0.02)
        #expect(
            run.inputSHA256
                == (try SavedSimulationRun.fingerprint(item.inputs.scenario, settings: item.inputs.settings)))

        // The same case here.
        let model = SimulationModel(document: document())
        try await sweep(model, worker: nil)
        let local = try #require(model.savedRuns.first { $0.scenario.charge.mass == 0.02 })
        #expect(run.gauges == local.gauges && run.stepCount == local.stepCount)
        worker.close()
        await server.value
    }

    @Test("A shared sweep keeps every case, in order, the same as one run here alone")
    func sharedSweep() async throws {
        let alone = SimulationModel(document: document())
        try await sweep(alone, worker: nil)
        #expect(alone.sweep.remoteCompleted == 0)

        let shared = SimulationModel(document: document())
        let (worker, server) = localWorker()
        try await sweep(shared, worker: { worker })
        #expect(shared.sweep.remoteCompleted == 1)
        #expect(shared.sweep.message.contains("1 on test worker"))
        #expect(shared.savedRuns.map(\.name) == alone.savedRuns.map(\.name))
        #expect(shared.savedRuns.map(\.gauges) == alone.savedRuns.map(\.gauges))
        #expect(shared.currentInputs == alone.currentInputs)
        await server.value
    }

    @Test("Cases a worker fails, or that it cannot reach, run here instead")
    func failures() async throws {
        let failing = SimulationModel(document: document())
        try await sweep(failing, worker: { failingWorker() })
        #expect(failing.savedRuns.count == 3 && failing.sweep.remoteCompleted == 0)
        #expect(failing.sweep.message.contains("complete"))

        let unreachable = SimulationModel(document: document())
        try await sweep(unreachable, worker: { throw ProjectFileError.invalid("Cannot reach it.") })
        #expect(unreachable.savedRuns.count == 3 && unreachable.sweep.remoteCompleted == 0)
    }

    @Test("Cancelling a shared sweep stops the worker's case and lets the worker go")
    func cancel() async throws {
        let model = SimulationModel(document: document())
        let (worker, server) = localWorker()
        model.sweep.remoteWorker = { worker }
        model.sweep.remoteRatio = 1
        try model.sweep.start(
            .init(prefix: "Cancel", parameter: .chargeMass([0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08])))
        let deadline = ContinuousClock.now + .seconds(60)
        while !model.sweep.message.contains("on test worker") {
            try #require(ContinuousClock.now < deadline && model.sweep.isActive)
            try await Task.sleep(for: .milliseconds(1))
        }
        model.sweep.cancel()
        while model.sweep.isActive || !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.sweep.message.contains("cancelled"))
        #expect(model.savedRuns.count < 8)
        // The worker was told to finish, and has.
        await server.value
    }

    @Test("SSH hosts that could pass for options or lists are refused")
    func hosts() {
        for host in ["scrimply-ci-tb", "user@my-mac.local", "10.10.10.2", "[fe80::1]"] {
            #expect((try? RemoteSweepWorker.validate(host)) != nil, "\(host)")
        }
        for host in ["", "-oProxyCommand=evil", "a b", "a;b", "a\nb", "$(x)"] {
            #expect(throws: ProjectFileError.self) { try RemoteSweepWorker.validate(host) }
        }
    }
}
