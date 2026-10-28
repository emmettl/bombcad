import Foundation
import simd

/// A district from files the user supplies: a map's buildings as envelopes, on a terrain's ground
/// if one is given, around a hemispherical charge on the ground at a longitude and latitude. The
/// app's File ▸ New District and `scenebench district-scene` both build their scenes with it
/// (docs/using-the-app.md, "A district from a map"; docs/beirut-2020.md for what it gets right).
public struct DistrictLayout: Sendable {
    public var buildings: [MapBuilding]
    /// Elevations in metres above sea level, already reduced to the ground if asked (`ground`).
    public var ground: ElevationGrid?
    /// Building heights for untagged buildings (GHSL's average net building height), if given.
    public var heights: ElevationGrid?
    /// The charge's longitude and latitude: the scene's centre.
    public var charge: SIMD2<Double>
    /// TNT, kg.
    public var mass: Float
    /// How far the sea lies above the terrain's zero, m: the ground's elevations are put on it.
    public var seaBase: Float = 6
    /// Credits for the files, added to the map's.
    public var attributions: [String] = []
    /// Clear the building over the charge (`MapBuildingPlacement.clearsChargeBuilding`).
    public var clearsChargeBuilding = true
    /// Keep the buildings' outlines on their envelopes (`MapBuildingPlacement.keepsOutlines`), for
    /// the façade surrogate's incidence from outlines (emmettl/bombcad-work#109). Off, the scene is
    /// as before, to the byte.
    public var keepsOutlines = false

    public init(buildings: [MapBuilding], charge: SIMD2<Double>, mass: Float) {
        self.buildings = buildings
        self.charge = charge
        self.mass = mass
    }

    /// `dem`'s elevations with those within `seaM` metres of sea level (or below it) put at it,
    /// and the rest opened over `openingM` metres (0 to keep them as they are): a surface model's
    /// roofs and trees taken down to the ground under them. The sea is left out of the opening,
    /// which would otherwise pull the quays down to it.
    public static func ground(_ dem: ElevationGrid, openingM: Double, seaM: Float) -> ElevationGrid {
        let metres = dem.units == .degrees ? dem.step.y * ElevationGrid.metresPerDegree : dem.step.y
        var land = dem
        let sea = dem.elevations.indices.filter { dem.elevations[$0] < seaM }
        for n in sea { land.elevations[n] = .nan }
        var ground = land.opened(radius: Int((openingM / metres).rounded()))
        for n in sea { ground.elevations[n] = 0 }
        return ground
    }

    /// Local metres (x east, y north) of a longitude and latitude from the charge, by the same
    /// equirectangular mapping the placement uses.
    public func offset(_ lonLat: SIMD2<Double>) -> SIMD2<Double> {
        MapBuildingPlacement(origin: charge, resolution: 1).position(lonLat)
    }

