import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Ground points in the app", .serialized)
struct GroundShockOverlayTests {
    /// A point under the block, then a line out along the ground from beside the charge.
    private func spec() -> GroundShockSpec {
        var spec = GroundShockSpec()
        spec.points = [SIMD2(6.75, 6.75)]
        spec.line = .init(from: SIMD2(2.5, 4), to: SIMD2(5.5, 4), count: 4)
        spec.depths = [0, 1]
        // The far end peaks just under a kilopascal on these coarse cells.
        spec.arrivalThreshold = 500
        return spec
    }

    private func airOnly() -> ProjectDocument {
        var scene = Scenario(
            name: "Ground", domainSize: SIMD3(8, 8, 4),
            boxes: [Box(min: SIMD3(6, 6, 0), max: SIMD3(7.5, 7.5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(2, 4, 0.5)))
        scene.gauges = [Gauge("Near", at: SIMD3(3, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        return document
    }

    private func waitUntil(_ model: SimulationModel, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !condition() {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Runs `document` to its end at unlimited speed and keeps the run.
    private func run(_ document: ProjectDocument, groundShock: GroundShockSpec?) async throws -> (
        SimulationModel, SavedSimulationRun
    ) {
        var document = document
        document.groundShock = groundShock
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        try await waitUntil(model) { model.experimentIsReady }
        model.run()
        try await waitUntil(model) {
            !model.isRunning && !model.hasPendingGPUWork && model.companionsCaughtUp
        }
        try model.keepRun(named: "Run")
        return (model, model.savedRuns.last!)
    }

    @Test("Ground points change nothing in the air, to the last bit")
    func airUnchanged() async throws {
        let (_, without) = try await run(airOnly(), groundShock: nil)
        let (model, with) = try await run(airOnly(), groundShock: spec())
        #expect(with.stepCount == without.stepCount && with.gauges == without.gauges)
        #expect(model.groundShock != nil && without.groundShock == nil)
    }

    @Test("The run estimates the ground's shaking as it goes, and draws the points coloured by it")
    func live() async throws {
        let (model, _) = try await run(airOnly(), groundShock: spec())
        let live = try #require(model.groundShockLive)
        #expect(live.points.count == 5 && live.points[0].covered)
        let line = live.points.dropFirst()
        #expect(line.allSatisfy { $0.arrival != nil && $0.peakOverpressure > 0 })
        // Faster nearer the charge.
        let speeds = line.map { $0.surfaceVelocity(in: live.soil) }
        #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 > $1 })
        #expect(model.groundShockStatus.contains("reached 4 of 5 points"))
        #expect(model.groundShockStatus.contains("1 under a block"))
        // The covered point is not drawn; the others are reached and coloured, nearer brighter.
        let dots = model.groundShockDots()
        #expect(dots.count == 4 && dots.allSatisfy { $0.w > 3 && $0.w < 4 && $0.z > 0 })
        #expect(zip(dots, dots.dropFirst()).allSatisfy { $0.w > $1.w })

        // Reset clears the estimate; the points are drawn grey where they stand, all five.
        model.reset()
        try await waitUntil(model) { model.experimentIsReady }
        #expect(model.groundShockLive == nil && model.groundShockStatus.isEmpty)
        #expect(model.groundShockDots().count == 5 && model.groundShockDots().allSatisfy { $0.w == 3 })
    }

    @Test("A kept run keeps its ground shock, through saving and reopening, and restores the points")
    func kept() async throws {
        let (model, kept) = try await run(airOnly(), groundShock: spec())
        let ground = try #require(kept.groundShock)
        #expect(ground.spec == spec() && ground.result.points.count == 5)
        #expect(ground.result.points.allSatisfy { $0.history.isEmpty })
        #expect(
            ground.result.points.map(\.peakOverpressure)
                == model.groundShockLive?.points.map(\.peakOverpressure))
        #expect(ground.summary.hasPrefix("Ground shock: 5 points, fastest "))
        // No part of the fingerprint.
        #expect(
            kept.inputSHA256 == (try SavedSimulationRun.fingerprint(kept.scenario, settings: kept.settings)))
        // A peak overpressure and a velocity at each depth for each point reached.
        #expect(kept.csv().components(separatedBy: ",kPa\n").count - 1 >= 4)
        #expect(kept.csv().components(separatedBy: ",mm/s\n").count - 1 == 8)

        let document = ProjectDocument(model: model)
        let reopened = try ProjectDocument(archive: document.makeArchive())
        #expect(reopened.savedRuns.last?.groundShock == ground && reopened.groundShock == spec())

        // Using the run's inputs brings the points back, as one step to undo.
        model.groundShockSpec = nil
        try await Task.sleep(for: .milliseconds(300))
        try model.useRunInputs(id: kept.id)
        #expect(model.groundShockSpec == spec())
        model.undo()
        #expect(model.groundShockSpec == nil)

        // A result that does not match its points, or with a history, is refused.
        var broken = kept
        broken.groundShock?.result.points.removeLast()
        #expect(throws: ProjectFileError.self) { try broken.validate() }
        broken = kept
        broken.groundShock?.result.points[1].history = [1]
        #expect(throws: ProjectFileError.self) { try broken.validate() }
    }

    @Test("A soil column runs alongside, its motion at depth charted live and its peaks kept with the run")
    func column() async throws {
        var column = spec()
        column.model = .column
        column.profile = GroundShockSection.defaultProfile(column.soil)
        column.profile?.base = GroundShockSection.Beneath.stiffSoil.base
        let (model, kept) = try await run(airOnly(), groundShock: column)
        let live = try #require(model.groundShockLive)
        let times = try #require(live.frameTimes)
        #expect(live.model == .column && times.count == live.frames && times.first == 0)
        let line = live.points.dropFirst()
        for point in line {
            let profile = try #require(point.profile)
            #expect(profile.depths.last == 1 && profile.velocity.allSatisfy { $0 >= 0 })
            #expect(point.responses.allSatisfy { $0.history?.count == live.frames })
            // Bilinear soil: less at a metre down than at the top, some left compacted.
            #expect(point.responses[1].verticalVelocity < point.responses[0].verticalVelocity)
            #expect(point.responses[0].residualDisplacement! > 0)
        }
        let speeds = line.map { $0.surfaceVelocity(in: live.soil) }
        #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 > $1 })
        // Kept without the histories or the frames' times, and through saving and reopening.
        let ground = try #require(kept.groundShock)
        #expect(ground.result.frameTimes == nil && ground.result.profile == column.profile)
        #expect(ground.result.points.allSatisfy { $0.responses.allSatisfy { $0.history == nil } })
        #expect(ground.summary.hasPrefix("Ground shock in a soil column: 5 points"))
        let reopened = try ProjectDocument(archive: ProjectDocument(model: model).makeArchive())
        #expect(reopened.savedRuns.last?.groundShock == ground && reopened.groundShock == column)
        var broken = kept
        broken.groundShock?.result.points[1].responses[0].history = [1]
        #expect(throws: ProjectFileError.self) { try broken.validate() }
        broken = kept
        broken.groundShock?.result.profile = nil
        #expect(throws: ProjectFileError.self) { try broken.validate() }
    }

    @Test("Points outside the domain are not estimated, and the line says so")
    func outside() async throws {
        var outside = spec()
        outside.points = [SIMD2(20, 20)]
        var document = airOnly()
        document.groundShock = outside
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        try await waitUntil(model) { model.experimentIsReady }
        model.run()
        try await waitUntil(model) { !model.isRunning && !model.hasPendingGPUWork }
        #expect(model.groundShock == nil && model.groundShockStatus.contains("outside the domain"))
        try model.keepRun(named: "Run")
        #expect(model.savedRuns.last?.groundShock == nil)
    }

    @Test("The Run tab's starting line lies in the domain, out from the charge the longest way")
    func defaults() throws {
        let spec = GroundShockSection.defaultSpec(for: airOnly().scenario)
        // A soil column of the dry soil, unloading at twice its loading wave speed.
        #expect(
            spec.model == .column && spec.profile?.layers.first?.unloadingSpeed == 2 * spec.soil.waveSpeed)
        try spec.validate(domain: SIMD3(8, 8, 4))
        let line = try #require(spec.line)
        // The charge is at x = 2: the ground runs furthest towards +x.
        #expect(line.from == SIMD2(3, 4) && line.to == SIMD2(7, 4) && line.count == 16)
        var corner = airOnly().scenario
        corner.charge.position = SIMD3(7.5, 7.5, 0.5)
        let back = try #require(GroundShockSection.defaultSpec(for: corner).line)
        #expect(back.to.x < back.from.x || back.to.y < back.from.y)
        try GroundShockSection.defaultSpec(for: corner).validate(domain: SIMD3(8, 8, 4))
    }

    @Test("A project keeps its ground points when saved and reopened")
    func saved() throws {
        var document = airOnly()
        document.groundShock = spec()
        #expect(try ProjectDocument(archive: document.makeArchive()).groundShock == spec())
        document.groundShock = nil
        #expect(try ProjectDocument(archive: document.makeArchive()).groundShock == nil)
    }

    @Test("On the Mac set for sweeps, the ground points come to the same estimate as here")
    func remote() async throws {
        let (_, here) = try await run(airOnly(), groundShock: spec())
        var document = airOnly()
        document.groundShock = spec()
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        let (worker, server) = localWorker(name: "the mini")
        _ = try await worker.start()
        model.useWorker(worker, host: "the mini")
        model.groundShockHost = "the mini"
        try await waitUntil(model) { model.experimentIsReady }
        model.run()
        try await waitUntil(model) {
            !model.isRunning && !model.hasPendingGPUWork && model.companionsCaughtUp
        }
        #expect(model.groundShock is ResilientFrameConsumer)
        try model.keepRun(named: "There")
        let there = try #require(model.savedRuns.last)
        #expect(there.gauges == here.gauges && there.stepCount == here.stepCount)
        // The frames fall where batches end, which follows the GPU's timing; compare the peaks and
        // impulses, which the solver keeps every step.
        #expect(
            there.groundShock?.result.points.map(\.peakOverpressure)
                == here.groundShock?.result.points.map(\.peakOverpressure))
        #expect(
            there.groundShock?.result.points.map(\.impulse) == here.groundShock?.result.points.map(\.impulse))
        worker.close()
        await server.value
    }
}
