import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Building exposure inspection", .serialized, .hangLimit)
struct EnvelopeInspectionTests {
    func document() throws -> ProjectDocument {
        var scene = Scenario(
            name: "Exposure inspection", domainSize: SIMD3(12, 10, 6), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(2, 4, 1)),
            gauges: [Gauge("Near", at: SIMD3(3, 4, 1))])
        for x: Float in [4, 8] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [
                    Box(min: SIMD3(x, 2, 0), max: SIMD3(x + 1, 6, 4))
                ]), name: x == 4 ? "North, \"building\"" : "South")
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.008
        return document
    }

    func wait(_ condition: () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Live summaries and kept records match full surface data; reset clears stale results")
    func live() async throws {
        let model = SimulationModel(document: try document(), playbackSpeed: .unlimited)
        try await wait { model.experimentIsReady }
        #expect(model.envelopeExposure.count == 2 && !model.canExportEnvelopeExposure)
        model.run()
        try await wait { !model.isRunning && !model.hasPendingGPUWork }
        #expect(model.canKeepRun && model.canExportEnvelopeExposure)
        let snapshots = try JSONDecoder().decode(
            [EnvelopeExposureSnapshot].self,
            from: model.envelopeResultsData())
        #expect(snapshots.count == model.envelopeExposure.count)
        #expect(model.envelopeExposure[0].peakPositivePa > 0)
        for (snapshot, summary) in zip(snapshots, model.envelopeExposure) {
            let faces = snapshot.surfaces
            let area = faces.reduce(0.0) { $0 + Double($1.areaM2) }
            let positive = faces.reduce(0.0) { $0 + Double($1.areaM2) * Double($1.positiveImpulsePaS) }
            #expect(summary.id == snapshot.id && summary.name == snapshot.name)
            #expect(summary.elapsedS == snapshot.elapsedS && summary.faceCount == faces.count)
            #expect(summary.areaM2 == area && summary.validAreaM2 == area && summary.invalidFaceCount == 0)
            #expect(abs(summary.surfacePositiveImpulseNS - positive) < 1e-8)
            #expect(abs((summary.meanPositiveImpulsePaS ?? 0) - positive / area) < 1e-8)
            #expect(summary.peakPositivePa == faces.map(\.peakPositivePa).max())
            for axis in 0..<3 {
                #expect(abs(summary.forceN[axis] - snapshot.forceN[axis]) < 1e-6)
                #expect(abs(summary.signedImpulseNS[axis] - snapshot.signedImpulseNS[axis]) < 1e-8)
            }
        }
        try model.keepRun(named: "Envelope result")
        let saved = try #require(model.savedRuns.last)
        #expect(saved.envelopeExposure == model.envelopeExposure)
        let archive = try ProjectDocument(model: model).makeArchive()
        #expect(
            try ProjectDocument(archive: archive).savedRuns.last?.envelopeExposure == saved.envelopeExposure)
        let path = "results/runs/\(saved.id.uuidString.lowercased()).json"
        let json = try #require(
            try JSONSerialization.jsonObject(with: archive.files[path]!) as? [String: Any])
        #expect(json["encodingVersion"] as? Int == 3)
        #expect(saved.csv().contains("summed positive surface loading"))
        #expect(saved.csv().contains("North, \"\"building\"\""))
        var bad = saved
        bad.envelopeExposure?[0].id = UUID()
        #expect(throws: ProjectFileError.self) { try bad.validate() }
        bad = saved
        bad.envelopeExposure?[0].signedImpulseNS.x = .nan
        #expect(throws: ProjectFileError.self) { try bad.validate() }
        bad = saved
        bad.envelopeExposure?[0].areaM2 *= 2
        #expect(throws: ProjectFileError.self) { try bad.validate() }
        model.reset()
        try await wait { model.experimentIsReady }
        #expect(
            !model.canExportEnvelopeExposure
                && model.envelopeExposure.allSatisfy { $0.elapsedS == 0 && $0.surfacePositiveImpulseNS == 0 })
    }

    @Test("Mixed scenes record their envelopes' surfaces beside the moving structures")
    func mixed() async throws {
        var scene = try StreetInteractionStudy.make(.pair)
        try scene.useEnvelope(id: scene.structuralObjects[0].id)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        try await wait { model.experimentIsReady }
        #expect(model.errorMessage == nil && model.envelopeExposureStatus.isEmpty)
        #expect(model.envelopeExposure.map(\.id) == scene.envelopeObjects.map(\.id))
    }

    @Test("A building with no face on the air (buried in a hill) is kept with none and the run saves")
    func buried() async throws {
        var scene = Scenario(
            name: "Buried", domainSize: SIMD3(20, 10, 16), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(2, 5, 1)))
        scene.terrain = .hill(
            domain: scene.domainSize, spacing: 0.5, centre: SIMD2(16, 5), height: 12, radius: 4)
        for (x, name) in [(Float(5), "Open"), (15.5, "Buried")] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 4, 0), max: SIMD3(x + 1, 6, 4))]), name: name)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        let folder = FileManager.default.temporaryDirectory.appending(path: "envelope-buried-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "input.bombcad")
        try document.makeArchive().fileWrapper().write(to: input, originalContentsURL: nil)
        let output = folder.appending(path: "output.bombcad")
        let result = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([input.path, "--out", output.path]))
        let exposure = try #require(result.run.envelopeExposure)
        #expect(exposure.map(\.faceCount).sorted().first == 0 && exposure.contains { $0.faceCount > 0 })
        #expect(try ProjectDocument.read(from: output).savedRuns.last?.envelopeExposure == exposure)
    }

    @Test("Headless export keeps summaries in a project and writes complete face records")
    func headless() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "envelope-inspection-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "input.bombcad")
        let output = folder.appending(path: "output.bombcad")
        let surfaces = folder.appending(path: "surfaces.json")
        let histories = folder.appending(path: "histories.json")
        let damage = folder.appending(path: "damage.json")
        try document().makeArchive().fileWrapper().write(to: input, originalContentsURL: nil)
        let options = try HeadlessRun.Options.parse([
            input.path, "--out", output.path,
            "--envelope-results", surfaces.path, "--envelope-histories", histories.path,
            "--envelope-damage", damage.path,
        ])
        let result = try await HeadlessRun.execute(options)
        // Each building is a wall 4 m tall that nothing holds: two panels, both sides binned at
        // 0.1 ms over the 8 ms run.
        let components = try JSONDecoder().decode(
            [EnvelopeComponentHistory].self, from: Data(contentsOf: histories))
        #expect(
            components.count == 4 && components.allSatisfy { $0.component.kind == .wall && !$0.truncated })
        #expect(components.allSatisfy { (80...81).contains($0.outerImpulsePaS.count) })
        #expect(components.contains { $0.peakOuterPa > 0 })
        // Each building judged one way from those histories, on the assumed construction.
        let judged = try JSONDecoder().decode([EnvelopeBuildingDamage].self, from: Data(contentsOf: damage))
        #expect(
            judged.count == 2
                && judged.allSatisfy { $0.components.count == 2 && $0.construction.source == .assumed })
        #expect(result.streams.filter { $0.contains("reinforced concrete, assumed") }.count == 2)
        let raw = try JSONDecoder().decode([EnvelopeExposureSnapshot].self, from: Data(contentsOf: surfaces))
        #expect(raw.count == 2 && raw.allSatisfy { abs($0.elapsedS - 0.008) < 1e-6 && !$0.surfaces.isEmpty })
        #expect(result.run.envelopeExposure?.count == 2)
        #expect(
            try ProjectDocument.read(from: output).savedRuns.last?.envelopeExposure
                == result.run.envelopeExposure)
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse([input.path, "--envelope-results", surfaces.path])
        }
        // A window from arrival: each history starts where the blast reached it (500 Pa); one it
        // has not reached keeps no bins.
        let later = folder.appending(path: "from-arrival.json")
        let windowed = try HeadlessRun.Options.parse([
            input.path, "--envelope-histories", later.path, "--envelope-window", "0.004",
        ])
        #expect(windowed.envelopeWindow == 0.004)
        _ = try await HeadlessRun.execute(windowed)
        let arrived = try JSONDecoder().decode(
            [EnvelopeComponentHistory].self, from: Data(contentsOf: later))
        #expect(arrived.count == 4 && arrived.contains { $0.windowStartS != nil })
        #expect(arrived.allSatisfy { $0.windowStartS != nil || $0.outerImpulsePaS.isEmpty })
        #expect(arrived.allSatisfy { $0.outerImpulsePaS.count <= 41 })
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse([
                input.path, "--envelope-histories", histories.path, "--envelope-window", "0",
            ])
        }
        var air = try document()
        air.scenario = ScenarioPreset.openGround.scenario
        await #expect(throws: ProjectFileError.self) { try await HeadlessRun.perform(air, options: options) }
    }
}
