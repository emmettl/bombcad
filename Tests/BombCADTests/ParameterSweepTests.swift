import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Parameter sweep planning")
struct ParameterSweepPlanTests {
    private func baseline() throws -> SimulationInputs {
        let run = try SavedRunTests().fixture()
        return SimulationInputs(scenario: run.scenario, settings: run.settings)
    }

    @Test("Mass cases change only the primary charge and validate every value")
    func masses() throws {
        var baseline = try baseline()
        baseline.scenario.additionalCharges = [Charge(mass: 3, position: SIMD3(5, 5, 1))]
        let plan = ParameterSweepPlan(prefix: "Mass", parameter: .chargeMass([0, 0.01, 2]))
        let cases = try plan.prepare(from: baseline)
        #expect(cases.map { $0.inputs.scenario.charge.mass } == [0, 0.01, 2])
        for item in cases {
            var restored = item.inputs
            restored.scenario.charge.mass = baseline.scenario.charge.mass
            #expect(restored == baseline)
        }
        for values: [Float] in [
            [], [-1], [.infinity], [.greatestFiniteMagnitude], [1, 1], Array(0...8).map(Float.init),
        ] {
            #expect(throws: ProjectFileError.self) {
                try ParameterSweepPlan(prefix: "Mass", parameter: .chargeMass(values)).prepare(from: baseline)
            }
        }
    }

    @Test("Grid cases resample independently, retain assignments and respect detached edits")
    func grids() throws {
        let original = try baseline()
        let cases = try ParameterSweepPlan(prefix: "Grid", parameter: .grid([.coarse, .fine])).prepare(
            from: original)
        #expect(cases[0].inputs == original)
        #expect(cases[1].inputs.scenario.importedModels?.first?.preview.cellSize == 0.125)
        #expect(
            cases[1].inputs.scenario.importedModels?.first?.source
                == original.scenario.importedModels?.first?.source)
        var edited = original
        edited.scenario.structure?.openings.append(Box(min: .zero, max: SIMD3(0.5, 0.5, 0.5)))
        #expect(throws: ImportedMesh.ImportError.self) {
            try ParameterSweepPlan(prefix: "Grid", parameter: .grid([.coarse, .fine])).prepare(from: edited)
        }
        edited.scenario.detachImport(id: edited.scenario.importedModels![0].id)
        let detached = try ParameterSweepPlan(prefix: "Detached", parameter: .grid([.fine])).prepare(
            from: edited)[0]
        #expect(detached.inputs.scenario == edited.scenario)
        #expect(detached.inputs.settings.solidElementSize == edited.settings.solidElementSize)
    }
}

