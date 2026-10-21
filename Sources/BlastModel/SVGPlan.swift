import Foundation
import simd

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// A floor plan read from SVG, as drawing programs and CAD exports give one: lines, polylines,
/// polygons, rectangles, circles, ellipses and paths (curves and arcs flattened in pieces of at
/// most 15°, as the DXF reader flattens arcs), each on the layer of the group it lies in (an
/// Inkscape layer's label, else the outermost group's id), with transforms applied and y turned up.
/// A `<use>` of a symbol is a block of its own, so that a window drawn as a symbol is grouped as a
/// DXF block's is. Its unit is the document's size over its view box where the size is given in
/// a physical unit (mm, cm, in, pt, pc); in pixels or none, the plan's scale is asked for.
/// Text, fills, images and styles are passed over.
extension DXFDrawing {
    public init(svg data: Data) throws { try self.init(svg: data, pieceLimit: Self.pieceLimit) }

    /// Reads an SVG, refusing it past `pieceLimit` pieces (`DXFDrawing.pieceLimit` but in tests).
    init(svg data: Data, pieceLimit: Int) throws {
        guard data.count <= Self.sizeLimit else { throw ReadError(message: "The SVG is over 100 MB.") }
        let tree = try SVGTree(data: data)
        guard let root = tree.root, root.name == "svg" else {
            throw ReadError(message: "Not an SVG: no svg element.")
        }
        var reader = SVGReader(ids: tree.ids)
        reader.limit = pieceLimit
        var known: [ObjectIdentifier: Int] = [:]
        let shapes = reader.shapes(under: root, known: &known)
        // y up: the plan's y is the SVG's turned over.
        if shapes <= pieceLimit / 2 {
            reader.walk(root, transform: .init(a: 1, b: 0, c: 0, d: -1, e: 0, f: 0), layer: "0", depth: 0)
        }
        guard shapes <= pieceLimit / 2, reader.pieces <= pieceLimit else {
            throw ReadError(
                message:
                    "The SVG comes to more than 5,000,000 pieces, the copies its <use> elements make counted: more than a plan needs."
            )
        }
        var names: [String] = []
        var named = Set<String>()
        // A block's own layer "0" takes its insert's: not a layer of the drawing.
        for entity in reader.entities + reader.blocks.values.flatMap(\.entities).filter({ $0.layer != "0" })
        where named.insert(entity.layer).inserted {
            names.append(entity.layer)
        }
        self.init(
            layers: names, entities: reader.entities, blocks: reader.blocks, unitMetres: Self.svgUnit(root))
        try checkFinite()
    }

    /// Metres per user unit from the root's width (or height) in a physical unit over its view
    /// box's; nil in pixels or without a unit.
    static func svgUnit(_ root: SVGTree.Node) -> Double? {
        let units: [String: Double] = [
            "mm": 0.001, "cm": 0.01, "m": 1, "in": 0.0254, "pt": 0.0254 / 72, "pc": 0.0254 / 6,
        ]
        let box = root.attributes["viewBox"].map(SVGReader.numbers) ?? []
        for (key, index) in [("width", 2), ("height", 3)] {
            guard let text = root.attributes[key]?.trimmingCharacters(in: .whitespaces) else { continue }
            // The longest unit that ends it ("mm" before "m").
            guard
                let unit = units.sorted(by: { $0.key.count > $1.key.count }).first(where: {
                    text.hasSuffix($0.key)
                }),
                let value = Double(text.dropLast(unit.key.count).trimmingCharacters(in: .whitespaces))
            else { continue }
            let span = box.count == 4 ? box[index] : value
            // A size or view box of 1e309, NaN or below zero gives no unit to go by.
            let metres = value * unit.value / span
            guard span > 0, metres.isFinite, metres > 0 else { continue }
            return metres
        }
        return nil
    }
}

/// An SVG document as a tree of elements, from Foundation's parser.
struct SVGTree {
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        package init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    var root: Node?
    var ids: [String: Node] = [:]
    /// The deepest an element may be nested (the root at depth 1).
    static let depthLimit = 64

