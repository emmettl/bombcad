import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Thermal radiation reckoned apart from the run", .serialized)
struct ThermalSessionTests {
    private var scene: FragmentScene {
        var scenario = Scenario(
            name: "Thermal", domainSize: SIMD3(40, 30, 20),
            boxes: [Box(min: SIMD3(26, 10, 0), max: SIMD3(30, 20, 8))],
            charge: Charge(mass: 5, position: SIMD3(15, 15, 1)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    private var spec: ThermalSpec {
        var spec = ThermalSpec()
        spec.groundSpacing = 2
        spec.samples = 64
        return spec
    }

    /// A fireball that grows and cools, then is gone.
    private var frames: [FireballFrame] {
        (0...12).map { n in
            let radius = n < 10 ? 0.5 + 0.3 * Float(n) : 0
            return FireballFrame(
                time: Double(n) * 0.001 + (n % 3 == 0 ? 0.0003 : 0),
                volume: 4 / 3 * Double.pi * pow(Double(radius), 3), centre: SIMD3(15, 15, 1 + radius / 2),
                temperature: radius > 0 ? 2600 - 60 * Float(n) : 0, hottest: radius > 0 ? 3000 : 0)
        }
    }

    @Test("On a worker, through its connection, the receivers come to exactly the same result")
    func remote() async throws {
        let kind = ConsumerKind.thermal(spec, scene, live: true)
        let here = LocalFrameConsumer(kind)
        for frame in frames { here.send(.fireball(frame)) }
        guard case .thermal(let local) = try await here.finish(frameInterval: 0.001) else {
            Issue.record("Not a thermal result")
            return
        }
        #expect(here.thermalLive?.frames == frames.count && here.sent == frames.count)
        #expect(local.fluence.contains { $0 > 0 } && local.fireball == frames)

        let (client, server) = localWorker()
        _ = try await client.start()
        let there = RemoteFrameConsumer(client: client, kind: kind)
        #expect(ThermalExposure.receivers(scene: scene, spec: spec) == local.receivers)
        for frame in frames { there.send(.fireball(frame)) }
        // The receivers come back after each frame, the same as here.
        let deadline = ContinuousClock.now + .seconds(30)
        while (there.thermalLive?.frames ?? 0) < frames.count {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(there.thermalLive == here.thermalLive)
        #expect(
            there.thermalLive?.fluence == local.fluence
                && there.thermalLive?.peakIrradiance == local.peakIrradiance)
        guard case .thermal(let remote) = try await there.finish(frameInterval: 0.001) else {
            Issue.record("Not a thermal result")
            return
        }
        #expect(remote == local)
        await server.value
    }

    @Test("A session the worker does not know fails, and a cancelled one is dropped")
    func unknown() async throws {
        let (client, server) = localWorker()
        _ = try await client.start()
        await #expect(throws: ProjectFileError.self) {
            try await client.finishConsumer(UUID(), frameInterval: 0.001)
        }
        let there = RemoteFrameConsumer(
            client: client, kind: .thermal(spec, scene, live: true), ownsClient: false)
        there.send(.fireball(frames[0]))
        there.cancel()
        await #expect(throws: ProjectFileError.self) {
            try await client.finishConsumer(there.id, frameInterval: 0.001)
        }
        client.close()
        await server.value
    }

    @Test("The receivers travel as little-endian floats, and a short payload is refused")
    func payload() throws {
        var exposure = ThermalExposure(spec: spec, scene: scene)
        for frame in frames.prefix(4) { exposure.add(frame) }
        let sent = ThermalLive(exposure)
        var received = ThermalLive(receivers: exposure.receivers.count)
        try received.read(sent.payload, header: ThermalLiveHeader(frames: sent.frames, time: sent.time))
        #expect(received == sent && sent.frames == 4)
        #expect(throws: ProjectFileError.self) {
            try received.read(sent.payload.dropLast(4), header: ThermalLiveHeader(frames: 5, time: 0))
        }
    }
}
