import BlastCore
import BlastRender
import Foundation
import Testing

@testable import BombCAD

/// Exercises the app's non-blocking run loop end to end, without a window.
@MainActor
@Suite("Simulation model", .serialized)
struct SimulationModelTests {
    private func makeModel() async throws -> SimulationModel {
        var document = ProjectDocument()
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        try #require(model.device != nil, "These tests need a Metal device")
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

    private func importedLayout(deformable: Bool = false) throws -> Scenario {
        let source = try ImportedMesh(
            data: Data(
                """
                v 0 0 0
                v 1 0 0
                v 1 1 0
                v 0 1 0
                v 0 0 1
                v 1 0 1
                v 1 1 1
                v 0 1 1
                f 1 4 3 2
                f 5 6 7 8
                f 1 2 6 5
                f 2 3 7 6
                f 3 4 8 7
                f 4 1 5 8
                """.utf8), fileExtension: "obj")
        let transformed = try source.transformed(scale: 1, yUp: false, corner: SIMD3(1, 1, 0))
        let imported = ImportedModel(
            name: "Cube", source: source, scale: 1, yUp: false, corner: SIMD3(1, 1, 0),
            behavior: deformable ? .deformable : .rigid,
            preview: try transformed.preview(cellSize: 0.5, domain: SIMD3(repeating: 4)))
        var layout = Scenario(
            name: "Sources", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(3, 3, 2)))
        try layout.installImport(imported, material: .plainConcrete, fixedBase: false)
        return layout
    }
    @Test("Retained imports resample on grid changes and undo restores their sampling grid")
    func retainedImportGrid() async throws {
        let model = try await makeModel()
        model.open(try importedLayout())
        try await waitUntil {
            model.grid?.nx == 8 && model.settings.scenario.importedModels?.first?.preview.cellSize == 0.5
        }
        model.settings.resolution = .fine
        model.settingsChanged()
        model.run()
        #expect(!model.isRunning)
        try await waitUntil {
            model.grid?.cellSize == 0.125
                && model.settings.scenario.importedModels?.first?.preview.occupiedCells == 512
                && !model.isPreparingImports
        }
        #expect(model.errorMessage == nil)
        model.undo()
        try await waitUntil { model.grid?.cellSize == 0.5 }
        #expect(model.settings.scenario.importedModels?.first?.preview.occupiedCells == 8)
        model.redo()
        try await waitUntil { model.grid?.cellSize == 0.125 }
        #expect(model.settings.scenario.importedModels?.first?.preview.occupiedCells == 512)
    }
    @Test("Source material assignments survive app grid changes and undo/redo")
    func partMaterialGridUndo() async throws {
        let model = try await makeModel()
        var layout = try importedLayout(deformable: true)
        var imported = try #require(layout.importedModels?.first)
        imported.partMaterials = [imported.source.parts[0].id: .structuralSteel]
        try layout.installImport(imported, material: .plainConcrete, fixedBase: false)
        model.open(layout)
        try await waitUntil { model.grid?.nx == 8 && model.errorMessage == nil }
        model.settings.resolution = .fine
        model.settingsChanged()
        try await waitUntil { model.grid?.cellSize == 0.125 && !model.isPreparingImports }
        #expect(model.settings.scenario.structure?.material(of: 0) == .structuralSteel)
        #expect(model.settings.scenario.importedModels?.first?.partMaterials == imported.partMaterials)
        model.undo()
        try await waitUntil { model.grid?.cellSize == 0.5 }
        #expect(model.settings.scenario.structure?.material(of: 0) == .structuralSteel)
        model.redo()
        try await waitUntil { model.grid?.cellSize == 0.125 }
        #expect(model.settings.scenario.structure?.material(of: 0) == .structuralSteel)
        #expect(model.errorMessage == nil)
    }
    @Test("Rapid grid edits use the latest sampling request and sources survive detaching undo")
    func retainedImportLatestRequest() async throws {
        let model = try await makeModel()
        model.open(try importedLayout())
        try await waitUntil { model.grid?.nx == 8 }
        model.settings.resolution = .fine
        model.settingsChanged()
        model.settings.resolution = .medium
        model.settingsChanged()
        try await waitUntil { model.grid?.cellSize == 0.25 && !model.isPreparingImports }
        let imported = try #require(model.settings.scenario.importedModels?.first)
        #expect(imported.preview.occupiedCells == 64)
        model.detachImport(id: imported.id)
        try await waitUntil {
            model.settings.scenario.importedModels?.first?.isAttached == false && !model.canRedo
        }
        model.undo()
        try await waitUntil {
            model.settings.scenario.importedModels?.first?.id == imported.id
                && model.settings.scenario.importedModels?.first?.isAttached == true
        }
        #expect(model.settings.scenario.boxes.isEmpty)
    }

