import Foundation
import simd

/// A district as the explorer downloads it (emmettl/bombcad-work#114): its buildings with their
/// heights resolved and its ground, cropped round the charge, in one JSON file that File ▸ New
/// District's layout reads as it reads a map. Beirut's port is the one there is (`ExplorerScene.Beirut`).
public struct ExplorerDistrict: Codable, Sendable, Equatable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missing
        case version(Int)

        public var description: String {
            switch self {
            case .missing: "the scene's file has not been downloaded"
            case .version(let v): "the scene's file is version \(v), which this app does not read"
            }
        }
    }

    public static let version = 1

    public struct Building: Codable, Sendable, Equatable {
        public var id: String
        public var name: String?
        public var kind: String
        /// Rings of (longitude, latitude), the first the outline, any others its courtyards.
        public var rings: [[[Double]]]
        /// Metres: its tags', or the height grid's where they said none.
        public var height: Float
        public var minHeight: Float?
        public var material: String?
        public var use: String?
    }

    public struct Ground: Codable, Sendable, Equatable {
        public var columns: Int
        public var rows: Int
        public var southWest: [Double]
        public var step: [Double]
        /// Metres, south row first; the ground as New District takes it (opened, the sea flat).
        public var elevations: [Float]
    }

    public var version = Self.version
    public var name: String
    /// Where the data came from, and under what licence, for the scene's attributions.
    public var attributions: [String]
    /// The charge's longitude and latitude, and the radius the buildings were taken within.
    public var charge: [Double]
    public var radiusM: Float
    public var buildings: [Building]
    public var ground: Ground?

    /// `buildings` within `radiusM` of `charge`, their heights resolved by `placement` (the tags, then
    /// its height grid), and `ground` cropped to `cropM` round the charge.
    public init(
        name: String, attributions: [String], charge: SIMD2<Double>, radiusM: Float, buildings: [MapBuilding],
        placement: MapBuildingPlacement, ground: ElevationGrid?, cropM: Double
    ) {
        self.name = name
        self.attributions = attributions
        self.charge = [charge.x, charge.y]
        self.radiusM = radiusM
        self.buildings = buildings.map { b in
            Building(
                id: b.id, name: b.name, kind: b.kind, rings: b.rings.map { $0.map { [$0.x, $0.y] } },
                height: placement.heights(b).top, minHeight: b.minHeight, material: b.material, use: b.use)
        }
        self.ground = ground.map { Self.crop($0, round: charge, by: cropM) }
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard version == Self.version else { throw Failure.version(version) }
    }

    /// The file's bytes: sorted keys, so the same district always writes the same file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func mapBuildings() -> [MapBuilding] {
        buildings.map { b in
            MapBuilding(
                id: b.id, name: b.name, kind: b.kind,
                rings: b.rings.map { $0.map { SIMD2($0[0], $0[1]) } }, height: b.height,
                minHeight: b.minHeight,
                material: b.material, use: b.use)
        }
    }

    public func groundGrid() -> ElevationGrid? {
        ground.map {
            ElevationGrid(
                columns: $0.columns, rows: $0.rows, southWest: SIMD2($0.southWest[0], $0.southWest[1]),
                step: SIMD2($0.step[0], $0.step[1]), units: .degrees, elevations: $0.elevations)
        }
    }

    /// `grid` (in degrees) cut to the cells within `metres` of `centre` each way.
    static func crop(_ grid: ElevationGrid, round centre: SIMD2<Double>, by metres: Double) -> Ground {
        let east = ElevationGrid.metresPerDegree * cos(centre.y * .pi / 180)
        let half = SIMD2(metres / east, metres / ElevationGrid.metresPerDegree)
        let low = SIMD2<Int>(((centre - half - grid.southWest) / grid.step).rounded(.down))
        let high = SIMD2<Int>(((centre + half - grid.southWest) / grid.step).rounded(.up))
        let i0 = max(0, low.x)
        let j0 = max(0, low.y)
        let i1 = min(grid.columns - 1, high.x)
        let j1 = min(grid.rows - 1, high.y)
        var values: [Float] = []
        for j in j0...j1 {
            for i in i0...i1 { values.append(grid.elevations[i + grid.columns * j]) }
        }
        let corner = grid.southWest + SIMD2(Double(i0), Double(j0)) * grid.step
        return Ground(
            columns: i1 - i0 + 1, rows: j1 - j0 + 1, southWest: [corner.x, corner.y],
            step: [grid.step.x, grid.step.y],
            elevations: values)
    }
}

extension ExplorerScene {
    /// Beirut's port for the explorer: within 1.5 km of where the charge went off, downloaded once.
    public enum Beirut {
        /// The charge's place, as Beirut's district runs take it (docs/beirut-2020.md).
        public static let charge = SIMD2(35.519042, 33.901425)
        public static let radiusM: Float = 1_500
        /// The ground kept round the charge, m each way: the buildings' reach, their open faces'
        /// clearance at 0.5 kt (4 m/kg^(1/3)) and a margin.
        public static let cropM = 2_100.0
        public static let fileName = "explorer-beirut-port-1500m-1.json"

        public static let attributions = [
            "Buildings © OpenStreetMap contributors, ODbL 1.0 (extract of 17 October 2026)",
            "Building heights: GHSL GHS-BUILT-H R2023A (2018), © European Union, CC BY 4.0",
            "Elevations: Copernicus DEM GLO-30, © DLR e.V. 2010–2014 and © Airbus Defence and Space GmbH "
                + "2014–2018, provided under COPERNICUS by the European Union and ESA",
        ]

        public enum Release {
            public static let tag = "explorer-beirut-1"
            /// Built on 2 November 2026 by `scenebench explorer-beirut` from Beirut's inputs
            /// (docs/explorer.md, "Stage 3"): 2,887 buildings and the ground, 166 × 138 cells.
            public static let asset = LearnedField.Release.Asset(
                file: fileName, bytes: 837_346,
                sha256: "95daab79ae09ae86a4769d6f33907b563c0c174f80f6ee941beaca467283e842", tag: tag)

            /// What the download is, in the words the app asks with.
            public static var offer: String {
                "Beirut's port is a real place, from map data: its buildings, their heights and its ground, "
                    + LearnedField.Release.megabytes(asset.bytes) + ", downloaded once from the repository's "
                    + "\(tag) release (" + asset.url.absoluteString + ") and kept in Application Support."
            }
        }
    }
}
