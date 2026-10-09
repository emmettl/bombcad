import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Thermal radiation reckoned over a run in the app", .serialized)
struct ThermalOverlayTests {
    /// Low enough that the charge's gas, spread over the coarse grid's half-metre cells, is
    /// luminous through the run.
    private var spec: ThermalSpec {
        var spec = ThermalSpec()
        spec.luminousTemperature = 600
        spec.samples = 32
        return spec
    }

    private func airOnly() -> ProjectDocument {
        var scene = Scenario(
            name: "Thermal", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 2, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1)), Gauge("Far", at: SIMD3(7.5, 7.5, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.01
        return document
    }

    private func structural() throws -> ProjectDocument {
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        return document
    }

    private func ready(_ model: SimulationModel, by deadline: ContinuousClock.Instant) async throws {
        while !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Runs `model` to its end and keeps the run once its thermal radiation is all reckoned.
    private func runAndKeep(_ model: SimulationModel, named name: String = "Run") async throws
        -> SavedSimulationRun
    {
        let deadline = ContinuousClock.now + .seconds(120)
        try await ready(model, by: deadline)
        model.run()
        while model.isRunning || model.hasPendingGPUWork {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        while let thermal = model.thermal, thermal.live.frames < thermal.sent {
            #expect(throws: ProjectFileError.self) { try model.keepRun(named: name) }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        try model.keepRun(named: name)
        return model.savedRuns.last!
    }

    private func run(_ document: ProjectDocument, thermal: ThermalSpec?) async throws -> (
        SimulationModel, SavedSimulationRun
    ) {
        var document = document
        document.thermal = thermal
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        return (model, try await runAndKeep(model))
    }

    @Test("The thermal radiation changes nothing in the air or the structure, to the last bit")
    func airUnchanged() async throws {
        for document in [airOnly(), try structural()] {
            let (_, without) = try await run(document, thermal: nil)
            let (model, with) = try await run(document, thermal: spec)
            #expect(with.stepCount == without.stepCount)
            #expect(with.gauges == without.gauges && with.structure == without.structure)
            #expect(model.thermal != nil && with.thermal != nil && without.thermal == nil)
        }
    }

    @Test("A kept run keeps its thermal radiation, through saving and reopening, and restores it")
    func kept() async throws {
        let (model, kept) = try await run(airOnly(), thermal: spec)
        let thermal = try #require(kept.thermal)
        let live = try #require(model.thermal?.live)
        #expect(thermal.spec == spec && thermal.fluence == live.fluence)
        #expect(
            thermal.peakIrradiance == live.peakIrradiance && thermal.receivers == model.thermal?.receivers)
        #expect(thermal.fluence.contains { $0 > 0 } && thermal.receivers.contains { $0.surface == "block 0" })
        // A frame at the start, about one a millisecond, and one at the end.
        #expect(thermal.fireball.first?.time == 0 && abs((thermal.fireball.last?.time ?? 0) - 0.01) < 1e-6)
        #expect((10...22).contains(thermal.fireball.count), "\(thermal.fireball.count) frames")
        #expect(thermal.fireball.contains { $0.volume > 0 })
        #expect(thermal.comparison.hasPrefix("Thermal: fireball up to "))
        // Not part of the inputs' fingerprint, as it does not act on the air.
        #expect(
            kept.inputSHA256 == (try SavedSimulationRun.fingerprint(kept.scenario, settings: kept.settings)))
        let csv = kept.csv()
        #expect(csv.components(separatedBy: ",K\n").count - 1 == thermal.fireball.count)

        var document = ProjectDocument(model: model)
        #expect(document.thermal == spec)
        let reopened = try ProjectDocument(archive: document.makeArchive())
        #expect(reopened.savedRuns.last?.thermal == thermal && reopened.thermal == spec)
        document.thermal = nil
        #expect(try ProjectDocument(archive: document.makeArchive()).thermal == nil)

        // Using a run's inputs brings its thermal radiation back, as one step to undo.
        model.thermalSpec = nil
        try await Task.sleep(for: .milliseconds(300))
        try model.useRunInputs(id: kept.id)
        #expect(model.thermalSpec == spec)
        model.undo()
        #expect(model.thermalSpec == nil)
        model.redo()
        #expect(model.thermalSpec == spec)

        // Out of range is refused.
        var broken = kept
        broken.thermal?.fluence.removeLast()
        #expect(throws: ProjectFileError.self) { try broken.validate() }
        broken = kept
        broken.thermal?.fluence[0] = -1
        #expect(throws: ProjectFileError.self) { try broken.validate() }
        broken = kept
        broken.thermal?.fireball.append(thermal.fireball[0])
        #expect(throws: ProjectFileError.self) { try broken.validate() }
    }

    @Test("A sweep's cases here wait for their thermal radiation before they are kept")
    func sweep() async throws {
        var document = airOnly()
        document.runSettings?.duration = 0.006
        // Slow enough to fall behind the run.
        var slow = spec
        slow.samples = 2048
        slow.groundSpacing = 0.2
        document.thermal = slow
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        try await ready(model, by: ContinuousClock.now + .seconds(60))
        try model.sweep.start(.init(prefix: "Mass", parameter: .chargeMass([1, 2])))
        let deadline = ContinuousClock.now + .seconds(300)
        while model.sweep.isActive {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.sweep.completed == 2, "\(model.sweep.message)")
        #expect(model.savedRuns.map(\.scenario.charge.mass) == [1, 2])
        #expect(model.savedRuns.allSatisfy { $0.thermal?.spec == slow })
    }

    @Test("Each edit to the section settles into a step to undo")
    func undo() async throws {
        let model = SimulationModel(document: airOnly(), playbackSpeed: .unlimited)
        try await ready(model, by: ContinuousClock.now + .seconds(60))
        let steps = model.undoStack.count
        // Each edit settles into its step a moment later, however busy the Mac.
        func settled(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while model.undoStack.count < steps + count {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        model.thermalSpec = ThermalSpec()
        try await settled(1)
        model.thermalSpec?.emissivity = 0.4
        try await settled(2)
        model.undo()
        #expect(model.thermalSpec == ThermalSpec())
        model.undo()
        #expect(model.thermalSpec == nil)
    }

    @Test("The receivers are drawn coloured by their fluence as the run goes, and Reset clears them")
    func dots() async throws {
        let (model, kept) = try await run(airOnly(), thermal: spec)
        let thermal = try #require(kept.thermal)
        let dots = model.thermalDots()
        #expect(dots.count == thermal.receivers.count)
        #expect(dots.allSatisfy { $0.w >= 4 && $0.w < 5 })
        let hottest = try #require(thermal.fluence.indices.max { thermal.fluence[$0] < thermal.fluence[$1] })
        #expect(dots[hottest].w == 4 + SimulationModel.thermalShade(thermal.fluence[hottest]))
        #expect(dots.contains { $0.w > 4 })
        #expect(SimulationModel.thermalShade(0) == 0 && SimulationModel.thermalShade(1e6) == 0.999)
        #expect(model.thermalStatus.contains("Fireball up to") && model.thermalStatus.contains("kJ/m²"))
        // The view, drawing only on change between runs, sees the last frames come in.
        let deadline = ContinuousClock.now + .seconds(10)
        while model.thermalReckoned < thermal.fireball.count {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.thermalReckoned == thermal.fireball.count)
        model.reset()
        try await ready(model, by: ContinuousClock.now + .seconds(10))
        #expect(model.thermalDots().isEmpty && model.thermalStatus.isEmpty && model.thermalReckoned == 0)
    }

    @Test(
        "Run on a worker, the thermal radiation comes out exactly as here, over a connection kept between runs"
    )
    func remote() async throws {
        let (_, here) = try await run(airOnly(), thermal: spec)
        var document = airOnly()
        document.thermal = spec
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        let (worker, server) = localWorker(name: "the mini")
        _ = try await worker.start()
        model.useFragmentWorker(worker, host: "the mini")
        model.thermalOnRemote = true
        for name in ["First", "Second"] {
            let there = try await runAndKeep(model, named: name)
            #expect(model.thermal is RemoteThermalConsumer)
            #expect(model.thermalStatus.hasSuffix("on the mini"))
            // The frames fall where batches end, which follows the GPU's timing; the same frames
            // reckoned here give the same result, to the last bit.
            let thermal = try #require(there.thermal)
            var local = ThermalExposure(spec: spec, scene: FragmentScene(there.scenario))
            for frame in thermal.fireball { local.add(frame) }
            #expect(local.result == thermal && thermal.fluence.contains { $0 > 0 })
            #expect(there.gauges == here.gauges)
            model.reset()
        }
        worker.close()
        await server.value
    }
}
