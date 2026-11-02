import Foundation
import Testing
import simd

@testable import BlastModel

/// The explorer's scenes, words, reach, comparisons and captions (emmettl/bombcad-work#114;
/// docs/explorer.md).
@Suite("The explorer")
struct ExplorerTests {
    /// Each footprint in metres east and north of the square's middle: its south-west and
    /// north-east corners.
    static func footprints(_ buildings: [MapBuilding]) -> [(low: SIMD2<Double>, high: SIMD2<Double>)] {
        buildings.map { building in
            let points = (building.rings.first ?? []).map { $0 * ElevationGrid.metresPerDegree }
            return (points.reduce(points[0], simd_min), points.reduce(points[0], simd_max))
        }
    }

    @Test("The square is the same every time, with its office, terrace and shops")
    func square() {
        let buildings = ExplorerScene.square.buildings()
        #expect(buildings == ExplorerScene.square.buildings())
        #expect(buildings.count == 398)
        #expect(buildings.filter { $0.name == "The glass office" }.count == 1)
        #expect(buildings.contains { $0.name == "The brick terrace" && $0.material == "brick" })
        #expect(buildings.contains { $0.kind == "retail" })
        // Every footprint within the radius, none in the square itself.
        for print in Self.footprints(buildings) {
            #expect(simd_length((print.low + print.high) / 2) < Double(ExplorerScene.square.radiusM))
            #expect(!(print.low.x < 35 && print.high.x > -35 && print.low.y < 35 && print.high.y > -35))
        }
    }

    @Test("Each named place is on open ground within the scene", arguments: [ExplorerScene.square, .street])
    func places(scene: ExplorerScene) {
        let prints = Self.footprints(scene.buildings())
        for place in scene.places {
            let p = SIMD2<Double>(Double(place.offset.x), Double(place.offset.y))
            let inside = prints.contains {
                p.x > $0.low.x - 1 && p.x < $0.high.x + 1 && p.y > $0.low.y - 1 && p.y < $0.high.y + 1
            }
            #expect(!inside, "\(place.name) lies in a building")
            #expect(simd_length(p) < 200)
        }
        #expect(scene.behindABuilding == scene.places[3])
    }

    @Test("The street is the same every time: shops and flats, a bank, terraces behind back lanes")
    func street() {
        let buildings = ExplorerScene.street.buildings()
        #expect(buildings == ExplorerScene.street.buildings())
        #expect(buildings.count > 300 && buildings.count < 900, "\(buildings.count)")
        #expect(buildings.filter { $0.name == "The bank" }.count == 1)
        #expect(buildings.contains { $0.kind == "terrace" && $0.material == "brick" })
        #expect(buildings.contains { $0.kind == "retail" })
        // Nothing in the high street, the back lanes or the side streets.
        for print in Self.footprints(buildings) {
            #expect(!(print.low.y < 9 && print.high.y > -9))
            #expect(!(print.low.y < 29 && print.high.y > 23) && !(print.low.y < -23 && print.high.y > -29))
            for side in [60.0, -150] { #expect(!(print.low.x < side + 5 && print.high.x > side - 5)) }
        }
        #expect(ExplorerScene.street.behindABuilding?.name == "In the back lane behind the shops")
    }

    @Test("Beirut's port is downloaded, not built in, and opens with its factual line")
    func beirut() {
        #expect(!ExplorerScene.beirut.isBuiltIn && ExplorerScene.beirut.buildings().isEmpty)
        #expect(ExplorerScene.beirut.behindABuilding == nil)
        #expect(ExplorerScene.beirut.opening?.contains("218 people died") == true)
        #expect(ExplorerScene.square.opening == nil)
        #expect(throws: ExplorerDistrict.Failure.missing) { try ExplorerScene.beirut.district() }
        #expect(ExplorerScene.Beirut.Release.asset.sha256.count == 64)
        #expect(
            ExplorerScene.Beirut.Release.asset.url.absoluteString.hasSuffix(
                "explorer-beirut-1/\(ExplorerScene.Beirut.fileName)"))
    }

