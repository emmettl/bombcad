import Foundation
import simd

/// A 2D drawing read from an ASCII DXF file, as a floor plan is handed over: the subset a plan
/// needs (LINE, LWPOLYLINE and POLYLINE, ARC, CIRCLE, INSERT of BLOCKs), each entity on its layer,
/// with the drawing's units where its header gives them ($INSUNITS). Heights, text, hatching,
/// dimensions and 3D entities are passed over. Binary DXF and DWG are not read.
public struct DXFDrawing: Sendable {
    public enum Shape: Sendable, Equatable {
        case line(SIMD2<Double>, SIMD2<Double>)
        /// Vertices with each one's bulge to the next (tan of a quarter of the arc's angle; 0
        /// straight).
        case polyline([SIMD2<Double>], bulges: [Double], closed: Bool)
        /// Angles in degrees, counterclockwise from `start` to `end`.
        case arc(center: SIMD2<Double>, radius: Double, start: Double, end: Double)
        case circle(center: SIMD2<Double>, radius: Double)
        case insert(block: String, position: SIMD2<Double>, scale: SIMD2<Double>, rotation: Double)
    }

    public struct Entity: Sendable, Equatable {
        public var layer: String
        public var shape: Shape
        public init(layer: String, shape: Shape) {
            self.layer = layer
            self.shape = shape
        }
    }

    public struct Block: Sendable {
        public var base: SIMD2<Double>
        public var entities: [Entity]
        public init(base: SIMD2<Double>, entities: [Entity]) {
            self.base = base
            self.entities = entities
        }
    }

    /// The header's $INSUNITS, if it has one: 1 inch, 2 foot, 4 millimetre, 5 centimetre, 6 metre…
    public var insertionUnits: Int?
    /// Layer names: those the LAYER table lists, then any others the entities use.
    public var layers: [String]
    /// The model space's entities.
    public var entities: [Entity]
    public var blocks: [String: Block]

    public struct ReadError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Metres per drawing unit given outright, as an SVG's size and view box give it; nil to go by
    /// `insertionUnits`.
    public var unitMetres: Double?

    /// A drawing of these layers, entities and blocks, `unitMetres` metres to its unit if known.
    public init(
        layers: [String], entities: [Entity], blocks: [String: Block] = [:], unitMetres: Double? = nil
    ) {
        self.layers = layers
        self.entities = entities
        self.blocks = blocks
        self.unitMetres = unitMetres
    }

    /// Metres per drawing unit for the header's $INSUNITS (or as given, `unitMetres`), or nil where
    /// it gives none (0, or a unit a plan is not drawn in).
    public var metresPerUnit: Double? {
        if let unitMetres { return unitMetres }
        return switch insertionUnits {
        case 1: 0.0254
        case 2: 0.3048
        case 4: 0.001
        case 5: 0.01
        case 6: 1
        case 14: 0.1
        default: nil
        }
    }

    /// The largest DXF read, in bytes.
    public static let sizeLimit = 100_000_000

    /// The most pieces a drawing may come to with its blocks inserted (`expandedPieces`). Far
    /// more than a plan within `sizeLimit` draws, it refuses a file whose blocks insert one
    /// another many times over, which a few kilobytes can make into more pieces than memory holds.
    public static let pieceLimit = 5_000_000

    /// About how many pieces `segments(depth:)` makes of the drawing (one for a line, an arc or a
    /// circle, one for each of a polyline's vertices), its blocks inserted as it inserts them,
    /// counted without making them and no further than just past `limit`.
    public func expandedPieces(depth: Int = 8, limit: Int = pieceLimit) -> Int {
        var known: [String: Int] = [:]
        func pieces(_ entities: [Entity], level: Int) -> Int {
            var total = 0
            for entity in entities {
                let count: Int
                switch entity.shape {
                case .line, .arc, .circle: count = 1
                case .polyline(let points, _, _): count = points.count
                case .insert(let name, _, _, _):
                    guard level < depth, let definition = blocks[name] else { continue }
                    let key = "\(level) \(name)"
                    if let n = known[key] {
                        count = n
                    } else {
                        count = pieces(definition.entities, level: level + 1)
                        known[key] = count
                    }
                }
                total = min(total + count, limit + 1)
                if total > limit { break }
            }
            return total
        }
        return pieces(entities, level: 0)
    }

