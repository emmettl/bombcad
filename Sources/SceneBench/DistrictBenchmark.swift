import BlastCore
import Foundation
import Metal
import simd

/// `scenebench district --osm map.osm [--dem dem.tif] --centre lon,lat [--radii 250,500,1000]
/// [--dx 4] [--height 120] [--mass 500000] [--steps 40] [--out file.json]`: what a district of map
/// buildings costs as it grows. For each radius, a square scene of twice it about the centre,
/// the map's buildings in it as envelopes on the DEM's terrain (sea level as the datum), a
/// hemispherical charge on the ground at the centre; the time to place the buildings, build the
/// solver, configure the surface recorder and the components' histories, the memory each takes,
/// and the time a step takes with the surface recorder alone and with the histories too.
enum DistrictBenchmark {
    struct Row: Codable {
        var radiusM: Float
        var cellSizeM: Float
        var cells: Int
        var buildings: Int
        var boxes: Int
        var placeS: Double
        var solverS: Double
        var exposureS: Double
        var faces: Int
        var componentsS: Double
        var components: Int
        var solverBytes: Int
        var exposureBytes: Int
        var historyBytes: Int
        var stepS: Double
        var stepWithHistoriesS: Double
    }

    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let took = start.duration(to: .now)
        return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func numbers(_ name: String, _ fallback: [Double]) -> [Double] {
            value(name).map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
        }
        guard let osm = value("osm"), let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("--osm and a Metal device")
        }
        let centre = numbers("centre", [35.519042, 33.901425])
        let dx = Float(value("dx").flatMap(Double.init) ?? 4)
        let height = Float(value("height").flatMap(Double.init) ?? 120)
        let mass = Float(value("mass").flatMap(Double.init) ?? 500_000)
        let steps = value("steps").flatMap(Int.init) ?? 40
        let start = ContinuousClock.now
        let buildings = try MapBuilding.read(contentsOf: URL(filePath: osm))
        print("Read \(buildings.count) buildings in \(String(format: "%.2f", seconds(start))) s")
        let dem = try value("dem").map { try ElevationGrid(contentsOf: URL(filePath: $0)) }
        var rows: [Row] = []
        for radius in numbers("radii", [250, 500, 1000]).map(Float.init) {
            // The scene's south-west corner, in degrees: local metres by the same equirectangular
            // mapping the placement and the crop use.
            let metresPerDegree = 6_371_008.8 * Double.pi / 180
            let corner = SIMD2(
                centre[0] - Double(radius) / (metresPerDegree * cos(centre[1] * .pi / 180)),
                centre[1] - Double(radius) / metresPerDegree)
            var scene = Scenario(
                name: "District \(Int(radius)) m", domainSize: SIMD3(2 * radius, 2 * radius, height),
                boxes: [],
                charge: Charge(mass: mass, position: SIMD3(radius, radius, 0)))
            if let dem {
                scene.terrain = try dem.terrain(
                    origin: corner, size: SIMD2(2 * radius, 2 * radius), spacing: dx, datum: 0, name: "DEM"
                ).terrain
            }
            var clock = ContinuousClock.now
            let report = try scene.addMapBuildings(
                buildings, placement: MapBuildingPlacement(origin: corner, resolution: dx))
            let place = seconds(clock)
            let boxes = scene.envelopeObjects.reduce(0) { $0 + $1.envelope!.blocks.count }
            print(
                "r \(Int(radius)) m: \(report.placed.count) buildings, \(boxes) boxes, placed in "
                    + String(format: "%.2f s", place))
            var row = Row(
                radiusM: radius, cellSizeM: dx, cells: 0, buildings: report.placed.count, boxes: boxes,
                placeS: place,
                solverS: 0, exposureS: 0, faces: 0, componentsS: 0, components: 0, solverBytes: 0,
                exposureBytes: 0,
                historyBytes: 0, stepS: 0, stepWithHistoriesS: 0)
            for histories in [false, true] {
                clock = .now
                let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx)
                if !histories {
                    row.solverS = seconds(clock)
                    row.cells = solver.grid.cellCount
                    row.solverBytes = solver.memoryFootprint
                }
                clock = .now
                try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                if !histories {
                    row.exposureS = seconds(clock)
                    row.exposureBytes = solver.memoryFootprint - row.solverBytes
                    row.faces = solver.envelopeExposureSnapshot()?.reduce(0) { $0 + $1.surfaces.count } ?? 0
                }
                if histories {
                    let before = solver.memoryFootprint
                    clock = .now
                    try solver.configureEnvelopeComponents(
                        objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 5))
                    row.componentsS = seconds(clock)
                    row.components = solver.envelopeComponents()?.count ?? 0
                    row.historyBytes = solver.memoryFootprint - before
                }
                // A few steps to warm up, then the timed ones.
                _ = solver.advance(steps: 4)
                clock = .now
                _ = solver.advance(steps: steps)
                let perStep = seconds(clock) / Double(steps)
                if histories { row.stepWithHistoriesS = perStep } else { row.stepS = perStep }
            }
            print(
                String(
                    format:
                        "  %d cells, solver %.1f s, surfaces %.1f s (%d faces), components %.1f s (%d), memory %.0f / %.1f / %.1f MB, step %.1f / %.1f ms",
                    row.cells, row.solverS, row.exposureS, row.faces, row.componentsS, row.components,
                    Double(row.solverBytes) / 1e6, Double(row.exposureBytes) / 1e6,
                    Double(row.historyBytes) / 1e6,
                    row.stepS * 1000, row.stepWithHistoriesS * 1000))
            rows.append(row)
            if let out = value("out") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(filePath: out))
            }
        }
    }
}
