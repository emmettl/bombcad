import Foundation

// A district scene's envelope buildings as the fire spread sees them, and the ignitions that seed it
// (emmettl/bombcad-work#38; docs/fire-spread.md).

extension FireSpread {
    /// Fire load energy density by use, MJ/m²: EN 1991-1-2 Annex E Table E.4's means (dwelling 780,
    /// office 420, shopping centre 600, classroom 285, hospital room 230, hotel room 310, theatre 300,
    /// transport 100), from the CIB W14 surveys. Industry and storage have no row there and take the
    /// shopping centre's (an assumption); unoccupied buildings take transport's.
    public static func fuelLoad(_ use: BuildingUse) -> Double {
        switch use {
        case .residential: 780
        case .office: 420
        case .retail: 600
        case .education: 285
        case .health: 230
        case .hotel: 310
        case .worship: 300
        case .industrial: 600
        case .unoccupied: 100
        }
    }

    /// Whether an envelope construction's walls burn: cross-laminated timber does; concrete,
    /// masonry, blockwork and steel sheeting do not.
    public static func cladding(_ walls: EnvelopeConstruction.Kind) -> Cladding {
        walls == .crossLaminatedTimber ? .combustible : .nonCombustible
    }

    /// Whether an envelope construction's roof is fire-rated: a concrete or blockwork roof is;
    /// sheeting and timber are not.
    public static func fireRated(_ roof: EnvelopeConstruction.Kind) -> Bool {
        roof == .reinforcedConcrete || roof == .reinforcedBlockwork
    }

    /// `scene`'s envelope buildings, in `envelopeObjects`' order, each with its construction, use,
    /// glazing and fire load, the blast's broken glass by side from `glass` (the quick estimate's
    /// `SideGlass`, each side's expected share broken), and its walls' chance of failing from
    /// `structure` (`StructureChance.wallsHeavy`). `cladding` sets every building's cladding when
    /// given (as for a timber district), else each takes its walls'; an untagged building's use is
    /// `untaggedUse`.
    public static func buildings(
        scene: Scenario, glass: [FacadeLoadSurrogate.SideGlass] = [],
        structure: [FacadeLoadSurrogate.StructureChance] = [], untaggedUse: BuildingUse = .residential,
        cladding override: Cladding? = nil
    ) -> [Building] {
        var broken: [UUID: [Double]] = [:]
        var counted: [UUID: [Double]] = [:]
        for side in glass where (0...1).contains(side.axis) {
            let k = 2 * side.axis + (side.outward > 0 ? 1 : 0)
            broken[side.owner, default: [0, 0, 0, 0]][k] += side.fractionBroken
            counted[side.owner, default: [0, 0, 0, 0]][k] += 1
        }
        var walls: [UUID: Double] = [:]
        for c in structure { walls[c.owner] = c.wallsHeavy }
        return buildings(
            scene: scene, broken: broken, counted: counted, walls: walls, untaggedUse: untaggedUse,
            cladding: override)
    }

    /// `scene`'s envelope buildings as `buildings(scene:glass:…)` gives them, with the blast's glass
    /// and walls from a run's judgement in place of the quick estimate's chances: each side's
    /// share of its panes broken, and walls heavily damaged or worse failed outright.
    public static func buildings(
        scene: Scenario, damage: [EnvelopeBuildingDamage], untaggedUse: BuildingUse = .residential,
        cladding override: Cladding? = nil
    ) -> [Building] {
        var broken: [UUID: [Double]] = [:]
        var counted: [UUID: [Double]] = [:]
        var walls: [UUID: Double] = [:]
        for building in damage {
            for side in building.facadeGlass ?? [] where (0...1).contains(side.axis) {
                let k = 2 * side.axis + (side.outward > 0 ? 1 : 0)
                broken[building.id, default: [0, 0, 0, 0]][k] += side.glass.broken
                counted[building.id, default: [0, 0, 0, 0]][k] += side.glass.panes
            }
            if building.structuralLevels.upperBound >= .heavy { walls[building.id] = 1 }
        }
        return buildings(
            scene: scene, broken: broken, counted: counted, walls: walls, untaggedUse: untaggedUse,
            cladding: override)
    }