    /// Whether `data` may be handed to XMLParser: UTF-8 that is valid, UTF-16 with its byte-order
    /// mark, or text whose declaration names one of the 8-bit encodings that libxml2 converts to
    /// valid UTF-8 itself. Linux's FoundationXML traps (SIGILL, in `_NSXMLParserStartElementNs`) on
    /// a name that is not valid UTF-8, which libxml2 passes on from a file it takes as UTF-8
    /// (`<p\u{F4}i/>`), or whose declared encoding it does not know (`encoding="UTF%8"`); XML in
    /// invalid UTF-8 is malformed anyway.
    static func isXMLText(_ data: Data) -> Bool {
        if String(data: data, encoding: .utf8) != nil { return true }
        let start = Array(data.prefix(200))
        if start.starts(with: [0xFE, 0xFF]) || start.starts(with: [0xFF, 0xFE]) { return true }
        // `<?xml version="1.0" encoding="ISO-8859-1"?>`.
        let head = String(decoding: start, as: UTF8.self).lowercased()
        guard head.hasPrefix("<?xml"), let range = head.range(of: "encoding=") else { return false }
        let name = head[range.upperBound...].dropFirst().prefix { $0 != "\"" && $0 != "'" }
        return ["iso-8859-1", "latin1", "iso-8859-15", "windows-1252", "cp1252"].contains(String(name))
    }

    init(data: Data) throws {
        guard Self.isXMLText(data) else {
            throw DXFDrawing.ReadError(
                message: "Not an SVG: it is not valid UTF-8 text, and names no other encoding.")
        }
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        // Linux's parser (FoundationXML over libxml2) can recover from a tag left open or closed by
        // another's name and still say it parsed; the builder's own count of open elements decides.
        let parsed = parser.parse()
        guard !builder.tooDeep else {
            throw DXFDrawing.ReadError(
                message:
                    "The SVG nests its elements more than \(Self.depthLimit) deep, which no drawing needs.")
        }
        guard parsed, !builder.malformed, builder.stack.isEmpty, let root = builder.root else {
            throw DXFDrawing.ReadError(
                message:
                    "Not an SVG: \(parser.parserError?.localizedDescription ?? "it does not read as XML").")
        }
        self.root = root
        ids = builder.ids
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var ids: [String: Node] = [:]
        /// An element closed by another's name, or a close with nothing open.
        var malformed = false
        /// Elements opened more than `depthLimit` deep: the walk down the tree recurses once a
        /// level, and thousands of levels overflowed the stack.
        var tooDeep = false

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard stack.count < SVGTree.depthLimit else {
                tooDeep = true
                parser.abortParsing()
                return
            }
            // Namespaced names (svg:path) as plain ones.
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let node = Node(name: local, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            if let id = attributes["id"] { ids[id] = node }
            stack.append(node)
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
        ) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if stack.popLast()?.name != local { malformed = true }
        }
    }
}

/// An affine map of the plane: (x, y) to (a x + c y + e, b x + d y + f), as SVG writes it.
struct SVGTransform {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }

    /// This map after `other`: other's first.
    func then(_ other: SVGTransform) -> SVGTransform {
        // self ∘ other
        SVGTransform(
            a: a * other.a + c * other.b, b: b * other.a + d * other.b, c: a * other.c + c * other.d,
            d: b * other.c + d * other.d, e: a * other.e + c * other.f + e, f: b * other.e + d * other.f + f)
    }

    /// A transform attribute's list, applied left to right as SVG composes it.
    static func parse(_ text: String) -> SVGTransform {
        var result = SVGTransform()
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ","))
        while !scanner.isAtEnd {
            guard let name = scanner.scanCharacters(from: .letters), scanner.scanString("(") != nil,
                let inside = scanner.scanUpToString(")"), scanner.scanString(")") != nil
            else { break }
            let n = SVGReader.numbers(inside)
            var t = SVGTransform()
            switch name {
            case "matrix" where n.count == 6:
                t = SVGTransform(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
            case "translate" where !n.isEmpty: t = SVGTransform(e: n[0], f: n.count > 1 ? n[1] : 0)
            case "scale" where !n.isEmpty: t = SVGTransform(a: n[0], d: n.count > 1 ? n[1] : n[0])
            case "rotate" where !n.isEmpty:
                let r = n[0] * .pi / 180
                t = SVGTransform(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
                if n.count == 3 {
                    t = SVGTransform(e: n[1], f: n[2]).then(t).then(SVGTransform(e: -n[1], f: -n[2]))
                }
            case "skewX" where !n.isEmpty: t = SVGTransform(c: tan(n[0] * .pi / 180))
            case "skewY" where !n.isEmpty: t = SVGTransform(b: tan(n[0] * .pi / 180))
            default: break
            }
            result = result.then(t)
        }
        return result
    }
}

