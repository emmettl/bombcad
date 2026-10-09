import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Sweep scheduling")
struct SweepScheduleTests {
    @Test("With no workers this Mac takes every case, largest first")
    func noWorkers() {
        var schedule = SweepSchedule(costs: [1, 16, 4])
        #expect(schedule.workers.isEmpty)
        #expect(schedule.next(.local) == 1)
        // One case at a time.
        #expect(schedule.next(.local) == nil)
        schedule.finish(.local, seconds: 16)
        #expect(schedule.next(.local) == 2)
        schedule.finish(.local, seconds: 4)
        #expect(schedule.next(.local) == 0)
        schedule.finish(.local, seconds: 1)
        #expect(schedule.isFinished && schedule.next(.local) == nil)
    }

    @Test("This Mac takes the largest cases, one worker the smallest it will finish in time")
    func oneWorker() {
        var schedule = SweepSchedule(costs: [1, 16, 1, 4], workers: 1)
        schedule.ratio = 3
        // Not connected yet.
        #expect(schedule.next(.worker(0)) == nil)
        schedule.join(0)
        #expect(schedule.next(.local) == 1)
        // The 16 running here, about to start: a small case fits in the worker's 3 times.
        #expect(schedule.next(.worker(0)) == 2)
        schedule.finish(.worker(0), seconds: 3)
        schedule.finish(.local, seconds: 16)
        #expect(schedule.next(.local) == 3)
        // Left: the case of cost 1, and 2 of the 4 running here; 3 times 1 would finish last.
        schedule.progress(.local, 0.5)
        #expect(schedule.next(.worker(0)) == nil)
        // With 3 of the 4 still to run, it would not.
        schedule.progress(.local, 0.25)
        #expect(schedule.next(.worker(0)) == 0)
        #expect(schedule.isEmpty && !schedule.isFinished && schedule.workersBusy)
    }

    @Test("A slow worker is given nothing it would finish after this Mac")
    func slowWorker() {
        var schedule = SweepSchedule(costs: [1, 1, 1], workers: 1)
        schedule.join(0)
        #expect(schedule.ratio == 3.5)
        #expect(schedule.next(.local) == 0)
        // 3.5 times one case against the two left: it would hold the sweep up.
        #expect(schedule.next(.worker(0)) == nil)
    }

    @Test("Several workers each take a case only if they will not hold the sweep up")
    func severalWorkers() {
        // Six equal cases, and workers 3.5 times slower: each worker added takes one more.
        for count in 1...3 {
            var schedule = SweepSchedule(costs: Array(repeating: 1, count: 6), workers: count)
            #expect(schedule.next(.local) == 0)
            for worker in 0..<count {
                schedule.join(worker)
                #expect(schedule.next(.worker(worker)) == 5 - worker, "\(count) workers")
            }
            #expect(schedule.pending.count == 5 - count)
        }
        // The third: two cases wait besides its own, which this Mac would finish by 3, but the
        // others' cases run to 3.5, so its 3.5 holds nothing up.
        var schedule = SweepSchedule(costs: Array(repeating: 1, count: 6), workers: 3)
        _ = schedule.next(.local)
        for worker in 0..<2 {
            schedule.join(worker)
            _ = schedule.next(.worker(worker))
        }
        #expect(schedule.deadline(excluding: 2, waiting: 2) == 3.5)
        // The second: three wait besides; this Mac clears 2.5 by 3.5, then shares the last half
        // with the first worker, finishing at 3.89.
        #expect(abs(schedule.deadline(excluding: 1, waiting: 3) - (3.5 + 0.5 / (1 + 1 / 3.5))) < 1e-12)

        // Four equal cases: two would wait besides a worker's, 3 against its 3.5, so no worker
        // takes one, however many there are.
        var few = SweepSchedule(costs: Array(repeating: 1, count: 4), workers: 3)
        _ = few.next(.local)
        for worker in 0..<3 {
            few.join(worker)
            #expect(few.next(.worker(worker)) == nil)
            few.leave(worker)
        }
        #expect(few.pending.map(\.index) == [1, 2, 3])
    }

