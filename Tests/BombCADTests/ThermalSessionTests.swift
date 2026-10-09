import BlastCore
import DocumentKit
import Foundation
import Testing
import simd

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
        // Few, for the shape's sake in a debug build: these tests are about exactness.
        spec.samples = 16
        return spec
    }

    /// A fireball that grows and cools, then is gone, in blocks as the air model gives it.
    private var frames: [FireballFrame] {
        (0...12).map { n in
            let radius = n < 10 ? 0.5 + 0.3 * Float(n) : 0
            let centre = SIMD3<Float>(15, 15, 1 + radius / 2)
            let temperature = radius > 0 ? 2600 - 60 * Float(n) : 0
            return FireballFrame(
                time: Double(n) * 0.001 + (n % 3 == 0 ? 0.0003 : 0),
                volume: 4 / 3 * Double.pi * pow(Double(radius), 3), centre: centre,
                temperature: temperature, hottest: radius > 0 ? 3000 : 0,
                shape: radius > 0 ? ball(centre, radius: radius, temperature: UInt16(temperature)) : nil)
        }
    }

    /// A ball in blocks half a metre a side, above the ground, their share of luminous air
    /// falling off across its edge.
    private func ball(_ centre: SIMD3<Float>, radius: Float, temperature: UInt16) -> FireballShape {
        let size: Float = 0.5
        var first = SIMD3<Int32>(((centre - radius) / size).rounded(.down)) &- 1
        first.z = max(first.z, 0)
        let counts = SIMD3<Int32>(((centre + radius) / size).rounded(.up)) &+ 1 &- first
        var fills: [UInt8] = []
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    let middle = (SIMD3<Float>(first &+ SIMD3(i, j, k)) + 0.5) * size
                    let share = min(max(0.5 + (radius - simd_distance(middle, centre)) / size, 0), 1)
                    fills.append(UInt8((255 * share).rounded()))
                }
            }
        }
        return FireballShape(
            blockSize: size, first: first, counts: counts, fills: fills,
            temperatures: fills.map { $0 > 0 ? temperature : 0 })
    }

    @Test("On a worker, through its connection, the receivers come to exactly the same result")
    func remote() async throws {
        let here = LocalThermalConsumer(spec: spec, scene: scene)
        for frame in frames { here.send(frame) }
        let local = try await here.finish()
        #expect(here.live.frames == frames.count && here.sent == frames.count)
        #expect(local.fluence.contains { $0 > 0 } && local.fireball == frames.map(\.withoutShape))

        let (client, server) = localWorker()
        _ = try await client.start()
        let there = RemoteThermalConsumer(client: client, spec: spec, scene: scene)
        #expect(there.receivers == local.receivers)
        for frame in frames { there.send(frame) }
        // The receivers come back after each frame, the same as here.
        let deadline = ContinuousClock.now + .seconds(30)
        while there.live.frames < frames.count {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(there.live == here.live)
        #expect(there.live.fluence == local.fluence && there.live.peakIrradiance == local.peakIrradiance)
        let remote = try await there.finish()
        #expect(remote == local)
        await server.value
    }

    @Test("A session the worker does not know fails, and a cancelled one is dropped")
    func unknown() async throws {
        let (client, server) = localWorker()
        _ = try await client.start()
        await #expect(throws: ProjectFileError.self) { try await client.finishThermal(UUID()) }
        let there = RemoteThermalConsumer(client: client, spec: spec, scene: scene, ownsClient: false)
        there.send(frames[0])
        there.cancel()
        await #expect(throws: ProjectFileError.self) { try await client.finishThermal(there.id) }
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
