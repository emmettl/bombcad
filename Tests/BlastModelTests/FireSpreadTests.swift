import Foundation
import Testing

@testable import BlastModel

/// The fire spread after the blast against its model's published tables and its own rules
/// (emmettl/bombcad-work#38; docs/fire-spread.md, "Checks").
@Suite("Fire spread: building to building after the blast")
struct FireSpreadTests {
    typealias F = FireSpread

    /// A building `width` × `depth` m with its south-west corner at (`x`, `y`), `height` m high.
    func building(
        x: Double, y: Double = 0, width: Double = 10, depth: Double = 10, height: Double = 4.5,
        cladding: F.Cladding = .combustible, broken: Double = 0, glazed: Double = 0.15
    ) -> F.Building {
        F.Building(
            footprint: [F.Rect(min: SIMD2(x, y), max: SIMD2(x + width, y + depth))], top: height,
            cladding: cladding, glazedFraction: glazed, brokenGlass: [broken, broken, broken, broken])
    }

    /// A row of `count` combustible houses 10 m square, `gap` m apart, west to east.
    func row(_ count: Int, gap: Double, cladding: F.Cladding = .combustible) -> [F.Building] {
        (0..<count).map { building(x: Double($0) * (10 + gap), cladding: cladding) }
    }

    /// The separation, m, at which a `width` × `height` radiator's flux falls to `flux` kW/m².
    func critical(_ p: F.Parameters, width: Double, height: Double, flux: Double) -> Double {
        var (low, high) = (0.01, 500.0)
        for _ in 0..<100 {
            let mid = 0.5 * (low + high)
            if p.fluxKWm2(width: width, height: height, distance: mid) >= flux {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    @Test("Report 27's Table 2: the flux from a 4.5 m high radiator, to its decimal")
    func report27Table2() {
        // Cousins et al. 2002 (NZFS Report 27), Table 2: incident radiation, kW/m², at 1.5–28.5 m
        // from radiators 3–75 m wide and of unbounded width (the last column), 4.5 m high, at
        // 1000 °C and ε 0.9. Its 24 m column repeats the unbounded one (a slip in the report).
        let widths: [Double] = [3, 6, 9, 12, 15, 21, 36, 39, 72, 75, 1e6]
        let table: [[Double]] = [
            [85.1, 104.6, 109.0, 110.4, 110.9, 111.3, 111.5, 111.5, 111.5, 111.6, 111.6],
            [23.0, 39.2, 48.4, 53.2, 55.8, 58.2, 59.5, 59.6, 59.9, 59.9, 60.0],
            [9.4, 17.6, 23.9, 28.3, 31.4, 34.8, 37.5, 37.7, 38.4, 38.4, 38.5],
            [5.0, 9.6, 13.6, 16.9, 19.5, 22.9, 26.4, 26.7, 27.8, 27.8, 28.1],
            [3.1, 6.0, 8.7, 11.0, 13.0, 16.0, 19.7, 20.1, 21.6, 21.7, 22.0],
            [2.1, 4.1, 6.0, 7.7, 9.2, 11.7, 15.3, 15.7, 17.5, 17.6, 18.1],
            [1.5, 3.0, 4.4, 5.7, 6.9, 8.9, 12.2, 12.6, 14.6, 14.7, 15.4],
            [1.1, 2.2, 3.3, 4.3, 5.3, 7.0, 9.9, 10.3, 12.4, 12.5, 13.3],
            [0.9, 1.7, 2.6, 3.4, 4.2, 5.6, 8.1, 8.5, 10.7, 10.8, 11.8],
            [0.7, 1.4, 2.1, 2.7, 3.4, 4.5, 6.8, 7.2, 9.3, 9.4, 10.6],
        ]
        let p = F.Parameters()
        var worst = 0.0
        for (row, values) in table.enumerated() {
            let distance = 1.5 + 3 * Double(row)
            for (width, value) in zip(widths, values) {
                worst = max(worst, abs(p.fluxKWm2(width: width, height: 4.5, distance: distance) - value))
            }
        }
        #expect(worst <= 0.11, "worst \(worst) kW/m²")
        // Its worked example (§4.5.2): 12 m by 4.5 m, 12 m away, 13.5 kW/m².
        #expect(abs(p.fluxKWm2(width: 12, height: 4.5, distance: 12) - 13.5) < 0.05)
    }

    @Test("Report 44's Table 2.1: critical separations through broken and intact windows")
    func report44Table21() {
        // Heron et al. 2003 (NZFS Report 44), Table 2.1: the greatest separation, m, at which a
        // façade 10, 20 or 30 m wide with 10–40% openings, 12 m of it alight, ignites a building
        // through its broken windows (piloted, 12.5 kW/m²) or its intact ones (spontaneous, 30
        // kW/m² of the half that glass lets through). Each is within a metre below the flux's
        // reach, or a tenth above it (the table's own rounding), but one: 10% of 10 m broken, 6 m
        // in the table, which reaches 4.7 m.
        let table: [(openings: Double, broken: [Double], intact: [Double])] = [
            (0.1, [6, 7, 10], [1, 1, 2]),
            (0.2, [7, 11, 14], [1, 3, 5]),
            (0.3, [10, 14, 18], [2, 5, 6]),
            (0.4, [11, 17, 21], [3, 6, 7]),
        ]
        let p = F.Parameters()
        var mismatches: [String] = []
        for row in table {
            for (k, facade) in [10.0, 20, 30].enumerated() {
                let width = row.openings * facade
                let broken = critical(p, width: width, height: 12, flux: p.pilotedKWm2)
                let intact = critical(
                    p, width: width, height: 12, flux: p.spontaneousKWm2 / p.glassTransmission)
                for (name, reach, listed) in [
                    ("broken", broken, row.broken[k]), ("intact", intact, row.intact[k]),
                ]
                where !(listed > reach - 1 && listed <= reach + 0.1) {
                    mismatches.append("\(row.openings) \(facade) \(name) \(String(format: "%.1f", reach))")
                }
            }
        }
        #expect(mismatches == ["0.1 10.0 broken 4.7"])
    }

    @Test("Report 27's Table 3: sparks' reach by wind, downwind and across")
    func sparkReach() {
        let p = F.Parameters()
        func kmh(_ v: Double) -> F.Wind { F.Wind(speedMS: v / 3.6, fromDegrees: 270) }
        #expect(p.sparkReach(wind: .calm, cosine: 1) == 12)
        #expect(abs(p.sparkReach(wind: kmh(20), cosine: 1) - 15) < 1e-9)
        #expect(abs(p.sparkReach(wind: kmh(30), cosine: 1) - 21) < 1e-9)
        #expect(abs(p.sparkReach(wind: kmh(50), cosine: 1) - 45) < 1e-9)
        #expect(abs(p.sparkReach(wind: kmh(25), cosine: 1) - 18) < 1e-9)
        for cosine in [0.0, -0.5, -1] { #expect(p.sparkReach(wind: kmh(50), cosine: cosine) == 12) }
        // A westerly blows east.
        #expect(abs(kmh(20).downwind.x - 1) < 1e-12 && abs(kmh(20).downwind.y) < 1e-12)
    }

    @Test("A row 6 m apart burns house by house, each a growth and a scan after the last")
    func rowWithinSpontaneousReach() {
        let p = F.Parameters()
        // A 10 m face 4.5 m high ignites timber spontaneously within 6.72 m.
        #expect(abs(critical(p, width: 10, height: 4.5, flux: 30) - 6.72) < 0.01)
        let district = F.District(buildings: row(6, gap: 6))
        let fire = district.run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        let step = district.stages[0].growthS + p.scanS
        // 7.5 min to full intensity, 2.5 min a 3 m cell across 10 m, then one scan: 18.3 minutes.
        #expect(abs(step - (450 + 150 * 10 / 3 + 150)) < 1e-9)
        for n in 0..<6 {
            #expect(abs((fire.ignitedS[n] ?? -1) - Double(n) * step) < 1e-6)
            #expect(fire.mode[n] == (n == 0 ? .seed : .spontaneous))
            #expect(fire.source[n] == (n == 0 ? nil : n - 1))
        }
        // 52 m an hour along the row: Hamada's formula for bare timber in calm air gives 166.
        let speed = 16 / step * 3600
        #expect(speed > 50 && speed < 60)
    }

    @Test("Past the piloted critical separation nothing spreads, whatever the chances")
    func criticalSeparation() {
        var p = F.Parameters()
        p.pilotedChance = 1
        p.brandChance = 1
        p.roofChance = 1
        // Piloted reach of a 10 m face 4.5 m high: 11.58 m, inside calm sparks' 12 m.
        let reach = critical(p, width: 10, height: 4.5, flux: p.pilotedKWm2)
        #expect(abs(reach - 11.58) < 0.01)
        let inside = F.District(buildings: row(4, gap: 11), parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(inside.ignitedS.allSatisfy { $0 != nil })
        #expect(inside.mode[1] == .piloted)
        let outside = F.District(buildings: row(4, gap: 12), parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(outside.ignitedS.compactMap { $0 }.count == 1)
        // Between 6.72 and 11.58 m it is the sparks' chance, Report 80's 10% by default.
        let ensemble = F.ensemble(
            F.District(buildings: row(2, gap: 9)), seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600,
            members: 2000)
        #expect(abs(ensemble.buildings[1].chance - 0.1) < 0.025)
    }

    @Test("Wind carries sparks downwind only: a fresh westerly reaches 21 m east, 12 m elsewhere")
    func windBias() {
        var p = F.Parameters()
        p.pilotedChance = 1
        // A fire 30 m wide, 14 m from four neighbours: 17.8 kW/m² on each, past piloted ignition but
        // beyond calm sparks' 12 m.
        #expect(abs(p.fluxKWm2(width: 30, height: 4.5, distance: 14) - 17.8) < 0.05)
        let centre = building(x: 0, y: 0, width: 30, depth: 30)
        let east = building(x: 44, y: 0, width: 30, depth: 30)
        let west = building(x: -44, y: 0, width: 30, depth: 30)
        let north = building(x: 0, y: 44, width: 30, depth: 30)
        let south = building(x: 0, y: -44, width: 30, depth: 30)
        let buildings = [centre, east, west, north, south]
        let calm = F.District(buildings: buildings, wind: .calm, parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(calm.ignitedS.compactMap { $0 }.count == 1)
        let westerly = F.Wind(speedMS: 30 / 3.6, fromDegrees: 270)
        let fire = F.District(buildings: buildings, wind: westerly, parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(fire.ignitedS.map { $0 != nil } == [true, true, false, false, false])
        #expect(fire.mode[1] == .piloted)
        // A southerly carries it north instead.
        let southerly = F.Wind(speedMS: 30 / 3.6, fromDegrees: 180)
        let north2 = F.District(buildings: buildings, wind: southerly, parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(north2.ignitedS.map { $0 != nil } == [true, false, false, true, false])
    }

    @Test("Non-combustible buildings take fire only through openings, more often when the blast broke them")
    func openings() {
        // Two concrete blocks 20 m wide, 12 m high, 25% glazed, 5 m apart: the burning one's
        // windows give 51.6 kW/m², 25.8 through intact glass, under the 30 that needs.
        let p = F.Parameters()
        #expect(abs(p.fluxKWm2(width: 0.25 * 20, height: 12, distance: 5) - 51.6) < 0.05)
        func pair(broken: Double) -> F.Ensemble {
            let a = building(x: 0, width: 20, depth: 20, height: 12, cladding: .nonCombustible, glazed: 0.25)
            let b = building(
                x: 25, width: 20, depth: 20, height: 12, cladding: .nonCombustible, broken: broken,
                glazed: 0.25)
            return F.ensemble(
                F.District(buildings: [a, b]), seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600,
                members: 4000)
        }
        // Intact: not enough through the glass. All broken: Report 80's 41% at 3–6 m. Half: half that.
        #expect(pair(broken: 0).buildings[1].chance == 0)
        #expect(abs(pair(broken: 1).buildings[1].chance - 0.41) < 0.03)
        #expect(abs(pair(broken: 0.5).buildings[1].chance - 0.205) < 0.03)
        #expect(pair(broken: 1).buildings[1].mode == .openings)
        // Walls the blast failed burn as combustible: within 6.7 m of a timber face, certainly.
        var shattered = building(x: 15, cladding: .nonCombustible)
        shattered.wallsFailed = 1
        let fire = F.District(buildings: [building(x: 0), shattered])
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(fire.mode[1] == .spontaneous)
    }

    @Test("A roof that is not fire-rated spreads to a taller neighbour within 5 m")
    func roof() {
        var p = F.Parameters()
        p.roofChance = 1
        var low = building(x: 0, height: 4, cladding: .nonCombustible, glazed: 0)
        low.fireRatedRoof = false
        let tall = building(x: 14, height: 20, cladding: .nonCombustible, glazed: 0)
        let fire = F.District(buildings: [low, tall], parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(fire.ignitedS[1] != nil && fire.mode[1] == .roof)
        let far = building(x: 16, height: 20, cladding: .nonCombustible, glazed: 0)
        let none = F.District(buildings: [low, far], parameters: p)
            .run(seeds: [F.Ignition(building: 0)], horizonS: 24 * 3600)
        #expect(none.ignitedS[1] == nil)
    }

    @Test("A fire's stages: growth, full involvement by fuel and openings, burning down")
    func stages() {
        let p = F.Parameters()
        // A two-storey house, 100 m², 15% glazed, 780 MJ/m²: 156 GJ. Ventilation-controlled 1.5 MW
        // × 36 m² × √1.2 m = 59 MW; fuel-controlled 250 kW/m² × 200 m² = 50 MW, the lesser: 52 min.
        let house = building(x: 0, height: 6)
        let s = F.stages(of: house, parameters: p)
        #expect(abs(s.fullS - 780e6 * 200 / 50e6) < 1e-6)
        #expect(abs(s.growthS - (450 + 500)) < 1e-9)
        #expect(s.decayS == 750)
        // Twelve storeys burn as three bands of 12 m, each as long as one band alone.
        let tower = building(x: 0, width: 20, depth: 20, height: 36, cladding: .nonCombustible, glazed: 0.4)
        let one = building(x: 0, width: 20, depth: 20, height: 12, cladding: .nonCombustible, glazed: 0.4)
        #expect(
            abs(F.stages(of: tower, parameters: p).fullS - 3 * F.stages(of: one, parameters: p).fullS) < 1e-6)
    }

    @Test("The same draws give the same fire; members differ; the horizon stops it")
    func determinism() {
        let district = F.District(buildings: row(8, gap: 9))
        let a = district.run(seeds: [F.Ignition(building: 0)], horizonS: 1e6, member: 3, seed: 7)
        let b = district.run(seeds: [F.Ignition(building: 0)], horizonS: 1e6, member: 3, seed: 7)
        #expect(a == b)
        let e1 = F.ensemble(district, seeds: [F.Ignition(building: 0)], horizonS: 1e6, members: 50, seed: 7)
        let e2 = F.ensemble(district, seeds: [F.Ignition(building: 0)], horizonS: 1e6, members: 50, seed: 7)
        #expect(e1.buildings.map(\.chance) == e2.buildings.map(\.chance))
        #expect(e1.timeline.map(\.burnt) == e2.timeline.map(\.burnt))
        let short = F.District(buildings: row(6, gap: 6))
            .run(seeds: [F.Ignition(building: 0)], horizonS: 3000)
        // 1,100 s a house: by 3,000 s the third.
        #expect(short.ignitedS.compactMap { $0 }.count == 3)
        // Random ignitions: so many distinct candidates a draw, the same for the same draw.
        let random = F.RandomIgnitions(count: 3, candidates: [2, 4, 5, 7])
        let picks = (0..<20).map { random.draw(member: UInt64($0), seed: 1) }
        #expect(picks.allSatisfy { Set($0).count == 3 && Set($0).isSubset(of: [2, 4, 5, 7]) })
        #expect(picks[5] == random.draw(member: 5, seed: 1))
        #expect(Set(picks.map { $0.description }).count > 1)
        let seeded = F.ensemble(district, seeds: [], random: random, horizonS: 600, members: 20, seed: 1)
        #expect(seeded.caught.x >= 3)
    }

    @Test("A district scene's envelopes, their glass by side, and thermal ignitions as seeds")
    func fromScene() throws {
        var scene = Scenario(
            name: "Fire", domainSize: SIMD3(200, 100, 40), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(10, 50, 0)))
        let a = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(50, 40, 0), max: SIMD3(60, 60, 9))]), name: "A")
        let b = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(70, 40, 0), max: SIMD3(80, 60, 9))]), name: "B")
        var timber = EnvelopeConstruction.assumed(objectID: b)
        timber.walls = .crossLaminatedTimber
        timber.roof = .crossLaminatedTimber
        timber.use = .office
        scene.envelopeConstructions = [timber]
        let glass = [
            FacadeLoadSurrogate.SideGlass(
                owner: a, axis: 0, outward: -1, distanceM: 40, someBroken: 1, blownOut: 1,
                fractionBroken: 0.9,
                thrownPast3b: 0),
            FacadeLoadSurrogate.SideGlass(
                owner: a, axis: 1, outward: 1, distanceM: 40, someBroken: 0, blownOut: 0, fractionBroken: 0.2,
                thrownPast3b: 0),
        ]
        let buildings = F.buildings(
            scene: scene, glass: glass,
            structure: [FacadeLoadSurrogate.StructureChance(owner: a, wallsHeavy: 0.3)])
        #expect(buildings.map(\.id) == [a, b])
        #expect(buildings[0].cladding == .nonCombustible && buildings[0].fireRatedRoof)
        #expect(buildings[0].brokenGlass == [0.9, 0, 0, 0.2])
        #expect(buildings[0].wallsFailed == 0.3)
        #expect(buildings[1].cladding == .combustible && !buildings[1].fireRatedRoof)
        #expect(buildings[1].use == .office && buildings[1].fuelLoadMJm2 == 420)
        #expect(F.buildings(scene: scene, cladding: .combustible).allSatisfy { $0.cladding == .combustible })
        #expect(F.buildings(near: SIMD2(45, 50), radius: 6, in: buildings) == [0])
        #expect(F.buildings(near: SIMD2(65, 50), radius: 6, in: buildings) == [0, 1])

        // A receiver on B's west face flagged by the fluence, one on A's roof by temperature only.
        let receivers = [
            ThermalReceiver(position: SIMD3(69.999, 50, 4), normal: SIMD3(-1, 0, 0), surface: "block 1"),
            ThermalReceiver(position: SIMD3(55, 50, 9.001), normal: SIMD3(0, 0, 1), surface: "block 0"),
            ThermalReceiver(position: SIMD3(30, 50, 0.001), normal: SIMD3(0, 0, 1), surface: "ground"),
        ]
        let result = ThermalResult(
            spec: ThermalSpec(), receivers: receivers, peakIrradiance: [0, 0, 0], fluence: [0, 0, 0],
            fireball: [], chargeEnergy: 0,
            heating: SurfaceHeatingResult(
                ambient: 293, materials: [], material: [0, 0, 0], peakTemperature: [700, 700, 700],
                ignition: [2, 1, 3]))
        #expect(F.ignited(by: result, buildings: buildings) == [1])
        #expect(F.ignited(by: result, buildings: buildings, seeding: .either) == [0, 1])
    }