    @Test("Each worker's measured ratio decides what it takes")
    func measuredRatios() {
        var schedule = SweepSchedule(costs: [4, 4, 2, 1, 1, 1], workers: 2)
        schedule.ratio = 2
        schedule.join(0)
        schedule.join(1)
        #expect(schedule.next(.local) == 0)
        #expect(schedule.next(.worker(0)) == 5)
        #expect(schedule.next(.worker(1)) == 4)
        schedule.finish(.local, seconds: 4)
        // The first worker took 2 s over its case, the second 6 s: twice and six times slower.
        schedule.finish(.worker(0), seconds: 2)
        schedule.finish(.worker(1), seconds: 6)
        #expect(schedule.ratio(of: 0) == 2 && schedule.ratio(of: 1) == 6)
        #expect(schedule.next(.local) == 1)
        // The fast worker: the 2 waiting besides, and the 4 here, take this Mac 6 s; 2 fits.
        #expect(schedule.next(.worker(0)) == 3)
        // The slow one, for the 2 left: this Mac is busy for 4 s, so 12 s does not.
        #expect(schedule.next(.worker(1)) == nil)
        // The same events give the same plan.
        var again = SweepSchedule(costs: [4, 4, 2, 1, 1, 1], workers: 2)
        again.ratio = 2
        again.join(0)
        again.join(1)
        _ = again.next(.local)
        _ = again.next(.worker(0))
        _ = again.next(.worker(1))
        again.finish(.local, seconds: 4)
        again.finish(.worker(0), seconds: 2)
        again.finish(.worker(1), seconds: 6)
        _ = again.next(.local)
        _ = again.next(.worker(0))
        _ = again.next(.worker(1))
        #expect(again == schedule)
    }

    @Test("A case a worker fails goes back to the queue, and the worker takes no more")
    func failure() {
        var schedule = SweepSchedule(costs: [4, 1, 1], workers: 2)
        schedule.ratio = 1
        schedule.join(0)
        schedule.join(1)
        #expect(schedule.next(.local) == 0)
        #expect(schedule.next(.worker(0)) == 2)
        #expect(schedule.next(.worker(1)) == 1)
        schedule.progress(.worker(0), 0.9)
        schedule.fail(0)
        #expect(schedule.pending.map(\.index) == [2])
        #expect(schedule.next(.worker(0)) == nil)
        // The other worker, or this Mac, may take it.
        schedule.finish(.worker(1), seconds: 1)
        #expect(schedule.next(.worker(1)) == 2)
        schedule.fail(1)
        #expect(schedule.next(.worker(1)) == nil)
        schedule.finish(.local, seconds: 4)
        #expect(schedule.next(.local) == 2)
        schedule.finish(.local, seconds: 1)
        #expect(schedule.isFinished)
    }

    @Test("Cancelling starts nothing more, anywhere, and runs nothing again")
    func cancellation() {
        var schedule = SweepSchedule(costs: [3, 2, 1], workers: 2)
        schedule.ratio = 1
        schedule.join(0)
        #expect(schedule.next(.local) == 0)
        #expect(schedule.next(.worker(0)) == 2)
        schedule.cancel()
        #expect(schedule.next(.local) == nil && schedule.next(.worker(0)) == nil)
        // A worker connecting late, or failing its cancelled case, changes nothing.
        schedule.join(1)
        #expect(schedule.next(.worker(1)) == nil)
        schedule.fail(0)
        schedule.finish(.local, seconds: 3)
        #expect(schedule.isFinished && schedule.pending.isEmpty)
    }

