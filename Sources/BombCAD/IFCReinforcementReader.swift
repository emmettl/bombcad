import BlastCore
import Foundation
import simd

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// Reads an IFC's reinforcement for `IFCReinforcement`: from the converter's metadata, the
/// reinforcing bars, meshes and tendons with their sizes and roles (their own or their type's),
/// the element each is nested in, and concrete elements' reinforcement properties; from the
/// converter's geometry of the reinforcing elements alone, each bar's path.
enum IFCReinforcementReader {
    static let classes = ["IfcReinforcingBar", "IfcReinforcingMesh", "IfcTendon"]

    /// What the metadata says about reinforcement.
    struct Metadata: Sendable, Hashable {
        struct Element: Sendable, Hashable {
            var kind: IFCReinforcement.Bar.Kind
            /// Its role, diameter and area as written, in the file's own numbers (units are
            /// worked out against the bar's shape, `size`).
            var role: String?
            var diameter: Float?
            var area: Float?
            /// Where the size came from.
            var source: String
            /// The building element the IFC nests it in, if any.
            var host: String?
        }

        /// Metres per project length unit.
        var scale: Float = 1
        var elements: [String: Element] = [:]
        /// Reinforcement properties by element GlobalId.
        var properties: [String: IFCReinforcement.Properties] = [:]

        init() {}

        init(_ data: Data) {
            let reader = Reader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else { return }
            self = reader.result()
        }

        var isEmpty: Bool { elements.isEmpty && properties.isEmpty }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private var scale: Float = 1
        private var section = ""
        private var depth = 0
        /// Types of reinforcing elements by id: their role, diameter and area.
        private var types: [String: (role: String?, diameter: Float?, area: Float?)] = [:]
        /// Property sets by id: their name and numeric properties.
        private var sets: [String: (name: String, values: [String: Float])] = [:]
        private var defining: (depth: Int, id: String)?
        /// The products open in the decomposition, outermost first: id, class and depth.
        private var products: [(depth: Int, id: String, ifcClass: String)] = []
        private var elements: [String: Metadata.Element] = [:]
        private var typeOf: [String: String] = [:]
        private var setsOf: [String: [String]] = [:]

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            depth += 1
            guard depth < 128, elements.count < 100_000, sets.count < 200_000 else {
                parser.abortParsing()
                return
            }
            if depth == 2 { section = name }
            func number(_ key: String) -> Float? {
                attributes[key].flatMap(Float.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            }
            switch section {
            case "units":
                if attributes["UnitType"] == "LENGTHUNIT", let value = number("SI_equivalent") {
                    scale = value
                }
            case "types":
                if depth == 3, let id = attributes["id"],
                    ["IfcReinforcingBarType", "IfcReinforcingMeshType", "IfcTendonType"].contains(name)
                {
                    types[id] = (
                        attributes["PredefinedType"], number("NominalDiameter"),
                        number("CrossSectionArea") ?? number("LongitudinalBarCrossSectionArea")
                    )
                }
            case "properties":
                if depth == 3, name == "IfcPropertySet", let id = attributes["id"] {
                    defining = (depth, id)
                    sets[id] = (attributes["Name"] ?? "", [:])
                } else if let current = defining, name == "IfcPropertySingleValue",
                    let property = attributes["Name"], let value = number("NominalValue")
                {
                    sets[current.id]?.values[property] = value
                }
            case "decomposition":
                if let id = attributes["id"], id.count == 22 {
                    if let kind = Self.kind(name) {
                        // Nested in the nearest building element above it, not an assembly or a
                        // storey.
                        let host = products.last { Self.isHost($0.ifcClass) }?.id
                        elements[id] = Metadata.Element(
                            kind: kind, role: attributes["PredefinedType"] ?? attributes["BarRole"],
                            diameter: number("NominalDiameter"),
                            area: number("CrossSectionArea") ?? number("LongitudinalBarCrossSectionArea"),
                            source: "its own attributes", host: host)
                    }
                    products.append((depth, id, name))
                } else if let href = attributes["xlink:href"] ?? attributes["href"], href.hasPrefix("#"),
                    let product = products.last, product.depth == depth - 1
                {
                    if name.hasSuffix("Type") { typeOf[product.id] = String(href.dropFirst()) }
                    if name == "IfcPropertySet" {
                        setsOf[product.id, default: []].append(String(href.dropFirst()))
                    }
                }
            default: break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
        ) {
            if defining?.depth == depth { defining = nil }
            if products.last?.depth == depth { products.removeLast() }
            depth -= 1
        }

        static func kind(_ name: String) -> IFCReinforcement.Bar.Kind? {
            switch name {
            case "IfcReinforcingBar": .bar
            case "IfcReinforcingMesh": .mesh
            case "IfcTendon": .tendon
            default: nil
            }
        }

        static func isHost(_ name: String) -> Bool {
            ["IfcWall", "IfcSlab", "IfcBeam", "IfcColumn", "IfcFooting", "IfcMember", "IfcPlate", "IfcRoof"]
                .contains { name.hasPrefix($0) }
        }

        func result() -> Metadata {
            var metadata = Metadata()
            metadata.scale = scale
            for (id, var element) in elements {
                // Where it gives no size of its own, its type's.
                if element.diameter == nil && element.area == nil,
                    let type = typeOf[id].flatMap({ types[$0] })
                {
                    element.diameter = type.diameter
                    element.area = type.area
                    element.source = "its type"
                }
                if element.role == nil || element.role == "NOTDEFINED",
                    let role = typeOf[id].flatMap({ types[$0]?.role })
                {
                    element.role = role
                }
                metadata.elements[id] = element
            }
            for (product, ids) in setsOf where elements[product] == nil {
                var properties = IFCReinforcement.Properties(source: "")
                var names: [String] = []
                for set in ids.compactMap({ sets[$0] }) {
                    var used = false
                    for (key, value) in set.values {
                        switch key {
                        case "ConcreteCover", "ConcreteCoverAtMainBars":
                            if properties.cover == nil || key == "ConcreteCoverAtMainBars" {
                                properties.cover = value * scale
                                used = true
                            }
                        case "ReinforcementAreaRatio":
                            // A ratio; written as a percentage where it is more than a fifth.
                            properties.areaRatio = value > 0.2 ? value / 100 : value
                            used = true
                        case "ReinforcementVolumeRatio":
                            // Steel's mass per volume of concrete (kg/m³).
                            properties.massRatio = value
                            used = true
                        default: break
                        }
                    }
                    if used { names.append(set.name) }
                }
                guard properties.cover != nil || properties.ratio != nil else { continue }
                properties.source = Array(Set(names)).sorted().joined(separator: ", ")
                metadata.properties[product] = properties
            }
            return metadata
        }
    }

