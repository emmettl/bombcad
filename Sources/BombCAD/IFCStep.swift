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
        statements(data) { statement, _ in
            if let entity = parse(statement, keep: keep) { result[entity.id] = entity }
        }
        return result
    }

    /// Each statement's bytes, comments and line breaks left out, and the range of the file it
    /// takes, its `;` included.
    static func statements(_ data: Data, _ visit: ([UInt8], Range<Int>) -> Void) {
        var statement: [UInt8] = []
        var start = 0
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
                } else if byte == UInt8(ascii: ";") {
                    visit(statement, start..<index)
                    statement.removeAll(keepingCapacity: true)
                } else if byte != 10 && byte != 13 {
                    if statement.isEmpty {
                        if byte == UInt8(ascii: " ") || byte == 9 { continue }
                        start = index - 1
                    }
                    if byte == UInt8(ascii: "'") { inString = true }
                    statement.append(byte)
                }
            }
        }
    }

    /// The curves a profile's outline is built from, and what they are placed by.
    static let curveClasses: Set<String> = [
        "IFCCOMPOSITECURVE", "IFCCOMPOSITECURVESEGMENT", "IFCREPARAMETRISEDCOMPOSITECURVESEGMENT",
        "IFCTRIMMEDCURVE", "IFCCIRCLE", "IFCELLIPSE", "IFCLINE", "IFCVECTOR", "IFCPOLYLINE",
        "IFCINDEXEDPOLYCURVE", "IFCOFFSETCURVE2D", "IFCBSPLINECURVEWITHKNOTS",
        "IFCRATIONALBSPLINECURVEWITHKNOTS", "IFCAXIS2PLACEMENT2D", "IFCAXIS2PLACEMENT3D",
    ]

    /// `data` with each composite curve given copies of its own of the segments it shares with
    /// others, and how many were copied. Exporters write a segment that two profiles have in common
    /// once (Revit, a steel section's fillet arcs); the converter then builds its edge for the
    /// first profile and reuses it in the next, whose own segments meet it a little apart, and
    /// that profile's end faces are lost, its mesh left open. The copies, and the curves and
    /// placements under them, are new entities after the curve; points and directions stay shared.
    static func unsharingCurveSegments(_ data: Data) -> (data: Data, copies: Int) {
        var curves: [Int: Entity] = [:]
        var ranges: [Int: Range<Int>] = [:]
        var last = 0
        statements(data) { statement, range in
            guard let entity = parse(statement, keep: { _ in true }) else { return }
            last = max(last, entity.id)
            guard curveClasses.contains(entity.name) else { return }
            curves[entity.id] = entity
            if entity.name == "IFCCOMPOSITECURVE" { ranges[entity.id] = range }
        }
        var uses: [Int: Int] = [:]
        for id in ranges.keys {
            for segment in Set(references(curves[id]!.arguments.first ?? "")) {
                uses[segment, default: 0] += 1
            }
        }
        guard uses.values.contains(where: { $0 > 1 }) else { return (data, 0) }
        var next = last + 1
        var copies = 0
        var seen = Set<Int>()
        // New statements in place of each composite curve that had to change.
        var replaced: [Int: String] = [:]
        for id in ranges.keys.sorted() {
            var curve = curves[id]!
            var added: [String] = []
            var copied: [Int: Int] = [:]
            func copy(_ n: Int) -> Int {
                guard let entity = curves[n] else { return n }
                if let done = copied[n] { return done }
                let new = next
                next += 1
                copied[n] = new
                let arguments = entity.arguments.map { rewriting($0, copy) }
                added.append("#\(new)=\(entity.name)(\(arguments.joined(separator: ",")));")
                return new
            }
            guard let list = curve.arguments.first else { continue }
            var changed = false
            curve.arguments[0] = rewriting(list) { segment in
                guard uses[segment, default: 0] > 1 else { return segment }
                if seen.insert(segment).inserted { return segment }
                changed = true
                copies += 1
                copied = [:]
                return copy(segment)
            }
            if changed {
                replaced[id] =
                    "#\(id)=IFCCOMPOSITECURVE(\(curve.arguments.joined(separator: ",")));\n"
                    + added.joined(separator: "\n")
            }
        }
        var result = Data()
        result.reserveCapacity(data.count + replaced.values.reduce(0) { $0 + $1.utf8.count })
        var position = data.startIndex
        for (id, text) in replaced.sorted(by: { ranges[$0.key]!.lowerBound < ranges[$1.key]!.lowerBound }) {
            let range = ranges[id]!
            result.append(data[position..<(data.startIndex + range.lowerBound)])
            result.append(Data(text.utf8))
            position = data.startIndex + range.upperBound
        }
        result.append(data[position...])
        return (result, copies)
    }

    /// The entity references (#n) in an argument, outside its strings.
    static func references(_ argument: String) -> [Int] {
        var found: [Int] = []
        _ = rewriting(argument) {
            found.append($0)
            return $0
        }
        return found
    }

    /// `argument` with each reference #n outside its strings replaced by #`map(n)`.
    static func rewriting(_ argument: String, _ map: (Int) -> Int) -> String {
        var result = ""
        var inString = false
        var characters = argument.makeIterator()
        var pending = characters.next()
        while let character = pending {
            pending = characters.next()
            if inString {
                result.append(character)
                if character == "'" { inString = false }
                continue
            }
            if character == "'" {
                inString = true
                result.append(character)
            } else if character == "#", let first = pending, first.isASCII, first.isNumber {
                var digits = ""
                while let digit = pending, digit.isASCII, digit.isNumber {
                    digits.append(digit)
                    pending = characters.next()
                }
                result += "#\(map(Int(digits)!))"
            } else {
                result.append(character)
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

    /// Each storey's elevation as the IFC gives it (in its length unit), by GlobalId.
    static func storeyElevations(_ data: Data) -> [String: Double] {
        var result: [String: Double] = [:]
        for entity in entities(data, where: { $0 == "IFCBUILDINGSTOREY" }).values
        where entity.arguments.count >= 10 {
            guard let id = entity.arguments.first.flatMap(string), let elevation = Double(entity.arguments[9])
            else {
                continue
            }
            result[id] = elevation
        }
        return result
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
