import AppKit
import BlastCore
import Foundation
import SwiftUI
import Testing

@testable import BombCAD

/// Terrain in a project: saved with the scene, refused by readers that would drop it.
@Suite("Terrain projects")
struct TerrainProjectTests {
    private func hilly() -> Scenario {
        var scene = ScenarioPreset.openGround.scenario
        let domain = scene.domainSize
        scene.replaceTerrain(
            with: .hill(
                domain: domain, spacing: 1, centre: SIMD2(0.7 * domain.x, domain.y / 2), height: 6,
                radius: 0.12 * domain.x))
        return scene
    }

    @Test("A scene with terrain saves as version eight and reopens with it; older versions are refused")
    func package() throws {
        let scene = hilly()
        let archive = try ProjectDocument(scenario: scene).makeArchive()
        let payload = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self, from: archive.files["scene.json"]!)
        #expect(payload.encodingVersion == 8)
        #expect(try ProjectDocument(archive: archive).scenario == scene)
        var old = archive
        var json = try #require(
            try JSONSerialization.jsonObject(with: old.files["scene.json"]!) as? [String: Any])
        json["encodingVersion"] = 3
        old.files["scene.json"] = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: old) }
        // Flat ground keeps the encoding it had.
        let flat = try ProjectDocument(scenario: ScenarioPreset.openGround.scenario).makeArchive()
        let flatPayload = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self, from: flat.files["scene.json"]!)
        #expect(flatPayload.encodingVersion == 3)
    }

    @Test("Laying a terrain carries the charge and gauges with the ground under them")
    func carried() {
        let flat = ScenarioPreset.openGround.scenario
        let scene = hilly()
        let terrain = scene.terrain!
        #expect(
            abs(scene.charge.position.z - flat.charge.position.z - terrain.height(at: flat.charge.position))
                < 1e-5)
        for (a, b) in zip(flat.gauges, scene.gauges) {
            #expect(abs(b.position.z - a.position.z - terrain.height(at: a.position)) < 1e-5)
        }
        var back = scene
        back.replaceTerrain(with: nil)
        #expect(back.terrain == nil)
        #expect(abs(back.charge.position.z - flat.charge.position.z) < 1e-5)
    }

    @MainActor
    @Test(
        "Render the window with a terrain for layout review",
        .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
    func review() throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = ProjectDocument(scenario: hilly())
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        let host = NSHostingView(
            rootView: ContentView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appending(path: "terrain.png"))
    }
}