    /// The buildings, from each side's broken glass summed over what it is counted by.
    private static func buildings(
        scene: Scenario, broken: [UUID: [Double]], counted: [UUID: [Double]], walls: [UUID: Double],
        untaggedUse: BuildingUse, cladding override: Cladding?
    ) -> [Building] {
        var constructions: [UUID: EnvelopeConstruction] = [:]
        for c in scene.envelopeConstructions ?? [] { constructions[c.objectID] = c }
        return scene.envelopeObjects.compactMap { object -> Building? in
            guard let solids = object.envelope?.solids, !solids.isEmpty else { return nil }
            let construction = constructions[object.id] ?? .assumed(objectID: object.id)
            let footprint = solids.map {
                Rect(
                    min: SIMD2(Double($0.min.x), Double($0.min.y)),
                    max: SIMD2(Double($0.max.x), Double($0.max.y)))
            }
            let mix = construction.glazing
            let paneShare = mix?.panes.reduce(0.0) { $0 + Double($1.share) } ?? 0
            let windowHeight =
                paneShare > 0
                ? mix!.panes.reduce(0.0) { $0 + Double($1.heightM * $1.share) } / paneShare : 1.2
            let use = construction.use ?? untaggedUse
            var shares = [Double](repeating: 0, count: 4)
            if let b = broken[object.id], let c = counted[object.id] {
                for k in 0..<4 where c[k] > 0 { shares[k] = min(max(b[k] / c[k], 0), 1) }
            }
            return Building(
                id: object.id, footprint: footprint, base: Double(solids.map(\.min.z).min() ?? 0),
                top: Double(solids.map(\.max.z).max() ?? 0),
                cladding: override ?? cladding(construction.walls),
                fireRatedRoof: fireRated(construction.roof),
                use: use, fuelLoadMJm2: fuelLoad(use), glazedFraction: Double(mix?.glazedFraction ?? 0.15),
                windowHeightM: windowHeight, brokenGlass: shares, wallsFailed: walls[object.id] ?? 0)
        }
    }

    /// Which of a thermal result's flags make a seed.
    public enum ThermalSeeding: String, Codable, Sendable, CaseIterable {
        /// A receiver past the short-pulse ignition fluence, the test threshold.
        case fluence
        /// Past either threshold: the fluence, or the surface temperature at piloted ignition under
        /// steady heating, which a short pulse passes long before wood gives off enough to burn.
        case either
    }

    /// The buildings a thermal result's surface heating flags as ignited (docs/surface-heating.md,
    /// "Ignition, illustrative"): those on whose faces or roofs a flagged receiver lies, by position.
    public static func ignited(
        by result: ThermalResult, buildings: [Building], seeding: ThermalSeeding = .fluence
    ) -> [Int] {
        guard let heating = result.heating else { return [] }
        return ignited(receivers: result.receivers, heating: heating, buildings: buildings, seeding: seeding)
    }

    /// The same, from a run's receivers and their surface heating as it stands.
    public static func ignited(
        receivers: [ThermalReceiver], heating: SurfaceHeatingResult, buildings: [Building],
        seeding: ThermalSeeding = .fluence
    ) -> [Int] {
        let wanted: UInt8 = seeding == .fluence ? 2 : 3
        var hit = Set<Int>()
        let tolerance = 0.05
        for (n, receiver) in receivers.enumerated()
        where heating.ignition.indices.contains(n) && heating.ignition[n] & wanted != 0 {
            let p = SIMD3(
                Double(receiver.position.x), Double(receiver.position.y), Double(receiver.position.z))
            for (k, b) in buildings.enumerated() where !hit.contains(k) {
                guard p.z >= b.base - tolerance, p.z <= b.top + tolerance else { continue }
                if b.footprint.contains(where: {
                    p.x >= $0.min.x - tolerance && p.x <= $0.max.x + tolerance && p.y >= $0.min.y - tolerance
                        && p.y <= $0.max.y + tolerance
                }) {
                    hit.insert(k)
                    break
                }
            }
        }
        return hit.sorted()
    }

    /// The buildings whose footprint comes within `radius` m of `point` (scene metres, x east, y
    /// north), nearest first.
    public static func buildings(near point: SIMD2<Double>, radius: Double, in buildings: [Building]) -> [Int]
    {
        buildings.indices.compactMap { k -> (Int, Double)? in
            let d =
                buildings[k].footprint.map { r -> Double in
                    let dx = max(r.min.x - point.x, 0, point.x - r.max.x)
                    let dy = max(r.min.y - point.y, 0, point.y - r.max.y)
                    return (dx * dx + dy * dy).squareRoot()
                }.min() ?? .infinity
            return d <= radius ? (k, d) : nil
        }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
    }
}
