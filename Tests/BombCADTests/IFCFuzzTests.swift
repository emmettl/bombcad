import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// The app's IFC importer run on a whole folder of inputs: the replay half of
/// Scripts/fuzz/fuzz-importers.py for its IFC kinds (macOS only, as the importer is), as
/// `ImporterFuzzReplayTests` is for BlastModel's readers. It runs only when `BLASTMODEL_FUZZ_DIR`
/// names the folder, and takes the same `BLASTMODEL_FUZZ_OUT`, `_PROGRESS` and `_SKIP`.
///
/// - `.ifc`: the STEP file as BombCAD reads it itself (the products in no spatial structure,
///   the length unit, the material layers, the storeys, the profiles' shared segments), and,
///   when `BOMBCAD_FUZZ_CONVERTER` names IfcConvert, the whole import through it: prepared,
///   converted with every supported element chosen, its reinforcement attached, and meshed as
///   a structure of shells and beams.
/// - `.ifcxml`: IfcConvert's metadata as the importer reads it (inventory, materials,
///   reinforcement properties).
/// - `.ifcobj`: IfcConvert's geometry as the importer reads it, each group's GlobalId taken as a
///   chosen wall, and as the reinforcement reader reads it.
enum IFCFuzz {
    static func exercise(_ data: Data, kind: String, converter: URL?) async -> String {
        do {
            switch kind {
            case "ifc":
                var line = step(data)
                if let converter { line += "; " + (await imported(data, converter: converter)) }
                return line
            case "ifcxml":
                let (elements, skipped) = try IFCImporter.decodeMetadata(data)
                var line = "metadata \(elements.count) elements, \(skipped.count) skipped"
                do {
                    let materials = try IFCMaterials.decode(data)
                    line += ", \(materials.count) with materials"
                } catch {
                    line += ", materials error: \(error.localizedDescription)"
                }
                let reinforcement = IFCReinforcementReader.Metadata(data)
                line += ", reinforcement empty \(reinforcement.isEmpty)"
                return line
            case "ifcobj":
                var chosen: [String: IFCImporter.Element] = [:]
                for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let fields = raw.split(whereSeparator: \.isWhitespace)
                    if fields.count == 2, fields[0] == "g" || fields[0] == "o" {
                        let id = String(fields[1])
                        chosen[id] = IFCImporter.Element(
                            id: id, name: String(id.prefix(40)), ifcClass: "IfcWall", supported: true)
                    }
                }
                var line: String
                do {
                    let review = try IFCImporter.inspectOBJ(data, metadata: chosen)
                    line =
                        "geometry \(review.elements.count) elements, \(review.failures.count) failures, "
                        + "\(review.repairs.count) repairs, origin finite \(review.origin.x.isFinite)"
                } catch {
                    line = "geometry error: \(error.localizedDescription)"
                }
                do {
                    let bars = try IFCReinforcementReader.parseOBJ(data, origin: .zero)
                    line += ", bars \(bars.count) groups"
                } catch {
                    line += ", bars error: \(error.localizedDescription)"
                }
                return line
            default:
                return "error: no reader for .\(kind)"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// What the importer reads from the STEP text itself.
    static func step(_ data: Data) -> String {
        let products = IFCStep.products(
            data, classes: Set(IFCImporter.physicalTypes + IFCImporter.standardCases))
        let unit = IFCStep.lengthUnit(data)
        let layers = IFCStep.layerMaterials(data)
        let storeys = IFCStep.storeyElevations(data)
        let unshared = IFCStep.unsharingCurveSegments(data)
        let finite = (unit?.metres.isFinite ?? true) && storeys.values.allSatisfy(\.isFinite)
        return
            "step \(products.count) products, unit \(unit.map { "\($0.metres) \($0.name)" } ?? "none"), "
            + "\(layers.count) layer sets, \(storeys.count) storeys, \(unshared.copies) segments unshared, "
            + "finite \(finite)"
    }

    /// The whole import, as the app makes it with every supported element chosen.
    static func imported(_ data: Data, converter: URL) async -> String {
        do {
            let prepared = try await IFCImporter.prepare(data, converter: converter)
            var line =
                "prepared \(prepared.inventory.count) elements, \(prepared.defaultIDs.count) supported"
            let chosen = Set(prepared.defaultIDs.sorted().prefix(1024))
            do {
                let mesh = try await IFCImporter.convert(prepared, includedIDs: chosen, converter: converter)
                let elements = mesh.buildingElements ?? []
                line += ", converted \(elements.count) elements, \(mesh.triangles.count) triangles"
                do {
                    let structure = try IFCStructure(elements: elements, chosen: [:], options: .init())
                    line += ", structure \(structure.report.members.count) members"
                } catch {
                    line += ", structure error: \(error.localizedDescription)"
                }
            } catch {
                line += ", convert error: \(error.localizedDescription)"
            }
            return line
        } catch {
            return "prepare error: \(error.localizedDescription)"
        }
    }
}

@Suite("IFC fuzz replay")
struct IFCFuzzReplayTests {
    static let folder = ProcessInfo.processInfo.environment["BLASTMODEL_FUZZ_DIR"]

    @Test("Every IFC input in BLASTMODEL_FUZZ_DIR imports or is refused", .enabled(if: folder != nil))
    func replay() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(Self.folder))
        let progress = environment["BLASTMODEL_FUZZ_PROGRESS"].map(URL.init(fileURLWithPath:))
        let output = try #require(environment["BLASTMODEL_FUZZ_OUT"].map(URL.init(fileURLWithPath:)))
        let skip = Int(environment["BLASTMODEL_FUZZ_SKIP"] ?? "") ?? 0
        let converter = environment["BOMBCAD_FUZZ_CONVERTER"].map(URL.init(fileURLWithPath:))
        // The converter is given what the app gives it; the driver's --timeout catches a hang.
        IFCImporter.conversionLimit.value = .seconds(120)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        if !FileManager.default.fileExists(atPath: output.path) {
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        for (n, name) in names.enumerated() where n >= skip {
            let url = folder.appending(path: name)
            if let progress { try Data("\(n) \(name)\n".utf8).write(to: progress) }
            let started = Date()
            let outcome = await IFCFuzz.exercise(
                try Data(contentsOf: url), kind: url.pathExtension.lowercased(), converter: converter)
            let seconds = Date().timeIntervalSince(started)
            let line =
                "\(n)\t\(name)\t\(String(format: "%.3f", seconds))\t\(outcome.replacingOccurrences(of: "\n", with: " "))\n"
            // Each line written as it is known: the next input may crash the process.
            let handle = try FileHandle(forWritingTo: output)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        }
    }
}

/// What fuzzing the IFC importer found (docs/linux.md#fuzzing-on-a-mac-and-threadsanitizer-on-the-slow-suites-28-october-2026),
/// on the converter's geometry as the importer reads it.
@Suite("IFC geometry refuses corrupt coordinates")
struct IFCGeometryRobustnessTests {
    static let id = String(repeating: "A", count: 22)