    /// Of the readings of a written size in the project's unit, millimetres or centimetres (bar
    /// sizes are often written in millimetres, and areas in square centimetres, whatever the
    /// project's unit), the one nearest the measured size, or else one a bar could have (3 to
    /// 60 mm across).
    static func diameter(_ written: Float, scale: Float, measured: Float?) -> (value: Float, unit: String)? {
        let readings: [(Float, String)] = [
            (written * scale, "the project's unit"), (written * 0.001, "mm"), (written * 0.01, "cm"),
        ]
        if let measured, measured > 0 {
            let best = readings.min { abs(log($0.0 / measured)) < abs(log($1.0 / measured)) }!
            return abs(log(best.0 / measured)) < log(1.5) ? best : nil
        }
        return readings.first { $0.0 >= 0.003 && $0.0 <= 0.06 }
    }

    static func area(_ written: Float, scale: Float, diameter: Float?) -> (value: Float, unit: String)? {
        let readings: [(Float, String)] = [
            (written * scale * scale, "the project's unit"), (written * 1e-6, "mm²"), (written * 1e-4, "cm²"),
        ]
        if let diameter {
            let expected = Float.pi * diameter * diameter / 4
            let best = readings.min { abs(log($0.0 / expected)) < abs(log($1.0 / expected)) }!
            return abs(log(best.0 / expected)) < log(1.5) ? best : nil
        }
        return readings.first { $0.0 >= 7e-6 && $0.0 <= 3e-3 }
    }

