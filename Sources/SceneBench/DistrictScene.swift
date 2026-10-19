import BlastCore
import Foundation
import simd

/// A district from open data: a map's buildings as envelopes on a DEM's ground, a hemispherical
/// charge on the ground at the centre (`DistrictLayout`). Shared by `scenebench district` and
/// `district-scene`.
struct DistrictInputs {
    var buildings: [MapBuilding]
    /// Elevations in metres above sea level, already reduced to the ground if asked.
    var ground: ElevationGrid?
    /// Building heights for untagged buildings (GHSL's), if given.
    var heights: ElevationGrid?
    /// Longitude and latitude of the centre.
    var centre: SIMD2<Double>
    var cellSize: Float
    var domainHeight: Float
    var mass: Float
    /// How far the sea lies above the terrain's zero, m: the DEM's elevations are put on this.
    var seaBase: Float = 6
    var attributions: [String] = []
    /// The footprints' cells (`--place-dx`), finer than the air's for refined runs; nil for the air's.
    var footprintCells: Float?

    static func read(_ args: [String]) throws -> DistrictInputs {
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
            "Read \(buildings.count) buildings in \(String(format: "%.2f", DistrictBenchmark.seconds(start))) s"
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
                    + String(format: "%.1f s", DistrictBenchmark.seconds(clock)))
            attributions.append(
                value("heights-credit") ?? "Building heights: \(URL(filePath: $0).lastPathComponent)")
            return grid
        }
        let centre = numbers("centre", [35.519042, 33.901425])
        return DistrictInputs(
            buildings: buildings, ground: ground, heights: heights, centre: SIMD2(centre[0], centre[1]),
            cellSize: Float(value("dx").flatMap(Double.init) ?? 4),
            domainHeight: Float(value("height").flatMap(Double.init) ?? 120),
            mass: Float(value("mass").flatMap(Double.init) ?? 500_000), attributions: attributions,
            footprintCells: value("place-dx").flatMap(Float.init))
    }

    /// The square scene of side `2 radius` about the centre, every building in it placed.
    func scene(radius: Float) throws -> (scene: Scenario, report: MapBuildingReport) {
        var layout = DistrictLayout(buildings: buildings, charge: centre, mass: mass)
        layout.ground = ground
        layout.heights = heights
        layout.seaBase = seaBase
        layout.attributions = attributions
        return try layout.scene(
            halfSide: radius, cellSize: cellSize, height: domainHeight, footprintCells: footprintCells)
    }
}

/// `scenebench district-scene --osm map.osm [--dem dem.tif [--ground-radius m] [--sea m]]
/// [--heights heights.tif] [--centre lon,lat] [--radius 1000] [--dx 4] [--height 120]
/// [--mass 500000] [--dem-credit text] [--heights-credit text] --out layout.json`: a district as
/// a layout the app opens and `BombCAD run` runs.
enum DistrictScene {
    static func run(_ args: [String]) throws {
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
