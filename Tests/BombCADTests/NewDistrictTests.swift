import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

/// File ▸ New District on the made-up district (Fixtures/SyntheticDistrict).
@MainActor
@Suite("New district", .serialized)
struct NewDistrictTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/SyntheticDistrict")

    /// The fixture's map, heights and ground read; 1 t of TNT at the grid's centre block, its
    /// neighbours within 250 m, on a Mac that lets the air take `memory`.
    func model(memory: Int = 8 << 30) throws -> NewDistrictModel {
        let model = NewDistrictModel()
        try model.readMap(Self.folder.appending(path: "district.osm"))
        try model.readHeights(Self.folder.appending(path: "heights.asc"))
        try model.readTerrain(Self.folder.appending(path: "ground.asc"))
        model.terrainIsSurface = false
        let east = ElevationGrid.metresPerDegree
        model.longitude = String(format: "%.7f", 612 / east)
        model.latitude = String(format: "%.7f", 608 / east)
        model.yieldValue = 1
        model.yieldUnit = .tonnes
        model.ground = .saturated
        model.radius = 250
        model.memory = memory
        // The whole district in the air unless a test asks for a far field.
        model.nearAndFar = false
        return model
    }

    @Test("Reading the map places the charge at its centre and the radius inside it")
    func reads() throws {
        let model = NewDistrictModel()
        try model.readMap(Self.folder.appending(path: "district.osm"))
        let charge = try #require(model.charge)
        let bounds = try #require(model.mapBounds)
        #expect(simd_length(charge - (bounds.low + bounds.high) / 2) < 1e-6)
        #expect(model.radius >= 50 && model.radius <= 450)
        #expect(throws: (any Error).self) { try model.readMap(Self.folder.appending(path: "heights.asc")) }
    }

    @Test("Lays the district out on the finest uniform cells this Mac holds and prices it before creating")
    func lays() async throws {
        let model = try model()
        model.airChoice = .uniform
        #expect(model.preview == nil)
        await model.lay()
        let preview = try #require(model.preview, "\(model.message ?? "")")
        let layout = try #require(model.layout)
        #expect(preview.within == layout.buildings(within: 250).count)
        // All but the centre block, which holds the charge.
        #expect(preview.report.placed.count == preview.within - 1)
        // The advisor's cells: they fit, and the next finer do not.
        #expect(
            preview.cellSize
                == NewDistrictModel.advisedCell(
                    layout, radius: 250, clearFaces: true, ground: .saturated, memory: model.memory))
        #expect(preview.cost.memory + preview.historyBudget <= model.memory)
        if let finer = NewDistrictModel.cellSizes.last(where: { $0 < preview.cellSize }) {
            #expect(
                !NewDistrictModel.fits(
                    layout, radius: 250, clearFaces: true, air: DistrictAir(cellSize: finer, refined: false),
                    ground: .saturated, memory: model.memory))
        }
        // The run as the district wants it: uniform cells, the ground, long enough for the farthest.
        let run = try #require(preview.document.runSettings)
        #expect(run.resolution == Resolution(cellSize: preview.cellSize)!.rawValue)
        #expect(!run.sharpShocks && run.shockLevels == nil)
        #expect(run.terrainCutCells == true)
        #expect(run.ground == .saturated)
        #expect(run.duration == DistrictLayout.duration(radius: 250))
        // The side faces 4 m/kg^(1/3) (40 m) beyond the buildings.
        #expect(preview.scenario.domainSize.x >= 2 * (250 + 40))
        #expect(preview.scenario.terrain != nil)
    }

    @Test(
        "Refined air: a base refined once where the shock is, under the roofs' ceiling, against the uniform cells"
    )
    func refined() async throws {
        let model = try model()
        model.airChoice = .refined
        await model.lay()
        let preview = try #require(model.preview, "\(model.message ?? "")")
        #expect(preview.air.refined && preview.air.finest == preview.air.cellSize / 2)
        let run = try #require(preview.document.runSettings)
        #expect(run.resolution == Resolution(cellSize: preview.air.cellSize)!.rawValue)
        #expect(run.sharpShocks && run.shockLevels == nil && run.shockThreshold == 0.005)
        // The ceiling: all but the tallest 2% of the buildings (tagged up to 32 m here) and four
        // base cells over them.
        let layout = try #require(model.layout)
        let ceiling = try #require(run.refinementCeiling)
        #expect(ceiling == layout.refinementCeiling(radius: 250, cellSize: preview.air.cellSize))
        #expect(ceiling > 6 + 4 * preview.air.cellSize && ceiling <= 32 + 4 * preview.air.cellSize)
        // The footprints on the finest cells.
        #expect(
            preview.scenario.envelopeSources?.allSatisfy {
                $0.detail.hasSuffix("cells of \(preview.air.finest) m")
            } == true)
        // On a staircase of whole cells until the finest level's cut cells stop ringing.
        #expect(run.terrainCutCells == nil)
        #expect(preview.cost.memory + preview.historyBudget <= model.memory)
        #expect(preview.cost.refinementMemory > 0)
        // The uniform cells it is set against, on the same layout.
        let other = try #require(preview.alternative)
        #expect(!other.air.refined)
        // It reopens refined.
        let restored = try ProjectDocument(fileWrapper: preview.document.makeArchive().fileWrapper())
        #expect(restored.runSettings == run)
    }

    @Test("The advisor takes refined air where it is finer at the façades and no dearer, else uniform cells")
    func advised() async throws {
        for memory in [2 << 30, 8 << 30, 32 << 30] {
            let model = try model(memory: memory)
            await model.lay()
            let preview = try #require(model.preview, "\(model.message ?? "")")
            let layout = try #require(model.layout)
            func first(_ refined: Bool) -> DistrictAir? {
                NewDistrictModel.cellSizes.filter { !refined || $0 >= 2 }.map {
                    DistrictAir(cellSize: $0, refined: refined)
                }.first {
                    NewDistrictModel.fits(
                        layout, radius: 250, clearFaces: true, air: $0, ground: .saturated, memory: memory)
                }
            }
            let (uniform, refined) = (first(false), first(true))
            let prefers = NewDistrictModel.prefersRefined(
                layout, radius: 250, clearFaces: true, uniform: uniform, refined: refined, ground: .saturated,
                memory: memory)
            // The kind the rule takes, on its finest cells that fit, or coarser where the laid-out
            // ground and roofs raise the top past the memory.
            let expected = try #require(prefers ? refined : uniform)
            #expect(preview.air.refined == expected.refined, "\(memory >> 30) GB")
            #expect(preview.air.cellSize >= expected.cellSize, "\(memory >> 30) GB")
            #expect(preview.cost.memory + preview.historyBudget <= memory)
            if prefers, let uniform, let refined {
                #expect(refined.finest < uniform.finest)
                func seconds(_ air: DistrictAir) -> Double {
                    NewDistrictModel.price(
                        layout, radius: 250, clearFaces: true, air: air, ground: .saturated, memory: memory
                    ).cost.seconds
                }
                #expect(seconds(refined) <= seconds(uniform))
            }
        }
    }

    @Test("The project it creates saves and reopens as laid out")
    func reopens() async throws {
        let model = try model()
        model.cellSize = 5
        await model.lay()
        let preview = try #require(model.preview, "\(model.message ?? "")")
        #expect(preview.cellSize == 5)
        let restored = try ProjectDocument(fileWrapper: preview.document.makeArchive().fileWrapper())
        #expect(restored.scenario == preview.scenario)
        #expect(restored.runSettings == preview.document.runSettings)
        #expect(restored.scenario.envelopeObjects.count == preview.report.placed.count)
    }

    @Test("Less memory takes coarser cells; too little says so")
    func memory() async throws {
        let roomy = try model(memory: 8 << 30)
        await roomy.lay()
        let tight = try model(memory: 1 << 30)
        await tight.lay()
        let wide = try #require(roomy.preview?.cellSize)
        let narrow = try #require(tight.preview?.cellSize, "\(tight.message ?? "")")
        #expect(narrow >= wide)
        let none = try model(memory: 1 << 10)
        await none.lay()
        #expect(none.preview == nil)
        #expect(none.message?.contains("fit this Mac") == true)
    }

    @Test("Without a map or a charge nothing is laid out")
    func needsInputs() async throws {
        let model = NewDistrictModel()
        #expect(model.layout == nil)
        await model.lay()
        #expect(model.preview == nil && model.message != nil)
        let far = try self.model()
        far.radius = 10
        far.longitude = "0.5"
        await far.lay()
        #expect(far.preview == nil)
        #expect(far.message?.contains("no building") == true)
    }

    @Test("A district's run keeps half a second of each component's load from its arrival")
    func histories() {
        let short = SimulationModel.defaultEnvelopeHistory(duration: 0.4, memory: 8 << 30)
        #expect(short.windowS == 0.4 && !short.windowFromArrival)
        let district = SimulationModel.defaultEnvelopeHistory(duration: 8, memory: 16 << 30)
        #expect(district.windowS == 0.5 && district.windowFromArrival)
        #expect(district.memoryBudget == 2 << 30)
        #expect(SimulationModel.defaultEnvelopeHistory(duration: 8, memory: 64 << 30).memoryBudget == 4 << 30)
    }

    @Test("The map view's clicks land where it draws")
    func mapFrame() {
        let frame = DistrictMapView.Frame(
            centre: SIMD2(35.5, 33.9), pixelsPerMetre: 0.2, size: CGSize(width: 400, height: 240))
        let point = SIMD2(35.505, 33.897)
        let drawn = frame.point(point)
        #expect(simd_length(frame.lonLat(drawn) - point) < 1e-9)
        // North up, east right.
        #expect(drawn.x > 200 && drawn.y > 120)
    }

    @Test(
        "Near field and far field: the air to the hand-over, the rest judged after the run, both kept on saving",
        .hangLimit)
    func nearAndFar() async throws {
        let model = try model()
        model.nearAndFar = true
        model.airChoice = .uniform
        model.cellSize = 5
        // 1 t: the hand-over at 12 m/kg^(1/3), 120 m, to 50 m.
        #expect(model.handover == 100)
        await model.lay()
        let preview = try #require(model.preview, "\(model.message ?? "")")
        let far = try #require(preview.far)
        #expect(far.handoverM == 100 && far.trendReach == FarFieldSet.trendReachDefault)
        #expect(!far.buildings.isEmpty && !preview.scenario.envelopeObjects.isEmpty)
        // The air reaches the hand-over and its faces' clearance, and runs until it is loaded.
        #expect(preview.scenario.domainSize.x == 2 * (100 + 40))
        #expect(preview.document.runSettings?.duration == DistrictLayout.duration(radius: 100))
        let reopened = try ProjectDocument(fileWrapper: preview.document.makeArchive().fileWrapper())
        #expect(reopened.farField == far)
        // Run it: the far buildings judged once the run ends.
        let app = SimulationModel(document: reopened, playbackSpeed: .unlimited)
        // A few draws: a debug build draws the glass's chances slowly.
        app.farFieldUncertainty.samples = 4
        #expect(app.farFieldSet == far)
        while !app.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        app.run()
        while app.isRunning || app.hasPendingGPUWork || app.judgingFarField || app.farFieldDamage.isEmpty {
            try #require(app.errorMessage == nil)
            try #require(!app.farFieldStatus.hasPrefix("The far field could not"), "\(app.farFieldStatus)")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Set(app.farFieldDamage.map(\.id)) == Set(far.buildings.map(\.id)))
        let match = try #require(app.farField)
        #expect(match.peak > 0 && match.peak.isFinite && match.impulse > 0 && match.seedStrips > 0)
        #expect(app.farFieldStatus.hasPrefix("Far field estimate"))
        // The far buildings' glass chances, side by side.
        #expect(!app.farFieldGlass.isEmpty)
        #expect(Set(app.farFieldGlass.map(\.owner)).isSubset(of: Set(far.buildings.map(\.id))))
        #expect(app.farFieldGlass.allSatisfy { (0...1).contains($0.someBroken) })
        // The project written back keeps the far set.
        #expect(ProjectDocument(model: app).farField == far)
    }

    @Test("The advisor hands over only where the whole district would not run on 4 m cells within the hour")
    func advisedHandover() throws {
        let model = try model()
        let layout = try #require(model.layout)
        func advised(_ memory: Int, radius: Float = 450, cellSize: Float? = nil) -> (Float?, String) {
            NewDistrictModel.advisedHandover(
                layout, radius: radius, scaled: 100, clearFaces: true, cellSize: cellSize, ground: .saturated,
                memory: memory)
        }
        // Roomy: the whole district on 4 m cells, and no far field.
        let roomy = advised(32 << 30)
        #expect(roomy.0 == nil && roomy.1.contains("no far field"))
        // Tight, the whole district on cells coarser than 4 m but the air to the hand-over on 4 m: at it.
        func cell(_ radius: Float, _ memory: Int) -> Float {
            NewDistrictModel.advisedCell(
                layout, radius: radius, clearFaces: true, ground: .saturated, memory: memory) ?? .infinity
        }
        let memory = try #require((2...64).map { $0 << 20 }.first { cell(450, $0) > 4 && cell(100, $0) <= 4 })
        #expect(advised(memory).0 == 100)
        // Tighter: brought in by tenths, to half of it and no nearer than 50 m.
        let tighter = try #require(advised(memory / 2).0)
        #expect(tighter >= 50 && tighter <= 100)
        // Cells chosen: the hand-over as asked.
        #expect(advised(32 << 30, cellSize: 4).0 == 100)
    }
}