    @Test("A simulated sweep runs every case once and never finishes later than this Mac alone")
    func simulated() {
        let costs: [Double] = [8, 8, 4, 4, 2, 2, 1, 1]
        for ratios in [[Double](), [3.5], [2, 4], [1.5, 3.5, 6]] {
            let first = simulate(costs, ratios: ratios)
            #expect(first.ran.sorted() == Array(costs.indices), "\(ratios)")
            #expect(first.time <= costs.reduce(0, +), "\(ratios)")
            #expect(simulate(costs, ratios: ratios) == first, "\(ratios)")
        }
        // A second worker is no later; here the two largest cases here set the time.
        #expect(simulate(costs, ratios: [2, 4]).time <= simulate(costs, ratios: [2]).time)
        // Eight equal cases: 8 alone, 6 with a worker twice as slow, and 5 with another four times
        // as slow too, the least whole cases allow; 7 with a mini, and 6 with two.
        let equal = Array(repeating: 1.0, count: 8)
        #expect(simulate(equal, ratios: []).time == 8)
        #expect(simulate(equal, ratios: [2]).time == 6)
        #expect(simulate(equal, ratios: [2, 4]).time == 5)
        #expect(simulate(equal, ratios: [3.5]).time == 7)
        #expect(simulate(equal, ratios: [3.5, 3.5]).time == 6)
    }

    /// Runs a sweep with workers this many times slower than this Mac, starting from the
    /// schedule's default ratio, and returns where each case ran, in order, and when it ended.
    private func simulate(_ costs: [Double], ratios: [Double]) -> (ran: [Int], where: [String], time: Double)
    {
        var schedule = SweepSchedule(costs: costs, workers: ratios.count)
        // Each machine's case, its cost, and when it started.
        var running: [SweepSchedule.Machine: (index: Int, cost: Double, start: Double)] = [:]
        var ran: [Int] = []
        var places: [String] = []
        var time = 0.0
        func duration(_ machine: SweepSchedule.Machine, _ cost: Double) -> Double {
            if case .worker(let worker) = machine { return cost * ratios[worker] }
            return cost
        }
        // Every machine free asks for a case, this Mac first; as in the app, a worker turned down
        // asks again whenever something changes, until no other worker could hand a case back.
        func askAll() {
            for machine in [.local] + ratios.indices.map(SweepSchedule.Machine.worker)
            where running[machine] == nil {
                if let index = schedule.next(machine) { running[machine] = (index, costs[index], time) }
            }
        }
        for worker in ratios.indices { schedule.join(worker) }
        askAll()
        while let next = running.min(by: {
            ($0.value.start + duration($0.key, $0.value.cost), $0.value.index)
                < ($1.value.start + duration($1.key, $1.value.cost), $1.value.index)
        }) {
            let (machine, item) = (next.key, next.value)
            time = item.start + duration(machine, item.cost)
            for (other, value) in running where other != machine {
                schedule.progress(other, (time - value.start) / duration(other, value.cost))
            }
            running[machine] = nil
            schedule.finish(machine, seconds: time - item.start)
            ran.append(item.index)
            places.append("\(machine)")
            askAll()
        }
        #expect(schedule.isFinished)
        return (ran, places, time)
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

/// A worker that greets, starts the first case it is sent, and then drops its connection, as
/// when another Mac sleeps or its network goes.
@MainActor
private func droppingWorker() -> SweepWorkerClient {
    let toWorker = Pipe()
    let fromWorker = Pipe()
    let writer = SweepWorkerWriter(fromWorker.fileHandleForWriting)
    try? writer.send(.hello(SweepWorkerHello(device: "Flaky GPU")))
    _ = Task {
        for try await message in SweepWorkerFrame.messages(from: toWorker.fileHandleForReading) {
            if case .run(let job) = message {
                try? writer.send(.progress(job.id, 0.5))
                try? fromWorker.fileHandleForWriting.close()
                return
            }
        }
    }
    return SweepWorkerClient(
        name: "flaky worker", input: fromWorker.fileHandleForReading, output: toWorker.fileHandleForWriting
    ) { try? toWorker.fileHandleForWriting.close() }
}

@MainActor @Suite("Sweeps shared with workers", .serialized)
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
        _ model: SimulationModel, workers: [@MainActor () async throws -> SweepWorkerClient] = [],
        ratio: Double = 1
    ) async throws {
        model.sweep.remoteWorkers = workers
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
        try await sweep(model)
        let local = try #require(model.savedRuns.first { $0.scenario.charge.mass == 0.02 })
        #expect(run.gauges == local.gauges && run.stepCount == local.stepCount)
        worker.close()
        await server.value
    }

