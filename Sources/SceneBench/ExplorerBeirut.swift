import BlastCore
import CryptoKit
import Foundation

/// `scenebench explorer-beirut <district-scene's inputs> --radius 1500 --out file.json`: Beirut's port
/// for the explorer (emmettl/bombcad-work#114) as one downloadable file (`ExplorerDistrict`): the
/// buildings within the radius, their heights resolved from the tags and the height grid, and the ground
/// as New District takes it (`--ground-radius 100 --sea 1`), cropped round the charge. Prints its size
/// and SHA-256, to pin in `ExplorerScene.Beirut.Release`.
enum ExplorerBeirut {
    static func run(_ args: [String]) throws {
        guard let index = args.firstIndex(of: "--out"), args.indices.contains(index + 1) else {
            throw BlastError.allocationFailed("explorer-beirut: --out file.json")
        }
        let inputs = try DistrictInputs.read(args)
        let radius = Float(SurrogateBench.value(args, "radius").flatMap(Double.init) ?? 1500)
        let layout = DistrictLayout(buildings: inputs.buildings, charge: inputs.centre, mass: inputs.mass)
        var placement = MapBuildingPlacement(origin: inputs.centre, resolution: 1)
        placement.heightGrid = inputs.heights
        let district = ExplorerDistrict(
            name: ExplorerScene.beirut.title, attributions: ExplorerScene.Beirut.attributions,
            charge: inputs.centre, radiusM: radius, buildings: layout.buildings(within: radius),
            placement: placement, ground: inputs.ground, cropM: ExplorerScene.Beirut.cropM)
        let data = try district.encoded()
        let url = URL(filePath: args[index + 1])
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print(
            "\(district.buildings.count) buildings within \(Int(radius)) m, ground "
                + "\(district.ground.map { "\($0.columns) × \($0.rows)" } ?? "none"); \(data.count) bytes, "
                + "SHA-256 \(digest), written to \(url.path)")
    }
}
