import BlastCore
import Foundation
import simd

/// A district from open data: a map's buildings as envelopes on a DEM's ground, a hemispherical
/// charge on the ground at the centre. Shared by `scenebench district` and `district-scene`.
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

    /// `--dem`'s elevations with those within `--sea` metres of sea level (or below it) put at it,
    /// and the rest opened over `--ground-radius` metres (0 to keep the surface model): the sea is
    /// left out of the opening, which would otherwise pull the quays down to it.
    static func ground(_ dem: ElevationGrid, openingM: Double, seaM: Float) -> ElevationGrid {
        let metres =
            dem.units == .degrees
            ? dem.step.y * ElevationGrid.metresPerDegree : dem.step.y
        var land = dem
        let sea = dem.elevations.indices.filter { dem.elevations[$0] < seaM }
        for n in sea { land.elevations[n] = .nan }
        var ground = land.opened(radius: Int((openingM / metres).rounded()))
        for n in sea { ground.elevations[n] = 0 }
        return ground
    }

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
            return Self.ground(
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
            mass: Float(value("mass").flatMap(Double.init) ?? 500_000), attributions: attributions)
    }

    /// The square scene of side `2 radius` about the centre.
    func scene(radius: Float) throws -> (scene: Scenario, report: MapBuildingReport) {
        // The scene's south-west corner, in degrees: local metres by the same equirectangular
        // mapping the placement and the crop use.
        let metresPerDegree = ElevationGrid.metresPerDegree
        let corner = SIMD2(
            centre.x - Double(radius) / (metresPerDegree * cos(centre.y * .pi / 180)),
            centre.y - Double(radius) / metresPerDegree)
        var scene = Scenario(
            name: "District \(Int(radius)) m", domainSize: SIMD3(2 * radius, 2 * radius, domainHeight),
            boxes: [],
            charge: Charge(mass: mass, position: SIMD3(radius, radius, 0)))
        if let ground {
            scene.terrain = try ground.terrain(
                origin: corner, size: SIMD2(2 * radius, 2 * radius), spacing: cellSize, datum: 0,
                base: seaBase,
                name: "DEM"
            ).terrain
            // On the ground at the centre.
            scene.charge.position.z = scene.terrain!.height(at: SIMD2(radius, radius))
        }
        var placement = MapBuildingPlacement(origin: corner, resolution: cellSize)
        placement.heightGrid = heights
        let report = try scene.addMapBuildings(buildings, placement: placement)
        scene.attributions = (scene.attributions ?? []) + attributions
        return (scene, report)
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
