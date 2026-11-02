import Foundation
import Testing
import simd

@testable import BlastModel

/// The fire's district kept between layers (emmettl/bombcad-work#113; `FireSpread.LayerCache`): a layer
/// made through the cache is the one made without it, to the bit, as the glass, the walls, the
/// wind, the charge and the buildings' construction change, and the cache lays out again only what
/// a change needs.
@Suite("Fire after the blast, kept between frames")
struct FireSpreadCacheTests {
    typealias F = FireSpread

    /// A block of 6 × 4 buildings 9–14 m apart, a third of them timber, with made-up glass broken and
    /// walls failed that move with `frame`.
    static func district() throws -> (Scenario, [UUID]) {
        var scene = Scenario(
            name: "Block", domainSize: SIMD3(200, 140, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(4, 70, 0.5)))
        var ids: [UUID] = []
        for j in 0..<4 {
            for i in 0..<6 {
                let x = Float(8 + i * (22 + i % 3 * 2))
                let y = Float(10 + j * 30)
                let id = try scene.addEnvelopeObject(
                    BuildingEnvelope(solids: [
                        Box(min: SIMD3(x, y, 0), max: SIMD3(x + 12, y + 18, Float(6 + (i + j) % 4 * 3)))
                    ]))
                var construction = EnvelopeConstruction.assumed(objectID: id)
                if (i + j) % 3 == 0 {
                    construction.walls = .crossLaminatedTimber
                    construction.roof = .crossLaminatedTimber
                }
                construction.glazing = j % 2 == 0 ? .apartments : .commercial
                scene.setEnvelopeConstruction(construction)
                ids.append(id)
            }
        }
        return (scene, ids)
    }

    static func source(_ ids: [UUID], frame: Int) -> F.LayerSource {
        var glass: [FacadeLoadSurrogate.SideGlass] = []
        var structure: [FacadeLoadSurrogate.StructureChance] = []
        for (n, id) in ids.enumerated() {
            for (axis, outward) in [(0, -1), (0, 1), (1, -1), (1, 1), (2, 1)] {
                let share = Double((n * 7 + axis * 3 + outward + frame * 5) % 11) / 10
                glass.append(
                    FacadeLoadSurrogate.SideGlass(
                        owner: id, axis: axis, outward: outward, distanceM: 10, someBroken: share,
                        blownOut: share / 2,
                        fractionBroken: share, thrownPast3b: 0))
            }
            // A side given twice, as a building of several facings is.
            glass.append(
                FacadeLoadSurrogate.SideGlass(
                    owner: id, axis: 0, outward: 1, distanceM: 12, someBroken: 0.3, blownOut: 0.1,
                    fractionBroken: 0.3, thrownPast3b: 0))
            structure.append(
                FacadeLoadSurrogate.StructureChance(
                    owner: id, wallsModerate: 0.5, wallsHeavy: Double((n + frame) % 5) / 4, roofModerate: 0.2)
            )
        }
        // And one of a building the scene no longer has.
        glass.append(
            FacadeLoadSurrogate.SideGlass(
                owner: UUID(), axis: 1, outward: -1, distanceM: 5, someBroken: 1, blownOut: 1,
                fractionBroken: 1,
                thrownPast3b: 0))
        structure.append(FacadeLoadSurrogate.StructureChance(owner: UUID(), wallsHeavy: 1))
        return .estimate(glass: glass, structure: structure)
    }

    /// The two layers alike to the bit: the same buildings, ignition times, neighbours' times and
    /// summary.
    static func same(_ a: F.Layer?, _ b: F.Layer?) throws -> Bool {
        let a = try #require(a)
        let b = try #require(b)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let summaries = (try encoder.encode(a.ensemble), try encoder.encode(b.ensemble))
        return a.ids == b.ids && a.ignitions == b.ignitions && a.fromNeighbour == b.fromNeighbour
            && a.fixedSeeds == b.fixedSeeds && a.randomCandidates == b.randomCandidates
            && a.combustible == b.combustible && summaries.0 == summaries.1
    }

