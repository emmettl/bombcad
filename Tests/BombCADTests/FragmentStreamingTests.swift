import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Fragment regions")
struct FragmentRegionTests {
    @Test("The air sent grows with the frames the consumer is behind, thinned to stay under the cap")
    func region() {
        let report = ConsumerReport(
            frame: 3, low: SIMD3(10, 10, 1), high: SIMD3(12, 12, 2), speed: 1000, airborne: 5)
        let domain = SIMD3<Float>(64, 64, 32)
        // Frame 5 is two frames on from 3, plus the frame after: 3 ms at 1,000 m/s, and a cell.
        let near = report.region(for: 5, interval: 0.001, domain: domain, cellSize: 0.25)
        #expect(near.box.min == SIMD3(6.75, 6.75, 0) && near.box.max == SIMD3(15.25, 15.25, 5.25))
        #expect(near.stride == 1)
        // Far behind, the whole domain: 8.4 million cells, every second one to keep to a million.
        let far = report.region(for: 100, interval: 0.001, domain: domain, cellSize: 0.25, cap: 1 << 20)
        #expect(far.box.min == .zero && far.box.max == domain && far.stride == 2)
        // Everything landed: a token frame.
        let landed = ConsumerReport(frame: 3, low: nil, high: nil, speed: 0, airborne: 0)
        #expect(
            landed.region(for: 4, interval: 0.001, domain: domain, cellSize: 0.25).box.size
                == SIMD3(repeating: 0.25))
    }
}

/// A consumer that consumes only when told to.
final class StalledConsumer: FrameConsumer, @unchecked Sendable {
    let kind = ConsumerKind.fragments(
        FragmentSpec(),
        FragmentScene(
            Scenario(
                name: "Stalled", domainSize: SIMD3(repeating: 4), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(2, 2, 1)))), live: false)
    private let lock = NSLock()
    private var count = 0
    private var consumed = -1
    private var released = false

    var sent: Int { lock.withLock { count } }
    var bytes: Int { 0 }
    var live: ConsumerLive? { nil }
    var report: ConsumerReport {
        lock.withLock {
            ConsumerReport(frame: released ? count - 1 : consumed, low: nil, high: nil, speed: 0, airborne: 0)
        }
    }
    func send(_ input: ConsumerInput) { lock.withLock { count += 1 } }
    func report(after frame: Int) -> ConsumerReport? {
        ConsumerReport(frame: frame, low: nil, high: nil, speed: 0, airborne: 0)
    }
    func release() { lock.withLock { released = true } }
    func finish(frameInterval: Double) async throws -> ConsumerOutcome {
        .fragments(
            FragmentResult(
                launchSpeed: 0, masses: [], impacts: [], airborne: 0, frames: [], fragmentCount: 0,
                frameInterval: frameInterval, misses: 0))
    }
    func cancel() {}
}

@MainActor @Suite("Fragments flown alongside a run", .serialized)
struct FragmentStreamingTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Cased", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        return document
    }

    private func options(_ spec: FragmentSpec) -> HeadlessRun.Options {
        var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
        options.fragments = spec
        options.name = "Fragments"
        return options
    }

    private var spec: FragmentSpec {
        var spec = FragmentSpec()
        spec.casingMass = 0.05
        spec.count = 200
        spec.tracers = 30
        spec.tracerRegion = Box(min: SIMD3(2, 3, 0.5), max: SIMD3(4, 5, 2))
        return spec
    }

    @Test("Fragments fly frame by frame on this Mac and land in the scene")
    func local() async throws {
        let result = try await HeadlessRun.perform(document(), options: options(spec))
        let fragments = try #require(result.fragments)
        // Frames at 0 to 6 ms.
        #expect(fragments.frames.count == 7 && fragments.frames.allSatisfy { $0.count == 230 })
        #expect(fragments.fragmentCount == 200 && fragments.misses == 0)
        #expect(!fragments.impacts.isEmpty)
        #expect(fragments.impacts.contains { $0.surface == "block 0" })
    }

    @Test("On a worker, through its connection, fragments fly to exactly the same result")
    func remote() async throws {
        let here = try #require(try await HeadlessRun.perform(document(), options: options(spec)).fragments)
        let (client, server) = localWorker()
        _ = try await client.start()
        let consumer = RemoteFrameConsumer(
            client: client, kind: .fragments(spec, FragmentScene(document().scenario), live: false))
        let there = try #require(
            try await HeadlessRun.perform(document(), options: options(spec), consumer: consumer).fragments)
        #expect(there == here)
        await server.value
    }

    @Test("A consumer that falls behind holds the run until it catches up")
    func hold() async throws {
        let consumer = StalledConsumer()
        let run = Task {
            try await HeadlessRun.perform(document(), options: options(spec), consumer: consumer)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while consumer.sent < 5, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Frame 0 and four more, ahead of a consumer stuck before its first.
        #expect(consumer.sent == 5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(consumer.sent == 5, "The paused consumer must continue to hold the run.")
        consumer.release()
        let result = try await run.value
        #expect(consumer.sent == 7 && result.run.elapsedTime >= 0.006 - 1e-9)
    }
}