@MainActor @Suite("Restoring run inputs and sweep execution", .serialized)
struct ParameterSweepExecutionTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Experiment baseline", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.003
        return document
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(
        "Restoring geometry and all numerical inputs is one undo step and preserves runs and document identity"
    )
    func restoreInputs() throws {
        let run = try SavedRunTests().fixture()
        var document = document()
        document.savedRuns = [run]
        document.runSettings?.detailedCharge = true
        document.runSettings?.solidElementSize = 0.125
        document.runSettings?.duration = 0.02
        let model = SimulationModel(document: document)
        let before = model.currentInputs
        let id = model.projectDocumentID
        try model.useRunInputs(id: run.id)
        let target = SimulationInputs(scenario: run.scenario, settings: run.settings)
        #expect(model.currentInputs == target)
        #expect(model.undoStack.count == 1)
        #expect(model.savedRuns == [run] && model.projectDocumentID == id)
        model.undo()
        #expect(model.currentInputs == before)
        model.redo()
        #expect(model.currentInputs == target)
        #expect(try ProjectDocument(archive: ProjectDocument(model: model).makeArchive()).savedRuns == [run])
    }

    @Test(
        "Sequential mass cases capture distinct inputs and restore the baseline without experiment undo entries"
    )
    func massSweep() async throws {
        let session = ProjectSession(document: document())
        let model = session.model
        let baseline = model.currentInputs
        let undoCount = model.undoStack.count
        let speed = model.speed
        try model.sweep.start(.init(prefix: "Mass", parameter: .chargeMass([0, 0.02, 0.03])))
        #expect(session.snapshot.scenario == baseline.scenario)
        #expect(session.snapshot.runSettings == baseline.settings)
        try await waitUntil { !model.sweep.isActive && model.experimentIsReady }
        #expect(model.savedRuns.count == 3)
        #expect(model.savedRuns.map { $0.scenario.charge.mass } == [0, 0.02, 0.03])
        #expect(Set(model.savedRuns.map(\.inputSHA256)).count == 3)
        #expect(model.currentInputs == baseline && model.speed == speed)
        #expect(model.undoStack.count == undoCount)
        #expect(model.sweep.completed == 3)
        let restored = try ProjectDocument(archive: session.snapshot.makeArchive())
        #expect(restored.scenario == baseline.scenario && restored.savedRuns == model.savedRuns)
    }

    @Test("Grid sweeps handle settings notifications without interrupting cases")
    func gridSweep() async throws {
        let model = SimulationModel(document: document())
        let baseline = model.currentInputs
        try model.sweep.start(.init(prefix: "Grid", parameter: .grid([.coarse, .fine])))
        // Simulate SwiftUI's settings-change callback during automatically applied cases.
        let deadline = ContinuousClock.now + .seconds(20)
        while model.sweep.isActive {
            try #require(ContinuousClock.now < deadline)
            model.settingsChanged()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.savedRuns.map { $0.settings.resolution } == ["coarse", "fine"])
        #expect(model.currentInputs == baseline)
        #expect(model.sweep.message.contains("complete"))
    }

    @Test("Cancellation restores persisted inputs immediately and leaves completed cases available")
    func cancellation() async throws {
        let session = ProjectSession(document: document())
        let model = session.model
        let baseline = model.currentInputs
        try model.sweep.start(
            .init(prefix: "Cancel", parameter: .chargeMass([0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08])))
        try await waitUntil { model.sweep.completed >= 1 || !model.sweep.isActive }
        let kept = model.savedRuns
        #expect(kept.count < 8)
        model.sweep.cancel()
        #expect(session.snapshot.scenario == baseline.scenario)
        #expect(session.snapshot.runSettings == baseline.settings)
        try await waitUntil { !model.sweep.isActive && model.experimentIsReady }
        #expect(model.savedRuns == kept)
        #expect(model.currentInputs == baseline)
    }

    @Test("Identical document inputs still reset the solver and prevent startup during reload")
    func loadingGuard() async throws {
        let document = document()
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.run()
        try await waitUntil { !model.isRunning }
        #expect(model.time > 0)
        model.open(document)
        #expect(model.isLoadingInputs)
        #expect(throws: ProjectFileError.self) {
            try model.sweep.start(.init(prefix: "Wait", parameter: .chargeMass([0.01])))
        }
        model.run()
        #expect(!model.isRunning)
        try await waitUntil { model.experimentIsReady }
        #expect(model.time == 0 && model.savedRuns.isEmpty)
    }

    @Test("Name collisions stop before running, and document replacement prevents late restoration")
    func failureAndReplacement() async throws {
        let model = SimulationModel(document: document())
        try model.sweep.start(.init(prefix: "Once", parameter: .chargeMass([0.01])))
        try await waitUntil { !model.sweep.isActive }
        let runs = model.savedRuns
        try model.sweep.start(.init(prefix: "Once", parameter: .chargeMass([0.01])))
        try await waitUntil { !model.sweep.isActive }
        #expect(model.savedRuns == runs)
        #expect(model.sweep.message.contains("already exist"))
        try model.sweep.start(.init(prefix: "Replace", parameter: .grid([.coarse, .fine])))
        var replacement = document()
        replacement.scenario.charge.mass = 0.04
        model.open(replacement)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.settings.scenario == replacement.scenario)
        #expect(model.savedRuns.isEmpty)
        #expect(!model.sweep.isActive)
    }
}
