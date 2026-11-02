import Foundation

/// `blastmodel explorer-scene [square] --out folder`: writes an explorer scene
/// (emmettl/bombcad-work#114) as `district.osm`, for the benches to judge it as a map
/// (`scenebench drag-time --osm folder/district.osm --centre 0,0 …`), and prints its buildings,
/// centre, cells and named places.
package enum ExplorerSceneStudy {
    package static func run(_ args: [String]) throws {
        let name = args.first { !$0.hasPrefix("--") } ?? ExplorerScene.square.rawValue
        guard let scene = ExplorerScene(rawValue: name) else {
            throw BlastError.allocationFailed(
                "explorer-scene: no scene \(name); \(ExplorerScene.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        guard let index = args.firstIndex(of: "--out"), args.indices.contains(index + 1) else {
            throw BlastError.allocationFailed("explorer-scene: --out folder")
        }
        let folder = URL(filePath: args[index + 1], directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "district.osm")
        try scene.osm().write(to: file, atomically: true, encoding: .utf8)
        print(
            "\(scene.title): \(scene.buildings().count) buildings within \(Int(scene.radiusM)) m, centre "
                + "\(scene.charge.x),\(scene.charge.y), \(scene.cellSizeM) m cells, \(scene.defaultMassKg) kg; "
                + "written to \(file.path)")
        for place in scene.places {
            print(
                String(format: "  %@: %.0f m east, %.0f m north", place.name, place.offset.x, place.offset.y))
        }
    }
}