    /// A unit cube of `IFCImporter.inspectOBJ`'s converter output, one vertex replaced by `far`.
    static func cube(_ far: String? = nil) -> Data {
        var vertices = [
            "0 0 0", "1 0 0", "1 1 0", "0 1 0", "0 0 1", "1 0 1", "1 1 1", "0 1 1",
        ]
        if let far { vertices[6] = far }
        let faces = [
            "1 3 2", "1 4 3", "5 6 7", "5 7 8", "1 2 6", "1 6 5", "2 3 7", "2 7 6", "3 4 8", "3 8 7",
            "4 1 5", "4 5 8",
        ]
        let text =
            "g \(id)\n" + vertices.map { "v \($0)\n" }.joined() + faces.map { "f \($0)\n" }.joined()
        return Data(text.utf8)
    }

    static let chosen = [id: IFCImporter.Element(id: id, name: "Wall", ifcClass: "IfcWall")]

    @Test("A cube of the converter's geometry reads as one closed element")
    func cubeReads() throws {
        let review = try IFCImporter.inspectOBJ(Self.cube(), metadata: Self.chosen)
        #expect(review.elements.count == 1 && review.failures.isEmpty)
    }

    @Test(
        "A converted vertex past ten million kilometres is refused, not trapped on",
        arguments: ["1 1e308 1", "1 -1e308 1", "9223372036854775807 1 1", "1 1 1e12"])
    func farVertex(vertex: String) {
        // Welding it to 0.1 µm (IFCMeshRepair) converted past Int64's range and trapped.
        #expect(throws: ImportedMesh.ImportError.self) {
            try IFCImporter.inspectOBJ(Self.cube(vertex), metadata: Self.chosen)
        }
    }

    @Test("A reinforcement vertex that is not finite or lies far off is refused, not made a bar at infinity")
    func farBar() throws {
        #expect(try IFCReinforcementReader.parseOBJ(Self.cube(), origin: .zero)[Self.id]?.count == 12)
        for vertex in ["1 nan 1", "1 inf 1", "1 1e300 1"] {
            #expect(throws: ImportedMesh.ImportError.self) {
                try IFCReinforcementReader.parseOBJ(Self.cube(vertex), origin: .zero)
            }
        }
    }
}
