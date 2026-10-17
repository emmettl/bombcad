import Foundation
import Testing
import simd

@testable import BlastCore

/// Imported and mapped buildings as stationary envelopes.
@Suite("Envelopes from imports and map data", .timeLimit(.minutes(120)))
struct EnvelopeImportTests {
    /// A box as OBJ text, from its low corner to its high one.
    private func box(_ low: SIMD3<Float>, _ high: SIMD3<Float>) throws -> ImportedMesh {
        var text = ""
        for n in 0..<8 {
            let p = SIMD3(
                n & 1 == 0 ? low.x : high.x, n & 2 == 0 ? low.y : high.y, n & 4 == 0 ? low.z : high.z)
            text += "v \(p.x) \(p.y) \(p.z)\n"
        }
        // Outward faces of the corners numbered by bits (x 1, y 2, z 4), one-based.
        for f in [[1, 3, 4, 2], [5, 6, 8, 7], [1, 2, 6, 5], [3, 7, 8, 4], [1, 5, 7, 3], [2, 4, 8, 6]] {
            text += "f \(f[0]) \(f[1]) \(f[2])\nf \(f[0]) \(f[2]) \(f[3])\n"
        }
        return try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
            .transformed(scale: 1, yUp: false, corner: low)
    }

    private func element(_ n: Int, _ ifcClass: String, _ mesh: ImportedMesh) -> ImportedMesh.BuildingElement {
        .init(
            globalID: String(format: "%022d", n), name: "\(ifcClass) \(n)", ifcClass: ifcClass, storey: nil,
            mesh: mesh)
    }

    /// A 6 m wall 0.5 m thick and 3 m high, with a window 2 m wide in it (the wall's own geometry
    /// solid through it, as if the window filled it), and a slab beside it.
    private func building() throws -> ImportedModel {
        let wall = element(1, "IfcWall", try box(SIMD3(2, 2, 0), SIMD3(8, 2.5, 3)))
        let window = element(2, "IfcWindow", try box(SIMD3(4, 2, 1), SIMD3(6, 2.5, 2)))
        let slab = element(3, "IfcSlab", try box(SIMD3(2, 2.5, 0), SIMD3(8, 6, 0.5)))
        let source = try ImportedMesh(buildingElements: [wall, window, slab])
        let placed = try source.transformed(scale: 1, yUp: false, corner: SIMD3(2, 2, 0))
        let preview = try placed.preview(cellSize: 0.25, domain: SIMD3(12, 10, 6))
        return ImportedModel(
            name: "House", source: source, scale: 1, yUp: false, corner: SIMD3(2, 2, 0), behavior: .rigid,
            preview: preview)
    }