    /// Throws where any entity's number (a point, radius, angle, bulge, scale or rotation) is NaN
    /// or infinite, as "nan", "inf" or 1e309 read: no drawing has one, and downstream it was
    /// dropped without a word or raised as a wall at infinity.
    func checkFinite() throws {
        func finite(_ shape: Shape) -> Bool {
            func point(_ p: SIMD2<Double>) -> Bool { p.x.isFinite && p.y.isFinite }
            switch shape {
            case .line(let a, let b): return point(a) && point(b)
            case .polyline(let points, let bulges, _):
                return points.allSatisfy(point) && bulges.allSatisfy(\.isFinite)
            case .arc(let c, let r, let start, let end):
                return point(c) && r.isFinite && start.isFinite && end.isFinite
            case .circle(let c, let r): return point(c) && r.isFinite
            case .insert(_, let position, let scale, let rotation):
                return point(position) && point(scale) && rotation.isFinite
            }
        }
        let all =
            entities.map { ($0, "the model space") }
            + blocks.flatMap { name, block in block.entities.map { ($0, "block \(name)") } }
        if let (bad, place) = all.first(where: { !finite($0.0.shape) }) {
            throw ReadError(
                message:
                    "An entity on layer \(bad.layer) in \(place) has a number that is NaN or infinite: the file is corrupt."
            )
        }
        for (name, block) in blocks where !(block.base.x.isFinite && block.base.y.isFinite) {
            throw ReadError(message: "Block \(name)'s base point is NaN or infinite: the file is corrupt.")
        }
    }

    /// Throws where the drawing's blocks expand past `pieceLimit`.
    func checkExpansion() throws {
        guard expandedPieces() <= Self.pieceLimit else {
            throw ReadError(
                message:
                    "The drawing's blocks insert one another so many times over that it comes to more than 5,000,000 pieces: explode or purge the nested blocks and import it again."
            )
        }
    }

