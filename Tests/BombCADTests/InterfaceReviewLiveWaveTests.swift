import AppKit
import BlastCore
import BlastRender
import SwiftUI
import Testing

@testable import BombCAD

/// The live blast wave (emmettl/bombcad-work#112 item 2; docs/live-wave.md), captured offscreen for a
/// look by eye and timed: its bar in light and dark, and the view at a few times as the front sweeps
/// the district, then with the charge dragged. On Beirut's district (File ▸ New District within
/// 2.5 km at 0.5 kt) with `BOMBCAD_HYBRID_INPUTS` (the folder holding Beirut's OSM/, DEM/ and GHSL/
/// files), else on the made-up New District fixture. Only with `BOMBCAD_INTERFACE_REVIEW` (the folder
/// to write). The times it prints are this build's: an optimised one
/// (`swift test -c release -Xswiftc -enable-testing`) is the app's. With `BOMBCAD_LIVE_WAVE_MODEL`
/// (the learned refinement's weights, emmettl/bombcad-work#115) the wave is refined as well.
@MainActor
@Suite(
    "The live blast wave, offscreen", .serialized, .hangLimit,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
struct InterfaceReviewLiveWaveTests {
    private func folder(_ name: String) throws -> URL {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "live-wave/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The view at the wave's time, written as `name`, and the frame's GPU time.
    @discardableResult
    private func view(_ model: SimulationModel, camera: OrbitCamera, to name: String?) throws -> Double {
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        var settings = model.renderSettings
        settings.showCharge = true
        settings.chargeAt = model.settings.chargePosition
        settings.liveWave = model.drawsLiveWave ? LiveWaveDisplay(time: Float(model.liveWaveTime)) : nil
        renderer.settings = settings
        renderer.setLiveWave(model.liveWave)
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

    private func waitForWave(_ model: SimulationModel, charge: SIMD3<Float>) async throws {
        while model.liveWave == nil || model.liveWaveInFlight || model.liveWaveShownFor?.charge != charge {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Render the live blast wave over a district, and time it")
    func liveWave() async throws {
        let district: NewDistrictModel
        let name: String
        if let path = ProcessInfo.processInfo.environment["BOMBCAD_HYBRID_INPUTS"] {
            let inputs = URL(filePath: path, directoryHint: .isDirectory)
            district = NewDistrictModel()
            try district.readMap(inputs.appending(path: "OSM/beirut-port-buildings.osm"))
            try district.readTerrain(
                inputs.appending(path: "DEM/Copernicus_DSM_COG_10_N33_00_E035_00_DEM.tif"))
            try district.readHeights(
                inputs.appending(path: "GHSL/GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R6_C22.tif"))
            district.longitude = "35.519042"
            district.latitude = "33.901425"
            district.yieldValue = 0.5
            district.yieldUnit = .kilotonnes
            district.ground = .saturated
            district.radius = 2_500
            district.nearAndFar = false
            name = "beirut"
        } else {
            district = try NewDistrictTests().model()
            name = "made-up"
        }
        await district.lay()
        let preview = try #require(district.preview, "\(district.message ?? "")")
        let model = SimulationModel(document: preview.document)
        model.refinesCloseCalls = false
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        let learned = ProcessInfo.processInfo.environment[LiveWave.Refinement.environmentKey] != nil
        model.liveWaveLearned = learned
        if learned { print("With the learned refinement from \(model.liveWaveLearnedWeightsURL.path)") }
        let size = model.settings.scenario.domainSize
        print("\(name): \(preview.report.placed.count) buildings on \(size.x) × \(size.y) m")

        var clock = ContinuousClock.now
        model.liveWaveShown = true
        let charge = model.settings.chargePosition
        try await waitForWave(model, charge: charge)
        let field = try #require(model.liveWave)
        print(
            "Shown in \(clock.duration(to: .now)): \(field.columns) × \(field.rows) on \(field.cell) m, "
                + String(
                    format: "%.0f ms the field; last arrival %.2f s. ", 1000 * field.seconds,
                    field.lastArrival)
                + model.liveWaveStatus)

        // The bar, light and dark.
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try InterfaceSnapshotTests().snapshot(
                LiveWaveControls(model: model).frame(width: 1100), size: CGSize(width: 1100, height: 44),
                appearance: appearance, to: try folder(style).appending(path: "\(name)-bar.png"))
        }

        let centre = SIMD3(charge.x, charge.y, 0)
        let reach = max(size.x, size.y)
        let camera = OrbitCamera(target: centre, distance: 0.75 * reach, azimuth: -1.9, elevation: 1.1)
        let end = model.liveWaveEnd
        for share in [0.05, 0.15, 0.35, 0.7, 1.0] {
            model.scrubLiveWave(to: share * end)
            try view(model, camera: camera, to: String(format: "\(name)-%03.0f", 100 * share))
        }
        model.scrubLiveWave(to: 0.15 * end)
        let near = OrbitCamera(target: centre, distance: 0.3 * reach, azimuth: -1.9, elevation: 0.9)
        try view(model, camera: near, to: "\(name)-near-015")

        // The frame's GPU time with the wave and without it.
        var with: [Double] = []
        var without: [Double] = []
        for k in 0..<30 {
            model.scrubLiveWave(to: Double(k) / 30 * end)
            with.append(try view(model, camera: camera, to: nil))
        }
        model.liveWaveShown = false
        for _ in 0..<30 { without.append(try view(model, camera: camera, to: nil)) }
        with.sort()
        without.sort()
        print(
            String(
                format:
                    "GPU frame at 1800 × 1200: %.1f ms with the wave (%.1f–%.1f), %.1f ms without (%.1f–%.1f)",
                1000 * with[15], 1000 * with[0], 1000 * with[29], 1000 * without[15], 1000 * without[0],
                1000 * without[29]))

        // A drag: the charge moved 5 m at a time, as the pointer would, each place worked out.
        model.liveWaveShown = true
        try await waitForWave(model, charge: charge)
        model.isDraggingCharge = true
        var times: [Double] = []
        var rounds: [Double] = []
        var refinements: [Double] = []
        var moved = charge
        for _ in 0..<20 {
            moved.x += 5
            clock = .now
            model.settings.chargePosition = moved
            try await waitForWave(model, charge: moved)
            rounds.append(clock.duration(to: .now) / .seconds(1))
            times.append(model.liveWave?.seconds ?? .nan)
            refinements.append(model.liveWave?.refinementSeconds ?? .nan)
        }
        let dragCell = model.liveWave?.cell ?? 0
        model.scrubLiveWave(to: 0.15 * end)
        try view(model, camera: camera, to: "\(name)-dragged-100m-015")
        model.isDraggingCharge = false
        clock = .now
        while model.liveWaveShownFor?.coarse != false || model.liveWaveInFlight {
            try await Task.sleep(for: .milliseconds(5))
        }
        let letGo = clock.duration(to: .now)
        times.sort()
        rounds.sort()
        refinements.sort()
        if learned {
            print(
                String(
                    format:
                        "The learned refinement while dragging: %.0f ms median (%.0f–%.0f) of the field's time",
                    1000 * refinements[10], 1000 * refinements[0], 1000 * refinements[19]))
            print("Let go: " + model.liveWaveStatus)
        }
        print(
            String(
                format:
                    "Drag on %.0f m cells: the field %.0f ms median (%.0f–%.0f), placed to shown %.0f ms median (%.0f–%.0f); ",
                dragCell, 1000 * times[10], 1000 * times[0], 1000 * times[19], 1000 * rounds[10],
                1000 * rounds[0],
                1000 * rounds[19]) + "let go, the fine cells again in \(letGo)")
        model.scrubLiveWave(to: 0.15 * end)
        try view(model, camera: camera, to: "\(name)-let-go-015")
        model.liveWaveShown = false
    }
}
