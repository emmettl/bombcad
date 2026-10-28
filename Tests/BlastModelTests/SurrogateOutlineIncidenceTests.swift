import Foundation
import Testing
import simd

@testable import BlastModel

/// The façade surrogate's facing from map outlines (`FacadeLoadSurrogate.Incidence.outline`,
/// emmettl/bombcad-work#109; docs/surrogate-first-look.md): a front at a slant to the cells faces
/// as its outline does, whatever the cells' orientation, and with the option off everything is as
/// before.
@Suite("Façade incidence from map outlines")
struct SurrogateOutlineIncidenceTests {
    typealias S = FacadeLoadSurrogate

    /// One block 40 m by 16 m and 12 m tall, its long front turned `degrees` from facing east, its
    /// middle at (100, 100) m, placed on 2 m cells (its outline kept with `keepsOutlines`); the charge
    /// 80 m out from the middle of that front, square to it.
    static func block(degrees: Double, keepsOutlines: Bool = true) throws -> Scenario {
        let angle = degrees * .pi / 180
        let normal = SIMD2(cos(angle), sin(angle))
        let along = SIMD2(-normal.y, normal.x)
        let centre = SIMD2<Double>(100, 100)
        let corners = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { a, b in
            centre + a * 8 * normal + b * 20 * along
        }
        let metres = ElevationGrid.metresPerDegree
        let building = MapBuilding(id: "way/1", rings: [corners.map { $0 / metres }], height: 12)
        let charge = centre + 88 * normal
        var scene = Scenario(
            name: "Block", domainSize: SIMD3(200, 200, 60), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(Float(charge.x), Float(charge.y), 0.5)))
        var placement = MapBuildingPlacement(origin: .zero, resolution: 2)
        placement.keepsOutlines = keepsOutlines
        try scene.addMapBuildings([building], placement: placement)
        return scene
    }

    /// The block's wall strips facing the charge (by their outline) and their cosines.
    static func frontCosines(_ scene: Scenario, incidence: S.Incidence) -> [Double] {
        let objects = scene.envelopeObjects
        let raster = S.Raster(
            objects: objects, blocks: [], terrain: nil, cell: 2, incidence: incidence)
        let charge = scene.charge.position
        return objects[0].envelope!.components(owner: objects[0].id, cellSize: 2)
            .filter { $0.kind == .facade && S.facesAir($0, raster: raster) }
            .map { S.features($0, owner: 0, charge: charge, raster: raster).cosIncidence }
            .filter { $0 > 0.5 }
    }

    static func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }

    @Test("A front turned 45° to the cells faces the charge squarely, as one along them does")
    func turnedFront() throws {
        for degrees in [0.0, 10, 30, 45] {
            let scene = try Self.block(degrees: degrees)
            let outline = Self.frontCosines(scene, incidence: .outline)
            #expect(!outline.isEmpty)
            // The front's strips, 88 m from a front 40 m long, within a few degrees of square; those
            // open round a corner as well face between the front and the side.
            #expect(Self.median(outline) > 0.98, "\(degrees)°: \(outline)")
            #expect(outline.filter { $0 > 0.96 }.count * 5 >= outline.count * 4, "\(degrees)°: \(outline)")
            if degrees == 45 {
                // On the cells the same front is a staircase whose faces look 45° off it.
                let cells = Self.frontCosines(scene, incidence: .cells)
                #expect(Self.median(cells) < 0.75, "\(cells)")
            }
        }
    }

    @Test("Each outline edge faces out of the building, courtyards into the court")
    func edgesFaceOut() {
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 30), SIMD2(0, 30)]
        // A courtyard wound the same way as the outer ring.
        let court: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(20, 10), SIMD2(20, 20), SIMD2(10, 20)]
        let edges = S.OutlineEdge.edges([outer, court])
        #expect(edges.count == 8)
        for edge in edges {
            let middle = 0.5 * (edge.a + edge.b)
            let outside = middle + edge.normal
            let inBlock =
                outside.x > 0 && outside.x < 30 && outside.y > 0 && outside.y < 30
                && !(outside.x > 10 && outside.x < 20 && outside.y > 10 && outside.y < 20)
            #expect(!inBlock, "\(edge)")
        }
    }

    @Test("Off, the envelopes, the scene's file and every feature are as before")
    func offUnchanged() throws {
        let kept = try Self.block(degrees: 45)
        let plain = try Self.block(degrees: 45, keepsOutlines: false)
        #expect(plain.envelopeObjects[0].envelope?.outline == nil)
        #expect(kept.envelopeObjects[0].envelope?.outline?.first?.count == 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("\"outline\""))
        // A scene saved with outlines keeps them.
        let back = try JSONDecoder().decode(Scenario.self, from: try encoder.encode(kept))
        #expect(back.envelopeObjects[0].envelope?.outline == kept.envelopeObjects[0].envelope?.outline)
        // The cells' facing does not read the outline; the outline's reads it only when asked.
        #expect(Self.frontCosines(kept, incidence: .cells) == Self.frontCosines(plain, incidence: .cells))
        #expect(Self.frontCosines(plain, incidence: .outline) == Self.frontCosines(plain, incidence: .cells))
        // Moved, the outline goes with the blocks.
        let envelope = try #require(kept.envelopeObjects[0].envelope)
        let moved = try envelope.translated(by: SIMD3(5, -3, 1))
        #expect(moved.outline?[0][0] == (envelope.outline?[0][0] ?? .zero) + SIMD2(5, -3))
    }

    @Test("The outline sets are named, off by default, and save with their facing")
    func namedSets() throws {
        #expect(S.TermSet.adopted == .deepCity && S.Coefficients.adopted.incidence == .cells)
        #expect(S.Coefficients.deepCity.facing == nil)
        #expect(try SurrogateBench.termSet(["--terms", "deep-city-outline"]) == .deepCityOutline)
        #expect(S.Coefficients.deepCityOutline.incidence == .outline)
        #expect(S.Coefficients.deepCityOutlineFront.incidence == .outline)
        #expect(S.Coefficients.deepCityOutlineFront.glassFront != nil)
        #expect(S.Coefficients.deepCityOutline.glassFront == nil)
        let data = try JSONEncoder().encode(S.Coefficients.deepCity)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"facing\""))
        let back = try JSONDecoder().decode(
            S.Coefficients.self, from: try JSONEncoder().encode(S.Coefficients.deepCityOutline))
        #expect(back == .deepCityOutline)
        #expect(SurrogateBench.incidence(["--terms", "deep-city-outline"]) == .outline)
        #expect(SurrogateBench.incidence(["--terms", "deep-city"]) == .cells)
        #expect(SurrogateBench.incidence(["--incidence", "outline"]) == .outline)
    }

    @Test("The quick estimate takes its terms' facing")
    func estimateTakesTheTermsFacing() throws {
        let scene = try Self.block(degrees: 45)
        let cells = S.estimate(scene: scene, cellSize: 2, coefficients: .deepCity)
        let outline = S.estimate(scene: scene, cellSize: 2, coefficients: .deepCityOutline)
        #expect(cells.components.count == outline.components.count)
        let front = { (e: S.Estimate) in Self.median(e.features.map(\.cosIncidence).filter { $0 > 0.5 }) }
        #expect(front(outline) > 0.98 && front(cells) < 0.75, "\(front(outline)) \(front(cells))")
        // Roofs keep the cells' facing.
        for n in cells.components.indices where cells.components[n].kind == .roof {
            #expect(cells.features[n].cosIncidence == outline.features[n].cosIncidence)
        }
    }
}