    @Test("A shared sweep keeps every case, in order, the same as one run here alone")
    func sharedSweep() async throws {
        let alone = SimulationModel(document: document())
        try await sweep(alone)
        #expect(alone.sweep.remoteCompleted == 0)

        let shared = SimulationModel(document: document())
        let (worker, server) = localWorker()
        try await sweep(shared, workers: [{ worker }])
        #expect(shared.sweep.remoteCompleted == 1)
        #expect(shared.sweep.message.contains("1 on test worker"))
        #expect(shared.savedRuns.map(\.name) == alone.savedRuns.map(\.name))
        #expect(shared.savedRuns.map(\.gauges) == alone.savedRuns.map(\.gauges))
        #expect(shared.currentInputs == alone.currentInputs)
        await server.value

        // Two workers as fast as this Mac: one case each, and the same results.
        let both = SimulationModel(document: document())
        let (first, firstServer) = localWorker(name: "worker A")
        let (second, secondServer) = localWorker(name: "worker B")
        try await sweep(both, workers: [{ first }, { second }])
        #expect(both.sweep.remoteCompleted == 2)
        #expect(both.sweep.message.contains("(1 on worker A, 1 on worker B)"))
        #expect(both.savedRuns.map(\.name) == alone.savedRuns.map(\.name))
        #expect(both.savedRuns.map(\.gauges) == alone.savedRuns.map(\.gauges))
        #expect(both.currentInputs == alone.currentInputs)
        await firstServer.value
        await secondServer.value
    }

    @Test("Cases a worker fails, or that it cannot reach, run here instead")
    func failures() async throws {
        let failing = SimulationModel(document: document())
        try await sweep(failing, workers: [{ failingWorker() }])
        #expect(failing.savedRuns.count == 3 && failing.sweep.remoteCompleted == 0)
        #expect(failing.sweep.message.contains("complete"))

        let unreachable = SimulationModel(document: document())
        try await sweep(unreachable, workers: [{ throw ProjectFileError.invalid("Cannot reach it.") }])
        #expect(unreachable.savedRuns.count == 3 && unreachable.sweep.remoteCompleted == 0)
    }

    @Test("A worker lost mid-case puts it back in the queue, for this Mac or another worker")
    func lostWorker() async throws {
        let alone = SimulationModel(document: document())
        try await sweep(alone)

        // This Mac takes the first case, the lost worker the third and the good one the second;
        // the third then runs on whichever is free first.
        let model = SimulationModel(document: document())
        let (worker, server) = localWorker()
        try await sweep(model, workers: [{ droppingWorker() }, { worker }])
        #expect(model.sweep.message.contains("Sweep complete"))
        #expect(model.savedRuns.map(\.name) == alone.savedRuns.map(\.name))
        #expect(model.savedRuns.map(\.gauges) == alone.savedRuns.map(\.gauges))
        #expect((1...2).contains(model.sweep.remoteCompleted))
        #expect(!model.sweep.message.contains("flaky"))
        await server.value

        // Workers that fail, drop or cannot be reached leave the sweep to this Mac.
        let unlucky = SimulationModel(document: document())
        try await sweep(
            unlucky,
            workers: [
                { droppingWorker() }, { failingWorker() },
                { throw ProjectFileError.invalid("Cannot reach it.") },
            ])
        #expect(unlucky.savedRuns.map(\.gauges) == alone.savedRuns.map(\.gauges))
        #expect(unlucky.sweep.remoteCompleted == 0)
    }

    @Test("Cancelling a shared sweep stops every worker's case and lets each worker go")
    func cancel() async throws {
        let model = SimulationModel(document: document())
        let (first, firstServer) = localWorker(name: "worker A")
        let (second, secondServer) = localWorker(name: "worker B")
        model.sweep.remoteWorkers = [{ first }, { second }]
        model.sweep.remoteRatio = 1
        try model.sweep.start(
            .init(prefix: "Cancel", parameter: .chargeMass([0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08])))
        let deadline = ContinuousClock.now + .seconds(60)
        while !(model.sweep.message.contains("on worker A") && model.sweep.message.contains("on worker B")) {
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
        // Both workers were told to finish, and have.
        await firstServer.value
        await secondServer.value
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