    /// The reinforcement the IFC gives `elements`: its reinforcing elements converted and
    /// measured, given to the elements they lie in (`IFCReinforcement.host`), and its concrete
    /// elements' reinforcement properties. Returns the elements and notes for the import's report.
    /// Never fails the import: what cannot be read is said in the notes.
    static func attach(
        _ metadata: Metadata, to elements: [ImportedMesh.BuildingElement], ifc: Data, origin: SIMD3<Double>,
        converter: URL?
    ) async -> ([ImportedMesh.BuildingElement], [String]) {
        var result = elements
        var notes: [String] = []
        for index in result.indices {
            if let properties = metadata.properties[result[index].globalID] {
                result[index].reinforcement = IFCReinforcement.Hosted(properties: properties)
            }
        }
        let withProperties = result.filter { $0.reinforcement != nil }.count
        guard !metadata.elements.isEmpty else {
            if withProperties > 0 {
                notes.append(
                    "Reinforcement properties (cover or steel ratio) read for \(withProperties) element"
                        + "\(withProperties == 1 ? "" : "s"); the IFC has no reinforcing bars.")
            }
            return (result, notes)
        }
        var bars: [IFCReinforcement.Bar] = []
        var unmeasured = 0
        var unsized = 0
        do {
            let shapes = try await convert(ifc, converter: converter, origin: origin)
            for (id, element) in metadata.elements.sorted(by: { $0.key < $1.key }) {
                guard let triangles = shapes[id],
                    var bar = IFCReinforcement.Bar(
                        globalID: id, kind: element.kind, role: element.role, triangles: triangles)
                else {
                    unmeasured += 1
                    continue
                }
                let d = element.diameter.flatMap {
                    diameter($0, scale: metadata.scale, measured: bar.diameter)
                }
                let a = element.area.flatMap {
                    area($0, scale: metadata.scale, diameter: d?.value ?? bar.diameter)
                }
                if d != nil || a != nil {
                    bar.size(
                        diameter: d?.value, area: a?.value,
                        source: "\(element.source)" + (d.map { " (diameter in \($0.unit))" } ?? ""))
                } else {
                    unsized += 1
                }
                bars.append(bar)
            }
        } catch {
            notes.append(
                "The IFC's \(metadata.elements.count) reinforcing elements could not be converted (\(error.localizedDescription.prefix(200))): their bars are not placed."
            )
            return (result, notes)
        }
        let hosts = metadata.elements.compactMapValues(\.host)
        let (hosted, unhosted) = IFCReinforcement.host(bars, in: result, hosts: hosts)
        result = hosted
        let placed = bars.count - unhosted.count
        var text =
            "Reinforcement read from the IFC: \(placed) of its \(metadata.elements.count) reinforcing element"
            + "\(metadata.elements.count == 1 ? "" : "s") placed in the concrete elements they lie in"
        if unmeasured > 0 { text += "; \(unmeasured) without geometry the converter could make" }
        if !unhosted.isEmpty { text += "; \(unhosted.count) outside every chosen concrete element" }
        if unsized > 0 {
            text += "; \(unsized) sized from their shapes alone, the IFC giving no size that fits"
        }
        notes.append(text + ".")
        if withProperties > 0 {
            notes.append(
                "Reinforcement properties (cover or steel ratio) read for \(withProperties) element"
                    + "\(withProperties == 1 ? "" : "s").")
        }
        return (result, notes)
    }

    /// The reinforcing elements' shapes, converted alone, by GlobalId, in the building's
    /// coordinates (`origin` taken off, as the import does).
    static func convert(_ ifc: Data, converter: URL?, origin: SIMD3<Double>) async throws
        -> [String: [ImportedMesh.Triangle]]
    {
        let converter = try IFCImporter.requireConverter(converter)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bombcad-reinforcement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.ifc")
        let obj = folder.appendingPathComponent("reinforcement.obj")
        try ifc.write(to: input)
        _ = try await IFCImporter.run(
            converter,
            arguments: [
                input.path, obj.path, "-y", "--use-element-guids", "--weld-vertices", "--include", "entities",
            ]
                + classes, folder: folder)
        guard FileManager.default.fileExists(atPath: obj.path) else { return [:] }
        return try parseOBJ(try IFCImporter.boundedData(obj), origin: origin)
    }

    /// Triangles by group from the converter's OBJ, less `origin`.
    static func parseOBJ(_ data: Data, origin: SIMD3<Double>) throws -> [String: [ImportedMesh.Triangle]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportedMesh.ImportError.invalid("Reinforcement geometry is not UTF-8.")
        }
        var vertices: [SIMD3<Float>] = []
        var shapes: [String: [ImportedMesh.Triangle]] = [:]
        var group: String?
        var count = 0
        for raw in text.split(separator: "\n") {
            let f = raw.split(whereSeparator: \.isWhitespace)
            guard let tag = f.first else { continue }
            if tag == "g" || tag == "o" { group = f.count == 2 ? String(f[1]) : nil }
            if tag == "v", f.count >= 4, let x = Double(f[1]), let y = Double(f[2]), let z = Double(f[3]) {
                guard vertices.count < 2_000_000 else {
                    throw ImportedMesh.ImportError.invalid("Reinforcement geometry exceeds its limits.")
                }
                vertices.append(SIMD3<Float>(SIMD3(x, y, z) - origin))
            }
            if tag == "f", let group, f.count == 4 {
                let indices = f.dropFirst().compactMap { $0.split(separator: "/").first.flatMap { Int($0) } }
                guard indices.count == 3, indices.allSatisfy({ $0 > 0 && $0 <= vertices.count }),
                    count < 4_000_000
                else { continue }
                let triangle = ImportedMesh.Triangle(
                    vertices[indices[0] - 1], vertices[indices[1] - 1], vertices[indices[2] - 1])
                shapes[group, default: []].append(triangle)
                count += 1
            }
        }
        return shapes
    }
}