/// Walks an SVG tree into a drawing's entities.
struct SVGReader {
    let ids: [String: SVGTree.Node]
    var entities: [DXFDrawing.Entity] = []
    var blocks: [String: DXFDrawing.Block] = [:]
    /// The points read so far, those of every copy a `<use>` makes included: past
    /// `limit` the walk stops, and the drawing is refused.
    var pieces = 0
    var limit = DXFDrawing.pieceLimit
    /// The largest angle an arc's piece spans, radians.
    static let arcStep = Double.pi / 12

    init(ids: [String: SVGTree.Node]) { self.ids = ids }

    /// Numbers in an attribute, however separated ("1,2 3e-1-4").
    static func numbers(_ text: String) -> [Double] {
        var result: [Double] = []
        var token = ""
        var previous: Character = " "
        func flush() {
            if let value = Double(token) { result.append(value) }
            token = ""
        }
        for ch in text {
            if ch.isNumber || ch == "." && !token.contains(".") && !token.contains("e") {
                token.append(ch)
            } else if ch == "." {
                flush()
                token = "."
            } else if ch == "-" || ch == "+" {
                if previous == "e" || previous == "E" {
                    token.append(ch)
                } else {
                    flush()
                    token = String(ch)
                }
            } else if ch == "e" || ch == "E" {
                token.append(ch)
            } else {
                flush()
            }
            previous = ch
        }
        flush()
        return result
    }

    private func number(_ node: SVGTree.Node, _ key: String) -> Double {
        node.attributes[key].flatMap { Self.numbers($0).first } ?? 0
    }

    /// The layer an element's groups put it on: an Inkscape layer's label, else the outermost
    /// group's id.
    private func layer(of group: SVGTree.Node, within layer: String, depth: Int) -> String {
        if group.attributes["inkscape:groupmode"] == "layer" {
            return group.attributes["inkscape:label"] ?? group.attributes["id"] ?? layer
        }
        if layer == "0", depth <= 1, let id = group.attributes["id"] ?? group.attributes["inkscape:label"] {
            return id
        }
        return layer
    }

    /// The shapes `walk` would draw under `node`, a `<use>` counting its target's again, counted
    /// without parsing a path: each shape is two points or more, so a file whose copies come to
    /// past the limit is refused before they are made, rather than after the copying up to it.
    func shapes(under node: SVGTree.Node, known: inout [ObjectIdentifier: Int]) -> Int {
        // As walkShape draws a used element: groups opened, shapes counted, nothing else.
        func drawn(_ node: SVGTree.Node) -> Int {
            switch node.name {
            case "g", "a": return node.children.reduce(0) { min($0 + drawn($1), Int.max / 4) }
            case "line", "polyline", "polygon", "rect", "circle", "ellipse", "path": return 1
            default: return 0
            }
        }
        switch node.name {
        case "defs", "symbol", "clipPath", "mask", "pattern", "marker", "metadata", "title", "desc", "style",
            "text", "image":
            return 0
        case "svg", "g", "a", "switch":
            return node.children.reduce(0) { min($0 + shapes(under: $1, known: &known), Int.max / 4) }
        case "use":
            let reference = (node.attributes["href"] ?? node.attributes["xlink:href"] ?? "")
            guard reference.hasPrefix("#"), let target = ids[String(reference.dropFirst())] else { return 0 }
            if let count = known[ObjectIdentifier(target)] { return count }
            let count = (target.name == "symbol" ? target.children : [target]).reduce(0) {
                min($0 + drawn($1), Int.max / 4)
            }
            known[ObjectIdentifier(target)] = count
            return count
        default: return drawn(node)
        }
    }