    /// The centre of a building's footprint (its outer ring's vertices), metres from the charge.
    public func centre(of building: MapBuilding) -> SIMD2<Double>? {
        guard let ring = building.rings.first, !ring.isEmpty else { return nil }
        return offset(ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count))
    }

    /// The farthest building's centre from the charge, m.
    public var reach: Float {
        Float(buildings.compactMap { centre(of: $0).map(simd_length) }.max() ?? 0)
    }

    /// The buildings whose footprint's centre lies within `radius` metres of the charge.
    public func buildings(within radius: Float) -> [MapBuilding] {
        buildings.filter { building in centre(of: building).map { simd_length($0) <= Double(radius) } ?? false
        }
    }

    /// The clearance the open faces want from the charge and the buildings, m: 4 m/kg^(1/3)
    /// (`Scenario.structureFaceClearance`).
    public var faceClearance: Float { Scenario.structureFaceClearance * cbrt(max(mass, 0)) }

    /// The square domain's half side for buildings within `radius`, to a multiple of `cellSize`:
    /// the side faces `faceClearance` beyond the outermost building, or at `radius` itself when
    /// `clearFaces` is off.
    public func halfSide(radius: Float, cellSize: Float, clearFaces: Bool = true) -> Float {
        ((radius + (clearFaces ? faceClearance : 0)) / cellSize).rounded(.up) * cellSize
    }

    /// The domain's top for a charge at `chargeZ` and roofs up to `highestRoof`, to a multiple of
    /// `cellSize`: `faceClearance` above the charge, and at least half of it above the highest
    /// roof or ground. On Beirut's 0.5 kt (docs/beirut-2020.md) a top twice as high gave the same glass and
    /// structure in every band, and a top half as high did not.
    ///
    /// With `radius`, the buildings' reach, at least a fifth of it (`topRadiusParts`) above the highest
    /// ground, `highestGround` (emmettl/bombcad-work#99, adopted 25 October 2026): an open top drains
    /// the far façades' loads from about five times its clearance over the ground, which on Beirut
    /// read the glass low beyond 1.5 km (docs/hybrid-far-field.md, "New District's top").
    public func top(
        chargeZ: Float, highestRoof: Float, cellSize: Float, radius: Float? = nil, highestGround: Float = 0
    ) -> Float {
        var wanted = max(chargeZ + faceClearance, highestRoof + faceClearance / 2, chargeZ + 2 * cellSize)
        if let radius { wanted = max(wanted, highestGround + radius / Self.topRadiusParts) }
        return (wanted / cellSize).rounded(.up) * cellSize
    }

    /// The parts of the buildings' reach of which the top keeps one above the highest ground (`top`).
    public static let topRadiusParts: Float = 5

    /// The height above the ground over which a refined district's air need not be refined: all
    /// but the tallest 2% of the buildings within `radius`, by their tags or the heights grid, and
    /// four of the air's cells over them for the shock's top. On Beirut's 1 km box, 72 m on 8 m
    /// cells (40 m and 32), which kept the glass and the arrivals of 4 m cells and cost a third of
    /// a run refined to the domain's top (docs/beirut-2020.md).
    public func refinementCeiling(radius: Float, cellSize: Float) -> Float {
        var placement = MapBuildingPlacement(origin: charge, resolution: cellSize)
        placement.heightGrid = heights
        let tall = buildings(within: radius).map { building -> Float in
            let h = placement.heights(building)
            return h.top - h.bottom
        }.sorted()
        let most = tall.isEmpty ? 0 : tall[min(tall.count - 1, Int(0.98 * Double(tall.count)))]
        return most + 4 * cellSize
    }

    /// The run's length for buildings within `radius`: the time sound takes to reach the farthest,
    /// plus `window` for its load, to a tenth of a second: 7.8 s for Beirut's 2.5 km (it ran 8 s).
    public static func duration(radius: Float, window: Double = 0.5) -> Double {
        ((Double(radius) / 343 + window) * 10).rounded(.up) / 10
    }

    /// The scene: a square of half side `halfSide` about the charge on `cellSize` cells (its
    /// footprints on `footprintCells` if given), with the
    /// buildings within `radius` (all of them, nil) placed as envelopes with their constructions
    /// and glazing, on the ground's terrain if there is one, and the top at `height` (nil: by the
    /// open-face rule, `top`, kept clear over `topRadius`, or `radius` if that is nil; neither, no
    /// floor). With `offset`, the square's centre lies that far east and north of the charge, for a
    /// study of one sector (`--box-offset`, emmettl/bombcad-work#108).
    public func scene(
        halfSide: Float, cellSize: Float, radius: Float? = nil, height: Float? = nil, name: String? = nil,
        footprintCells: Float? = nil, topRadius: Float? = nil, offset: SIMD2<Float> = .zero
    ) throws -> (scene: Scenario, report: MapBuildingReport) {
        let corner = SIMD2(
            charge.x - Double(halfSide - offset.x)
                / (ElevationGrid.metresPerDegree * cos(charge.y * .pi / 180)),
            charge.y - Double(halfSide - offset.y) / ElevationGrid.metresPerDegree)
        let at = SIMD2(halfSide, halfSide) - offset
        let placed = radius.map { buildings(within: $0) } ?? buildings
        var scene = Scenario(
            name: name ?? "District \(Int(halfSide)) m",
            domainSize: SIMD3(2 * halfSide, 2 * halfSide, height ?? 0), boxes: [],
            charge: Charge(mass: mass, position: SIMD3(at.x, at.y, 0)))
        if let ground {
            scene.terrain = try ground.terrain(
                origin: corner, size: SIMD2(2 * halfSide, 2 * halfSide), spacing: cellSize, datum: 0,
                base: seaBase, name: "DEM"
            ).terrain
            // On the ground at the centre.
            scene.charge.position.z = scene.terrain!.height(at: at)
        }
        if height == nil {
            // A top that holds any building while they are placed, brought down to the rule after.
            let tallest = placed.compactMap(\.height).max() ?? 0
            scene.domainSize.z = (scene.terrain?.highest ?? 0) + max(4 * faceClearance, 1_000, 2 * tallest)
        }
        // The footprints on `footprintCells` (a refined air's finest cells, so that its fine
        // outlines are the buildings' own), or the air's cells.
        var placement = MapBuildingPlacement(origin: corner, resolution: footprintCells ?? cellSize)
        placement.heightGrid = heights
        placement.clearsChargeBuilding = clearsChargeBuilding
        placement.keepsOutlines = keepsOutlines
        let report = try scene.addMapBuildings(placed, placement: placement)
        scene.attributions = (scene.attributions ?? []) + attributions
        if height == nil {
            let roofs = max(report.placed.map(\.top).max() ?? 0, scene.terrain?.highest ?? 0)
            scene.domainSize.z = top(
                chargeZ: scene.charge.position.z, highestRoof: roofs, cellSize: cellSize,
                radius: topRadius ?? radius, highestGround: scene.terrain?.highest ?? 0)
        }
        return (scene, report)
    }
}
