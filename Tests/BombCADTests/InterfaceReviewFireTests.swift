import AppKit
import BlastCore
import BlastRender
import SwiftUI
import Testing

@testable import BombCAD

/// Fire after the blast on Beirut's district (emmettl/bombcad-work#38, stage 3; docs/fire-spread.md),
/// captured offscreen for a look by eye: File ▸ New District's buildings within 2.5 km at 0.5 kt
/// (9,708 on the advisor's 6 m cells), the quick estimate's glass, 20 fires at random within 1.5 km in the airport's wind, the
/// section in light and dark and the view by the hour, by the chance of catching from a neighbour (the
/// map's since 31 October 2026) and of catching at all (the earlier map's), with the timber-clad
/// contrast. Only with
/// `BOMBCAD_INTERFACE_REVIEW` (the folder to write) and `BOMBCAD_HYBRID_INPUTS` (the folder holding
/// Beirut's OSM/, DEM/ and GHSL/ files, as docs/beirut-2020.md fetches them). The times it prints are
/// this build's: in an optimised one (`swift test -c release -Xswiftc -enable-testing`), as the quick
/// estimate judges 10,000 buildings.
@MainActor
@Suite(
    "Fire after the blast on Beirut, offscreen", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil
            && ProcessInfo.processInfo.environment["BOMBCAD_HYBRID_INPUTS"] != nil))
struct InterfaceReviewFireTests {
    private static let fireStyles: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    private func fireFolder(_ style: String) throws -> URL {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "fire/\(style)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fireSections<V: View>(_ name: String, @ViewBuilder _ content: () -> V) throws {
        for (style, appearance) in Self.fireStyles {
            try InterfaceSnapshotTests().snapshot(
                Form { content() }.formStyle(.grouped).frame(width: 310),
                size: CGSize(width: 310, height: 400),
                appearance: appearance, to: try fireFolder(style).appending(path: "\(name).png"))
        }
    }

