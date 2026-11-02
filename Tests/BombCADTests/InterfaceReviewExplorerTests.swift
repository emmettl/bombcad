import AppKit
import BlastCore
import BlastRender
import SwiftUI
import Testing

@testable import BombCAD

/// The explorer (emmettl/bombcad-work#114; docs/explorer.md), captured offscreen for a look by eye and
/// timed: its scenes, its sidebar at each layer in light and dark, the view as the wave plays and with
/// the glass, the film's comparison and the fire, then a drag in 2 m steps across the square. Only with
/// `BOMBCAD_INTERFACE_REVIEW` (the folder to write). The times it prints are this build's: an optimised
/// one (`swift test -c release -Xswiftc -enable-testing`) is the app's. With `BOMBCAD_LIVE_WAVE_MODEL`
/// the wave is refined.
@MainActor
@Suite(
    "The explorer, offscreen", .serialized, .hangLimit,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
struct InterfaceReviewExplorerTests {
    private func folder(_ name: String) throws -> URL {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "explorer/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The view as the model has it now, written as `name`; the frame's GPU time.
    @discardableResult
    private func view(_ model: SimulationModel, camera: OrbitCamera, to name: String?) throws -> Double {
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        var settings = model.renderSettings
        settings.showCharge = true
        settings.chargeAt = model.settings.chargePosition
        settings.liveWave =
            model.drawsLiveWave && !model.explorerHidesLiveWave
            ? LiveWaveDisplay(time: Float(model.liveWaveTime)) : nil
        renderer.settings = settings
        renderer.setLiveWave(model.liveWave)
        renderer.setLines(model.explorerLines)
        model.applyEnvelopeDamageColours()
        renderer.pixelsPerPoint = 2
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 1800, height: 1200, camera: camera))
        if let name {
            let rep = NSBitmapImageRep(cgImage: frame.image)
            try #require(rep.representation(using: .png, properties: [:])).write(
                to: try folder("view").appending(path: "\(name).png"))
        }
        return frame.gpuSeconds
    }

    /// The view written to `stage3/name.png` under the review folder.
    private func stage3(_ model: SimulationModel, camera: OrbitCamera, _ name: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "stage3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        var settings = model.renderSettings
        settings.showCharge = true
        settings.chargeAt = model.settings.chargePosition
        settings.liveWave =
            model.drawsLiveWave && !model.explorerHidesLiveWave
            ? LiveWaveDisplay(time: Float(model.liveWaveTime)) : nil
        renderer.settings = settings
        renderer.setLiveWave(model.liveWave)
        renderer.setLines(model.explorerLines)
        model.applyEnvelopeDamageColours()
        renderer.pixelsPerPoint = 2
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 1800, height: 1200, camera: camera))
        let rep = NSBitmapImageRep(cgImage: frame.image)
        try #require(rep.representation(using: .png, properties: [:])).write(
            to: folder.appending(path: "\(name).png"))
    }

    private func stage3Sidebar(_ explorer: ExplorerModel, _ name: String, height: CGFloat = 1500) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "stage3")
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try InterfaceSnapshotTests().snapshot(
                ExplorerSidebar(explorer: explorer, showWorkbench: {}).frame(width: 340),
                size: CGSize(width: 340, height: height), appearance: appearance,
                to: folder.appending(path: "\(name)-\(style).png"))
        }
    }

    private func camera(_ model: SimulationModel, share: Float = 0.55) -> OrbitCamera {
        let charge = model.settings.chargePosition
        let size = model.settings.scenario.domainSize
        return OrbitCamera(
            target: SIMD3(charge.x, charge.y, 0), distance: share * max(size.x, size.y), azimuth: -1.9,
            elevation: 0.95)
    }

    @Test("Capture stage 3: the four fixes on the square, the street, and Beirut's opening")
    func stage3() async throws {
        let model = SimulationModel(document: ProjectDocument.newProject())
        try await settle(model)
        model.liveWaveLearned = ProcessInfo.processInfo.environment[LiveWave.Refinement.environmentKey] != nil
        let explorer = ExplorerModel(model: model)
        explorer.reduceMotion = true

        // The square: the wave with no ball of hot gas, the marker; the charge's section; behind the
        // terrace in the warm grey, the wave not drawn over it, and the ring.
        await explorer.open(.square)
        try await settle(model)
        model.scrubLiveWave(to: 0.35 * model.liveWaveEnd)
        try stage3(model, camera: camera(model), "fix2-square-wave-035")
        try stage3(model, camera: camera(model, share: 0.12), "fix2-square-marker-close")
        try stage3Sidebar(explorer, "fix1-sidebar")
        explorer.run(.behindABuilding)
        try await settle(model)
        try stage3(model, camera: camera(model), "fix3-behind-change")
        try stage3Sidebar(explorer, "fix3-behind-sidebar")
        explorer.putBack()
        try await settle(model)
        explorer.unpin()
        explorer.run(.twiceTheCharge)
        try await settle(model)
        explorer.showsChange = false
        try stage3(model, camera: camera(model), "ring-twice-the-charge")
        print("Twice: \(explorer.comparison ?? "")")
        explorer.close()

        // The street.
        var clock = ContinuousClock.now
        await explorer.open(.street)
        try await settle(model)
        print("Opened the street in \(clock.duration(to: .now)): \(model.envelopeDamageStatus)")
        model.scrubLiveWave(to: 0.35 * model.liveWaveEnd)
        try stage3(model, camera: camera(model), "street-wave-035")
        explorer.layer = .glass
        try await settle(model)
        try stage3(model, camera: camera(model), "street-glass")
        try stage3Sidebar(explorer, "street-sidebar")
        print("Street: \(explorer.finding ?? "")")
        explorer.run(.behindABuilding)
        try await settle(model)
        try stage3(model, camera: camera(model), "street-behind-change")
        print("Street behind: \(explorer.comparison ?? "")")
        explorer.close()

        // Beirut, from its file (`BOMBCAD_EXPLORER_BEIRUT`), when given.
        guard ProcessInfo.processInfo.environment["BOMBCAD_EXPLORER_BEIRUT"] != nil else { return }
        clock = .now
        await explorer.open(.beirut)
        try await settle(model)
        #expect(explorer.problem == nil, "\(explorer.problem ?? "")")
        print(
            "Opened Beirut in \(clock.duration(to: .now)): \(model.settings.scenario.envelopeObjects.count) "
                + "buildings, \(model.settings.resolution.cellSize) m cells; \(model.envelopeDamageStatus)")
        print("Beirut's wave: \(model.liveWaveStatus)")
        try stage3Sidebar(explorer, "beirut-opening", height: 1600)
        model.scrubLiveWave(to: 0.35 * model.liveWaveEnd)
        try stage3(model, camera: camera(model, share: 0.5), "beirut-wave-035")
        explorer.layer = .glass
        try await settle(model)
        try stage3(model, camera: camera(model, share: 0.5), "beirut-glass")
        print("Beirut: \(explorer.finding ?? "")")
        // A drag on Beirut: the preview and the wave, 5 m steps along the quay.
        explorer.layer = .wave
        try await settle(model)
        model.isDraggingCharge = true
        model.estimateFollowsCharge = true
        var looks: [Double] = []
        var waves: [Double] = []
        var moved = model.settings.chargePosition
        for _ in 0..<20 {
            moved.x += 5
            clock = .now
            model.settings.chargePosition = moved
            model.requestLook(preview: true)
            while model.lookInFlight || model.lookWaiting != nil {
                try await Task.sleep(for: .milliseconds(1))
            }
            looks.append(clock.duration(to: .now) / .seconds(1))
            while model.liveWaveInFlight || model.liveWaveShownFor?.charge != moved {
                try await Task.sleep(for: .milliseconds(1))
            }
            waves.append(clock.duration(to: .now) / .seconds(1))
        }
        model.isDraggingCharge = false
        looks.sort()
        waves.sort()
        print(
            String(
                format: "Beirut drag: preview %.0f ms median (%.0f–%.0f), wave %.0f ms median (%.0f–%.0f)",
                1000 * looks[10], 1000 * looks[0], 1000 * looks[19], 1000 * waves[10], 1000 * waves[0],
                1000 * waves[19]))
        explorer.close()
    }

    private func settle(_ model: SimulationModel) async throws {
        while model.estimatingEnvelopeDamage || model.isLoadingInputs || model.liveWaveInFlight
            || model.envelopeEstimateIsPreview || model.fireTask != nil
        {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sidebar(_ explorer: ExplorerModel, _ name: String) throws {
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try InterfaceSnapshotTests().snapshot(
                ExplorerSidebar(explorer: explorer, showWorkbench: {}).frame(width: 340),
                size: CGSize(width: 340, height: 1500), appearance: appearance,
                to: try folder(style).appending(path: "sidebar-\(name).png"))
        }
    }

    @Test("Capture the explorer on the square, and time it")
    func square() async throws {
        let model = SimulationModel(document: ProjectDocument.newProject())
        try await settle(model)
        model.liveWaveLearned = ProcessInfo.processInfo.environment[LiveWave.Refinement.environmentKey] != nil
        let explorer = ExplorerModel(model: model)
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try InterfaceSnapshotTests().snapshot(
                ExplorerScenes(explorer: explorer), size: CGSize(width: 620, height: 420),
                appearance: appearance,
                to: try folder(style).appending(path: "scenes.png"))
        }
        var clock = ContinuousClock.now
        explorer.reduceMotion = true
        await explorer.open(.square)
        try await settle(model)
        print(
            "Opened the square, its estimate and wave in \(clock.duration(to: .now)): \(model.envelopeDamageStatus)"
        )
        print("Wave: \(model.liveWaveStatus)")
        let charge = model.settings.chargePosition
        let size = model.settings.scenario.domainSize
        let camera = OrbitCamera(
            target: SIMD3(charge.x, charge.y, 0), distance: 0.55 * max(size.x, size.y), azimuth: -1.9,
            elevation: 0.95)

        // The wave as it plays, then each layer.
        for share in [0.15, 0.35, 1.0] {
            model.scrubLiveWave(to: share * model.liveWaveEnd)
            try view(model, camera: camera, to: String(format: "wave-%03.0f", 100 * share))
            print(String(format: "At %.0f%%: ", 100 * share) + (explorer.caption ?? "no caption"))
        }
        try sidebar(explorer, "wave")
        for layer in [ExplorerWords.Layer.glass, .walls, .people, .fire] {
            explorer.layer = layer
            try await settle(model)
            try view(model, camera: camera, to: layer.rawValue)
            try sidebar(explorer, layer.rawValue)
            print("\(layer.title): \(explorer.finding ?? "")")
        }

        // Glass with film against the picture pinned, and behind the terrace.
        explorer.layer = .glass
        explorer.run(.glassWithFilm)
        try await settle(model)
        try view(model, camera: camera, to: "film-change")
        try sidebar(explorer, "film")
        print("Film: \(explorer.comparison ?? "")")
        explorer.putBack()
        try await settle(model)
        explorer.run(.twiceTheCharge)
        try await settle(model)
        print("Twice: \(explorer.comparison ?? "")")
        explorer.run(.behindABuilding)
        try await settle(model)
        try view(model, camera: camera, to: "behind-change")
        explorer.showsChange = false
        model.scrubLiveWave(to: 0.35 * model.liveWaveEnd)
        try view(model, camera: camera, to: "behind-wave-035")
        print("Behind: \(explorer.comparison ?? "")")
        explorer.putBack()
        explorer.unpin()
        try await settle(model)

        // The frame's GPU time with the glass coloured and the wave drawn.
        explorer.layer = .glass
        var frames: [Double] = []
        for k in 0..<30 {
            model.scrubLiveWave(to: Double(k) / 30 * model.liveWaveEnd)
            frames.append(try view(model, camera: camera, to: nil))
        }
        frames.sort()
        print(
            String(
                format: "GPU frame at 1800 × 1200: %.1f ms median (%.1f–%.1f)", 1000 * frames[15],
                1000 * frames[0],
                1000 * frames[29]))

        // A drag in 2 m steps across the square, the glass's preview and the wave following, for each layer's colouring.
        for layer in [ExplorerWords.Layer.glass, .walls, .fire] {
            explorer.layer = layer
            try await settle(model)
            model.isDraggingCharge = true
            model.estimateFollowsCharge = true
            var looks: [Double] = []
            var waves: [Double] = []
            var moved = model.settings.chargePosition
            for _ in 0..<20 {
                moved.x += 2
                clock = .now
                model.settings.chargePosition = moved
                model.requestLook(preview: true)
                while model.lookInFlight || model.lookWaiting != nil {
                    try await Task.sleep(for: .milliseconds(1))
                }
                looks.append(clock.duration(to: .now) / .seconds(1))
                while model.liveWaveInFlight || model.liveWaveShownFor?.charge != moved {
                    try await Task.sleep(for: .milliseconds(1))
                }
                waves.append(clock.duration(to: .now) / .seconds(1))
            }
            model.isDraggingCharge = false
            looks.sort()
            waves.sort()
            print(
                String(
                    format:
                        "Drag, %@: preview placed to shown %.0f ms median (%.0f–%.0f), wave %.0f ms median (%.0f–%.0f); ",
                    layer.title, 1000 * looks[10], 1000 * looks[0], 1000 * looks[19], 1000 * waves[10],
                    1000 * waves[0], 1000 * waves[19]) + model.envelopeDamageStatus)
            model.placeCharge(at: charge)
            try await settle(model)
        }
    }
}
