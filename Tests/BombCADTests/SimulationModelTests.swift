import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// Exercises the app's non-blocking run loop end to end, without a window.
@MainActor
@Suite("Simulation model", .serialized)
struct SimulationModelTests {
    private func makeModel() async throws -> SimulationModel {
        let model = SimulationModel()
        try #require(model.device != nil, "These tests need a Metal device")
        model.settings.resolution = .coarse
        model.settingsChanged()
        try await waitUntil { model.grid?.cellSize == 0.5 }
        return model
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("An unpaced run reaches the stop time and records every gauge")
    func runsToCompletion() async throws {
        let model = try await makeModel()
        model.speed = .unlimited
        model.duration = 0.05
        model.run()
        #expect(model.isRunning)
        try await waitUntil { !model.isRunning }

        #expect(model.errorMessage == nil)
        #expect(abs(model.time - 0.05) < 1e-6)
        #expect(model.stepCount > 50)
        #expect(model.stats.cellUpdatesPerSecond > 0)
        #expect(model.traces.count == ScenarioPreset.streetCanyon.scenario.gauges.count)
        // The near façade is about 5 m from the charge, so the blast has long since arrived.
        let near = try #require(model.traces.first)
        #expect(near.peak > 50, "peak \(near.peak) kPa")
        #expect(near.points.count > 20)
    }

    @Test("Paced playback holds the requested slow-motion factor")
    func pacedPlayback() async throws {
        let model = try await makeModel()
        model.speed = .x25
        model.duration = 0.02
        let start = ContinuousClock.now
        model.run()
        try await waitUntil { !model.isRunning }
        let wall = ContinuousClock.now - start
        let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18

        // 20 ms of simulation at 25x slow motion should take about half a second.
        #expect(seconds > 0.45 && seconds < 1.0, "took \(seconds) s")
        #expect(abs(model.time - 0.02) < 1e-6)
    }

    @Test("Changing settings mid-run rebuilds from the start")
    func rebuildWhileRunning() async throws {
        let model = try await makeModel()
        model.speed = .x100
        model.run()
        try await waitUntil { model.time > 0.002 }

        model.select(.singleBuilding)
        model.settingsChanged()
        try await waitUntil { !model.isRunning && model.time == 0 }

        #expect(model.traces.map(\.name) == ScenarioPreset.singleBuilding.scenario.gauges.map(\.name))
        #expect(model.stepCount == 0)
        #expect(model.errorMessage == nil)

        // Pausing and resuming carries on from where it stopped.
        model.speed = .unlimited
        model.run()
        try await waitUntil { model.time > 0.005 }
        model.toggleRun()
        try await waitUntil { !model.isRunning }
        let paused = model.time
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.time - paused < 0.005)
        model.toggleRun()
        try await waitUntil { model.time > paused + 0.005 }
        model.toggleRun()
    }

    @Test("A scenario with a structure runs coupled and reports its damage")
    func structureScenario() async throws {
        let model = try await makeModel()
        model.select(.blastWall)
        model.settings.chargeMass = 500
        model.settingsChanged()
        try await waitUntil { model.structureSummary != nil && model.time == 0 && model.traces.count == 3 }
        #expect(model.structureSummary?.erodedElements == 0)
        #expect(model.structureSubsteps > 0)

        model.speed = .unlimited
        model.duration = 0.06
        model.run()
        try await waitUntil { !model.isRunning && model.time > 0.05 }
        let summary = try #require(model.structureSummary)
        #expect(model.errorMessage == nil)
        #expect(!summary.hasBlownUp)
        #expect(summary.erodedElements > 0, "500 kg at 6 m should shear the wall off its base")
        #expect(summary.maxDisplacement > 0.1)

        // Changing the material rebuilds an undamaged structure.
        model.settings.material = .masonry
        model.settingsChanged()
        try await waitUntil { model.time == 0 && model.structureSummary?.erodedElements == 0 }
        // Scenarios without a structure report none.
        model.select(.openGround)
        model.settingsChanged()
        try await waitUntil { model.structureSummary == nil }
    }

    // MARK: Editing

    @Test("Editing the layout rebuilds the simulation with the new geometry")
    func editing() async throws {
        let model = try await makeModel()
        model.select(.openGround)
        model.settingsChanged()
        try await waitUntil { model.traces.count == 5 && model.structureSummary == nil }

        // A rigid block, then a deformable wall with an opening cut in it.
        model.addBlock()
        #expect(model.selection == .block(0))
        #expect(model.highlightedBox == model.settings.scenario.boxes[0])
        model.addWall()
        model.addOpening()
        #expect(model.selection == .opening(0))
        let structure = try #require(model.settings.scenario.structure)
        #expect(structure.solids.count == 1 && structure.openings.count == 1)
        #expect(structure.reinforcement.count == 2, "a wall gets a mat in each face")
        model.settingsChanged()
        try await waitUntil { model.structureSummary != nil }
        let elements = try #require(model.structureSummary).activeElements
        // 4 m by 3 m by 250 mm less a 1 m cube's worth of wall, in 62.5 mm elements.
        #expect(elements == (64 * 48 - 16 * 16) * 4)

        // Removing the wall removes the structure; removing the block empties the layout.
        model.removeSolid(at: 0)
        model.removeBlock(at: 0)
        #expect(model.settings.scenario.structure == nil && model.settings.scenario.boxes.isEmpty)
        #expect(model.selection == nil && model.highlightedBox == nil)
        model.settingsChanged()
        try await waitUntil { model.structureSummary == nil }
    }

    @Test("Clicking the ground moves the charge only in placing mode")
    func placingCharge() async throws {
        let model = try await makeModel()
        let before = model.settings.chargePosition
        // The centre of the view looks at the camera's target, which is on or near the ground.
        model.click(ndc: .zero, aspectRatio: 1.5)
        #expect(model.settings.chargePosition == before)

        model.isPlacingCharge = true
        model.click(ndc: .zero, aspectRatio: 1.5)
        let after = model.settings.chargePosition
        #expect(after != before)
        #expect(after.z == before.z, "height is kept")
        let hit = try #require(model.camera.groundPoint(ndc: .zero, aspectRatio: 1.5))
        #expect(abs(after.x - hit.x) <= 0.125 && abs(after.y - hit.y) <= 0.125)
        // A click on the sky does nothing.
        model.click(ndc: SIMD2(0, 5), aspectRatio: 1.5)
        #expect(model.settings.chargePosition == after)
    }

    @Test("A layout survives being saved and opened again")
    func saveAndOpen() async throws {
        let model = try await makeModel()
        for preset in ScenarioPreset.allCases {
            var scenario = preset.scenario
            scenario.charge.mass = 42
            let data = try ScenarioDocument.encode(scenario)
            let decoded = try JSONDecoder().decode(Scenario.self, from: data)
            #expect(decoded == scenario, "\(preset.title)")

            model.open(decoded)
            #expect(model.settings.scenario == scenario)
            #expect(model.settings.chargeMass == 42)
        }
    }
}
