import BlastCore
import Darwin
import Foundation
import simd

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// Native IFC geometry translation. All work stays local and each product is validated independently.
enum IFCImporter {
    static let physicalTypes = [
        "IfcWall", "IfcSlab", "IfcRoof", "IfcColumn", "IfcBeam", "IfcMember", "IfcPlate",
        "IfcFooting", "IfcStair", "IfcStairFlight", "IfcRailing", "IfcDoor", "IfcWindow",
    ]
    static func supportedClass(_ name: String) -> Bool {
        physicalTypes.contains(name)
            || [
                "IfcWallStandardCase", "IfcSlabStandardCase", "IfcBeamStandardCase",
                "IfcColumnStandardCase", "IfcMemberStandardCase", "IfcPlateStandardCase",
                "IfcDoorStandardCase",
                "IfcWindowStandardCase",
            ].contains(name)
    }
    static var converterURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/IfcConvert")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ifc-converter/IfcConvert")
        return FileManager.default.isExecutableFile(atPath: local.path) ? local : nil
    }
    struct Prepared: Sendable {
        var data: Data
        var inventory: [Element]
        var metadataLog: String
        var defaultIDs: Set<String> { Set(inventory.filter(\.supported).map(\.id)) }
    }
    static func prepare(_ data: Data, converter: URL? = converterURL) async throws -> Prepared {
        guard data.count <= 20_000_000 else {
            throw ImportedMesh.ImportError.invalid(
                "IFC exceeds the 20 MB limit. Export a smaller building or subset.")
        }
        let converter = try requireConverter(converter)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.ifc")
        let xml = folder.appendingPathComponent("metadata.xml")
        try data.write(to: input)
        let log = try await run(converter, arguments: [input.path, xml.path, "-y"], folder: folder)
        try Task.checkCancellation()
        let inventory = try decodeMetadata(try boundedData(xml))
        try Task.checkCancellation()
        guard inventory.contains(where: \.supported) else {
            throw ImportedMesh.ImportError.invalid(
                "No supported physical elements were found in the IFC decomposition tree.")
        }
        return Prepared(data: data, inventory: inventory, metadataLog: log)
    }
    static func convert(_ data: Data, converter: URL? = converterURL) async throws -> ImportedMesh {
        let prepared = try await prepare(data, converter: converter)
        return try await convert(prepared, includedIDs: prepared.defaultIDs, converter: converter)
    }
    static func convert(_ prepared: Prepared, includedIDs: Set<String>, converter: URL? = converterURL)
        async throws -> ImportedMesh
    {
        try Task.checkCancellation()
        guard !includedIDs.isEmpty, includedIDs.count <= 1024, includedIDs.isSubset(of: prepared.defaultIDs)
        else {
            throw ImportedMesh.ImportError.invalid("Choose between 1 and 1,024 supported IFC elements.")
        }
        let converter = try requireConverter(converter)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.ifc")
        let obj = folder.appendingPathComponent("geometry.obj")
        try prepared.data.write(to: input)
        // Exact GUID filtering never implicitly includes descendants. Openings are still subtracted
        // by the converter, even though opening entities are not imported as solid obstacles.
        let geometryLog = try await run(
            converter,
            arguments: [
                input.path, obj.path, "-y", "-v", "--use-element-guids", "--weld-vertices", "--include",
                "attribute", "GlobalId",
            ] + includedIDs.sorted(), folder: folder)
        guard !geometryLog.contains("Unable to detect unit information") else {
            throw ImportedMesh.ImportError.invalid(
                "IFC units could not be determined by the converter. Review project/context and unit definitions in your CAD tool, then re-export. Geometry is blocked to avoid importing it at the wrong scale."
            )
        }
        let chosen = prepared.inventory.filter { includedIDs.contains($0.id) }
        let geometry = try decodeOBJ(
            try boundedData(obj), metadata: Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0) }))
        let present = Set(geometry.elements.map(\.globalID))
        let missing = chosen.filter { !present.contains($0.id) }
        var notes: [String] = []
        if !missing.isEmpty {
            notes.append(
                "Selected IFC elements without converted geometry: "
                    + missing.prefix(10).map(\.name).joined(separator: ", ")
                    + ". Containers may have geometry only in their children; other omissions may be conversion failures. Review completeness before applying."
            )
        }
        let metadataLog = prepared.metadataLog
        let lines = (metadataLog + geometryLog).split(whereSeparator: \.isNewline).map(String.init)
        let errors = lines.indices.filter { lines[$0].contains("[Error]") }
        if !errors.isEmpty
            && errors.allSatisfy({ $0 + 1 < lines.count && lines[$0 + 1].contains("=IfcMaterial(") })
        {
            notes.append(
                "Some IFC material metadata could not be translated. Element geometry was retained; this rigid import does not map physical material properties."
            )
        } else if !errors.isEmpty || lines.contains(where: { $0.contains("[Warning]") }) {
            let messages = lines.filter { $0.contains("[Error]") || $0.contains("[Warning]") }
                .map {
                    $0.replacingOccurrences(
                        of: #"\[\d{4}-\d{2}-\d{2}[^\]]*\]"#, with: "", options: .regularExpression)
                }
            notes.append(
                "IFC converter diagnostics: "
                    + String(Array(Set(messages)).sorted().joined(separator: "; ").prefix(1800)))
        }
        notes.append(
            "Inventory follows the IFC decomposition tree. Uncontained products may be absent; compare this import with the source CAD model."
        )
        notes.append(
            "Converted coordinates are rebased and canonicalised at 0.1 micrometre; existing edge junctions are split into conforming triangles; all resulting element solids are revalidated. This is independent of the air-grid resolution."
        )
        notes.append(
            "IFC converted to metres, Z up. Only explicitly chosen supported elements were converted. Spaces, furnishings, site/proxy markers and other unsupported types are excluded. Material properties are not mapped."
        )
        return try ImportedMesh(
            buildingElements: geometry.elements, notes: notes, origin: geometry.origin,
            sourceData: prepared.data,
            selection: .init(inventory: prepared.inventory, includedIDs: includedIDs))
    }

    private static func boundedData(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else {
            throw ImportedMesh.ImportError.invalid(
                "Converted IFC output exceeds 20 MB. Simplify or split the model.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else {
            throw ImportedMesh.ImportError.invalid("Converted IFC output exceeds its limit.")
        }
        return data
    }
    private static func run(_ executable: URL, arguments: [String], folder: URL) async throws -> String {
        try Task.checkCancellation()
        let log = folder.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(120)
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ImportedMesh.ImportError.invalid(
                    "IFC conversion exceeded two minutes. Simplify or split the model.")
            }
            for url in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey])
            {
                if (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 20_000_000 {
                    throw ImportedMesh.ImportError.invalid(
                        "IFC conversion exceeded its output limit. Simplify or split the model.")
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        let text = String(decoding: try boundedData(log), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ImportedMesh.ImportError.invalid("IFC conversion failed. \(String(text.suffix(1800)))")
        }
        return text
    }

    private static func requireConverter(_ converter: URL?) throws -> URL {
        guard let converter else {
            throw ImportedMesh.ImportError.invalid(
                "The IFC converter is unavailable. Build BombCAD.app with Scripts/build-app.sh, or run python3 Scripts/prepare-ifc-converter.py before swift run."
            )
        }
        return converter
    }
    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bombcad-ifc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    typealias Element = ImportedMesh.BuildingSourceElement
    static func decodeMetadata(_ data: Data) throws -> [Element] {
        let parser = Metadata()
        let document = XMLParser(data: data)
        document.delegate = parser
        document.shouldResolveExternalEntities = false
        guard document.parse(), parser.issue == nil else {
            throw ImportedMesh.ImportError.invalid(
                "IFC metadata could not be read: \(parser.issue ?? document.parserError?.localizedDescription ?? "invalid XML")"
            )
        }
        return parser.elements.values.sorted { $0.id < $1.id }
    }
    private final class Metadata: NSObject, XMLParserDelegate {
        var elements: [String: Element] = [:]
        var issue: String?
        private var depth = 0
        private var decomposition = false
        private var buildings: [(Int, String, String)] = []
        private var storeys: [(Int, String, String)] = []
        private var parents: [(Int, String)] = []
        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            depth += 1
            guard depth < 128, elements.count < 20_000 else {
                issue = "metadata exceeds its limits"
                parser.abortParsing()
                return
            }
            if name == "decomposition" { decomposition = true }
            guard decomposition, let id = attributes["id"] else { return }
            guard id.count == 22,
                id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") })
            else {
                issue = "invalid IFC GlobalId"
                parser.abortParsing()
                return
            }
            let label = String((attributes["Name"] ?? name).prefix(200))
            if name == "IfcBuilding" {
                buildings.append((depth, id, label))
                return
            }
            if name == "IfcBuildingStorey" {
                storeys.append((depth, id, label))
                return
            }
            guard !["IfcProject", "IfcSite"].contains(name), !name.hasSuffix("Type"),
                !["IfcProperty", "IfcQuantity", "IfcElementQuantity", "IfcMaterial"].contains(
                    where: name.hasPrefix)
            else { return }
            guard elements[id] == nil else {
                issue = "duplicate IFC GlobalId"
                parser.abortParsing()
                return
            }
            if let parent = parents.last?.1 { elements[parent]?.hasChildren = true }
            elements[id] = Element(
                id: id, name: label, ifcClass: name,
                buildingID: buildings.last?.1, building: buildings.last?.2,
                storeyID: storeys.last?.1, storey: storeys.last?.2,
                supported: IFCImporter.supportedClass(name))
            parents.append((depth, id))
        }
        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
        ) {
            if storeys.last?.0 == depth { storeys.removeLast() }
            if buildings.last?.0 == depth { buildings.removeLast() }
            if parents.last?.0 == depth { parents.removeLast() }
            if name == "decomposition" { decomposition = false }
            depth -= 1
        }
        func parser(
            _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
            systemID: String?
        ) {
            issue = "external XML entities are unsupported"
            parser.abortParsing()
        }
    }
    struct ElementFailure: LocalizedError {
        var id: String
        var name: String
        var reason: String
        var errorDescription: String? { "IFC element \(name) (\(id)) is not a valid closed solid: \(reason)" }
    }
    static func decodeOBJ(_ data: Data, metadata: [String: Element]) throws -> (
        elements: [ImportedMesh.BuildingElement], origin: SIMD3<Double>
    ) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportedMesh.ImportError.invalid("IFC converter output is not UTF-8.")
        }
        var vertices: [SIMD3<Double>] = []
        var faces: [String: [[Int]]] = [:]
        var guid: String?
        var count = 0
        for (line, raw) in text.split(separator: "\n").enumerated() {
            if line % 256 == 0 { try Task.checkCancellation() }
            let f = raw.split(whereSeparator: \.isWhitespace)
            if f.first == "g" || f.first == "o" { guid = f.count == 2 ? String(f[1]) : nil }
            if f.first == "v" {
                guard f.count >= 4, let x = Double(f[1]), let y = Double(f[2]), let z = Double(f[3]),
                    [x, y, z].allSatisfy(\.isFinite), vertices.count < 300_000
                else { throw ImportedMesh.ImportError.invalid("Invalid or excessive IFC vertices.") }
                vertices.append(SIMD3(x, y, z))
            }
            if f.first == "f" {
                guard let guid, metadata[guid] != nil, f.count == 4, count < 100_000 else {
                    throw ImportedMesh.ImportError.invalid(
                        "IFC geometry lacks element identity or exceeds triangle limits.")
                }
                let indices = try f.dropFirst().map { value -> Int in
                    guard let token = value.split(separator: "/").first, let n = Int(token), n > 0,
                        n <= vertices.count
                    else { throw ImportedMesh.ImportError.invalid("Invalid IFC face index.") }
                    return n - 1
                }
                faces[guid, default: []].append(indices)
                count += 1
            }
        }
        guard !faces.isEmpty else {
            throw ImportedMesh.ImportError.invalid(
                "No supported physical building geometry was found in this IFC file.")
        }
        let used = Set(faces.values.flatMap { $0.flatMap { $0 } })
        let origin = used.reduce(SIMD3<Double>(repeating: .infinity)) { simd_min($0, vertices[$1]) }
        var elements: [ImportedMesh.BuildingElement] = []
        for id in faces.keys.sorted() {
            try Task.checkCancellation()
            let info = metadata[id]!
            let originalTriangles = faces[id]!
            let triangles = try conformingFaces(originalTriangles, vertices: vertices, origin: origin)
            let indices = Set(triangles.flatMap { $0 }).sorted()
            let mapping = Dictionary(
                uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset + 1) })
            var obj = ""
            for n in indices {
                // IFC meshing can emit coincident face vertices with floating-point roundoff.
                // Canonicalise at 0.1 micrometre, then strictly revalidate every resulting solid.
                let v = ((vertices[n] - origin) / 0.0000001).rounded(.toNearestOrAwayFromZero) * 0.0000001
                obj += "v \(v.x) \(v.y) \(v.z)\n"
            }
            for f in triangles { obj += "f \(mapping[f[0]]!) \(mapping[f[1]]!) \(mapping[f[2]]!)\n" }
            do {
                let mesh = try ImportedMesh(data: Data(obj.utf8), fileExtension: "obj")
                elements.append(
                    .init(
                        globalID: id, name: info.name, ifcClass: info.ifcClass, storey: info.storey,
                        mesh: mesh))
            } catch is CancellationError { throw CancellationError() } catch {
                throw ElementFailure(id: id, name: info.name, reason: error.localizedDescription)
            }
        }
        return (elements, origin)
    }
    /// Split a triangle edge at an existing boundary vertex. This changes triangulation only:
    /// no missing face is created, and the original surface is strictly validated afterwards.
    private static func conformingFaces(_ input: [[Int]], vertices: [SIMD3<Double>], origin: SIMD3<Double>)
        throws -> [[Int]]
    {
        struct Edge: Hashable {
            var a: SIMD3<Double>
            var b: SIMD3<Double>
        }
        func point(_ n: Int) -> SIMD3<Double> {
            ((vertices[n] - origin) / 0.0000001).rounded(.toNearestOrAwayFromZero) * 0.0000001
        }
        func less(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
            for k in 0..<3 where a[k] != b[k] { return a[k] < b[k] }
            return false
        }
        func edge(_ a: Int, _ b: Int) -> Edge {
            let p = point(a)
            let q = point(b)
            return less(p, q) ? Edge(a: p, b: q) : Edge(a: q, b: p)
        }
        var counts: [Edge: Int] = [:]
        for f in input { for k in 0..<3 { counts[edge(f[k], f[(k + 1) % 3]), default: 0] += 1 } }
        let boundary = Set(
            input.flatMap { f in
                (0..<3).flatMap { k -> [Int] in
                    counts[edge(f[k], f[(k + 1) % 3])] == 1 ? [f[k], f[(k + 1) % 3]] : []
                }
            }
        ).sorted()
        var output: [[Int]] = []
        var work = 0
        for original in input {
            try Task.checkCancellation()
            var queue = [original]
            while let f = queue.popLast() {
                var split = false
                for k in 0..<3 where !split {
                    let a = f[k]
                    let b = f[(k + 1) % 3]
                    let c = f[(k + 2) % 3]
                    let p = point(a)
                    let q = point(b)
                    let delta = q - p
                    let length = simd_length_squared(delta)
                    guard length > 1e-20 else { continue }
                    for n in boundary {
                        work += 1
                        guard work <= 2_000_000 else {
                            throw ImportedMesh.ImportError.invalid(
                                "IFC boundary triangulation exceeds its work limit. Simplify the source.")
                        }
                        let v = point(n)
                        let t = simd_dot(v - p, delta) / length
                        if t > 1e-8 && t < 1 - 1e-8 && simd_length_squared(v - (p + delta * t)) < 1e-18 {
                            queue += [[a, n, c], [n, b, c]]
                            split = true
                            break
                        }
                    }
                }
                if !split { output.append(f) }
                guard output.count + queue.count <= 100_000 else {
                    throw ImportedMesh.ImportError.invalid("IFC triangulation exceeds 100,000 triangles.")
                }
            }
        }
        return output
    }

}