    @Test("The app's layer: draws in chunks as at once, stopped between them, its chances by the hour")
    func layer() throws {
        // Eight timber houses 9 m apart, west to east: sparks cross each gap one time in ten.
        var scene = Scenario(
            name: "Row", domainSize: SIMD3(200, 40, 20), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(2, 20, 0)))
        var ids: [UUID] = []
        for n in 0..<8 {
            let x = Float(5 + n * 19)
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 15, 0), max: SIMD3(x + 10, 25, 4.5))]))
            var timber = EnvelopeConstruction.assumed(objectID: id)
            timber.walls = .crossLaminatedTimber
            timber.roof = .crossLaminatedTimber
            scene.setEnvelopeConstruction(timber)
            ids.append(id)
        }
        var settings = F.LayerSettings()
        #expect(!settings.hasSeeds)
        settings.picked = [ids[0]]
        settings.hours = 3
        let full = try #require(
            F.layer(
                scene: scene, source: .estimate(glass: [], structure: []), settings: settings, members: 60))
        #expect(full.ids == ids && full.fixedSeeds == 1 && full.combustible == 8 && full.members == 60)
        // As the ensemble gives it, at the horizon; the seed certain from the blast.
        for n in ids.indices {
            #expect(abs(full.chance(n, at: full.horizonS) - full.ensemble.buildings[n].chance) < 1e-12)
        }
        #expect(full.chance(0, at: 0) == 1)
        // The seed burns out within the hours: then caught but no longer alight.
        let out = full.ensemble.buildings[0].burnS + 1
        #expect(full.chance(0, at: out) == 1 && full.chance(0, at: out, alight: true) == 0)
        // A neighbour's chance grows with the hours, and is never more than its neighbour's nearer the seed.
        let hours = stride(from: 0.0, through: full.horizonS, by: 600).map { full.chance(1, at: $0) }
        #expect(zip(hours, hours.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(full.chance(2, at: full.horizonS) <= full.chance(1, at: full.horizonS))
        #expect(full.step(at: 3599)?.atS == 2700)
        #expect(full.likely(at: 0) == 1)

        // In chunks of 7 the same draws, the progress told after each.
        var told: [Int] = []
        let chunked = try #require(
            F.layer(
                scene: scene, source: .estimate(glass: [], structure: []), settings: settings, members: 60,
                chunk: 7, progress: { told.append($0) }))
        #expect(chunked.ignitions == full.ignitions)
        #expect(told == [7, 14, 21, 28, 35, 42, 49, 56, 60])
        // Stopped after the second chunk: nothing.
        var asked = 0
        let stopped = F.layer(
            scene: scene, source: .estimate(glass: [], structure: []), settings: settings, members: 60,
            chunk: 7,
            stop: {
                asked += 1
                return asked > 3
            })
        #expect(stopped == nil)

        // Near the charge, and at random in a band: the seeds they give.
        var near = F.LayerSettings()
        near.nearChargeM = 5
        let nearLayer = try #require(
            F.layer(scene: scene, source: .estimate(glass: [], structure: []), settings: near, members: 4))
        #expect(nearLayer.fixedSeeds == 1 && nearLayer.chance(0, at: 0) == 1)
        var random = F.LayerSettings()
        random.randomCount = 2
        random.randomFromM = 50
        random.randomToM = 120
        let randomLayer = try #require(
            F.layer(scene: scene, source: .estimate(glass: [], structure: []), settings: random, members: 40))
        // Centres at 8 + 19 n m from the charge: 65, 84 and 103 m.
        #expect(randomLayer.randomCandidates == 3 && randomLayer.fixedSeeds == 0)
        #expect(abs((3...5).map { randomLayer.chance($0, at: 0) }.reduce(0, +) - 2) < 1e-12)
        #expect(randomLayer.chance(0, at: 0) == 0)
    }

    @Test("A run's judgement as the fire's glass and walls: each side's panes broken, heavy walls failed")
    func fromRun() throws {
        var scene = Scenario(
            name: "Run", domainSize: SIMD3(100, 100, 20), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(10, 50, 0)))
        let a = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(40, 40, 0), max: SIMD3(50, 60, 9))]), name: "A")
        let b = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(60, 40, 0), max: SIMD3(70, 60, 9))]), name: "B")
        func damage(_ id: UUID, worst: EnvelopeDamageLevel, sides: [FacadeGlass]) -> EnvelopeBuildingDamage {
            EnvelopeBuildingDamage(
                id: id, construction: .assumed(objectID: id), components: [], structuralLevels: .none...worst,
                beyondOneWay: false, panes: 0, panesBroken: 0, firstPaneBrokenAtS: nil, facadeGlass: sides,
                insidePeakPa: 0, insideImpulsePaS: 0, vented: nil)
        }
        func side(_ axis: Int, _ outward: Int, panes: Double, broken: Double) -> FacadeGlass {
            var glass = GlazingBreakage()
            glass.panes = panes
            glass.broken = broken
            return FacadeGlass(axis: axis, outward: outward, glass: glass)
        }
        let buildings = F.buildings(
            scene: scene,
            damage: [
                damage(
                    a, worst: .heavy,
                    sides: [side(0, -1, panes: 10, broken: 9), side(1, 1, panes: 4, broken: 1)]),
                damage(b, worst: .moderate, sides: [side(0, -1, panes: 0, broken: 0)]),
            ])
        #expect(buildings.map(\.id) == [a, b])
        #expect(buildings[0].brokenGlass == [0.9, 0, 0, 0.25])
        #expect(buildings[0].wallsFailed == 1)
        #expect(buildings[1].brokenGlass == [0, 0, 0, 0] && buildings[1].wallsFailed == 0)

        // Seeded from a run's surface heating: B's west face flagged.
        let thermal = F.ThermalFlags(
            receivers: [
                ThermalReceiver(position: SIMD3(60, 50, 4), normal: SIMD3(-1, 0, 0), surface: "block 1")
            ],
            heating: SurfaceHeatingResult(
                ambient: 293, materials: [], material: [0], peakTemperature: [700], ignition: [2]))
        var settings = F.LayerSettings()
        settings.thermal = .fluence
        let layer = try #require(
            F.layer(
                scene: scene, source: .run([]), thermal: thermal, settings: settings, members: 2))
        #expect(layer.thermalFlagged == 1 && layer.chance(1, at: 0) == 1 && layer.chance(0, at: 0) == 0)
    }
}
