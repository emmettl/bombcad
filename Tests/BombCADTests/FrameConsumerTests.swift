import BlastCore
import DocumentKit
import Foundation
import Metal
import Testing

@testable import BombCAD

/// Eight frames of a small blast beside a wall: each consumer kind's input, as a run would send it.
@MainActor
private struct Frames {
    let kinds: [ConsumerKind]
    let inputs: [[ConsumerInput]]

    init() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Consumers", domainSize: SIMD3(16, 16, 8),
            boxes: [Box(min: SIMD3(10, 4, 0), max: SIMD3(11, 12, 4))],
            charge: Charge(mass: 2, position: SIMD3(7, 8, 1)))
        let scene = FragmentScene(scenario)
        let decoder = JSONDecoder()
        let fragments = try decoder.decode(
            FragmentSpec.self,
            from: Data(
                #"{"casingMass": 2, "count": 200, "tracers": 20, "tracerRegion": {"min": [5, 6, 0.5], "max": [9, 10, 3]}, "seed": 3}"#
                    .utf8))
        let thermal = try decoder.decode(
            ThermalSpec.self, from: Data(#"{"surfaceSpacing": 1, "groundSpacing": 2, "samples": 16}"#.utf8))
        let ground = try decoder.decode(
            GroundShockSpec.self,
            from: Data(
                #"{"points": [[9, 8], [13, 8]], "line": {"from": [4, 4], "to": [14, 4], "count": 5}, "depths": [0, 1]}"#
                    .utf8))
        kinds = [
            .fragments(fragments, scene, live: false), .thermal(thermal, scene, live: false),
            .groundShock(ground, live: false),
        ]

        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let groundRegion = GroundShockConsumer(spec: ground).region(cellSize: 0.25)
        var inputs: [[ConsumerInput]] = []
        for frame in 0..<8 {
            if frame > 0 { solver.advance(until: Double(frame) * 0.001) }
            inputs.append([
                .air(solver.airSlice(region: Box(min: SIMD3(2, 3, 0), max: SIMD3(12, 13, 5)), stride: 1)),
                .fireball(solver.fireball(luminousTemperature: 1500)),
                .ground(solver.groundSlice(low: groundRegion.low, high: groundRegion.high)),
            ])
        }
        self.inputs = inputs
    }

    /// Every frame to every consumer, interleaved as a run sends them, then every result.
    func run(_ consumers: [any FrameConsumer]) async throws -> [ConsumerOutcome] {
        for frame in inputs {
            for (consumer, input) in zip(consumers, frame) { consumer.send(input) }
        }
        var outcomes: [ConsumerOutcome] = []
        for consumer in consumers { outcomes.append(try await consumer.finish(frameInterval: 0.001)) }
        return outcomes
    }
}

/// A worker that reports the first frames it is sent, as if it had taken them, then drops its
/// connection: after `dropAfter` frames in all, or when asked for a result.
@MainActor
func flakyWorker(dropAfter limit: Int = .max) -> SweepWorkerClient {
    let toWorker = Pipe()
    let fromWorker = Pipe()
    let writer = SweepWorkerWriter(fromWorker.fileHandleForWriting)
    try? writer.send(.hello(SweepWorkerHello(device: "Flaky GPU")))
    _ = Task.detached {
        var frames: [UUID: Int] = [:]
        var total = 0
        do {
            loop: for try await message in SweepWorkerFrame.messages(from: toWorker.fileHandleForReading) {
                switch message {
                case .input(let id, _):
                    total += 1
                    guard total <= limit else { break loop }
                    let frame = frames[id, default: -1] + 1
                    frames[id] = frame
                    try? writer.send(
                        .report(id, ConsumerReport(frame: frame, low: nil, high: nil, speed: 0, airborne: 0)))
                case .finishConsumer: break loop
                default: continue
                }
            }
        } catch {}
        try? fromWorker.fileHandleForWriting.close()
    }
    return SweepWorkerClient(
        name: "flaky", input: fromWorker.fileHandleForReading, output: toWorker.fileHandleForWriting
    ) { try? toWorker.fileHandleForWriting.close() }
}

@MainActor @Suite("Models fed by the blast, here or on workers", .serialized)
struct FrameConsumerTests {
    @Test("Each kind gives the same result here, all on one worker, or spread over two")
    func placement() async throws {
        let frames = try Frames()
        let here = try await frames.run(frames.kinds.map { LocalFrameConsumer($0) })
        #expect(here.count == 3)
        guard case .fragments(let fragments) = here[0], case .thermal(let thermal) = here[1],
            case .groundShock(let ground) = here[2]
        else {
            Issue.record("The results are of the wrong kinds: \(here)")
            return
        }
        #expect(fragments.frames.count == 8 && fragments.fragmentCount == 200)
        #expect(thermal.fireball.count == 8)
        #expect(ground.frames == 8 && ground.points.count == 7)

        // All three sharing one worker, each on a queue of its own there.
        let (worker, server) = localWorker()
        _ = try await worker.start()
        let shared = try await frames.run(
            frames.kinds.map { RemoteFrameConsumer(client: worker, kind: $0, ownsClient: false) })
        #expect(shared == here)
        worker.close()
        await server.value

        // The fragments on one, the radiation and the ground on another.
        let (first, firstServer) = localWorker(name: "first")
        let (second, secondServer) = localWorker(name: "second")
        _ = try await first.start()
        _ = try await second.start()
        let spread = try await frames.run([
            RemoteFrameConsumer(client: first, kind: frames.kinds[0], ownsClient: false),
            RemoteFrameConsumer(client: second, kind: frames.kinds[1], ownsClient: false),
            RemoteFrameConsumer(client: second, kind: frames.kinds[2], ownsClient: false),
        ])
        #expect(spread == here)
        first.close()
        second.close()
        await firstServer.value
        await secondServer.value
    }