    /// Reads an ASCII DXF (any release; group codes and values on alternate lines).
    public init(data: Data) throws {
        guard data.count <= Self.sizeLimit else { throw ReadError(message: "The DXF is over 100 MB.") }
        if data.starts(with: Data("AutoCAD Binary DXF".utf8)) {
            throw ReadError(message: "A binary DXF: save the drawing as ASCII DXF and import that.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            throw ReadError(message: "The DXF is not text.")
        }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count % 2 == 1 { lines.append("") }
        var pairs: [(Int, String)] = []
        pairs.reserveCapacity(lines.count / 2)
        var index = 0
        while index + 1 < lines.count {
            guard let code = Int(lines[index]) else {
                throw ReadError(message: "Not a DXF: line \(index + 1) is not a group code.")
            }
            pairs.append((code, lines[index + 1]))
            if code == 0 && lines[index + 1] == "EOF" { break }
            index += 2
        }
        guard pairs.contains(where: { $0.0 == 0 && $0.1 == "SECTION" }) else {
            throw ReadError(message: "Not a DXF: no SECTION.")
        }
        // Every section closed: a file cut off part way would otherwise read as what came before.
        let opened = pairs.filter { $0.0 == 0 && $0.1 == "SECTION" }.count
        let closed = pairs.filter { $0.0 == 0 && $0.1 == "ENDSEC" }.count
        guard closed >= opened else {
            throw ReadError(
                message: "The DXF ends part way through a section: it was cut off, or not saved whole.")
        }
        var reader = Reader(pairs: pairs)
        try reader.read()
        insertionUnits = reader.units
        var names = reader.tableLayers
        // A set beside the list: searching the list for each entity's layer took a file of many
        // layers quadratic time.
        var named = Set(names)
        for entity in reader.entities + reader.blocks.values.flatMap(\.entities)
        where named.insert(entity.layer).inserted {
            names.append(entity.layer)
        }
        layers = names
        entities = reader.entities
        blocks = reader.blocks
        try checkFinite()
        try checkExpansion()
    }

    public init(insertionUnits: Int?, layers: [String], entities: [Entity], blocks: [String: Block] = [:]) {
        self.insertionUnits = insertionUnits
        self.layers = layers
        self.entities = entities
        self.blocks = blocks
    }

    /// A straight piece of the drawing on its layer, in drawing units, and the INSERT it came
    /// from (the block's name and the insert's index among the model space's entities), if any.
    public struct Segment: Sendable, Equatable {
        public var layer: String
        public var a: SIMD2<Double>
        public var b: SIMD2<Double>
        public var block: String?
        public var insert: Int?
    }

    /// Every entity as straight segments: arcs and bulges in pieces of at most `arcStep` radians,
    /// blocks inserted as placed (to `depth` levels; entities on layer 0 inside a block take the
    /// insert's layer, as CAD programs draw them).
    public func segments(arcStep: Double = .pi / 12, depth: Int = 8) -> [Segment] {
        var out: [Segment] = []
        func emit(
            _ entity: Entity, _ transform: (SIMD2<Double>) -> SIMD2<Double>, layer: String?, block: String?,
            insert: Int?, level: Int
        ) {
            let layer = (layer != nil && entity.layer == "0") ? layer! : entity.layer
            func add(_ p: SIMD2<Double>, _ q: SIMD2<Double>) {
                let (a, b) = (transform(p), transform(q))
                if simd_distance(a, b) > 1e-12 {
                    out.append(Segment(layer: layer, a: a, b: b, block: block, insert: insert))
                }
            }
            func arc(_ c: SIMD2<Double>, _ r: Double, _ from: Double, _ to: Double) {
                // A NaN or infinite angle has no arc to draw, nor a count of pieces (a file's is
                // refused as it is read; this is for a drawing made in code).
                guard (to - from).isFinite else { return }
                let n = max(1, Int(((to - from) / arcStep).rounded(.up)))
                var previous = c + r * SIMD2(cos(from), sin(from))
                for k in 1...n {
                    let t = from + (to - from) * Double(k) / Double(n)
                    let point = c + r * SIMD2(cos(t), sin(t))
                    add(previous, point)
                    previous = point
                }
            }
            switch entity.shape {
            case .line(let a, let b): add(a, b)
            case .polyline(let points, let bulges, let closed):
                guard points.count > 1 else { return }
                let count = closed ? points.count : points.count - 1
                for k in 0..<count {
                    let p = points[k]
                    let q = points[(k + 1) % points.count]
                    let bulge = k < bulges.count ? bulges[k] : 0
                    let chord = simd_distance(p, q)
                    // A vertex repeated (no chord to bend) or a NaN or infinite bulge is drawn
                    // straight.
                    if abs(bulge) < 1e-9 || !bulge.isFinite || !(chord > 0) {
                        add(p, q)
                        continue
                    }
                    // The arc through p and q whose included angle is 4 atan(bulge).
                    let angle = 4 * atan(bulge)
                    let radius = chord / (2 * sin(abs(angle) / 2))
                    let mid = (p + q) / 2
                    let normal = simd_normalize(SIMD2(-(q - p).y, (q - p).x)) * (bulge > 0 ? 1 : -1)
                    let centre =
                        mid + normal * sqrt(max(radius * radius - chord * chord / 4, 0))
                        * (abs(angle) > .pi ? -1 : 1)
                    var from = atan2(p.y - centre.y, p.x - centre.x)
                    var to = atan2(q.y - centre.y, q.x - centre.x)
                    if bulge > 0 {
                        while to < from { to += 2 * .pi }
                    } else {
                        while from < to { from += 2 * .pi }
                    }
                    arc(centre, radius, from, to)
                }
            case .arc(let c, let r, var start, var end):
                guard start.isFinite, end.isFinite else { return }
                // Angles beyond two turns (a corrupt file's) brought within one first: turns added
                // one at a time would take forever to reach 1e15 degrees, and never reach 1e300.
                if abs(start) > 720 { start = start.truncatingRemainder(dividingBy: 360) }
                if abs(end) > 720 { end = end.truncatingRemainder(dividingBy: 360) }
                var to = end
                while to <= start { to += 360 }
                arc(c, r, start * .pi / 180, to * .pi / 180)
            case .circle(let c, let r): arc(c, r, 0, 2 * .pi)
            case .insert(let name, let position, let scale, let rotation):
                guard level < depth, let definition = blocks[name] else { return }
                let angle = rotation * .pi / 180
                let (c, s) = (cos(angle), sin(angle))
                let place: (SIMD2<Double>) -> SIMD2<Double> = { p in
                    let local = (p - definition.base) * scale
                    return transform(position + SIMD2(c * local.x - s * local.y, s * local.x + c * local.y))
                }
                for inner in definition.entities {
                    emit(inner, place, layer: layer, block: block ?? name, insert: insert, level: level + 1)
                }
            }
        }
        for (n, entity) in entities.enumerated() {
            let isInsert: Bool
            if case .insert = entity.shape { isInsert = true } else { isInsert = false }
            emit(entity, { $0 }, layer: nil, block: nil, insert: isInsert ? n : nil, level: 0)
        }
        return out
    }

    /// The pairs' parser: sections, the LAYER table, BLOCKS and ENTITIES.
    private struct Reader {
        let pairs: [(Int, String)]
        var position = 0
        var units: Int?
        var tableLayers: [String] = []
        var entities: [Entity] = []
        var blocks: [String: Block] = [:]

        init(pairs: [(Int, String)]) { self.pairs = pairs }

        /// Pair `index`'s value as a number. A value that is there but does not parse (`1e`, `--1`)
        /// refuses the file, naming its line: read as 0, it moved a point to the origin unseen.
        func double(at index: Int) throws -> Double {
            let (code, value) = pairs[index]
            guard let number = Double(value) else { throw Self.unparsable(code, value, index) }
            return number
        }

        /// Pair `index`'s value as a whole number (a flag or a unit code), refused as `double`.
        func integer(at index: Int) throws -> Int {
            let (code, value) = pairs[index]
            guard let number = Int(value) else { throw Self.unparsable(code, value, index) }
            return number
        }

        static func unparsable(_ code: Int, _ value: String, _ index: Int) -> ReadError {
            // Pair k's code is on line 2k + 1 and its value on the line after.
            ReadError(
                message:
                    "Line \(2 * index + 2): the value \"\(value.prefix(40))\" of group code \(code) is not a number: the file is corrupt."
            )
        }

        mutating func read() throws {
            while position < pairs.count {
                let (code, value) = pairs[position]
                position += 1
                guard code == 0, value == "SECTION", position < pairs.count, pairs[position].0 == 2 else {
                    continue
                }
                let name = pairs[position].1
                position += 1
                switch name {
                case "HEADER": try header()
                case "TABLES": tables()
                case "BLOCKS": try readBlocks()
                case "ENTITIES": entities = try readEntities(until: ["ENDSEC"])
                default: skipSection()
                }
            }
        }

        mutating func skipSection() {
            while position < pairs.count {
                defer { position += 1 }
                if pairs[position].0 == 0 && pairs[position].1 == "ENDSEC" { return }
            }
        }

        mutating func header() throws {
            while position < pairs.count {
                let (code, value) = pairs[position]
                position += 1
                if code == 0 && value == "ENDSEC" { return }
                if code == 9 && value == "$INSUNITS", position < pairs.count, pairs[position].0 == 70 {
                    units = try integer(at: position)
                }
            }
        }

        mutating func tables() {
            var inLayer = false
            var listed = Set(tableLayers)
            while position < pairs.count {
                let (code, value) = pairs[position]
                position += 1
                if code == 0 && value == "ENDSEC" { return }
                if code == 0 { inLayer = value == "LAYER" }
                if inLayer && code == 2 && listed.insert(value).inserted { tableLayers.append(value) }
            }
        }

        mutating func readBlocks() throws {
            while position < pairs.count {
                let (code, value) = pairs[position]
                if code == 0 && value == "ENDSEC" {
                    position += 1
                    return
                }
                guard code == 0, value == "BLOCK" else {
                    position += 1
                    continue
                }
                position += 1
                var name = ""
                var base = SIMD2<Double>.zero
                while position < pairs.count && pairs[position].0 != 0 {
                    let (c, v) = pairs[position]
                    if c == 2 { name = v }
                    if c == 10 { base.x = try double(at: position) }
                    if c == 20 { base.y = try double(at: position) }
                    position += 1
                }
                let inner = try readEntities(until: ["ENDBLK", "ENDSEC"])
                if position < pairs.count && pairs[position].1 == "ENDBLK" { position += 1 }
                if !name.isEmpty { blocks[name] = Block(base: base, entities: inner) }
            }
        }

        /// Entities up to (not past) a 0 group in `stops`.
        mutating func readEntities(until stops: Set<String>) throws -> [Entity] {
            var result: [Entity] = []
            var pendingPolyline:
                (layer: String, closed: Bool, points: [SIMD2<Double>], bulges: [Double], flip: Bool)?
            while position < pairs.count {
                let (code, value) = pairs[position]
                if code == 0 && stops.contains(value) {
                    if value == "ENDSEC" { position += 1 }
                    return result
                }
                guard code == 0 else {
                    position += 1
                    continue
                }
                position += 1
                // Field n of this entity is pair `start + n`.
                let start = position
                var fields: [(Int, String)] = []
                while position < pairs.count && pairs[position].0 != 0 {
                    fields.append(pairs[position])
                    position += 1
                }
                func number(_ c: Int, _ fallback: Double = 0) throws -> Double {
                    guard let n = fields.firstIndex(where: { $0.0 == c }) else { return fallback }
                    return try double(at: start + n)
                }
                func closedFlag() throws -> Bool {
                    guard let n = fields.firstIndex(where: { $0.0 == 70 }) else { return false }
                    return try integer(at: start + n) & 1 == 1
                }
                let layer = fields.first { $0.0 == 8 }?.1 ?? "0"
                // An extrusion of (0, 0, -1) mirrors an entity's own coordinates in x.
                let flip = try number(230, 1) < 0
                func point(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(flip ? -x : x, y) }
                switch value {
                case "LINE":
                    result.append(
                        Entity(
                            layer: layer,
                            shape: .line(
                                SIMD2(try number(10), try number(20)), SIMD2(try number(11), try number(21))))
                    )
                case "LWPOLYLINE":
                    var points: [SIMD2<Double>] = []
                    var bulges: [Double] = []
                    var x: Double?
                    for (n, (c, _)) in fields.enumerated() {
                        switch c {
                        case 10:
                            if points.count > bulges.count { bulges.append(0) }
                            x = try double(at: start + n)
                        case 20:
                            let py = try double(at: start + n)
                            if let px = x { points.append(point(px, py)) }
                            x = nil
                        case 42:
                            let bulge = try double(at: start + n)
                            if points.count > bulges.count { bulges.append(bulge * (flip ? -1 : 1)) }
                        default: break
                        }
                    }
                    while bulges.count < points.count { bulges.append(0) }
                    let closed = try closedFlag()
                    result.append(
                        Entity(layer: layer, shape: .polyline(points, bulges: bulges, closed: closed)))
                case "POLYLINE":
                    pendingPolyline = (layer, try closedFlag(), [], [], flip)
                case "VERTEX":
                    if pendingPolyline != nil {
                        let f = pendingPolyline!.flip
                        let (x, y, bulge) = (try number(10), try number(20), try number(42))
                        pendingPolyline!.points.append(SIMD2(f ? -x : x, y))
                        pendingPolyline!.bulges.append(bulge * (f ? -1 : 1))
                    }
                case "SEQEND":
                    if let p = pendingPolyline {
                        result.append(
                            Entity(
                                layer: p.layer, shape: .polyline(p.points, bulges: p.bulges, closed: p.closed)
                            ))
                    }
                    pendingPolyline = nil
                case "ARC":
                    var start = try number(50)
                    var end = try number(51)
                    if flip { (start, end) = (180 - end, 180 - start) }
                    result.append(
                        Entity(
                            layer: layer,
                            shape: .arc(
                                center: point(try number(10), try number(20)), radius: try number(40),
                                start: start, end: end)))
                case "CIRCLE":
                    result.append(
                        Entity(
                            layer: layer,
                            shape: .circle(
                                center: point(try number(10), try number(20)), radius: try number(40))))
                case "INSERT":
                    guard let block = fields.first(where: { $0.0 == 2 })?.1 else { break }
                    var rotation = try number(50)
                    var scale = SIMD2(try number(41, 1), try number(42, 1))
                    if flip {
                        rotation = 180 - rotation
                        scale.x = -scale.x
                    }
                    result.append(
                        Entity(
                            layer: layer,
                            shape: .insert(
                                block: block, position: point(try number(10), try number(20)), scale: scale,
                                rotation: rotation)))
                default: break
                }
            }
            return result
        }
    }
}
