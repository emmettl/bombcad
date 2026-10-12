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
    static let standardCases = [
        "IfcWallStandardCase", "IfcSlabStandardCase", "IfcBeamStandardCase", "IfcColumnStandardCase",
        "IfcMemberStandardCase", "IfcPlateStandardCase", "IfcDoorStandardCase", "IfcWindowStandardCase",
    ]
    static func validGlobalID(_ id: String) -> Bool {
        id.count == 22
            && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") })
    }
    /// Classes that, aggregated into a supported element, carry its geometry as its parts: a
    /// wall of sand-lime blocks, a slab of precast planks drawn as proxies.
    static let partClasses: Set<String> = [
        "IfcBuildingElementPart", "IfcBuildingElementProxy", "IfcElementAssembly", "IfcCovering",
    ]
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
        /// Each element's material layers, by GlobalId, where the IFC gives them.
        var materials: [String: [IFCStructure.Layer]] = [:]
        /// Elements the metadata had to leave out, and why.
        var skipped: [String] = []
        /// Metres per length unit, read from the IFC itself, for where the converter cannot find
        /// its units; nil unless the file has one project with one length unit.
        var lengthUnit: (metres: Double, name: String)?
        /// The IFC's reinforcing elements and reinforcement properties (`IFCReinforcementReader`).
        var reinforcement = IFCReinforcementReader.Metadata()
        var defaultIDs: Set<String> { Set(inventory.filter(\.supported).map(\.id)) }
    }
    static func prepare(_ data: Data, converter: URL? = converterURL) async throws -> Prepared {
        guard data.count <= ImportedMesh.ifcSourceLimit else {
            throw ImportedMesh.ImportError.invalid(
                "IFC exceeds the 100 MB limit. Export a smaller building or subset.")
        }
        let converter = try requireConverter(converter)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.ifc")
        let xml = folder.appendingPathComponent("metadata.xml")
        try data.write(to: input)
        let log = try await run(converter, arguments: [input.path, xml.path, "-y"], folder: folder)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: xml.path) else {
            let errors = converterErrors(log)
            throw ImportedMesh.ImportError.invalid(
                "The IFC converter could not read the file's structure"
                    + (errors.isEmpty ? "." : ": " + errors + "."))
        }
        let metadata = try boundedData(xml)
        var (inventory, skipped) = try decodeMetadata(metadata)
        // Products in no spatial structure are missing from the converter's tree: find them in
        // the IFC itself.
        let known = Set(inventory.map(\.id))
        for product in IFCStep.products(data, classes: Set(physicalTypes + standardCases))
        where !known.contains(product.id) && validGlobalID(product.id) {
            inventory.append(
                Element(
                    id: product.id, name: product.name, ifcClass: product.ifcClass, supported: true,
                    uncontained: true))
        }
        inventory.sort { $0.id < $1.id }
        // The converter writes no units where it cannot find them; then the file's own.
        let unitsRead = String(decoding: metadata.prefix(200_000), as: UTF8.self).contains("LENGTHUNIT")
        let lengthUnit = IFCStep.lengthUnit(data)
        // Materials are only for meshing the building as a structure: an unreadable set leaves
        // them out rather than the import.
        let materials =
            (try? IFCMaterials.decode(metadata, metresPerUnit: unitsRead ? 1 : Float(lengthUnit?.metres ?? 1)))
            ?? [:]
        var reinforcement = IFCReinforcementReader.Metadata(metadata)
        if !unitsRead { reinforcement.scale = Float(lengthUnit?.metres ?? 1) }
        try Task.checkCancellation()
        guard inventory.contains(where: \.supported) else {
            var classes: [String: Int] = [:]
            for element in inventory where !element.hasChildren { classes[element.ifcClass, default: 0] += 1 }
            let found = classes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8)
                .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            throw ImportedMesh.ImportError.invalid(
                "No supported physical elements were found in the IFC"
                    + (found.isEmpty ? "." : ": it holds \(found)")
                    + (found.isEmpty
                        ? ""
                        : ", and none is a wall, slab, roof, column, beam, member, plate, footing, stair, railing, door or window, or a part of one.")
            )
        }
        return Prepared(
            data: data, inventory: inventory, metadataLog: log, materials: materials, skipped: skipped,
            lengthUnit: lengthUnit, reinforcement: reinforcement)
    }
    static func convert(_ data: Data, converter: URL? = converterURL) async throws -> ImportedMesh {
        let prepared = try await prepare(data, converter: converter)
        return try await convert(prepared, includedIDs: prepared.defaultIDs, converter: converter)
    }
    static func convert(_ prepared: Prepared, includedIDs: Set<String>, converter: URL? = converterURL)
        async throws -> ImportedMesh
    {
        let mesh = try await convertElements(prepared, includedIDs: includedIDs, converter: converter)
        // Reinforcement goes to the elements it lies in, once they are known. (Awaited apart from
        // the conversion: in the same function, the debug build's task allocator traps.)
        guard !prepared.reinforcement.isEmpty, let elements = mesh.buildingElements else { return mesh }
        let (reinforced, notes) = await IFCReinforcementReader.attach(
            prepared.reinforcement, to: elements, ifc: prepared.data, origin: mesh.buildingOrigin ?? .zero,
            converter: converter, lengthUnit: prepared.lengthUnit?.metres)
        try Task.checkCancellation()
        return try ImportedMesh(
            buildingElements: reinforced, notes: (mesh.buildingNotes ?? []) + notes,
            origin: mesh.buildingOrigin,
            sourceData: mesh.buildingSourceData, selection: mesh.buildingSelection)
    }
    private static func convertElements(_ prepared: Prepared, includedIDs: Set<String>, converter: URL?)
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
        var scale = 1.0
        var notes: [String] = []
        if geometryLog.contains("Unable to detect unit information") {
            // The converter then writes the file's own units; scale them by the project's.
            guard let unit = prepared.lengthUnit else {
                throw ImportedMesh.ImportError.invalid(
                    "IFC units could not be determined, by the converter or from the file's one project and its length unit. Review project/context and unit definitions in your CAD tool, then re-export. Geometry is blocked to avoid importing it at the wrong scale."
                )
            }
            scale = unit.metres
            notes.append(
                "The converter could not find this IFC's units, so its project's own length unit, the \(unit.name) (\(unit.metres) m), was applied to the geometry. Check the building's size."
            )
        }
        let chosen = prepared.inventory.filter { includedIDs.contains($0.id) }
        let output = try boundedData(obj)
        guard output.range(of: Data("\nf ".utf8)) != nil else {
            let errors = converterErrors(geometryLog)
            throw ImportedMesh.ImportError.invalid(
                "The converter produced no geometry for the chosen elements"
                    + (errors.isEmpty ? "." : ": " + errors + ".")
                    + " Their representations may be in a context or form it does not read.")
        }
        let geometry = try decodeOBJ(
            output, metadata: Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0) }), scale: scale)
        if prepared.data.count > 20_000_000 {
            notes.append(
                "This IFC is \(prepared.data.count / 1_000_000) MB, past 20 MB: converting, sampling and saving it are slower, and the project keeps the whole file.")
        }
        // A repaired element is present in its solids.
        let present = Set(geometry.elements.map { $0.assembly?.id ?? $0.globalID })
        let byID = Dictionary(uniqueKeysWithValues: prepared.inventory.map { ($0.id, $0) })
        if !geometry.repairs.isEmpty {
            let left = geometry.repairs.filter { $0.leftOut > 0 }
            notes.append(
                "\(geometry.repairs.count) element\(geometry.repairs.count == 1 ? "" : "s") whose meshes were not closed solids "
                    + "(pieces welded together, faces shared) were remade as the "
                    + "\(geometry.repairs.reduce(0) { $0 + $1.solids }) closed solid\(geometry.repairs.reduce(0) { $0 + $1.solids } == 1 ? "" : "s") "
                    + "they are made of, faces they shared removed, each imported as a piece of its element: "
                    + geometry.repairs.prefix(8).map(\.name).joined(separator: ", ") + (geometry.repairs.count > 8 ? ", …" : "")
                    + (left.isEmpty
                        ? "."
                        : ". Of \(left.count) of them, \(left.reduce(0) { $0 + $1.leftOut }) pieces left out, being open or "
                            + "not valid solids on their own: " + left.prefix(5).map(\.name).joined(separator: ", ") + "."))
        }
        // An element whose geometry is all in its parts is not missing.
        let carried = Set(geometry.elements.compactMap { byID[$0.globalID]?.parentID })
        let missing = chosen.filter { !present.contains($0.id) && !carried.contains($0.id) }
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
        // A part takes its element's storey and, where it has none of its own, materials.
        func root(of id: String) -> Element? {
            var current = byID[id]
            while let element = current, !supportedClass(element.ifcClass), let parent = element.parentID {
                current = byID[parent]
            }
            return current.flatMap { supportedClass($0.ifcClass) ? $0 : nil }
        }
        var parts = 0
        let elements = geometry.elements.map { element in
            var copy = element
            // A repaired element's solids stand for it: its id, materials and place.
            let source = element.assembly?.id ?? element.globalID
            copy.materials = prepared.materials[source]
            if let entry = byID[source], !supportedClass(entry.ifcClass), let owner = root(of: source) {
                copy.assembly = .init(id: owner.id, name: owner.name, ifcClass: owner.ifcClass)
                copy.storey = copy.storey ?? owner.storey
                copy.materials = copy.materials ?? prepared.materials[owner.id]
                parts += 1
            }
            return copy
        }
        if parts > 0 {
            notes.append(
                "\(parts) parts (blocks, planks, proxies) carry the geometry of the elements they make up; each is kept as an element of its own, and meshed with its element as a structure."
            )
        }
        let uncontained = chosen.filter { $0.uncontained == true && present.contains($0.id) }
        if !uncontained.isEmpty {
            notes.append(
                "\(uncontained.count) elements are in no storey or building of the IFC's spatial structure; they were found in the file itself and imported without a storey: "
                    + uncontained.prefix(10).map(\.name).joined(separator: ", ")
                    + (uncontained.count > 10 ? ", …" : "") + ".")
        }
        if !prepared.skipped.isEmpty {
            notes.append(
                "Left out of the IFC's inventory: " + prepared.skipped.prefix(10).joined(separator: "; ")
                    + (prepared.skipped.count > 10 ? "; and \(prepared.skipped.count - 10) more." : "."))
        }
        var unsupported: [String: Int] = [:]
        for element in prepared.inventory where !element.supported && !element.hasChildren {
            unsupported[element.ifcClass, default: 0] += 1
        }
        if !unsupported.isEmpty {
            notes.append(
                "Not imported, as their classes are not supported: "
                    + unsupported.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(12)
                    .map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ".")
        }
        return try ImportedMesh(
            buildingElements: elements, notes: notes, origin: geometry.origin,
            sourceData: prepared.data,
            selection: .init(inventory: prepared.inventory, includedIDs: includedIDs))
    }

    static func boundedData(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200_000_000 else {
            throw ImportedMesh.ImportError.invalid(
                "Converted IFC output exceeds 200 MB. Simplify or split the model.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 200_000_000 else {
            throw ImportedMesh.ImportError.invalid("Converted IFC output exceeds its limit.")
        }
        return data
    }
    static func run(_ executable: URL, arguments: [String], folder: URL) async throws -> String {
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
                if (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 200_000_000 {
                    throw ImportedMesh.ImportError.invalid(
                        "IFC conversion exceeded its output limit. Simplify or split the model.")
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        let text = String(decoding: try boundedData(log), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let errors = converterErrors(text)
            throw ImportedMesh.ImportError.invalid(
                "IFC conversion failed"
                    + (errors.isEmpty
                        ? (process.terminationReason == .uncaughtSignal
                            ? ": the converter crashed (signal \(process.terminationStatus))."
                            : ". \(String(text.suffix(1200)))")
                        : ": " + errors + "."))
        }
        return text
    }

    /// The converter's error lines, without their time stamps and repeats.
    static func converterErrors(_ log: String) -> String {
        var seen = Set<String>()
        return log.split(whereSeparator: \.isNewline).filter { $0.contains("[Error]") }
            .map {
                $0.replacingOccurrences(
                    of: #"\[Error\]\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            }
            .map {
                $0.replacingOccurrences(
                    of: #"'/[^']*source\.ifc'"#, with: "the file", options: .regularExpression)
            }
            .filter { seen.insert($0).inserted }.prefix(4).joined(separator: "; ")
    }

    static func requireConverter(_ converter: URL?) throws -> URL {
        guard let converter else {
            throw ImportedMesh.ImportError.invalid(
                "The IFC converter is unavailable. Build BombCAD.app with Scripts/build-app.sh, or run python3 Scripts/prepare-ifc-converter.py before swift run."
            )
        }
        return converter
    }
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bombcad-ifc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    typealias Element = ImportedMesh.BuildingSourceElement
    static func decodeMetadata(_ data: Data) throws -> (elements: [Element], skipped: [String]) {
        let parser = Metadata()
        let document = XMLParser(data: data)
        document.delegate = parser
        document.shouldResolveExternalEntities = false
        guard document.parse(), parser.issue == nil else {
            throw ImportedMesh.ImportError.invalid(
                "IFC metadata could not be read: \(parser.issue ?? document.parserError?.localizedDescription ?? "invalid XML")"
            )
        }
        return (parser.elements.values.sorted { $0.id < $1.id }, parser.skipped)
    }
    private final class Metadata: NSObject, XMLParserDelegate {
        var elements: [String: Element] = [:]
        var issue: String?
        var skipped: [String] = []
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
            let label = String((attributes["Name"] ?? name).prefix(200))
            guard IFCImporter.validGlobalID(id) else {
                // One bad identifier leaves out its element, not the file.
                if skipped.count < 1000 {
                    skipped.append("\(label) (\(name)), its GlobalId '\(id.prefix(40))' invalid")
                }
                return
            }
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
                if skipped.count < 1000 {
                    skipped.append("\(label) (\(name)), its GlobalId \(id) used twice")
                }
                return
            }
            let parent = parents.last?.1
            if let parent { elements[parent]?.hasChildren = true }
            // A part of a supported element (or of a part of one) carries its geometry.
            let part =
                parent.flatMap { elements[$0]?.supported } == true && IFCImporter.partClasses.contains(name)
            elements[id] = Element(
                id: id, name: label, ifcClass: name,
                buildingID: buildings.last?.1, building: buildings.last?.2,
                storeyID: storeys.last?.1, storey: storeys.last?.2,
                supported: IFCImporter.supportedClass(name) || part, parentID: parent)
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
    struct ElementFailure: Sendable, Hashable, Identifiable {
        var id: String
        var name: String
        var reason: String
    }
    struct ElementFailures: LocalizedError {
        var failures: [ElementFailure]
        var inspectedElements: Int
        var errorDescription: String? {
            "\(failures.count) of \(inspectedElements) converted IFC element meshes do not form valid closed solids. Review all failures, repair the source, or explicitly exclude reviewed elements."
        }
        var report: String {
            (errorDescription ?? "IFC geometry review") + "\n\n"
                + failures.map { "\($0.name) · \($0.id)\n\($0.reason)" }.joined(separator: "\n\n")
        }
    }
    /// An element whose mesh was taken apart into the closed solids it is made of
    /// (`IFCMeshRepair`), and what could not be.
    struct ElementRepair: Sendable, Hashable {
        var id: String
        var name: String
        var solids: Int
        /// Pieces left out: open, or not valid solids on their own.
        var leftOut: Int
        var reason: String
    }
    struct GeometryReview {
        var elements: [ImportedMesh.BuildingElement]
        var origin: SIMD3<Double>
        var failures: [ElementFailure]
        var inspectedElements: Int
        var repairs: [ElementRepair] = []
    }
    static func decodeOBJ(_ data: Data, metadata: [String: Element], scale: Double = 1) throws -> (
        elements: [ImportedMesh.BuildingElement], origin: SIMD3<Double>, repairs: [ElementRepair]
    ) {
        let review = try inspectOBJ(data, metadata: metadata, scale: scale)
        if !review.failures.isEmpty {
            throw ElementFailures(failures: review.failures, inspectedElements: review.inspectedElements)
        }
        return (review.elements, review.origin, review.repairs)
    }
    static func inspectOBJ(
        _ data: Data, metadata: [String: Element], scale: Double = 1,
        triangleLimit: Int = ImportedMesh.buildingTriangleLimit
    ) throws
        -> GeometryReview
    {
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
                    [x, y, z].allSatisfy(\.isFinite), vertices.count < 3 * ImportedMesh.buildingTriangleLimit
                else { throw ImportedMesh.ImportError.invalid("Invalid or excessive IFC vertices.") }
                vertices.append(SIMD3(x, y, z) * scale)
            }
            if f.first == "f" {
                guard let guid, metadata[guid] != nil else {
                    throw ImportedMesh.ImportError.invalid(
                        "IFC geometry came back for an element that was not chosen (\(guid ?? "no element"))."
                    )
                }
                guard f.count == 4 else {
                    throw ImportedMesh.ImportError.invalid(
                        "IFC converter output has a face that is not a triangle.")
                }
                guard count < triangleLimit else {
                    throw ImportedMesh.ImportError.invalid(
                        "The chosen IFC elements have more than \(triangleLimit.formatted(.number.locale(Locale(identifier: "en_GB")))) triangles. Choose fewer elements, for example a storey at a time."
                    )
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
        var failures: [ElementFailure] = []
        var repairs: [ElementRepair] = []
        // The scene holds coordinates in single precision: across a large building, vertices
        // closer than a few of its steps fall together. A mesh that fails for that is welded at
        // four steps of the building's extent, its collapsed triangles dropped.
        let extent = used.reduce(0.0) { max($0, simd_reduce_max(simd_abs(vertices[$1] - origin))) }
        let coarse = max(0.0000001, extent * 4.8e-7)
        func mesh(_ triangles: [[Int]], quantum: Double = 0.0000001, _ position: (Int) -> SIMD3<Double>) throws
            -> ImportedMesh
        {
            // IFC meshing can emit coincident face vertices with floating-point roundoff.
            // Canonicalise at 0.1 micrometre, then strictly revalidate every resulting solid.
            func at(_ n: Int) -> SIMD3<Double> {
                ((position(n) - origin) / quantum).rounded(.toNearestOrAwayFromZero) * quantum
            }
            let kept = quantum > 0.0000001 ? triangles.filter { f in at(f[0]) != at(f[1]) && at(f[1]) != at(f[2]) && at(f[0]) != at(f[2]) } : triangles
            let indices = Set(kept.flatMap { $0 }).sorted()
            let mapping = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset + 1) })
            var obj = ""
            for n in indices {
                let v = at(n)
                obj += "v \(v.x) \(v.y) \(v.z)\n"
            }
            for f in kept { obj += "f \(mapping[f[0]]!) \(mapping[f[1]]!) \(mapping[f[2]]!)\n" }
            return try ImportedMesh(data: Data(obj.utf8), fileExtension: "obj")
        }
        for id in faces.keys.sorted() {
            try Task.checkCancellation()
            let info = metadata[id]!
            do {
                let originalTriangles = faces[id]!
                let triangles = try conformingFaces(originalTriangles, vertices: vertices, origin: origin)
                elements.append(
                    .init(
                        globalID: id, name: info.name, ifcClass: info.ifcClass, storey: info.storey,
                        mesh: try mesh(triangles) { vertices[$0] }))
            } catch is CancellationError { throw CancellationError() } catch {
                let reason = String(error.localizedDescription.prefix(2000))
                // Welded at the scene's precision, where its tiny edges were what failed.
                if coarse > 0.0000001,
                    let welded = try? mesh(conformingFaces(faces[id]!, vertices: vertices, origin: origin), quantum: coarse, {
                        vertices[$0]
                    })
                {
                    elements.append(
                        .init(globalID: id, name: info.name, ifcClass: info.ifcClass, storey: info.storey, mesh: welded))
                    continue
                }
                // Its mesh taken apart into the closed solids it is made of, where it is.
                let repair = IFCMeshRepair.shells(faces[id]!, vertices: vertices)
                var pieces: [ImportedMesh] = []
                var invalid = 0
                for shell in repair.shells {
                    try Task.checkCancellation()
                    let triangles = shell.map { [$0.x, $0.y, $0.z] }
                    if let piece = try? mesh(triangles, { repair.points[$0] }) {
                        pieces.append(piece)
                    } else if let piece = try? mesh(triangles, quantum: coarse, { repair.points[$0] }) {
                        pieces.append(piece)
                    } else {
                        invalid += 1
                    }
                }
                guard !pieces.isEmpty, pieces.count <= 64 * 64 else {
                    failures.append(ElementFailure(id: id, name: info.name, reason: reason))
                    continue
                }
                let owner = ImportedMesh.BuildingElement.Assembly(id: id, name: info.name, ifcClass: info.ifcClass)
                for (k, piece) in pieces.enumerated() {
                    elements.append(
                        .init(
                            globalID: IFCMeshRepair.pieceID(id, k), name: String("\(info.name) · \(k + 1)".prefix(200)),
                            ifcClass: info.ifcClass, storey: info.storey, assembly: owner, mesh: piece))
                }
                repairs.append(
                    ElementRepair(
                        id: id, name: info.name, solids: pieces.count, leftOut: repair.openPieces + invalid,
                        reason: reason))
            }
        }
        return GeometryReview(
            elements: elements, origin: origin, failures: failures, inspectedElements: faces.count, repairs: repairs)
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
