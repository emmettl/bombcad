import Foundation

/// What the converter's metadata leaves out, read from the IFC's own STEP text: products that
/// are in no spatial structure, and the project's length unit where the converter cannot find it.
enum IFCStep {
    struct Entity: Equatable {
        var id: Int
        /// Its class as written, upper case (IFCWALL).
        var name: String
        /// Its arguments, unparsed, at the top level.
        var arguments: [String]
    }

    /// The DATA section's entities whose class `keep` accepts, by id.
    static func entities(_ data: Data, where keep: (String) -> Bool) -> [Int: Entity] {
        var result: [Int: Entity] = [:]
        var statement: [UInt8] = []
        var inString = false
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if inString {
                    statement.append(byte)
                    if byte == UInt8(ascii: "'") {
                        // '' inside a string is a quote, not its end.
                        if index < bytes.count && bytes[index] == UInt8(ascii: "'") {
                            statement.append(byte)
                            index += 1
                        } else {
                            inString = false
                        }
                    }
                    continue
                }
                if byte == UInt8(ascii: "/") && index < bytes.count && bytes[index] == UInt8(ascii: "*") {
                    // A comment, to its end.
                    index += 1
                    while index + 1 < bytes.count
                        && !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/"))
                    {
                        index += 1
                    }
                    index += 2
                } else if byte == UInt8(ascii: "'") {
                    inString = true
                    statement.append(byte)
                } else if byte == UInt8(ascii: ";") {
                    if let entity = parse(statement, keep: keep) { result[entity.id] = entity }
                    statement.removeAll(keepingCapacity: true)
                } else if byte != 10 && byte != 13 {
                    statement.append(byte)
                }
            }
        }
        return result
    }

    private static func parse(_ bytes: [UInt8], keep: (String) -> Bool) -> Entity? {
        guard let hash = bytes.firstIndex(where: { $0 != UInt8(ascii: " ") && $0 != 9 }),
            bytes[hash] == UInt8(ascii: "#"),
            let equals = bytes.firstIndex(of: UInt8(ascii: "=")),
            let id = Int(
                String(decoding: bytes[(hash + 1)..<equals], as: UTF8.self).trimmingCharacters(
                    in: .whitespaces)),
            let open = bytes[equals...].firstIndex(of: UInt8(ascii: "("))
        else { return nil }
        let name = String(decoding: bytes[(equals + 1)..<open], as: UTF8.self).trimmingCharacters(
            in: .whitespaces
        )
        .uppercased()
        guard !name.isEmpty, keep(name), let close = bytes.lastIndex(of: UInt8(ascii: ")")), close > open
        else {
            return nil
        }
        return Entity(id: id, name: name, arguments: split(Array(bytes[(open + 1)..<close])))
    }

    /// Top-level comma-separated arguments.
    static func split(_ bytes: [UInt8]) -> [String] {
        var parts: [String] = []
        var current: [UInt8] = []
        var depth = 0
        var inString = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inString {
                current.append(byte)
                if byte == UInt8(ascii: "'") {
                    if index < bytes.count && bytes[index] == UInt8(ascii: "'") {
                        current.append(byte)
                        index += 1
                    } else {
                        inString = false
                    }
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "'"):
                inString = true
                current.append(byte)
            case UInt8(ascii: "("):
                depth += 1
                current.append(byte)
            case UInt8(ascii: ")"):
                depth -= 1
                current.append(byte)
            case UInt8(ascii: ",") where depth == 0:
                parts.append(String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespaces))
                current.removeAll()
            default:
                current.append(byte)
            }
        }
        parts.append(String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// A STEP string argument's text ('it''s' → it's), or nil for $ and anything else.
    static func string(_ argument: String) -> String? {
        guard argument.count >= 2, argument.hasPrefix("'"), argument.hasSuffix("'") else { return nil }
        return String(argument.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }

    static func reference(_ argument: String) -> Int? {
        argument.hasPrefix("#") ? Int(argument.dropFirst()) : nil
    }

    /// The products of the classes in `classes` (IFC names, as IfcWall), with their GlobalId and
    /// name.
    static func products(_ data: Data, classes: Set<String>) -> [(id: String, name: String, ifcClass: String)]
    {
        let names = Dictionary(uniqueKeysWithValues: classes.map { ($0.uppercased(), $0) })
        return entities(data) { names[$0] != nil }.values.sorted { $0.id < $1.id }.compactMap { entity in
            guard let id = entity.arguments.first.flatMap(string), let ifcClass = names[entity.name] else {
                return nil
            }
            let name = entity.arguments.count > 2 ? string(entity.arguments[2]) : nil
            return (id, String((name ?? ifcClass).prefix(200)), ifcClass)
        }
    }

    static let prefixes: [String: Double] = [
        "EXA": 1e18, "PETA": 1e15, "TERA": 1e12, "GIGA": 1e9, "MEGA": 1e6, "KILO": 1e3, "HECTO": 1e2,
        "DECA": 1e1, "DECI": 1e-1, "CENTI": 1e-2, "MILLI": 1e-3, "MICRO": 1e-6, "NANO": 1e-9, "PICO": 1e-12,
        "FEMTO": 1e-15, "ATTO": 1e-18,
    ]

    /// Metres per length unit of the file's one IfcProject, with the unit's name: an SI unit with
    /// its prefix, or a conversion-based one (feet, inches) by its factor; nil unless there is
    /// exactly one project with exactly one length unit.
    static func lengthUnit(_ data: Data) -> (metres: Double, name: String)? {
        let wanted: Set<String> = [
            "IFCPROJECT", "IFCUNITASSIGNMENT", "IFCSIUNIT", "IFCCONVERSIONBASEDUNIT", "IFCMEASUREWITHUNIT",
        ]
        let all = entities(data) { wanted.contains($0) }
        let projects = all.values.filter { $0.name == "IFCPROJECT" }
        guard projects.count == 1, let project = projects.first, project.arguments.count >= 9,
            let assignment = reference(project.arguments[8]).flatMap({ all[$0] }),
            assignment.name == "IFCUNITASSIGNMENT", let list = assignment.arguments.first
        else { return nil }
        func si(_ unit: Entity) -> Double? {
            guard unit.name == "IFCSIUNIT", unit.arguments.count >= 4, unit.arguments[3] == ".METRE." else {
                return nil
            }
            let prefix = unit.arguments[2].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return unit.arguments[2] == "$" ? 1 : prefixes[prefix]
        }
        var found: [(Double, String)] = []
        for item in split(Array(list.dropFirst().dropLast().utf8)) {
            guard let unit = reference(item).flatMap({ all[$0] }), unit.arguments.count >= 2,
                unit.arguments[1] == ".LENGTHUNIT."
            else { continue }
            if let metres = si(unit) {
                let prefix =
                    unit.arguments[2] == "$"
                    ? ""
                    : unit.arguments[2].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                found.append((metres, prefix + "metre"))
            } else if unit.name == "IFCCONVERSIONBASEDUNIT", unit.arguments.count >= 4,
                let measure = reference(unit.arguments[3]).flatMap({ all[$0] }), measure.arguments.count >= 2,
                let base = reference(measure.arguments[1]).flatMap({ all[$0] }).flatMap(si)
            {
                // IFCLENGTHMEASURE(0.3048) or a bare number.
                let text = measure.arguments[0]
                let number =
                    text.firstIndex(of: "(").map { String(text[text.index(after: $0)...].dropLast()) } ?? text
                if let value = Double(number), value.isFinite, value > 0 {
                    found.append((value * base, string(unit.arguments[2])?.lowercased() ?? "unit"))
                }
            }
        }
        guard found.count == 1, let unit = found.first, unit.0.isFinite, unit.0 > 0 else { return nil }
        return unit
    }
}
