import Foundation
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// File ▸ New District's layout (`DistrictLayout`) on a made-up district (Fixtures/SyntheticDistrict).
@Suite("District layout")
struct DistrictLayoutTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/SyntheticDistrict")

    /// The charge at the grid's centre, 1 t of TNT, on the fixture's ground and heights.
    static func layout(ground: Bool = true) throws -> DistrictLayout {
        let buildings = try MapBuilding.read(contentsOf: folder.appending(path: "district.osm"))
        let centre = MapBuildingPlacement(origin: .zero, resolution: 1)
        let east = ElevationGrid.metresPerDegree * cos(0.0)
        var layout = DistrictLayout(
            buildings: buildings, charge: SIMD2(612 / east, 608 / ElevationGrid.metresPerDegree), mass: 1_000)
        #expect(simd_length(centre.position(layout.charge) - SIMD2(612, 608)) < 0.01)
        layout.heights = try ElevationGrid(contentsOf: folder.appending(path: "heights.asc"))
        if ground {
            layout.ground = DistrictLayout.ground(
                try ElevationGrid(contentsOf: folder.appending(path: "ground.asc")), openingM: 0, seaM: 1)
        }
        return layout
    }

    @Test("Reads the made-up map: footprints, a courtyard block, no building parts")
    func reads() throws {
        let layout = try Self.layout()
        // 49 on the grid, the warehouse and the courtyard block; the part is left out.
        #expect(layout.buildings.count == 51)
        #expect(layout.buildings.contains { $0.kind == "office" && $0.rings.count == 2 })
        #expect(!layout.buildings.contains { $0.height == 30 })
    }

    @Test("Takes the buildings whose centre lies within the radius")
    func within() throws {
        let layout = try Self.layout()
        // The grid's centre block is at 0 m; its neighbours at 100 m; diagonals at 141 m.
        #expect(layout.buildings(within: 50).count == 1)
        #expect(layout.buildings(within: 120).count == 5)
        #expect(layout.buildings(within: 150).count == 9)
        // The farthest, the courtyard block, about 470 m north.
        #expect(layout.reach > 450 && layout.reach < 500)
    }

    @Test("Puts the open faces 4 m/kg^(1/3) beyond the buildings and above the charge")
    func faces() throws {
        let layout = try Self.layout()
        #expect(abs(layout.faceClearance - 40) < 1e-3)
        #expect(layout.halfSide(radius: 250, cellSize: 4) == 292)
        #expect(layout.halfSide(radius: 250, cellSize: 4, clearFaces: false) == 252)
        // 40 m above the charge, or 20 m above the highest roof if that is higher.
        #expect(layout.top(chargeZ: 6, highestRoof: 20, cellSize: 4) == 48)
        #expect(layout.top(chargeZ: 6, highestRoof: 40, cellSize: 4) == 60)
        #expect(DistrictLayout.duration(radius: 2_500) == 7.8)
    }

    @Test("Lays the district out: envelopes with constructions and glazing, on the ground, under the rule")
    func scene() throws {
        let layout = try Self.layout()
        let half = layout.halfSide(radius: 250, cellSize: 4)
        let (scene, report) = try layout.scene(halfSide: half, cellSize: 4, radius: 250)
        #expect(scene.domainSize.x == 2 * half && scene.domainSize.y == 2 * half)
        #expect(report.placed.count == layout.buildings(within: 250).count)
        #expect(scene.envelopeObjects.count == report.placed.count)
        // Each with a construction and a glazing mix; the brick ones from their tag.
        for object in scene.envelopeObjects {
            #expect(scene.envelopeConstruction(for: object.id).glazing != nil)
        }
        // Untagged buildings take the heights grid's (6–21 m), tagged ones their tags.
        let sources = Set(report.placed.map(\.heightSource))
        #expect(sources.isSuperset(of: [.height, .levels, .grid]))
        #expect(!sources.contains(.assumed))
        // On the ground: the charge at the terrain's height at the centre, the top by the rule.
        let terrain = try #require(scene.terrain)
        #expect(abs(scene.charge.position.z - terrain.height(at: SIMD2(half, half))) < 1e-4)
        #expect(scene.charge.position.x == half && scene.charge.position.y == half)
        let roofs = report.placed.map(\.top).max()!
        #expect(scene.domainSize.z >= scene.charge.position.z + layout.faceClearance)
        #expect(scene.domainSize.z >= roofs + layout.faceClearance / 2)
        #expect(scene.domainSize.z - 4 < max(scene.charge.position.z + 40, roofs + 20, terrain.highest + 20))
        #expect(scene.attributions?.contains(MapBuilding.openStreetMapAttribution) == true)
    }

    @Test("The sea stays at the base when a surface model is opened")
    func sea() throws {
        let dem = try ElevationGrid(contentsOf: Self.folder.appending(path: "ground.asc"))
        let ground = DistrictLayout.ground(dem, openingM: 100, seaM: 1)
        for n in dem.elevations.indices where dem.elevations[n] < 1 { #expect(ground.elevations[n] == 0) }
        // Opening takes the hill down: nowhere higher than before.
        for n in dem.elevations.indices where dem.elevations[n] >= 1 {
            #expect(ground.elevations[n] <= dem.elevations[n] + 1e-4)
        }
        #expect(ground.elevations.max()! < dem.elevations.max()!)
    }

    @Test("Without a ground the district stands on the floor")
    func flat() throws {
        let layout = try Self.layout(ground: false)
        let (scene, report) = try layout.scene(halfSide: 200, cellSize: 5, radius: 150)
        #expect(scene.terrain == nil && scene.charge.position.z == 0)
        #expect(report.placed.allSatisfy { $0.base == 0 })
        #expect(
            scene.domainSize.z
                == layout.top(chargeZ: 0, highestRoof: report.placed.map(\.top).max()!, cellSize: 5))
    }
}