    @Test("A grid change cannot run or overwrite an imported structure with local edits")
    func retainedImportEdits() async throws {
        let model = try await makeModel()
        model.open(try importedLayout(deformable: true))
        try await waitUntil { model.grid?.nx == 8 }
        let opening = Box(min: SIMD3(1, 1, 0), max: SIMD3(1.5, 1.5, 1))
        model.settings.scenario.structure?.openings = [opening]
        model.settings.resolution = .fine
        model.settingsChanged()
        try await waitUntil { model.errorMessage?.contains("Could not resample") == true }
        #expect(model.settings.scenario.structure?.openings == [opening])
        #expect(!model.isPreparingImports)
        model.run()
        #expect(!model.isRunning)
        let imported = try #require(model.settings.scenario.importedModels?.first)
        model.detachImport(id: imported.id)
        try await waitUntil { model.grid?.cellSize == 0.125 && model.errorMessage == nil }
        #expect(model.settings.scenario.structure?.openings == [opening])
        #expect(model.settings.scenario.importedModels?.first?.source == imported.source)
    }

    @Test("Clicking an imported occupied volume selects it and opens the shared inspector")
    func importedViewportSelection() async throws {
        let model = try await makeModel()
        model.open(try importedLayout())
        try await waitUntil { model.grid?.nx == 8 }
        let imported = try #require(model.settings.scenario.importedModels?.first)
        let originalCharge = model.settings.chargePosition
        model.camera = OrbitCamera(
            target: SIMD3(1.5, 1.5, 0.5), distance: 5, azimuth: -.pi / 2, elevation: 0.2)
        model.click(ndc: .zero, aspectRatio: 1)
        #expect(model.selection == .imported(imported.id))
        #expect(model.inspectedImportID == imported.id)
        #expect(model.highlightedBox == imported.preview.boxes.first)
        #expect(model.settings.chargePosition == originalCharge)
        model.inspectedImportID = nil
        model.selection = nil
        model.isPlacingCharge = true
        model.click(ndc: .zero, aspectRatio: 1)
        #expect(model.inspectedImportID == nil)
        #expect(model.settings.chargePosition != originalCharge)
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

        // 20 ms of simulation at 25x slow motion should take about half a second: never less, and
        // not much more, though other suites running at once on the main actor can delay it.
        #expect(seconds > 0.45 && seconds < 2.0, "took \(seconds) s")
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
        // A batch already on the GPU still lands; after that, time stands still.
        try await Task.sleep(for: .milliseconds(50))
        let paused = model.time
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.time == paused)
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
        try await waitUntil {
            model.experimentIsReady && model.structureSummary != nil && model.traces.count == 3
        }
        #expect(model.structureSummary?.erodedElements == 0)
        #expect(model.structureSubsteps > 0)

        model.speed = .unlimited
        model.duration = 0.06
        model.run()
        // 7 s on an M4 Max, 20 s on the CI mini's M4, and longer when other tests share the GPU.
        try await waitUntil(timeout: .seconds(120)) { !model.isRunning && model.time > 0.05 }
        let summary = try #require(model.structureSummary)
        #expect(model.errorMessage == nil)
        #expect(!summary.hasBlownUp)
        #expect(summary.erodedElements > 0, "500 kg at 6 m should shear the wall off its base")
        // The deflection history runs to the end of the run and agrees with the summary.
        let last = try #require(model.structureHistory.last)
        #expect(abs(last.time - model.time * 1000) < 1e-6)
        #expect(abs(last.deflection - Double(summary.maxDisplacement) * 1000) < 1e-6)
        #expect(model.peakDeflection >= last.deflection)
        #expect(
            zip(model.structureHistory, model.structureHistory.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(summary.maxDisplacement > 0.1)

        // Changing the material rebuilds an undamaged structure.
        model.settings.material = .masonry
        model.settingsChanged()
        try await waitUntil { model.time == 0 && model.structureSummary?.erodedElements == 0 }
        #expect(model.structureHistory.isEmpty)
        // Scenarios without a structure report none.
        model.select(.openGround)
        model.settingsChanged()
        try await waitUntil { model.structureSummary == nil }
    }