    @Test("An IFC import's windows and doors become openings; its other elements, solids")
    func ifcEnvelope() throws {
        let model = try building()
        let (envelope, report) = try model.buildingEnvelope()
        #expect(report.openingElements == 1 && report.openings == 1)
        #expect(report.solidClasses == ["IfcWall": 1, "IfcSlab": 1])
        // The window's cells are open; the wall beside it and the slab are solid.
        #expect(!envelope.occupies(SIMD3(5, 2.25, 1.5)))
        #expect(envelope.occupies(SIMD3(3, 2.25, 1.5)) && envelope.occupies(SIMD3(5, 2.25, 2.5)))
        #expect(envelope.occupies(SIMD3(5, 4, 0.25)))
        // Everything else is as the rigid import samples it.
        for b in model.preview.boxes {
            let centre = (b.min + b.max) / 2
            let inWindow = all(centre .> SIMD3(4, 2, 1)) && all(centre .< SIMD3(6, 2.5, 2))
            #expect(envelope.occupies(centre) == !inWindow)
        }

        var scene = Scenario(
            name: "Street", domainSize: SIMD3(12, 10, 6), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 8, 0.5)))
        scene.importedModels = [model]
        let reports = try scene.useEnvelopes(importIDs: [model.id])
        #expect(reports == [report])
        #expect(scene.importedModels == nil)
        #expect(scene.envelopeObjects.count == 1 && scene.envelopeObjects[0].name == "House")
        #expect(scene.importNotes?.last?.contains("1 windows and doors as 1 openings") == true)
        #expect(scene.rigidBoxes.count == envelope.blocks.count)
        // A deformable import, or a missing one, is refused and changes nothing.
        var deformable = model
        deformable.behavior = .deformable
        #expect(throws: (any Error).self) { try deformable.buildingEnvelope() }
        let before = scene
        #expect(throws: (any Error).self) { try scene.useEnvelopes(importIDs: [UUID()]) }
        #expect(scene == before)
    }

    @Test("An OBJ import becomes an envelope of its boxes, without openings")
    func objEnvelope() throws {
        let mesh = try box(SIMD3(1, 1, 0), SIMD3(3, 2, 2))
        let model = ImportedModel(
            name: "Shed", source: mesh, scale: 1, yUp: false, corner: SIMD3(1, 1, 0), behavior: .rigid,
            preview: try mesh.preview(cellSize: 0.5, domain: SIMD3(6, 6, 4)))
        let (envelope, report) = try model.buildingEnvelope()
        #expect(report.openings == 0 && envelope.solids == model.preview.boxes)
    }

    // MARK: - Map data

    /// Synthetic, not OpenStreetMap's: a square of 0.001° at (0, 51.5), and buildings in it.
    private static let osm = """
        <?xml version="1.0" encoding="UTF-8"?>
        <osm version="0.6" generator="hand">
          <node id="1" lat="51.5001" lon="0.0001"/><node id="2" lat="51.5001" lon="0.0003"/>
          <node id="3" lat="51.5002" lon="0.0003"/><node id="4" lat="51.5002" lon="0.0001"/>
          <node id="5" lat="51.5004" lon="0.0001"/><node id="6" lat="51.5004" lon="0.0002"/>
          <node id="7" lat="51.5005" lon="0.0002"/><node id="8" lat="51.5005" lon="0.0001"/>
          <node id="11" lat="51.5003" lon="0.0005"/><node id="12" lat="51.5003" lon="0.0008"/>
          <node id="13" lat="51.5006" lon="0.0008"/><node id="14" lat="51.5006" lon="0.0005"/>
          <node id="15" lat="51.50042" lon="0.00062"/><node id="16" lat="51.50042" lon="0.00068"/>
          <node id="17" lat="51.50048" lon="0.00068"/><node id="18" lat="51.50048" lon="0.00062"/>
          <node id="21" lat="51.5008" lon="0.0001"/><node id="22" lat="51.5008" lon="0.0002"/>
          <node id="23" lat="51.5008" lon="0.0003"/>
          <node id="31" lat="51.50085" lon="0.0005"/><node id="32" lat="51.50085" lon="0.000502"/>
          <node id="33" lat="51.500852" lon="0.000502"/>
          <node id="41" lat="51.5011" lon="0.0001"/><node id="42" lat="51.5011" lon="0.0002"/>
          <node id="43" lat="51.5012" lon="0.0002"/>
          <way id="100"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
            <tag k="building" v="house"/><tag k="height" v="12 m"/><tag k="name" v="Corner house"/></way>
          <way id="101"><nd ref="5"/><nd ref="6"/><nd ref="7"/><nd ref="8"/><nd ref="5"/>
            <tag k="building" v="apartments"/><tag k="building:levels" v="4"/><tag k="roof:levels" v="1"/></way>
          <way id="102"><nd ref="11"/><nd ref="12"/><nd ref="13"/><nd ref="14"/><nd ref="11"/></way>
          <way id="103"><nd ref="15"/><nd ref="16"/><nd ref="17"/><nd ref="18"/><nd ref="15"/></way>
          <relation id="200"><member type="way" ref="102" role="outer"/><member type="way" ref="103" role="inner"/>
            <tag k="type" v="multipolygon"/><tag k="building" v="yes"/><tag k="height" v="40 ft"/></relation>
          <way id="104"><nd ref="21"/><nd ref="22"/><nd ref="23"/><nd ref="21"/><tag k="building" v="yes"/></way>
          <way id="105"><nd ref="31"/><nd ref="32"/><nd ref="33"/><nd ref="31"/><tag k="building" v="shed"/></way>
          <way id="106"><nd ref="41"/><nd ref="42"/><tag k="building" v="yes"/></way>
          <way id="107"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
            <tag k="building:part" v="yes"/></way>
          <way id="108"><nd ref="41"/><nd ref="42"/><nd ref="43"/><nd ref="41"/><tag k="building" v="garage"/></way>
        </osm>
        """

    @Test("OSM tags give heights: height in metres or feet, levels with roof levels, or assumed")
    func heights() throws {
        let buildings = try MapBuilding.readOSM(Data(Self.osm.utf8))
        let byID = Dictionary(uniqueKeysWithValues: buildings.map { ($0.id, $0) })
        // Ways 100–108 less the outline and courtyard ways and the building part, plus the relation.
        #expect(
            Set(byID.keys) == [
                "way/100", "way/101", "way/104", "way/105", "way/106", "way/108", "relation/200",
            ])
        let placement = MapBuildingPlacement(origin: SIMD2(0, 51.5), resolution: 0.5)
        #expect(placement.heights(byID["way/100"]!).top == 12)
        #expect(placement.heights(byID["way/100"]!).source == .height)
        #expect(placement.heights(byID["way/101"]!) == (0, 15, .levels))
        #expect(abs(placement.heights(byID["relation/200"]!).top - 12.192) < 1e-4)
        #expect(placement.heights(byID["way/108"]!) == (0, 6, .assumed))
        #expect(byID["relation/200"]!.rings.count == 2)
        // A height grid fills in where the tags say nothing, from the cell under the footprint's
        // centre; tags still win, and a cell without buildings (0) leaves the assumption.
        let centre =
            byID["way/108"]!.rings[0].reduce(SIMD2<Double>.zero, +) / Double(byID["way/108"]!.rings[0].count)
        var gridded = placement
        gridded.heightGrid = ElevationGrid(
            columns: 3, rows: 3, southWest: centre - 0.001, step: SIMD2(0.001, 0.001), units: .degrees,
            elevations: [0, 0, 0, 0, 17.5, 0, 0, 0, 0])
        #expect(gridded.heights(byID["way/108"]!) == (0, 17.5, .grid))
        #expect(gridded.heights(byID["way/101"]!) == (0, 15, .levels))
        gridded.heightGrid?.elevations[4] = 0
        #expect(gridded.heights(byID["way/108"]!) == (0, 6, .assumed))
        for (text, metres) in [
            ("12", 12), ("12.5 m", 12.5), ("12m", 12), ("40 ft", 12.192), ("40'6\"", 12.344), ("9;12", 9),
        ]
            as [(String, Float)]
        {
            #expect(abs(MapBuilding.length(text)! - metres) < 1e-3, "\(text)")
        }
        #expect(MapBuilding.length("tall") == nil)
    }

    @Test("Footprints land where their coordinates put them, courtyards open, degenerate ones left out")
    func placement() throws {
        let buildings = try MapBuilding.readOSM(Data(Self.osm.utf8))
        var scene = Scenario(
            name: "Block", domainSize: SIMD3(70, 150, 40), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(35, 5, 0.5)))
        let placement = MapBuildingPlacement(origin: SIMD2(0, 51.5), resolution: 0.5)
        let report = try scene.addMapBuildings(buildings, placement: placement)
        let reasons = Dictionary(uniqueKeysWithValues: report.skipped.map { ($0.id, $0.reason) })
        #expect(reasons["way/104"] == "a footprint with no area")
        #expect(reasons["way/105"] == "smaller than a cell, or outside the scene")
        #expect(reasons["way/106"] == "fewer than three distinct corners")
        #expect(report.placed.count == 4)
        #expect(report.count(.height) == 2 && report.count(.levels) == 1 && report.count(.assumed) == 1)
        #expect(scene.attributions == [MapBuilding.openStreetMapAttribution])
        // 0.0001° of longitude at 51.5° is 6.92 m, of latitude 11.12 m: the corner house spans
        // x 6.92–20.77 m and y 11.12–22.24 m.
        let east = ElevationGrid.metresPerDegree * cos(51.5 * Double.pi / 180) * 1e-4
        let north = ElevationGrid.metresPerDegree * 1e-4
        let house = try #require(scene.envelopeObjects.first { $0.name == "Corner house" }?.envelope)
        let low = house.solids.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1.min) }
        let high = house.solids.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1.max) }
        #expect(abs(Double(low.x) - east) <= 0.5 && abs(Double(high.x) - 3 * east) <= 0.5)
        #expect(abs(Double(low.y) - north) <= 0.5 && abs(Double(high.y) - 2 * north) <= 0.5)
        #expect(low.z == 0 && high.z == 12)
        // The courtyard of the relation is open; its walls are not.
        let court = try #require(scene.envelopeObjects.first { $0.name.contains("relation/200") }?.envelope)
        let middle = SIMD3<Float>(Float(6.5 * east), Float(4.5 * north), 3)
        #expect(!court.occupies(middle))
        #expect(court.occupies(SIMD3<Float>(Float(5.5 * east), Float(4.5 * north), 3)))
        // Rectangles cover each footprint's cells exactly once.
        for placed in report.placed {
            let envelope = try #require(scene.envelopeObjects.first { $0.id == placed.objectID }?.envelope)
            let area = envelope.solids.reduce(Float(0)) { $0 + $1.size.x * $1.size.y }
            #expect(abs(area - Float(placed.cells) * 0.25) < 1e-3)
        }
    }

    @Test("On a terrain a building stands on the lowest ground under it; overlaps go to the first")
    func terrainAndOverlap() throws {
        let square: [SIMD2<Double>] = [
            SIMD2(10, 10), SIMD2(20, 10), SIMD2(20, 20), SIMD2(10, 20), SIMD2(10, 10),
        ]
        // Coordinates in metres: an origin of (0, 0) and a tiny scale make degrees metres apart.
        let toDegrees = 1 / ElevationGrid.metresPerDegree
        func building(_ id: String, _ offset: SIMD2<Double>, height: Float) -> MapBuilding {
            MapBuilding(id: id, rings: [square.map { ($0 + offset) * toDegrees }], height: height)
        }
        var scene = Scenario(
            name: "Slope", domainSize: SIMD3(40, 40, 30), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 2, 0.5)))
        scene.terrain = .slope(domain: scene.domainSize, spacing: 1, foot: 0, angle: 20)
        let placement = MapBuildingPlacement(origin: .zero, resolution: 1)
        let report = try scene.addMapBuildings(
            [building("a", .zero, height: 8), building("b", SIMD2(5, 0), height: 8)], placement: placement)
        let a = report.placed[0]
        // The lowest cell centre under it is at x = 10.5 m, 10.5 tan 20° up.
        #expect(abs(a.base - 10.5 * tan(20 * Float.pi / 180)) < 1e-3 && abs(a.top - a.base - 8) < 1e-3)
        // b overlaps a over half its cells, which it gives up.
        #expect(report.overlapCells == 50 && report.placed[1].cells == 50)
        let boxes = scene.envelopeObjects.flatMap { $0.envelope!.solids }
        for (n, x) in boxes.enumerated() {
            for y in boxes.dropFirst(n + 1) {
                let extent = simd_min(x.max, y.max) - simd_max(x.min, y.min)
                #expect(!(extent.x > 0 && extent.y > 0 && extent.z > 0))
            }
        }
    }

    @Test("GeoJSON: polygons, multipolygons and unclosed rings")
    func geoJSON() throws {
        let text = """
            {"type": "FeatureCollection", "features": [
              {"type": "Feature", "id": "w1", "properties": {"building": "yes", "building:levels": 3},
               "geometry": {"type": "Polygon", "coordinates": [[[0, 0], [0.0001, 0], [0.0001, 0.0001], [0, 0.0001]]]}},
              {"type": "Feature", "properties": {"building": "school", "height": "9.5"},
               "geometry": {"type": "MultiPolygon", "coordinates": [
                 [[[0.0002, 0], [0.0003, 0], [0.0003, 0.0001], [0.0002, 0.0001], [0.0002, 0]]],
                 [[[0.0004, 0], [0.0005, 0], [0.0005, 0.0001], [0.0004, 0.0001], [0.0004, 0]]]]}},
              {"type": "Feature", "properties": {"highway": "path"},
               "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}}
            ]}
            """
        let buildings = try MapBuilding.readGeoJSON(Data(text.utf8))
        #expect(buildings.map(\.id) == ["w1", "feature/2#1", "feature/2#2"])
        #expect(buildings[0].levels == 3 && buildings[1].height == 9.5)
        var scene = Scenario(
            name: "Campus", domainSize: SIMD3(60, 20, 20), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 15, 0.5)))
        let report = try scene.addMapBuildings(
            buildings, placement: MapBuildingPlacement(origin: .zero, resolution: 0.5))
        // The unclosed ring is closed; all three are placed.
        #expect(report.placed.count == 3 && report.skipped.isEmpty)
        #expect(throws: (any Error).self) { try MapBuilding.readGeoJSON(Data("[1, 2]".utf8)) }
    }

    @Test("Attributions persist with the layout but stay out of the numerical input")
    func attribution() throws {
        var scene = ScenarioPreset.openGround.scenario
        scene.attributions = [MapBuilding.openStreetMapAttribution]
        let decoded = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene))
        #expect(decoded.attributions == scene.attributions)
        let encoder = JSONEncoder()
        encoder.userInfo[Scenario.physicsInputEncoding] = true
        #expect(!String(decoding: try encoder.encode(scene), as: UTF8.self).contains("OpenStreetMap"))
    }

    @Test("Envelopes from imports and map data carry their source into the standing and the USD")
    func provenance() throws {
        var scene = Scenario(
            name: "Street", domainSize: SIMD3(12, 10, 6), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 8, 0.5)))
        #expect(!StandingInputs(scenario: scene, cellSize: 0.25).options.contains(.importedEnvelopes))
        let model = try building()
        scene.importedModels = [model]
        try scene.useEnvelopes(importIDs: [model.id])
        #expect(scene.envelopeSources(.ifc).count == 1)
        let square = [SIMD2<Double>(0.5, 0.5), SIMD2(2, 0.5), SIMD2(2, 1.5), SIMD2(0.5, 1.5)].map {
            $0 / ElevationGrid.metresPerDegree
        }
        try scene.addMapBuildings(
            [MapBuilding(id: "way/1", rings: [square])], placement: .init(origin: .zero, resolution: 0.25))
        let options = StandingInputs(scenario: scene, cellSize: 0.25).options
        #expect(options.contains(.importedEnvelopes) && options.contains(.mapBuildings))
        // Removing the buildings removes the options.
        var bare = scene
        for object in bare.envelopeObjects { try bare.removeObject(id: object.id) }
        #expect(!StandingInputs(scenario: bare, cellSize: 0.25).options.contains(.mapBuildings))

        let folder = FileManager.default.temporaryDirectory.appending(path: "map-usd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = try USDSceneWriter(
            url: folder.appending(path: "scene.usda"), scenario: scene, frameInterval: 0.001)
        try writer.append(nil)
        try writer.finish()
        let text = try String(contentsOf: folder.appending(path: "scene.usda"), encoding: .utf8)
        #expect(text.contains("string[] attributions = [\"Buildings © OpenStreetMap contributors"))
    }
}