    @Test("A downloaded district reads back as its buildings and ground, heights resolved")
    func district() throws {
        let square = ExplorerScene.square.buildings()
        var untagged = square[0]
        untagged.height = nil
        let buildings = [untagged] + square[1...]
        // A height grid of 7 m everywhere, and a ground of 1 km each way on 30 m cells.
        let heights = ElevationGrid(
            columns: 4, rows: 4, southWest: SIMD2(-0.01, -0.01), step: SIMD2(0.01, 0.01), units: .degrees,
            elevations: Array(repeating: 7, count: 16))
        let step = 30 / ElevationGrid.metresPerDegree
        let ground = ElevationGrid(
            columns: 67, rows: 67, southWest: SIMD2(-33 * step, -33 * step), step: SIMD2(step, step),
            units: .degrees, elevations: (0..<67 * 67).map { Float($0 % 67) })
        var placement = MapBuildingPlacement(origin: .zero, resolution: 1)
        placement.heightGrid = heights
        let district = ExplorerDistrict(
            name: "Test", attributions: ["made up"], charge: .zero, radiusM: 300, buildings: buildings,
            placement: placement, ground: ground, cropM: 400)
        let url = FileManager.default.temporaryDirectory.appending(path: "explorer-district-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try district.encoded().write(to: url)
        #expect(try district.encoded() == district.encoded())
        let read = try ExplorerDistrict(contentsOf: url)
        #expect(read == district)
        let back = read.mapBuildings()
        #expect(back.count == buildings.count)
        #expect(back[0].height == 7)
        #expect(
            zip(back.dropFirst(), buildings.dropFirst()).allSatisfy {
                $0.height == $1.height && $0.rings == $1.rings
            })
        // The ground cropped to 400 m each way: about 27 cells of 30 m across, and its values kept.
        let grid = try #require(read.groundGrid())
        #expect(grid.columns >= 27 && grid.columns <= 29 && grid.rows == grid.columns)
        #expect(grid.elevations[0] == Float(Int(((grid.southWest.x - ground.southWest.x) / step).rounded())))
    }