    @Test("A structure can be meshed with shells and back")
    func shellStructure() async throws {
        let model = try await makeModel()
        model.select(.concreteBox)
        model.settings.elementKind = .shell
        model.settingsChanged()
        try await waitUntil { model.structureSummary != nil && model.time == 0 }
        #expect(model.errorMessage == nil)
        #expect(model.settings.scenario.structure?.elementSize == 0.25)
        let shells = try #require(model.structureSummary)
        #expect(shells.activeElements > 1000 && shells.activeElements < 10_000)

        model.speed = .unlimited
        model.duration = 0.02
        model.run()
        try await waitUntil { !model.isRunning && model.time > 0.015 }
        #expect(model.errorMessage == nil)
        #expect((model.structureSummary?.maxDisplacement ?? 0) > 0)

        model.settings.elementKind = .solid
        model.settingsChanged()
        try await waitUntil { model.time == 0 && (model.structureSummary?.activeElements ?? 0) > 100_000 }
        #expect(model.settings.scenario.structure?.elementSize == 0.0625)
        // A frame's columns become beams.
        model.select(.frame)
        model.settings.elementKind = .shell
        model.settingsChanged()
        try await waitUntil { model.time == 0 && model.structureSummary != nil }
        #expect(model.errorMessage == nil)
        // A block as long as it is wide is neither a wall nor a column: the editor reports why.
        model.settings.scenario.structure?.solids.append(Box(x: 18...19, y: 15...16, height: 1))
        model.settingsChanged()
        try await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage?.contains("column") == true)
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
        #expect(model.selection == .block(model.settings.scenario.fixedObjects[0].id))
        #expect(model.highlightedBox == model.settings.scenario.boxes[0])
        model.addWall()
        model.addOpening()
        #expect(model.selection == model.componentSelection(.opening, at: 0))
        let structure = try #require(model.settings.scenario.structure)
        #expect(structure.solids.count == 1 && structure.openings.count == 1)
        #expect(structure.reinforcement.count == 2, "a wall gets a mat in each face")
        model.settingsChanged()
        try await waitUntil { model.structureSummary != nil }
        let elements = try #require(model.structureSummary).activeElements
        // 4 m by 3 m by 250 mm less a 1 m cube's worth of wall, in 62.5 mm elements.
        #expect(elements == (64 * 48 - 16 * 16) * 4)

        // The wall's reinforcement can be set by hand, and survives saving and opening.
        model.setReinforcement(.mats(areaPerMetre: 1000e-6, depth: 0.05, bothFaces: false), ofSolid: 0)
        let custom = try #require(model.settings.scenario.structure)
        #expect(custom.reinforcement.count == 1)
        let reopened = try JSONDecoder().decode(
            Scenario.self, from: ScenarioDocument.encode(model.settings.scenario))
        #expect(reopened.structure?.reinforcement(of: 0) == custom.reinforcement(of: 0))
        model.setReinforcement(.none, ofSolid: 0)
        #expect(model.settings.scenario.structure?.reinforcement.isEmpty == true)