    @Test("A layer through the cache is the layer without it, to the bit, as each input moves")
    func sameAsWithout() throws {
        let (start, ids) = try Self.district()
        var scene = start
        let cache = F.LayerCache()
        var settings = F.LayerSettings()
        settings.randomCount = 4
        settings.picked = [ids[0]]
        settings.hours = 6
        settings.wind = F.Wind(speedMS: 3, fromDegrees: 240)
        func both(frame: Int, reordered: Bool = false) throws -> Bool {
            var source = Self.source(ids, frame: frame)
            // Another estimate's sides: reversed, a third left out, the walls of half.
            if reordered, case .estimate(let glass, let structure) = source {
                source = .estimate(
                    glass: glass.enumerated().filter { $0.offset % 3 != 1 }.map(\.element).reversed(),
                    structure: Array(structure.prefix(structure.count / 2)))
            }
            let plain = F.layer(scene: scene, source: source, settings: settings, members: 40, preview: true)
            let kept = F.layer(
                scene: scene, source: source, settings: settings, members: 40, preview: true, cache: cache)
            return try Self.same(plain, kept)
        }
        // First: everything laid out, and fire spreads from building to building.
        #expect(try both(frame: 0))
        let first = try #require(
            F.layer(
                scene: scene, source: Self.source(ids, frame: 0), settings: settings, members: 40,
                preview: true))
        #expect(first.fromNeighbour.joined().contains { $0 > 0 })
        #expect(cache.rebuilt == (true, true, true))
        // The glass and walls of another frame, the charge dragged: nothing laid out again.
        scene.charge.position.x = 30
        #expect(try both(frame: 1))
        #expect(cache.rebuilt == (false, false, false))
        // The wind turned: the neighbours kept (their reach is the speed's). Its speed raised past the
        // first list's reach: the list for the strongest wind's, once, cut to each speed's after.
        settings.wind.fromDegrees = 90
        #expect(try both(frame: 2))
        #expect(cache.rebuilt == (false, false, false))
        settings.wind.speedMS = 12
        #expect(F.Parameters().reach(wind: settings.wind) > F.Parameters().reach(wind: F.Wind(speedMS: 3)))
        #expect(try both(frame: 3))
        #expect(cache.rebuilt.neighbours && !cache.rebuilt.buildings)
        for (frame, speed) in [(7, 6.0), (8, 25.0), (9, 0.0), (10, 13.0)] {
            settings.wind.speedMS = speed
            #expect(try both(frame: frame))
            #expect(cache.rebuilt == (false, false, false))
        }
        // Sides in another order, or fewer, then as before.
        #expect(try both(frame: 11, reordered: true))
        #expect(try both(frame: 12))
        // A building's construction changed, or every building's cladding: laid out again.
        var timber = scene.envelopeConstruction(for: ids[5])
        timber.walls = .crossLaminatedTimber
        scene.setEnvelopeConstruction(timber)
        #expect(try both(frame: 4))
        #expect(cache.rebuilt == (true, true, true))
        settings.cladding = .combustible
        #expect(try both(frame: 5))
        #expect(cache.rebuilt.buildings)
        // The fire's own parameters changed: the stages again, with the same layer.
        let parameters = F.Parameters()
        var other = parameters
        other.growthS *= 1.5
        let source = Self.source(ids, frame: 6)
        #expect(
            try Self.same(
                F.layer(scene: scene, source: source, settings: settings, members: 40, parameters: other),
                F.layer(
                    scene: scene, source: source, settings: settings, members: 40, parameters: other,
                    cache: cache)))
        #expect(cache.rebuilt.stages && !cache.rebuilt.buildings)
    }

    @Test("A what-if builds the fire's buildings as a scene built that way, laid out when picked or cleared")
    func whatIf() throws {
        let (scene, ids) = try Self.district()
        let cache = F.LayerCache()
        var settings = F.LayerSettings()
        settings.randomCount = 4
        settings.picked = [ids[1]]
        settings.hours = 6
        settings.wind = F.Wind(speedMS: 5, fromDegrees: 240)
        let source = Self.source(ids, frame: 0)
        func layer(_ scene: Scenario, cache: F.LayerCache? = nil) -> F.Layer? {
            F.layer(
                scene: scene, source: source, settings: settings, members: 40, preview: true, cache: cache)
        }
        // Every building's walls and roof timber, set one by one as the inspector sets them.
        var timber = scene
        for id in ids {
            var c = scene.envelopeConstruction(for: id)
            c.walls = .crossLaminatedTimber
            c.wallThicknessM = EnvelopeConstruction.defaultThickness(.crossLaminatedTimber)
            c.roof = .crossLaminatedTimber
            c.roofThicknessM = 0.14
            timber.setEnvelopeConstruction(c)
        }
        let picked = LiveResponse.WhatIf(walls: .crossLaminatedTimber, roof: .crossLaminatedTimber)
        // As built, then the what-if picked: the buildings laid out again, the fire the timber scene's.
        #expect(
            try Self.same(layer(cache.scene(scene, as: LiveResponse.WhatIf()), cache: cache), layer(scene)))
        #expect(try Self.same(layer(cache.scene(scene, as: picked), cache: cache), layer(timber)))
        #expect(cache.rebuilt.buildings)
        let asBuilt = try #require(layer(scene))
        let asTimber = try #require(layer(timber))
        #expect(asTimber.combustible == ids.count && asBuilt.combustible < ids.count)
        // Dragged with the what-if kept: nothing laid out again.
        var dragged = scene
        dragged.charge.position.x += 20
        var timberDragged = timber
        timberDragged.charge.position.x += 20
        #expect(
            try Self.same(layer(cache.scene(dragged, as: picked), cache: cache), layer(timberDragged)))
        #expect(cache.rebuilt == (false, false, false))
        // Cleared: as built again.
        #expect(
            try Self.same(
                layer(cache.scene(dragged, as: LiveResponse.WhatIf()), cache: cache), layer(dragged)))
        #expect(cache.rebuilt.buildings)
        // The glass what-if too, which changes the windows' share of each façade.
        let glass = LiveResponse.WhatIf(glass: .laminated(.facade))
        var laminated = scene
        for id in ids {
            laminated.setEnvelopeConstruction(glass.applied(to: scene.envelopeConstruction(for: id)))
        }
        #expect(try Self.same(layer(cache.scene(scene, as: glass), cache: cache), layer(laminated)))
    }
}