    @Test("The view's shader draws the explorer's warm grey")
    func shaderGrey() throws {
        let shader = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/BlastRender/Shaders/Render.metal"),
            encoding: .utf8)
        let c = ExplorerColours.sameColour
        let text = String(format: "float3(%.3ff, %.3ff, %.3ff)", c.x, c.y, c.z)
        #expect(shader.contains("code == \(ExplorerColours.same)") && shader.contains(text))
    }

    @Test("Written as a map, it reads back as the same buildings")
    func osm() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "explorer-square-\(UUID()).osm")
        defer { try? FileManager.default.removeItem(at: url) }
        try ExplorerScene.square.osm().write(to: url, atomically: true, encoding: .utf8)
        let read = try MapBuilding.read(contentsOf: url)
        let made = ExplorerScene.square.buildings()
        #expect(read.count == made.count)
        for (a, b) in zip(read, made) {
            #expect(a.kind == b.kind && a.material == b.material && a.name == b.name)
            #expect(abs((a.height ?? 0) - (b.height ?? 0)) < 0.051)
            for (p, q) in zip(a.rings[0], b.rings[0]) {
                #expect(simd_length(p - q) * ElevationGrid.metresPerDegree < 1e-3)
            }
        }
    }

    @Test("Each layer's words lead with its standing, and take their figures from the table")
    func words() {
        for layer in ExplorerWords.Layer.allCases {
            #expect(ExplorerWords.howSure(layer).hasPrefix(ExplorerWords.standing(layer.level)))
            #expect(!ExplorerWords.what(layer).isEmpty)
            #expect(ExplorerWords.legend(layer).count >= 2)
        }
        #expect(ExplorerWords.Layer.glass.level == .approximation)
        // The refined wave: 96% and 70% within ×1.25; the plain wave 91% and 68%.
        #expect(
            ExplorerWords.howSure(.wave).contains("19 places in 20 in the open and 7 places in 10 behind"))
        #expect(ExplorerWords.howSure(.wave, refinedWave: false).contains("9 places in 10 in the open"))
        // The quick estimate's glass, 68–89% of sides.
        #expect(ExplorerWords.howSure(.glass).contains("7 to 9 building sides in 10"))
        // Its walls: concrete 29–51%, stone 45–56%.
        #expect(ExplorerWords.howSure(.walls).contains("only a quarter to three fifths"))
        #expect(ExplorerWords.howSure(.people).contains("never how many"))
        #expect(
            ExplorerWords.steps.map(ExplorerWords.massText) == ["50 kg", "500 kg", "5 tonnes", "500 tonnes"])
        #expect(ExplorerWords.massSpoken(500) == "500 kilograms")
        #expect(ExplorerWords.distanceText(183) == "180 m")
        #expect(ExplorerWords.distanceText(1_240) == "1.2 km")
    }

    /// Sides along a line from the charge, every 2 m to 400 m, their chances falling through a half
    /// at `some` and `blown` m.
    static func sides(some: Double, blown: Double, owners: [UUID]? = nil) -> [FacadeLoadSurrogate.SideGlass] {
        stride(from: 2.0, through: 400, by: 2).enumerated().map { n, d in
            func falling(_ at: Double) -> Double { 1 / (1 + exp((d - at) / (0.1 * at))) }
            return FacadeLoadSurrogate.SideGlass(
                owner: owners?[n] ?? UUID(), axis: 0, outward: 1, distanceM: d, someBroken: falling(some),
                blownOut: falling(blown), fractionBroken: falling(some), thrownPast3b: 0)
        }
    }

    @Test("How far the windows break, and how much further for twice the charge")
    func reach() throws {
        let reach = ExplorerReach(sides: Self.sides(some: 100, blown: 40))
        let windows = try #require(reach.windowsBreakM)
        let blown = try #require(reach.blownInM)
        #expect(windows > 95 && windows < 115)
        #expect(blown > 36 && blown < 48)
        #expect(!reach.beyondScene)
        #expect(reach.sentence.hasPrefix("Windows break out to about"))
        let twice = ExplorerReach(sides: Self.sides(some: 126, blown: 50))
        let line = ExplorerReach.scaled(from: reach, to: twice, ratio: 2)
        #expect(line.contains("a quarter further, not twice as far"))
        #expect(line.contains("about 1.26 times as far"))
        // Windows breaking across the scene: the windows blown in say how much further instead.
        let wide = ExplorerReach(sides: Self.sides(some: 2_000, blown: 95))
        let wider = ExplorerReach(sides: Self.sides(some: 2_000, blown: 120))
        let across = ExplorerReach.scaled(from: wide, to: wider, ratio: 2)
        #expect(
            across.hasPrefix("Windows break right across the scene; they are now blown in out to about"),
            "\(across)")
        #expect(across.contains("a quarter further, not twice as far"), "\(across)")
        #expect(ExplorerWords.steps.map(ExplorerWords.stepText) == ["50 kg", "500 kg", "5 t", "500 t"])
        // None breaks, and every one breaks.
        #expect(ExplorerReach(sides: Self.sides(some: 0.5, blown: 0.5)).windowsBreakM == nil)
        #expect(ExplorerReach(sides: Self.sides(some: 2_000, blown: 10)).beyondScene)
    }

    @Test("Pinned and compared: better, the same or worse, building by building")
    func compare() {
        let owners = (0..<200).map { _ in UUID() }
        let pinned = ExplorerSnapshot(
            sides: Self.sides(some: 100, blown: 40, owners: owners), structure: [], charge: .zero, massKg: 500
        )
        let filmed = ExplorerSnapshot(
            sides: Self.sides(some: 100, blown: 10, owners: owners), structure: [], charge: .zero, massKg: 500
        )
        let change = pinned.change(to: filmed, measure: .glass)
        #expect(change.worse == 0 && change.better > 10 && change.better + change.same == 200)
        #expect(change.codes.values.allSatisfy { $0 == ExplorerColours.better || $0 == ExplorerColours.same })
        #expect(change.sentence.hasPrefix("Against the pinned picture, windows fare better at"))
        #expect(
            pinned.change(to: pinned, measure: .glass).sentence
                == "Against the pinned picture, nothing much changes.")
        // Film: the same panes broken, less glass thrown into the rooms.
        var held = Self.sides(some: 100, blown: 40, owners: owners)
        let thrown = held.map { side in
            var side = side
            side.thrownPast3b = side.blownOut
            return side
        }
        for n in held.indices { held[n].thrownPast3b = 0.1 * thrown[n].thrownPast3b }
        let before = ExplorerSnapshot(sides: thrown, structure: [], charge: .zero, massKg: 500)
        let after = ExplorerSnapshot(sides: held, structure: [], charge: .zero, massKg: 500)
        #expect(before.change(to: after, measure: .glass).sentence.hasSuffix("nothing much changes."))
        let flies = before.change(to: after, measure: .thrown)
        #expect(flies.better > 10 && flies.worse == 0)
        #expect(flies.sentence.contains("less broken glass flies into the rooms at"))
        let people = OccupantInjury.Comparison(
            hurt: -0.38, low: -0.4, high: -0.36, severe: -0.4, sameBuildings: true)
        #expect(explorerPeopleChange(people) == "About 38% fewer people hurt than before.")
    }

    @Test("The wave's captions follow its own times on the square")
    func captions() throws {
        let scene = ExplorerScene.square
        var layout = DistrictLayout(
            buildings: scene.buildings(), charge: scene.charge, mass: scene.defaultMassKg)
        layout.keepsOutlines = true
        let cell = try #require(scene.cellSizeM)
        let half = layout.halfSide(radius: scene.radiusM, cellSize: cell)
        let (made, report) = try layout.scene(halfSide: half, cellSize: cell, radius: scene.radiusM)
        #expect(report.placed.count == 398)
        let plan = LiveWave.Plan(scene: made, cell: LiveWave.Plan.cellSize(for: made))
        let field = LiveWave.field(
            plan: plan, charge: made.charge.position, mass: Double(scene.defaultMassKg))
        let captions = ExplorerWords.captions(field)
        #expect(captions.count == 4)
        #expect(captions.first?.time == 0)
        #expect(captions.last?.time == Double(field.lastArrival))
        #expect(captions.map(\.time) == captions.map(\.time).sorted())
        #expect(captions.contains { $0.text.contains("a shadow") })
        #expect(ExplorerWords.caption(captions, at: 0)?.text.hasPrefix("The charge goes off") == true)
        #expect(
            ExplorerWords.caption(captions, at: Double(field.lastArrival))?.text.contains("crossed") == true)
    }
}
