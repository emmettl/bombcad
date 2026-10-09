import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("The app's companions placed on different Macs", .serialized)
struct CompanionPlacementTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Placed", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        var thermal = ThermalSpec()
        thermal.luminousTemperature = 1000
        thermal.samples = 16
        document.thermal = thermal
        var ground = GroundShockSpec()
        ground.line = .init(from: SIMD2(2.5, 4), to: SIMD2(5.5, 4), count: 4)
        ground.depths = [0, 1]
        document.groundShock = ground
        return document
    }

    private func run(_ model: SimulationModel) async throws -> SavedSimulationRun {
        let deadline = ContinuousClock.now + .seconds(120)
        while !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        model.run()
        while model.isRunning || model.hasPendingGPUWork || !model.companionsCaughtUp {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        try model.keepRun(named: "Run")
        return model.savedRuns.last!
    }

    @Test("The thermal radiation on one Mac and the ground shock on another come out as here")
    func twoMacs() async throws {
        let here = try await run(SimulationModel(document: document(), playbackSpeed: .unlimited))
        let model = SimulationModel(document: document(), playbackSpeed: .unlimited)
        let (first, firstServer) = localWorker(name: "first")
        let (second, secondServer) = localWorker(name: "second")
        _ = try await first.start()
        _ = try await second.start()
        model.useWorker(first, host: "first")
        model.useWorker(second, host: "second")
        model.thermalHost = "first"
        model.groundShockHost = "second"
        #expect(model.wantedHosts == ["first", "second"])
        let there = try await run(model)
        #expect((model.thermal as? ResilientFrameConsumer)?.host == "first")
        #expect((model.groundShock as? ResilientFrameConsumer)?.host == "second")
        #expect(model.thermalStatus.hasSuffix("on first") && model.groundShockStatus.hasSuffix("on second"))
        #expect(there.gauges == here.gauges)
        // The frames fall where batches end, which follows the GPU's timing; the peaks and impulses
        // are the solver's own, kept every step.
        #expect(
            there.groundShock?.result.points.map(\.peakOverpressure)
                == here.groundShock?.result.points.map(\.peakOverpressure))
        #expect(there.thermal?.receivers == here.thermal?.receivers)
        // A Mac no companion wants any more is let go; one still wanted is kept.
        model.thermalHost = nil
        await model.connectWorkers(model.wantedHosts)
        await firstServer.value
        model.groundShockHost = nil
        await model.connectWorkers(model.wantedHosts)
        await secondServer.value
    }
}
