import BlastCore
import BlastRender
import Foundation
import ImageIO
import Testing
import simd

@testable import BombCAD

/// The guide's picture of a district run near the charge and judged far (docs/hybrid-far-field.md):
/// Beirut at 0.5 kt through File ▸ New District on 4 m cells, handing over at 12 m/kg^(1/3)
/// (950 m), drawn once the far field is judged. Only with `BOMBCAD_HYBRID_IMAGE` (the PNG to write)
/// and `BOMBCAD_HYBRID_INPUTS` (the folder holding Beirut's OSM/, DEM/ and GHSL/ files, as
/// docs/beirut-2020.md fetches them); in an optimised build, as the far field judges 14,000
/// buildings.
@MainActor
@Suite("Hybrid district image", .serialized)
struct HybridDistrictImageTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(
        "Draw Beirut run to the hand-over and judged beyond on the far field",
        .enabled(
            if: environment["BOMBCAD_HYBRID_IMAGE"] != nil && environment["BOMBCAD_HYBRID_INPUTS"] != nil))
    func beirut() async throws {
        let output = URL(filePath: try #require(Self.environment["BOMBCAD_HYBRID_IMAGE"]))
        let inputs = URL(
            filePath: try #require(Self.environment["BOMBCAD_HYBRID_INPUTS"]), directoryHint: .isDirectory)
        let district = NewDistrictModel()
        try district.readMap(inputs.appending(path: "OSM/beirut-port-buildings.osm"))
        try district.readTerrain(inputs.appending(path: "DEM/Copernicus_DSM_COG_10_N33_00_E035_00_DEM.tif"))
        try district.readHeights(
            inputs.appending(path: "GHSL/GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R6_C22.tif"))
        district.longitude = "35.519042"
        district.latitude = "33.901425"
        district.yieldValue = 0.5
        district.yieldUnit = .kilotonnes
        district.ground = .saturated
        district.radius = 2_500
        district.nearAndFar = true
        district.cellSize = 4
        let laid = ContinuousClock.now
        await district.lay()
        let preview = try #require(district.preview, "\(district.message ?? "")")
        let far = try #require(preview.far)
        print(
            "Laid out in \(laid.duration(to: .now)): \(preview.report.placed.count) buildings in the air, "
                + "\(far.buildings.count) beyond \(far.handoverM) m")

        let model = SimulationModel(document: preview.document, playbackSpeed: .unlimited)
        model.farFieldUncertainty.samples = 16
        while !model.experimentIsReady {
            try #require(model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        let ran = ContinuousClock.now
        model.run()
        while model.isRunning || model.hasPendingGPUWork || model.judgingFarField
            || model.farFieldDamage.isEmpty
        {
            try #require(model.errorMessage == nil)
            try #require(
                !model.farFieldStatus.hasPrefix("The far field could not"), "\(model.farFieldStatus)")
            try await Task.sleep(for: .milliseconds(200))
        }
        print("Ran and judged in \(ran.duration(to: .now)): \(model.farFieldStatus)")
        model.showsEnvelopeDamage = true

        // The whole district from the south-west, the air's square in the middle of it.
        let size = preview.scenario.domainSize
        let camera = OrbitCamera(
            target: SIMD3(size.x / 2, size.y / 2, 0), distance: 6_500, azimuth: -2.2, elevation: 0.62)
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        let image = try #require(
            renderer.snapshot(commandQueue: queue, width: 1600, height: 1000, camera: camera)?.image)
        let destination = try #require(
            CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