    mutating func walk(_ node: SVGTree.Node, transform: SVGTransform, layer: String, depth: Int) {
        guard pieces <= limit else { return }
        var transform = transform
        if let text = node.attributes["transform"] { transform = transform.then(SVGTransform.parse(text)) }
        switch node.name {
        case "defs", "symbol", "clipPath", "mask", "pattern", "marker", "metadata", "title", "desc", "style",
            "text", "image":
            return
        case "svg" where depth > 0, "g", "a", "switch":
            let inner = node.name == "g" ? self.layer(of: node, within: layer, depth: depth) : layer
            for child in node.children { walk(child, transform: transform, layer: inner, depth: depth + 1) }
        case "svg":
            for child in node.children { walk(child, transform: transform, layer: layer, depth: depth + 1) }
        case "use":
            let reference = (node.attributes["href"] ?? node.attributes["xlink:href"] ?? "")
            guard reference.hasPrefix("#"), let target = ids[String(reference.dropFirst())] else { return }
            let placed = transform.then(SVGTransform(e: number(node, "x"), f: number(node, "y")))
            // The referenced element (or a symbol's children) drawn here, as a block of its own.
            var inner = SVGReader(ids: ids)
            let children = target.name == "symbol" ? target.children : [target]
            for child in children { inner.walkShape(child, transform: placed, layer: "0") }
            pieces += inner.pieces
            guard !inner.entities.isEmpty, pieces <= limit else { return }
            let name = "use \(blocks.count + 1)"
            blocks[name] = DXFDrawing.Block(base: .zero, entities: inner.entities)
            for (key, block) in inner.blocks { blocks[key] = block }
            entities.append(
                DXFDrawing.Entity(
                    layer: layer,
                    shape: .insert(block: name, position: .zero, scale: SIMD2(1, 1), rotation: 0)))
        default:
            walkShape(node, transform: transform, layer: layer)
        }
    }