        // A second wall in masonry makes a structure of two materials, which rebuilds.
        model.addWall()
        model.setMaterial(.masonry, ofSolid: 1)
        #expect(
            model.settings.scenario.structure?.materials.map(\.name) == ["Reinforced concrete", "Masonry"])
        model.settingsChanged()
        try await waitUntil { model.structureSummary != nil && model.errorMessage == nil && model.time == 0 }
        model.removeSolid(at: 1)

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

    @Test("Fragment changes settle into steps to undo, alongside layout edits")
    func undoFragments() async throws {
        let model = try await makeModel()
        #expect(!model.canUndo)

        // Turning fragments on, then dragging the casing's mass, settles into two steps.
        model.fragmentSpec = FragmentSection.defaultSpec(for: model.settings.scenario)
        try await waitUntil { model.undoStack.count == 1 }
        for mass in [20, 30, 40] as [Float] { model.fragmentSpec?.casingMass = mass }
        try await waitUntil { model.undoStack.count == 2 }
        model.settings.chargeMass = 50
        model.settingsChanged()
        try await waitUntil { model.undoStack.count == 3 }

        model.undo()
        #expect(model.settings.chargeMass != 50 && model.fragmentSpec?.casingMass == 40)
        model.undo()
        #expect(model.fragmentSpec?.casingMass == 10)
        model.undo()
        #expect(model.fragmentSpec == nil && !model.canUndo)
        // Undoing is not itself an edit to record.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.redoStack.count == 3)
        model.redo()
        model.redo()
        #expect(model.fragmentSpec?.casingMass == 40)
        model.redo()
        #expect(model.settings.chargeMass == 50 && !model.canRedo)
    }

    @Test("Undo and redo step through settled layout edits")
    func undoRedo() async throws {
        let model = try await makeModel()
        let original = model.settings.scenario
        #expect(!model.canUndo && !model.canRedo)

        // Several changes in quick succession settle into one edit.
        model.settings.chargeMass = 10
        model.settings.chargeMass = 20
        model.settings.chargeMass = 30
        model.settingsChanged()
        try await waitUntil { model.undoStack.count == 1 }
        model.addBlock()
        model.settingsChanged()
        try await waitUntil { model.undoStack.count == 2 }
        let withBlock = model.settings.scenario

        model.undo()
        #expect(model.settings.scenario.boxes.count == original.boxes.count)
        #expect(model.settings.chargeMass == 30)
        #expect(model.selection == nil, "the selected block no longer exists")
        model.undo()
        #expect(model.settings.scenario == original)
        #expect(!model.canUndo && model.canRedo)
        model.redo()
        model.redo()
        #expect(model.settings.scenario == withBlock)
        #expect(!model.canRedo)

        // An edit that has not yet settled is undone too, and a new edit clears the redo list.
        model.undo()
        model.settings.chargeMass = 99
        model.undo()
        #expect(model.settings.chargeMass == 30)
        #expect(model.canRedo)
        model.settings.chargeMass = 5
        model.settingsChanged()
        try await waitUntil { !model.canRedo }
        // The undone layouts were rebuilt, not just shown.
        try await waitUntil { model.time == 0 && model.grid != nil }
        #expect(model.errorMessage == nil)
    }

    @Test("Gauges can be added, moved by clicking, renamed and removed")
    func editingGauges() async throws {
        let model = try await makeModel()
        model.select(.openGround)
        let count = model.settings.scenario.gauges.count
        model.addGauge()
        #expect(model.settings.scenario.gauges.count == count + 1)
        #expect(model.selection == .gauge(count))
        let gauge = model.settings.scenario.gauges[count]
        #expect(model.highlightedBox?.size == SIMD3(repeating: 0.5))
        #expect(model.highlightedBox.map { ($0.min + $0.max) / 2 } == gauge.position)

        // With the gauge selected, placing mode moves the gauge and leaves the charge alone.
        let charge = model.settings.chargePosition
        model.isPlacingCharge = true
        model.click(ndc: SIMD2(0.3, -0.2), aspectRatio: 1.5)
        let moved = model.settings.scenario.gauges[count].position
        #expect(model.settings.chargePosition == charge)
        #expect(moved.x != gauge.position.x || moved.y != gauge.position.y)
        #expect(moved.z == gauge.position.z, "height is kept")

        model.settings.scenario.gauges[count].name = "Doorway"
        model.settingsChanged()
        try await waitUntil { model.traces.last?.name == "Doorway" && model.traces.count == count + 1 }

        model.removeGauge(at: count)
        #expect(model.settings.scenario.gauges.count == count && model.selection == nil)
        // The solver records at most sixteen.
        for _ in 0..<20 { model.addGauge() }
        #expect(model.settings.scenario.gauges.count == 16 && !model.canAddGauge)
    }

    @Test("Results export as one row per gauge sample and deflection sample")
    func exportCSV() async throws {
        let model = try await makeModel()
        model.select(.blastWall)
        model.settingsChanged()
        try await waitUntil {
            model.experimentIsReady && model.structureSummary != nil && model.traces.count == 3
        }
        model.speed = .unlimited
        model.duration = 0.02
        model.run()
        try await waitUntil { !model.isRunning && model.time > 0.019 }

        let lines = model.resultsCSV().split(separator: "\n").map(String.init)
        #expect(lines.first == "series,time (ms),value,unit")
        let rows = lines.dropFirst().map(Self.fields)
        #expect(rows.allSatisfy { $0.count == 4 })
        let names = model.settings.scenario.gauges.map(\.name)
        for name in names {
            let samples = rows.filter { $0[0] == name }
            // Every step is recorded (with the moment of detonation), not just the points the
            // chart shows, and in order.
            #expect(abs(samples.count - model.stepCount) <= 1, "\(name): \(samples.count) rows")
            let times = samples.compactMap { Double($0[1]) }
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
            #expect(samples.allSatisfy { $0[3] == "kPa" })
            let peak = samples.compactMap { Double($0[2]) }.max() ?? 0
            let trace = try #require(model.traces.first { $0.name == name })
            #expect(abs(peak - trace.peak) < 0.01, "\(name): \(peak) vs \(trace.peak) kPa")
        }
        let deflection = rows.filter { $0[0] == "Largest deflection" }
        #expect(deflection.count == model.structureHistory.count && !deflection.isEmpty)
        #expect(deflection.allSatisfy { $0[3] == "mm" })
    }

    /// Splits one CSV row into fields, honouring double-quoted fields.
    private static func fields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var previous: Character?
        for character in line {
            if character == "\"" {
                if quoted, previous == "\"" { current.append("\"") }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        fields.append(current)
        return fields
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
