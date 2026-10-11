import BlastCore
import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// The materials each IFC element is made of, from the converter's metadata: its material layers
/// (with their thicknesses, in metres) where the IFC gives a layer set, else its materials' names.
enum IFCMaterials {
    static func decode(_ data: Data) throws -> [String: [IFCStructure.Layer]] {
        let parser = Reader()
        let document = XMLParser(data: data)
        document.delegate = parser
        document.shouldResolveExternalEntities = false
        guard document.parse(), parser.issue == nil else {
            throw ImportedMesh.ImportError.invalid(
                "IFC material metadata could not be read: \(parser.issue ?? document.parserError?.localizedDescription ?? "invalid XML")"
            )
        }
        return parser.result()
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var issue: String?
        /// Metres per project length unit.
        private var scale: Float = 1
        private var section = ""
        private var depth = 0
        /// Material definitions by id: their layers (thickness in project units).
        private var definitions: [String: [(name: String, thickness: Float?)]] = [:]
        private var defining: (depth: Int, id: String)?
        /// Each product's references to material definitions, by GlobalId.
        private var references: [String: [String]] = [:]
        private var products: [(depth: Int, id: String)] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            depth += 1
            guard depth < 128, definitions.count < 50_000, references.count < 50_000 else {
                issue = "metadata exceeds its limits"
                parser.abortParsing()
                return
            }
            if depth == 2 { section = name }
            switch section {
            case "units":
                if attributes["UnitType"] == "LENGTHUNIT",
                    let value = attributes["SI_equivalent"].flatMap(Float.init),
                    value.isFinite, value > 0
                {
                    scale = value
                }
            case "materials":
                if let id = attributes["id"], depth == 3 {
                    defining = (depth, id)
                    if name == "IfcMaterial" {
                        definitions[id] = [(String((attributes["Name"] ?? "").prefix(200)), nil)]
                    } else {
                        definitions[id] = []
                    }
                } else if let current = defining,
                    name == "IfcMaterialLayer" || name == "IfcMaterial"
                        || name == "IfcMaterialConstituent" || name == "IfcMaterialProfile"
                {
                    let thickness = attributes["LayerThickness"].flatMap(Float.init)
                    definitions[current.id, default: []].append(
                        (String((attributes["Name"] ?? attributes["Category"] ?? "").prefix(200)), thickness))
                }
            case "decomposition":
                if let id = attributes["id"], id.count == 22 {
                    products.append((depth, id))
                } else if let href = attributes["xlink:href"] ?? attributes["href"], href.hasPrefix("#"),
                    name.hasPrefix("IfcMaterial"), let product = products.last, product.depth == depth - 1
                {
                    references[product.id, default: []].append(String(href.dropFirst()))
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

        func result() -> [String: [IFCStructure.Layer]] {
            references.mapValues { ids in
                ids.flatMap { definitions[$0] ?? [] }.filter { !$0.name.isEmpty }.map {
                    IFCStructure.Layer(name: $0.name, thickness: $0.thickness.map { $0 * scale })
                }
            }.filter { !$0.value.isEmpty }
        }
    }
}
