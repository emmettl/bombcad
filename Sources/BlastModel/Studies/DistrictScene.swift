import Foundation
import simd

/// A district from open data: a map's buildings as envelopes on a DEM's ground, a hemispherical
/// charge on the ground at the centre (`DistrictLayout`). Shared by `scenebench district` and
/// `district-scene`.
package struct DistrictInputs {
    package var buildings: [MapBuilding]
    /// Elevations in metres above sea level, already reduced to the ground if asked.
    package var ground: ElevationGrid?
    /// Building heights for untagged buildings (GHSL's), if given.
    package var heights: ElevationGrid?
    /// Longitude and latitude of the centre.
    package var centre: SIMD2<Double>
    package var cellSize: Float
    var domainHeight: Float
    package var mass: Float
    /// How far the sea lies above the terrain's zero, m: the DEM's elevations are put on this.
    package var seaBase: Float = 6
    package var attributions: [String] = []
    /// The footprints' cells (`--place-dx`), finer than the air's for refined runs; nil for the air's.
    var footprintCells: Float?
    /// How far east and north of the charge the square's centre lies (`--box-offset east,north`, m):
    /// one sector of the district in a smaller box, for a study (emmettl/bombcad-work#108); none
    /// otherwise.
    package var boxOffset: SIMD2<Float> = .zero
    /// Keep the buildings' outlines on their envelopes (`DistrictLayout.keepsOutlines`): where the
    /// bench's façades face as their outlines (`SurrogateBench.incidence`, `--incidence outline`
    /// or terms fitted so; emmettl/bombcad-work#109). Off, the scene is as before, to the byte.
    package var keepsOutlines = false
    /// Read the map's wood and timber tags as timber constructions (`DistrictLayout.readsWoodTags`),
    /// the default since 31 October 2026; `--wood-tags ignore` leaves them unread, as before, to
    /// reproduce earlier estimates.
    package var readsWoodTags = true

    package static func read(_ args: [String]) throws -> DistrictInputs {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func numbers(_ name: String, _ fallback: [Double]) -> [Double] {
            value(name).map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
        }
        guard let osm = value("osm") else { throw BlastError.allocationFailed("--osm map.osm") }
        let start = ContinuousClock.now
        let buildings = try MapBuilding.read(contentsOf: URL(filePath: osm))
        print(
            "Read \(buildings.count) buildings in \(String(format: "%.2f", StudyClock.seconds(start))) s"
        )
        var attributions: [String] = []
        let ground = try value("dem").map {
            let dem = try ElevationGrid(contentsOf: URL(filePath: $0))
            attributions.append(value("dem-credit") ?? "Elevations: \(URL(filePath: $0).lastPathComponent)")
            return DistrictLayout.ground(
                dem, openingM: value("ground-radius").flatMap(Double.init) ?? 0,
                seaM: Float(value("sea").flatMap(Double.init) ?? 0))
        }
        let heights = try value("heights").map {
            let clock = ContinuousClock.now
            let grid = try ElevationGrid(contentsOf: URL(filePath: $0))
            print(
                "Read the height grid, \(grid.columns) × \(grid.rows), in "
                    + String(format: "%.1f s", StudyClock.seconds(clock)))
            attributions.append(
                value("heights-credit") ?? "Building heights: \(URL(filePath: $0).lastPathComponent)")
            return grid
        }
        let centre = numbers("centre", [35.519042, 33.901425])
        var inputs = DistrictInputs(
            buildings: buildings, ground: ground, heights: heights, centre: SIMD2(centre[0], centre[1]),
            cellSize: Float(value("dx").flatMap(Double.init) ?? 4),
            domainHeight: Float(value("height").flatMap(Double.init) ?? 120),
            mass: Float(value("mass").flatMap(Double.init) ?? 500_000), attributions: attributions,
            footprintCells: value("place-dx").flatMap(Float.init))
        inputs.keepsOutlines = SurrogateBench.incidence(args) == .outline
        switch value("wood-tags") {
        case nil, "timber": break
        case "ignore": inputs.readsWoodTags = false
        case let other?: throw BlastError.allocationFailed("--wood-tags timber|ignore, not \(other)")
        }
        let offset = numbers("box-offset", [0, 0])
        if offset.count == 2 { inputs.boxOffset = SIMD2(Float(offset[0]), Float(offset[1])) }
        if let degrees = value("turn").flatMap(Double.init), degrees != 0 {
            let reach =
                (value("radius").flatMap(Double.init) ?? 1000)
                + Double(max(abs(inputs.boxOffset.x), abs(inputs.boxOffset.y)))
            inputs = inputs.turned(degrees: degrees, reach: reach)
            print(String(format: "Turned the map %g° anticlockwise about the charge", degrees))
        }
        return inputs
    }

    /// The district turned `degrees` anticlockwise about the charge, for a study of the solver's
    /// grid (`--turn`, emmettl/bombcad-work#108): the buildings' outlines, and the ground over a
    /// square of half side `reach` (plus a margin), turned in the map, so that the same city meets
    /// the cells at another angle. A building's height from the heights grid is taken where it
    /// stands before the turn, so that every building keeps its height; the ground is resampled
    /// at an eighth of the DEM's spacing, bilinear, so that the terrain the scene samples is the
    /// untouched DEM's to well under its own resolution.
    package func turned(degrees: Double, reach: Double) -> DistrictInputs {
        let angle = degrees * .pi / 180
        let (c, s) = (cos(angle), sin(angle))
        let east = ElevationGrid.metresPerDegree * cos(centre.y * .pi / 180)
        let scale = SIMD2(east, ElevationGrid.metresPerDegree)
        func turn(_ lonLat: SIMD2<Double>, by sign: Double) -> SIMD2<Double> {
            let q = (lonLat - centre) * scale
            return centre + SIMD2(c * q.x - sign * s * q.y, sign * s * q.x + c * q.y) / scale
        }
        var copy = self
        copy.buildings = buildings.map { building in
            var b = building
            if !(b.height.map { $0 > 0 } ?? false), !(b.levels.map { $0 > 0 } ?? false), let grid = heights,
                let h = MapBuildingPlacement.gridHeight(grid, building), h > 0
            {
                b.height = h
            }
            b.rings = b.rings.map { $0.map { turn($0, by: 1) } }
            return b
        }
        copy.heights = nil
        if let ground, ground.units == .degrees {
            let step = ground.step / 8
            let half = (reach + 64) * SIMD2(1, 1) / scale
            let southWest = centre - half
            let columns = Int((2 * half.x / step.x).rounded(.up)) + 1
            let rows = Int((2 * half.y / step.y).rounded(.up)) + 1
            var elevations = [Float](repeating: .nan, count: columns * rows)
            for j in 0..<rows {
                for i in 0..<columns {
                    let point = southWest + SIMD2(Double(i), Double(j)) * step
                    elevations[i + columns * j] = ground.elevation(at: turn(point, by: -1)) ?? .nan
                }
            }
            copy.ground = ElevationGrid(
                columns: columns, rows: rows, southWest: southWest, step: step, units: .degrees,
                elevations: elevations)
        }
        return copy
    }

    /// The square scene of side `2 radius` about the centre (its own centre `boxOffset` from it),
    /// every building in it placed.
    package func scene(radius: Float) throws -> (scene: Scenario, report: MapBuildingReport) {
        var layout = DistrictLayout(buildings: buildings, charge: centre, mass: mass)
        layout.ground = ground
        layout.heights = heights
        layout.seaBase = seaBase
        layout.attributions = attributions
        layout.keepsOutlines = keepsOutlines
        layout.readsWoodTags = readsWoodTags
        return try layout.scene(
            halfSide: radius, cellSize: cellSize, height: domainHeight, footprintCells: footprintCells,
            offset: boxOffset)
    }
}

/// `scenebench district-scene --osm map.osm [--dem dem.tif [--ground-radius m] [--sea m]]
/// [--heights heights.tif] [--centre lon,lat] [--radius 1000] [--dx 4] [--height 120]
/// [--mass 500000] [--dem-credit text] [--heights-credit text] [--turn degrees] --out layout.json`: a
/// district as a layout the app opens and `BombCAD run` runs. `--turn`, read by every bench that
/// lays out a district, turns the map about the charge (`DistrictInputs.turned`).
package enum DistrictScene {
    package static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let out = value("out") else { throw BlastError.allocationFailed("--out layout.json") }
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1000)
        var (scene, report) = try inputs.scene(radius: radius)
        if let name = value("name") { scene.name = name }
        print(report.summary)
        if let terrain = scene.terrain {
            print(
                String(
                    format: "Terrain %d × %d nodes, %.1f–%.1f m; charge at %.1f m",
                    terrain.columns, terrain.rows, terrain.heights.min() ?? 0, terrain.highest,
                    scene.charge.position.z))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(scene).write(to: URL(filePath: out))
        print("Wrote \(out)")
    }
}