    /// A shape element (or a group of them, inside a used symbol).
    mutating func walkShape(_ node: SVGTree.Node, transform: SVGTransform, layer: String) {
        var transform = transform
        if node.name != "svg", let text = node.attributes["transform"], node.name != "g" {
            transform = transform.then(SVGTransform.parse(text))
        }
        func add(_ points: [SIMD2<Double>], closed: Bool) {
            let mapped = points.map(transform.apply)
            guard mapped.count >= 2 else { return }
            pieces += mapped.count
            if mapped.count == 2 && !closed {
                entities.append(DXFDrawing.Entity(layer: layer, shape: .line(mapped[0], mapped[1])))
            } else {
                entities.append(
                    DXFDrawing.Entity(
                        layer: layer,
                        shape: .polyline(
                            mapped, bulges: Array(repeating: 0, count: mapped.count), closed: closed)))
            }
        }
        switch node.name {
        case "g", "a":
            let inner =
                node.attributes["transform"].map { transform.then(SVGTransform.parse($0)) } ?? transform
            for child in node.children { walkShape(child, transform: inner, layer: layer) }
        case "line":
            add(
                [
                    SIMD2(number(node, "x1"), number(node, "y1")),
                    SIMD2(number(node, "x2"), number(node, "y2")),
                ],
                closed: false)
        case "polyline", "polygon":
            let n = Self.numbers(node.attributes["points"] ?? "")
            let points = stride(from: 0, to: n.count - 1, by: 2).map { SIMD2(n[$0], n[$0 + 1]) }
            add(points, closed: node.name == "polygon")
        case "rect":
            let (x, y) = (number(node, "x"), number(node, "y"))
            let (w, h) = (number(node, "width"), number(node, "height"))
            guard w > 0, h > 0 else { return }
            add([SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h)], closed: true)
        case "circle", "ellipse":
            let centre = SIMD2(number(node, "cx"), number(node, "cy"))
            let rx = node.name == "circle" ? number(node, "r") : number(node, "rx")
            let ry = node.name == "circle" ? rx : number(node, "ry")
            guard rx > 0, ry > 0 else { return }
            let n = Int((2 * Double.pi / Self.arcStep).rounded(.up))
            add(
                (0..<n).map { k in
                    let t = 2 * Double.pi * Double(k) / Double(n)
                    return centre + SIMD2(rx * cos(t), ry * sin(t))
                }, closed: true)
        case "path":
            for (points, closed) in Self.path(node.attributes["d"] ?? "") { add(points, closed: closed) }
        default:
            break
        }
    }

    /// A path's subpaths as points, curves and arcs flattened, and whether each is closed.
    static func path(_ d: String) -> [(points: [SIMD2<Double>], closed: Bool)] {
        // Tokens: command letters and numbers (an arc's flags may run together: "a5 5 0 015 5").
        var tokens: [Either] = []
        enum Either {
            case command(Character)
            case number(Double)
        }
        var text = ""
        func flush() {
            for value in numbers(text) { tokens.append(.number(value)) }
            text = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush()
                tokens.append(.command(ch))
            } else {
                text.append(ch)
            }
        }
        flush()
        var result: [(points: [SIMD2<Double>], closed: Bool)] = []
        var current: [SIMD2<Double>] = []
        var point = SIMD2<Double>.zero
        var start = SIMD2<Double>.zero
        var lastControl: SIMD2<Double>?
        var lastQuadratic: SIMD2<Double>?
        var index = 0
        var command: Character = "M"
        func finish(closed: Bool) {
            if current.count >= 2 { result.append((current, closed)) }
            current = []
        }
        func take(_ count: Int) -> [Double]? {
            var values: [Double] = []
            var at = index
            while values.count < count, at < tokens.count {
                guard case .number(let v) = tokens[at] else { return nil }
                values.append(v)
                at += 1
            }
            guard values.count == count else { return nil }
            index = at
            return values
        }
        // An arc's flags are single digits that may run into the next number.
        func takeArc() -> [Double]? {
            guard let first = take(3) else { return nil }
            var flags: [Double] = []
            while flags.count < 2, index < tokens.count, case .number(let v) = tokens[index] {
                if v == 0 || v == 1 {
                    flags.append(v)
                    index += 1
                } else {
                    // "015" read as 15 after 0: split a run of flag digits.
                    let digits = String(format: "%g", v)
                    guard let firstDigit = digits.first, firstDigit == "0" || firstDigit == "1" else {
                        return nil
                    }
                    flags.append(firstDigit == "1" ? 1 : 0)
                    let rest = Double(digits.dropFirst()) ?? 0
                    tokens[index] = .number(rest)
                }
            }
            guard flags.count == 2, let end = take(2) else { return nil }
            return first + flags + end
        }
        while index < tokens.count {
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
                if c == "Z" || c == "z" {
                    // Closed: the polyline's last edge runs back to its first point.
                    if current.count > 2, let first = current.first, let last = current.last,
                        simd_distance(first, last) < 1e-12
                    {
                        current.removeLast()
                    }
                    finish(closed: true)
                    point = start
                    lastControl = nil
                    lastQuadratic = nil
                    continue
                }
            }
            let relative = command.isLowercase
            let base = relative ? point : .zero
            switch command.uppercased().first ?? "M" {
            case "M":
                guard let v = take(2) else {
                    index = tokens.count
                    break
                }
                finish(closed: false)
                point = base + SIMD2(v[0], v[1])
                start = point
                current = [point]
                // Further pairs after a move are lines.
                command = relative ? "l" : "L"
                lastControl = nil
                lastQuadratic = nil
            case "L":
                guard let v = take(2) else {
                    index = tokens.count
                    break
                }
                point = base + SIMD2(v[0], v[1])
                current.append(point)
                lastControl = nil
                lastQuadratic = nil
            case "H":
                guard let v = take(1) else {
                    index = tokens.count
                    break
                }
                point = SIMD2(relative ? point.x + v[0] : v[0], point.y)
                current.append(point)
                lastControl = nil
                lastQuadratic = nil
            case "V":
                guard let v = take(1) else {
                    index = tokens.count
                    break
                }
                point = SIMD2(point.x, relative ? point.y + v[0] : v[0])
                current.append(point)
                lastControl = nil
                lastQuadratic = nil
            case "C", "S":
                let isSmooth = command.uppercased() == "S"
                guard let v = take(isSmooth ? 4 : 6) else {
                    index = tokens.count
                    break
                }
                let c1 =
                    isSmooth ? (lastControl.map { 2 * point - $0 } ?? point) : base + SIMD2(v[0], v[1])
                let c2 = base + (isSmooth ? SIMD2(v[0], v[1]) : SIMD2(v[2], v[3]))
                let end = base + (isSmooth ? SIMD2(v[2], v[3]) : SIMD2(v[4], v[5]))
                let p0 = point
                for k in 1...8 {
                    let t = Double(k) / 8
                    let u = 1 - t
                    current.append(u * u * u * p0 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * end)
                }
                point = end
                lastControl = c2
                lastQuadratic = nil
            case "Q", "T":
                let isSmooth = command.uppercased() == "T"
                guard let v = take(isSmooth ? 2 : 4) else {
                    index = tokens.count
                    break
                }
                let control =
                    isSmooth ? (lastQuadratic.map { 2 * point - $0 } ?? point) : base + SIMD2(v[0], v[1])
                let end = base + (isSmooth ? SIMD2(v[0], v[1]) : SIMD2(v[2], v[3]))
                let p0 = point
                for k in 1...8 {
                    let t = Double(k) / 8
                    let u = 1 - t
                    current.append(u * u * p0 + 2 * u * t * control + t * t * end)
                }
                point = end
                lastQuadratic = control
                lastControl = nil
            case "A":
                guard let v = takeArc() else {
                    index = tokens.count
                    break
                }
                let end = base + SIMD2(v[5], v[6])
                current += arcPoints(
                    from: point, to: end, radii: SIMD2(abs(v[0]), abs(v[1])), rotation: v[2] * .pi / 180,
                    large: v[3] != 0, sweep: v[4] != 0)
                point = end
                lastControl = nil
                lastQuadratic = nil
            default:
                index += 1
            }
        }
        finish(closed: false)
        return result
    }

    /// An elliptical arc in SVG's endpoint form (SVG 1.1, F.6.5) as points after `from`, in pieces
    /// of at most `arcStep`.
    static func arcPoints(
        from p0: SIMD2<Double>, to p1: SIMD2<Double>, radii: SIMD2<Double>, rotation phi: Double, large: Bool,
        sweep: Bool
    ) -> [SIMD2<Double>] {
        guard radii.x > 0, radii.y > 0, simd_distance(p0, p1) > 1e-12 else { return [p1] }
        let (cosPhi, sinPhi) = (cos(phi), sin(phi))
        let half = (p0 - p1) / 2
        let x1 = SIMD2(cosPhi * half.x + sinPhi * half.y, -sinPhi * half.x + cosPhi * half.y)
        var r = radii
        let lambda = (x1.x * x1.x) / (r.x * r.x) + (x1.y * x1.y) / (r.y * r.y)
        if lambda > 1 { r *= sqrt(lambda) }
        let numerator = r.x * r.x * r.y * r.y - r.x * r.x * x1.y * x1.y - r.y * r.y * x1.x * x1.x
        let denominator = r.x * r.x * x1.y * x1.y + r.y * r.y * x1.x * x1.x
        var factor = sqrt(max(numerator / denominator, 0))
        if large == sweep { factor = -factor }
        let c1 = factor * SIMD2(r.x * x1.y / r.y, -r.y * x1.x / r.x)
        let centre = SIMD2(cosPhi * c1.x - sinPhi * c1.y, sinPhi * c1.x + cosPhi * c1.y) + (p0 + p1) / 2
        func angle(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double {
            let a = atan2(u.x * v.y - u.y * v.x, simd_dot(u, v))
            return a
        }
        let u = SIMD2((x1.x - c1.x) / r.x, (x1.y - c1.y) / r.y)
        let v = SIMD2((-x1.x - c1.x) / r.x, (-x1.y - c1.y) / r.y)
        let theta = angle(SIMD2(1, 0), u)
        var delta = angle(u, v)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        // Radii or ends so large that the arithmetic overflows (a corrupt file's) leave no arc to
        // draw: the path goes straight to the end, as it does where a radius is zero.
        guard delta.isFinite, theta.isFinite, centre.x.isFinite, centre.y.isFinite else { return [p1] }
        let n = max(1, Int((abs(delta) / arcStep).rounded(.up)))
        return (1...n).map { k in
            if k == n { return p1 }
            let t = theta + delta * Double(k) / Double(n)
            let e = SIMD2(r.x * cos(t), r.y * sin(t))
            return centre + SIMD2(cosPhi * e.x - sinPhi * e.y, sinPhi * e.x + cosPhi * e.y)
        }
    }
}