    @Test("Live sessions send each model's state back after every frame, the same as here")
    func live() async throws {
        let frames = try Frames()
        let kinds: [ConsumerKind] = frames.kinds.map { kind in
            switch kind {
            case .fragments(let spec, let scene, _): .fragments(spec, scene, live: true)
            case .thermal(let spec, let scene, _): .thermal(spec, scene, live: true)
            case .groundShock(let spec, _): .groundShock(spec, live: true)
            }
        }
        let here = kinds.map { LocalFrameConsumer($0) }
        let (worker, server) = localWorker()
        _ = try await worker.start()
        let there = kinds.map { RemoteFrameConsumer(client: worker, kind: $0, ownsClient: false) }
        // Before any frame, both start from the same state.
        #expect(zip(here, there).allSatisfy { $0.live == $1.live && $0.live != nil })
        for frame in frames.inputs {
            for (n, input) in frame.enumerated() {
                here[n].send(input)
                there[n].send(input)
            }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !(here + there as [any FrameConsumer]).allSatisfy(\.caughtUp) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        // Caught up, each has its last frame's state in.
        #expect(zip(here, there).allSatisfy { $0.live == $1.live })
        #expect(here[0].fragmentLive?.positions.count == 220)
        #expect(here[1].thermalLive?.frames == 8)
        #expect(here[2].groundShockLive?.frames == 8)
        for consumer in here + there as [any FrameConsumer] {
            _ = try await consumer.finish(frameInterval: 0.001)
        }
        worker.close()
        await server.value
    }

    @Test("Reports count the frames taken; a frame of the wrong kind fails the session, not the others")
    func reportsAndMistakes() async throws {
        let frames = try Frames()
        let (worker, server) = localWorker()
        _ = try await worker.start()
        let ground = RemoteFrameConsumer(client: worker, kind: frames.kinds[2], ownsClient: false)
        let thermal = RemoteFrameConsumer(client: worker, kind: frames.kinds[1], ownsClient: false)
        #expect(ground.report.frame == -1)
        for frame in frames.inputs.prefix(3) {
            ground.send(frame[2])
            // The radiation is sent the ground's layer by mistake.
            thermal.send(frame[2])
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ground.report.frame < 2 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ground.report(after: 1)?.frame == 1)
        await #expect(throws: ProjectFileError.self) { try await thermal.finish(frameInterval: 0.001) }
        guard case .groundShock(let result) = try await ground.finish(frameInterval: 0.001) else {
            Issue.record("Not the ground's result")
            return
        }
        #expect(result.frames == 3)

        // Here, likewise.
        let local = LocalFrameConsumer(frames.kinds[1])
        local.send(frames.inputs[0][0])
        await #expect(throws: ProjectFileError.self) { try await local.finish(frameInterval: 0.001) }
        worker.close()
        await server.value
    }

    @Test("A model whose Mac drops carries on here, from the frames kept, to the same result")
    func recovery() async throws {
        let frames = try Frames()
        let here = try await frames.run(frames.kinds.map { LocalFrameConsumer($0) })
        // Dropped after three frames of each, after the second model's first frame, and at the end.
        for limit in [9, 4, Int.max] {
            let worker = flakyWorker(dropAfter: limit)
            _ = try await worker.start()
            let consumers = try frames.kinds.map {
                try ResilientFrameConsumer(client: worker, kind: $0, ownsClient: false)
            }
            let outcomes = try await frames.run(consumers)
            #expect(outcomes == here, "dropped after \(limit)")
            #expect(consumers.allSatisfy { $0.fallback != nil }, "dropped after \(limit)")
            if limit == 9 { #expect(consumers.map { $0.fallback?.frame } == [2, 2, 2]) }
            #expect(consumers.allSatisfy { $0.sent == 8 && $0.report.frame == 7 })
            worker.close()
        }
        // A worker that does not fail leaves nothing to take over.
        let (good, server) = localWorker()
        _ = try await good.start()
        let consumers = try frames.kinds.map {
            try ResilientFrameConsumer(client: good, kind: $0, ownsClient: false)
        }
        #expect(try await frames.run(consumers) == here)
        #expect(consumers.allSatisfy { $0.fallback == nil })
        good.close()
        await server.value
    }

    @Test("A consumer's result survives its journey, the fragments' trajectories included")
    func outcomeEncoding() throws {
        let result = FragmentResult(
            launchSpeed: 1000, masses: [0.1, 0.2], impacts: [], airborne: 1,
            frames: [[SIMD3(1, 2, 3), SIMD3(4, 5, 6)], [SIMD3(1.5, 2, 3), SIMD3(4, 5.5, 6)]],
            fragmentCount: 2,
            frameInterval: 0.001, misses: 0)
        let outcome = ConsumerOutcome.fragments(result)
        #expect(try ConsumerOutcome(encoded: outcome.encoded()) == outcome)
        #expect(throws: ProjectFileError.self) { try ConsumerOutcome(encoded: Data([0, 0, 1])) }
    }
}