    private func fireView(_ model: SimulationModel, camera: OrbitCamera, to name: String) throws {
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        var settings = model.renderSettings
        settings.showCharge = true
        renderer.settings = settings
        renderer.setLines(model.fireSeedOutlines())
        renderer.pixelsPerPoint = 2
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 1800, height: 1200, camera: camera))
        let rep = NSBitmapImageRep(cgImage: frame.image)
        try #require(rep.representation(using: .png, properties: [:])).write(
            to: try fireFolder("view").appending(path: "\(name).png"))
    }

    @Test("Render the fire after the blast on Beirut's district")
    func fireOnBeirut() async throws {
        let inputs = URL(
            filePath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_HYBRID_INPUTS"]),
            directoryHint: .isDirectory)
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
        district.nearAndFar = false
        var clock = ContinuousClock.now
        await district.lay()
        let preview = try #require(district.preview, "\(district.message ?? "")")
        print(
            "Laid out in \(clock.duration(to: .now)): \(preview.report.placed.count) buildings, \(preview.air.title)"
        )
        // The map's wood and timber tags, read as timber since 31 October 2026.
        let timberPlaced = (preview.document.scenario.envelopeConstructions ?? []).filter {
            $0.walls == .crossLaminatedTimber
        }.count
        let woodTagged = district.map!.buildings.filter {
            $0.material.map { EnvelopeConstruction.mapTimber.contains($0.lowercased()) } ?? false
        }.count
        print("Wood-tagged on the map: \(woodTagged); placed as timber: \(timberPlaced)")

        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let model = SimulationModel(document: preview.document)
        model.learnedDefaults = temporary.defaults
        model.refinesCloseCalls = false
        model.setLearnedPeaks(false, environment: [:])
        func settle() async throws {
            while model.isLoadingInputs || model.estimatingEnvelopeDamage || model.fireTask != nil
                || model.fireProgress != nil
            {
                try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await settle()
        clock = .now
        model.quickEstimate()
        try await settle()
        print("Quick estimate in \(clock.duration(to: .now)): \(model.envelopeDamageStatus)")
        #expect(model.fireSource != nil)
        try fireSections("fire-no-seeds") { FireSection(model: model) }

        // Twenty fires at random within 1.5 km, in the airport's wind at 15Z (240° at 11 kt), as in
        // docs/fire-spread.md's judgement.
        var settings = FireSpread.LayerSettings()
        settings.randomCount = 20
        settings.randomFromM = 0
        settings.randomToM = 1500
        settings.wind = FireSpread.Wind(speedMS: 5.7, fromDegrees: 240)
        clock = .now
        model.fireSettings = settings
        try await settle()
        let full = try #require(model.fireLayer)
        print(
            "Full fire: \(full.members) draws in \(clock.duration(to: .now)) on the main actor's clock, "
                + String(format: "%.2f s in the layer; ", full.seconds) + model.fireStatus)
        #expect(full.ids.count == preview.report.placed.count)
        #expect(!full.preview)

        // A preview's few draws, while the wind's slider is held.
        model.fireAdjusting = true
        clock = .now
        model.fireSettings.wind.fromDegrees = 245
        try await settle()
        let few = try #require(model.fireLayer)
        print(
            "Preview: \(few.members) draws in \(clock.duration(to: .now)), "
                + String(format: "%.2f s", few.seconds))
        try fireSections("fire-preview") { FireSection(model: model) }
        model.fireAdjusting = false
        try await settle()

        model.showsEnvelopeDamage = true
        model.envelopeColouring = .fire
        let centre = SIMD3(model.settings.chargePosition.x, model.settings.chargePosition.y, 0)
        let city = OrbitCamera(target: centre, distance: 4_200, azimuth: -1.9, elevation: 1.05)
        let near = OrbitCamera(target: centre, distance: 2_000, azimuth: -1.9, elevation: 1.15)
        // The buildings whose centres lie within the random fires' 1.5 km, as the draws choose them.
        let band = Set(
            FireSpread.candidates(
                in: FireSpread.buildings(scene: model.settings.scenario),
                from: SIMD2(Double(centre.x), Double(centre.y)), fromM: 0, toM: 1500))
        /// The band's buildings by the map's bands at the hour shown: grey, up to 1%, 1–2.5%,
        /// 2.5%–1/8 and above.
        func bands(_ measure: FireSpread.MapChance) -> [Int] {
            let t = model.fireHour * 3600
            let c = band.map { full.chance($0, at: t, measure: measure) }
            return [
                c.filter { $0 <= 0 }.count, c.filter { $0 > 0 && $0 <= 0.01 }.count,
                c.filter { $0 > 0.01 && $0 <= 0.025 }.count, c.filter { $0 > 0.025 && $0 <= 0.125 }.count,
                c.filter { $0 > 0.125 }.count,
            ]
        }
        for measure in [FireSpread.MapChance.neighbour, .caught] {
            model.fireMapChance = measure
            for hour in [1.0, 3.0, 12.0] {
                model.fireHour = hour
                try fireView(
                    model, camera: near,
                    to: String(
                        format: measure == .neighbour ? "beirut-neighbour-%02.0fh" : "beirut-caught-%02.0fh",
                        hour))
                // Grey where no draw counted has a building caught: most of the city, the ramp for the rest.
                let codes = model.fireCodes()
                let grey = codes.values.filter { $0 == EnvelopeChanceColour.neutral }.count
                let b = bands(measure)
                print(
                    String(
                        format:
                            "%@ by %.0f h: %d of %d buildings grey; within 1.5 km (%d): %d grey, %d up to 1%%, "
                            + "%d 1–2.5%%, %d 2.5%%–1/8, %d above 1/8",
                        measure == .neighbour ? "From a neighbour" : "Caught at all", hour, grey, codes.count,
                        band.count, b[0], b[1], b[2], b[3], b[4]))
                #expect(grey > codes.count / 2 && grey < codes.count)
            }
        }
        model.fireMapChance = .neighbour
        model.fireHour = 2
        try fireSections("fire-beirut") { FireSection(model: model, showsAssumptions: true) }
        model.fireShowsAlight = true
        try fireView(model, camera: near, to: "beirut-alight-02h")
        try fireSections("fire-beirut-alight") { FireSection(model: model) }
        model.fireShowsAlight = false

        // A building picked in the view as well: the selected building's switch, its seed outlined.
        let picked = try #require(
            full.ids.indices.max { full.ensemble.buildings[$0].chance < full.ensemble.buildings[$1].chance })
        model.inspectedEnvelope = full.ids[picked]
        // Before it is picked: its chance from a neighbour, and the draws it was a random fire in.
        try fireSections("fire-inspected") {
            InspectedEnvelopeSection(model: model)
        }
        model.toggleFireSeed(full.ids[picked])
        try await settle()
        try fireSections("fire-selected") {
            InspectedEnvelopeSection(model: model)
        }
        model.inspectedEnvelope = nil

        // Every building timber-clad: the contrast, a conflagration.
        clock = .now
        model.fireSettings.cladding = .combustible
        try await settle()
        let timber = try #require(model.fireLayer)
        print(
            "Timber-clad: \(timber.members) draws in \(clock.duration(to: .now)), "
                + String(
                    format: "%.2f s; caught %.0f (%.0f–%.0f)", timber.seconds, timber.ensemble.caught.y,
                    timber.ensemble.caught.x, timber.ensemble.caught.z))
        model.fireHour = 12
        try fireView(model, camera: city, to: "beirut-timber-neighbour-12h")
        try fireSections("fire-timber") { FireSection(model: model, showsAssumptions: true) }
        #expect(timber.ensemble.caught.y > full.ensemble.caught.y)
    }
}
