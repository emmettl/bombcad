import Foundation
import simd

/// A building read from a 2D floor plan (`DXFDrawing`), as a CAD drawing hands it over: walls drawn
/// by both faces or by their centrelines on the layers the user marks as walls, doors and windows
/// as blocks or lines on their layers or as gaps in the walls, and floor outlines. The plan is
/// raised into storeys and turned into the building elements an IFC import makes
/// (`ImportedMesh.BuildingElement`, boxes in metres with IFC classes and material layers), so that
/// everything after (`IFCStructure`'s shells and panes, envelopes, the review, saving) treats it as
/// it treats an IFC building. Walls must run square to the plan's axes; others are left out and
/// counted. See docs/using-the-app.md, "From architectural plans".
public enum FloorPlan {
    /// What a layer of the drawing holds.
    public enum Role: Sendable, Hashable, Codable {
        case ignore
        /// Walls of this construction, drawn by both faces or by centrelines.
        case wall(Construction)
        case door
        case window
        /// Closed outlines of the floors (and roof).
        case slab
    }

    /// A wall's build-up, outside to in, as IFC material layers (names `IFCStructure.classify`
    /// reads).
    public struct Construction: Sendable, Hashable, Codable, Identifiable {
        public var name: String
        public var layers: [IFCStructure.Layer]
        public var id: String { name }
        public var thickness: Double { layers.reduce(0) { $0 + Double($1.thickness ?? 0) } }

        public init(name: String, layers: [IFCStructure.Layer]) {
            self.name = name
            self.layers = layers
        }

        public static let cavityBrickBlock = Construction(
            name: "Cavity wall, brick and block, 280 mm",
            layers: [
                .init(name: "Facing brick", thickness: 0.1025),
                .init(name: "Mineral wool insulation", thickness: 0.05),
                .init(name: "Air cavity", thickness: 0.0275),
                .init(name: "Aggregate concrete block", thickness: 0.1),
            ])
        public static let cavityBrickBrick = Construction(
            name: "Cavity wall, brick both leaves, 255 mm",
            layers: [
                .init(name: "Facing brick", thickness: 0.1025), .init(name: "Air cavity", thickness: 0.05),
                .init(name: "Common brick", thickness: 0.1025),
            ])
        public static let solidBrick = Construction(
            name: "Solid brick, 215 mm", layers: [.init(name: "Common brick", thickness: 0.215)])
        public static let halfBrick = Construction(
            name: "Brick, one leaf, 102.5 mm", layers: [.init(name: "Common brick", thickness: 0.1025)])
        public static let block100 = Construction(
            name: "Concrete block, 100 mm", layers: [.init(name: "Aggregate concrete block", thickness: 0.1)])
        public static let block215 = Construction(
            name: "Concrete block, 215 mm",
            layers: [.init(name: "Aggregate concrete block", thickness: 0.215)])
        public static let concrete200 = Construction(
            name: "Reinforced concrete, 200 mm", layers: [.init(name: "Concrete C30/37", thickness: 0.2)])
        public static let concrete300 = Construction(
            name: "Reinforced concrete, 300 mm", layers: [.init(name: "Concrete C30/37", thickness: 0.3)])
        public static let studPartition = Construction(
            name: "Stud partition, 100 mm",
            layers: [
                .init(name: "Gypsum board", thickness: 0.0125), .init(name: "Timber stud", thickness: 0.075),
                .init(name: "Gypsum board", thickness: 0.0125),
            ])

        public static let presets: [Construction] = [
            cavityBrickBlock, cavityBrickBrick, solidBrick, halfBrick, block100, block215, concrete200,
            concrete300, studPartition,
        ]
    }

    public enum OpeningKind: String, Sendable, Hashable, Codable, CaseIterable {
        case door, window
    }

    public struct Options: Sendable, Hashable, Codable {
        /// Metres per drawing unit (the drawing's $INSUNITS, or asked).
        public var metresPerUnit: Double = 0.001
        public var roles: [String: Role] = [:]
        /// The storeys (0 the ground) a layer's walls or openings belong to; all where absent.
        public var layerStoreys: [String: Int] = [:]
        public var storeys = 2
        /// Floor to floor (m).
        public var storeyHeight = 2.9
        /// The floors' and the roof's thickness (m), concrete of `slabMaterial`.
        public var slabThickness = 0.2
        public var slabMaterial = "Concrete C30/37"
        /// A slab on the ground under the ground floor (m thick; 0 for none).
        public var groundSlab = 0.15
        /// A flat roof slab over the top storey.
        public var roof = true
        /// Floors and roof seated inside the outer walls, which run the storey's full height, as a
        /// BIM model lays them (FreeCAD's, the example's IFC); else laid over the whole outline, on
        /// top of every wall, which stop under it.
        public var slabsInsideWalls = true
        public var doorHead = 2.1
        public var windowSill = 0.9
        public var windowHead = 2.1
        /// What a gap in a wall with nothing drawn in it is taken as.
        public var gapKind = OpeningKind.window
        /// Wall thicknesses that faces drawn this far apart may be (m).
        public var thinnestWall = 0.05
        public var thickestWall = 0.6
        /// Gaps in a wall up to this long (m) are openings; longer, two walls.
        public var widestOpening = 6.0

        public init() {}
    }

    /// A straight wall square to the plan's axes: along x (`axis` 0) or y (1), its midline at
    /// `offset` on the other axis, from `from` to `to` along its own (m).
    public struct Wall: Sendable, Hashable, Codable {
        public var axis: Int
        public var offset: Double
        public var from: Double
        public var to: Double
        public var thickness: Double
        public var construction: Construction
        public var layer: String
        /// Drawn by its centreline rather than by both faces.
        public var centreline: Bool

        /// The wall's footprint: min and max corners in the plan (m).
        public var rectangle: (min: SIMD2<Double>, max: SIMD2<Double>) {
            let half = thickness / 2
            return axis == 0
                ? (SIMD2(from, offset - half), SIMD2(to, offset + half))
                : (SIMD2(offset - half, from), SIMD2(offset + half, to))
        }
        public var length: Double { to - from }
    }

    public struct Opening: Sendable, Hashable, Codable {
        /// The wall it is in (an index into `Analysis.walls`).
        public var wall: Int
        public var from: Double
        public var to: Double
        public var kind: OpeningKind
        /// Where it came from: a layer's name, or nil for a gap with nothing drawn in it.
        public var layer: String?
        /// The storey it is on, or nil for every storey.
        public var storey: Int?
    }

    public struct Analysis: Sendable {
        public var walls: [Wall] = []
        public var openings: [Opening] = []
        /// Each floor outline as rectangles (m).
        public var slabs: [[(min: SIMD2<Double>, max: SIMD2<Double>)]] = []
        /// The plan's extent (m).
        public var bounds: (min: SIMD2<Double>, max: SIMD2<Double>) = (.zero, .zero)
        public var notes: [String] = []
        /// Lines on wall layers that are not square to the axes, and their length (m).
        public var angledLines = 0
        public var angledLength = 0.0
    }

    /// Straight pieces of a layer square to an axis: `offset` across, `from`…`to` along (m).
    struct Line: Hashable {
        var axis: Int
        var offset: Double
        var from: Double
        var to: Double
        var length: Double { to - from }
    }

    /// Finds the walls, openings and floors in `drawing` under `options`.
    public static func analyse(_ drawing: DXFDrawing, options: Options) -> Analysis {
        var analysis = Analysis()
        let scale = options.metresPerUnit
        let segments = drawing.segments().map { s -> DXFDrawing.Segment in
            var s = s
            s.a *= scale
            s.b *= scale
            return s
        }
        guard !segments.isEmpty else {
            analysis.notes.append("The drawing has nothing in it to read.")
            return analysis
        }
        var low = SIMD2(Double.infinity, .infinity)
        var high = -low
        for s in segments where options.roles[s.layer].map({ $0 != .ignore }) ?? false {
            low = simd_min(low, simd_min(s.a, s.b))
            high = simd_max(high, simd_max(s.a, s.b))
        }
        if low.x.isFinite { analysis.bounds = (low, high) }

        // Walls, layer by layer.
        for (layer, role) in options.roles.sorted(by: { $0.key < $1.key }) {
            guard case .wall(let construction) = role else { continue }
            var lines: [Line] = []
            for s in segments where s.layer == layer {
                if let line = squareLine(s.a, s.b) {
                    lines.append(line)
                } else {
                    analysis.angledLines += 1
                    analysis.angledLength += simd_distance(s.a, s.b)
                }
            }
            lines = merged(lines)
            let lineLength = lines.reduce(0) { $0 + $1.length }
            let found = solidPieces(lines, options: options)
            // Drawn by both faces where the solid's outline is most of what is drawn; by centrelines
            // where the lines enclose little but rooms.
            var walls: [Wall]
            if let found, found.outline >= 0.5 * lineLength {
                walls = found.pieces.map {
                    Wall(
                        axis: $0.axis, offset: $0.offset, from: $0.from, to: $0.to, thickness: $0.thickness,
                        construction: construction, layer: layer, centreline: false)
                }
                analysis.notes.append(
                    "\(layer): read as walls drawn by their outlines, \(walls.count) pieces, thicknesses "
                        + thicknessSummary(walls.map(\.thickness)) + "; their build-up "
                        + construction.name + ".")
            } else {
                walls = lines.filter { $0.length > construction.thickness }.map {
                    Wall(
                        axis: $0.axis, offset: $0.offset, from: $0.from, to: $0.to,
                        thickness: construction.thickness, construction: construction, layer: layer,
                        centreline: true)
                }
                analysis.notes.append(
                    found == nil
                        ? "\(layer): too many lines to read as outlines; read as centrelines of \(construction.name)."
                        : "\(layer): read as centrelines of \(construction.name).")
            }
            analysis.walls += walls
        }
        if analysis.angledLines > 0 {
            analysis.notes.append(
                "\(analysis.angledLines) lines on wall layers (\(String(format: "%.1f", analysis.angledLength)) m) are not square to the plan's axes and are left out: angled and curved walls are not read yet."
            )
        }
        analysis.walls = cleaned(analysis.walls)
        // The plan's extent takes in the walls' faces, beyond centrelines.
        for wall in analysis.walls {
            low = simd_min(low, wall.rectangle.min)
            high = simd_max(high, wall.rectangle.max)
        }
        if low.x.isFinite { analysis.bounds = (low, high) }

        // Openings drawn on their layers, by INSERT or by clusters of lines.
        var drawn: [(box: (min: SIMD2<Double>, max: SIMD2<Double>), kind: OpeningKind, layer: String)] = []
        var groups: [String: (min: SIMD2<Double>, max: SIMD2<Double>, kind: OpeningKind, layer: String)] = [:]
        var loose: [(min: SIMD2<Double>, max: SIMD2<Double>, kind: OpeningKind, layer: String)] = []
        for s in segments {
            let kind: OpeningKind
            switch options.roles[s.layer] {
            case .door: kind = .door
            case .window: kind = .window
            default: continue
            }
            let lo = simd_min(s.a, s.b)
            let hi = simd_max(s.a, s.b)
            if let insert = s.insert {
                let key = "\(insert)"
                if let g = groups[key] {
                    groups[key] = (simd_min(g.min, lo), simd_max(g.max, hi), kind, s.layer)
                } else {
                    groups[key] = (lo, hi, kind, s.layer)
                }
            } else {
                loose.append((lo, hi, kind, s.layer))
            }
        }
        drawn += groups.values.map { (($0.min, $0.max), $0.kind, $0.layer) }
        drawn += clusters(loose).map { (($0.min, $0.max), $0.kind, $0.layer) }
        // Walls carried across what is drawn just past their ends; then gaps in the walls, then
        // what is drawn in them or in centreline walls.
        analysis.walls = bridged(analysis.walls, over: drawn)
        analysis.openings = gapOpenings(&analysis.walls, options: options)
        place(
            drawn, walls: analysis.walls, storeys: options.layerStoreys, openings: &analysis.openings,
            notes: &analysis.notes)
        let gaps = analysis.openings.filter { $0.layer == nil }.count
        if gaps > 0 {
            analysis.notes.append(
                "\(gaps) gaps in walls with no door or window drawn in them are taken as \(options.gapKind.rawValue)s in outer walls and doorways inside (assumed)."
            )
        }

        // Floors: the slab layers' closed outlines, else the walls' extent.
        var outlines: [[(min: SIMD2<Double>, max: SIMD2<Double>)]] = []
        for entity in drawing.entities where options.roles[entity.layer] == .slab {
            guard case .polyline(let points, _, let closed) = entity.shape, closed, points.count >= 4 else {
                continue
            }
            let pts = points.map { $0 * scale }
            if let rects = rectangles(ofOrthogonal: pts) { outlines.append(rects) }
        }
        if outlines.isEmpty, let first = analysis.walls.first {
            var lo = first.rectangle.min
            var hi = first.rectangle.max
            for wall in analysis.walls {
                lo = simd_min(lo, wall.rectangle.min)
                hi = simd_max(hi, wall.rectangle.max)
            }
            outlines = [[(lo, hi)]]
            analysis.notes.append(
                "The floors are taken as the walls' outer rectangle, \(String(format: "%.2f × %.2f", hi.x - lo.x, hi.y - lo.y)) m (no closed outline on a slab layer)."
            )
        }
        analysis.slabs = outlines
        analysis.notes.append(
            "\(analysis.walls.count) walls and \(analysis.openings.count) openings over \(options.storeys) storeys of \(String(format: "%.2f", options.storeyHeight)) m."
        )
        return analysis
    }

    // MARK: - Lines

    /// A segment square to x or y within half a degree, as a line; nil otherwise.
    static func squareLine(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Line? {
        let d = b - a
        let tolerance = tan(0.5 * Double.pi / 180)
        if abs(d.y) <= tolerance * abs(d.x) {
            return Line(axis: 0, offset: (a.y + b.y) / 2, from: min(a.x, b.x), to: max(a.x, b.x))
        }
        if abs(d.x) <= tolerance * abs(d.y) {
            return Line(axis: 1, offset: (a.x + b.x) / 2, from: min(a.y, b.y), to: max(a.y, b.y))
        }
        return nil
    }

    /// Collinear lines that overlap or touch, joined.
    static func merged(_ lines: [Line], tolerance: Double = 0.001) -> [Line] {
        var result: [Line] = []
        for axis in 0...1 {
            let sorted = lines.filter { $0.axis == axis }.sorted {
                ($0.offset, $0.from) < ($1.offset, $1.from)
            }
            var current: Line?
            for line in sorted {
                if var c = current, abs(line.offset - c.offset) <= tolerance, line.from <= c.to + tolerance {
                    c.to = max(c.to, line.to)
                    current = c
                } else {
                    if let c = current, c.length > tolerance { result.append(c) }
                    current = line
                }
            }
            if let c = current, c.length > tolerance { result.append(c) }
        }
        return result
    }

    /// A wall drawn by both faces, found as solid: axis, midline, extent along and thickness (m).
    struct SolidPiece: Hashable {
        var axis: Int
        var offset: Double
        var from: Double
        var to: Double
        var thickness: Double
    }

    /// Walls drawn by their outlines, read as the regions the lines enclose: the plan cut into
    /// cells at every line's coordinates, cells joined where no line parts them, and a region
    /// counted as wall where most of it is no wider than `thickestWall` (a room is wider, and the
    /// outside reaches the edge). Faces of solids that overlap, or of a wall's leaves, part a wall
    /// into thin regions that are all solid, so the wall is read whole. The solid is then cut into
    /// rectangles, each cell going with the longer of its row's and its column's solid runs, so
    /// that at a corner or a junction one wall runs through and the other stops at its face.
    /// Returns the pieces and the length of the solid's outline, or nil if the lines would make
    /// too many cells.
    static func solidPieces(_ lines: [Line], options: Options, cellLimit: Int = 4_000_000)
        -> (pieces: [SolidPiece], outline: Double)?
    {
        let snap = 0.001
        func coordinates(_ values: [Double]) -> [Double] {
            var result: [Double] = []
            for v in values.sorted() where result.last.map({ v - $0 > snap }) ?? true { result.append(v) }
            return result
        }
        // x: the vertical lines' offsets and the horizontal lines' ends; y alike.
        var xValues: [Double] = []
        var yValues: [Double] = []
        for line in lines {
            if line.axis == 0 {
                yValues.append(line.offset)
                xValues += [line.from, line.to]
            } else {
                xValues.append(line.offset)
                yValues += [line.from, line.to]
            }
        }
        guard !xValues.isEmpty, !yValues.isEmpty else { return ([], 0) }
        var xs = coordinates(xValues)
        var ys = coordinates(yValues)
        // A margin of outside all round.
        xs = [xs[0] - 1] + xs + [xs[xs.count - 1] + 1]
        ys = [ys[0] - 1] + ys + [ys[ys.count - 1] + 1]
        let nx = xs.count - 1
        let ny = ys.count - 1
        guard nx * ny <= cellLimit else { return nil }
        func index(_ values: [Double], _ v: Double) -> Int {
            var lo = 0
            var hi = values.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[mid] < v - snap { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        // Which cell edges a line lies on: blockedX[j * (nx + 1) + i] parts cells i - 1 and i of
        // row j (a vertical line at xs[i]); blockedY[i * (ny + 1) + j] parts cells j - 1 and j of
        // column i.
        var blockedX = [Bool](repeating: false, count: (nx + 1) * ny)
        var blockedY = [Bool](repeating: false, count: (ny + 1) * nx)
        for line in lines {
            if line.axis == 1 {
                let i = index(xs, line.offset)
                for j in index(ys, line.from)..<max(index(ys, line.from), index(ys, line.to)) {
                    blockedX[j * (nx + 1) + i] = true
                }
            } else {
                let j = index(ys, line.offset)
                for i in index(xs, line.from)..<max(index(xs, line.from), index(xs, line.to)) {
                    blockedY[i * (ny + 1) + j] = true
                }
            }
        }
        // Regions, by flood fill.
        var label = [Int](repeating: -1, count: nx * ny)
        var regions = 0
        for start in label.indices where label[start] < 0 {
            label[start] = regions
            var stack = [start]
            while let cell = stack.popLast() {
                let i = cell % nx
                let j = cell / nx
                func visit(_ other: Int) {
                    if label[other] < 0 {
                        label[other] = regions
                        stack.append(other)
                    }
                }
                if i > 0, !blockedX[j * (nx + 1) + i] { visit(cell - 1) }
                if i + 1 < nx, !blockedX[j * (nx + 1) + i + 1] { visit(cell + 1) }
                if j > 0, !blockedY[i * (ny + 1) + j] { visit(cell - nx) }
                if j + 1 < ny, !blockedY[i * (ny + 1) + j + 1] { visit(cell + nx) }
            }
            regions += 1
        }
        // Each cell's run along its row and its column within its region, and so how wide the
        // region is there.
        func runs(_ same: (Int, Int) -> Bool) -> (row: [Double], column: [Double]) {
            var row = [Double](repeating: 0, count: nx * ny)
            var column = [Double](repeating: 0, count: nx * ny)
            for j in 0..<ny {
                var i = 0
                while i < nx {
                    var k = i
                    while k + 1 < nx, same(j * nx + k, j * nx + k + 1) { k += 1 }
                    for m in i...k { row[j * nx + m] = xs[k + 1] - xs[i] }
                    i = k + 1
                }
            }
            for i in 0..<nx {
                var j = 0
                while j < ny {
                    var k = j
                    while k + 1 < ny, same(k * nx + i, (k + 1) * nx + i) { k += 1 }
                    for m in j...k { column[m * nx + i] = ys[k + 1] - ys[j] }
                    j = k + 1
                }
            }
            return (row, column)
        }
        let within = runs { label[$0] == label[$1] }
        var thinArea = [Double](repeating: 0, count: regions)
        var totalArea = [Double](repeating: 0, count: regions)
        for cell in label.indices {
            let area = (xs[cell % nx + 1] - xs[cell % nx]) * (ys[cell / nx + 1] - ys[cell / nx])
            totalArea[label[cell]] += area
            if min(within.row[cell], within.column[cell]) <= options.thickestWall + snap {
                thinArea[label[cell]] += area
            }
        }
        let outside = label[0]
        let solidRegion = (0..<regions).map { $0 != outside && thinArea[$0] >= 0.8 * totalArea[$0] }
        let solid = label.map { solidRegion[$0] }
        // The outline: cell edges between solid and not.
        var outline = 0.0
        for j in 0..<ny {
            for i in 0..<nx where solid[j * nx + i] {
                if i == 0 || !solid[j * nx + i - 1] { outline += ys[j + 1] - ys[j] }
                if i + 1 == nx || !solid[j * nx + i + 1] { outline += ys[j + 1] - ys[j] }
                if j == 0 || !solid[(j - 1) * nx + i] { outline += xs[i + 1] - xs[i] }
                if j + 1 == ny || !solid[(j + 1) * nx + i] { outline += xs[i + 1] - xs[i] }
            }
        }
        // Cells to the longer run of the solid, then runs of each direction joined into
        // rectangles across rows (or columns) of the same extent.
        let across = runs { solid[$0] && solid[$1] }
        let alongX = solid.indices.map { solid[$0] && across.row[$0] >= across.column[$0] }
        let alongY = solid.indices.map { solid[$0] && across.row[$0] < across.column[$0] }
        var pieces: [SolidPiece] = []
        // Horizontal pieces: runs in each row, stacked while the next row has the same run.
        var open: [ClosedRange<Int>: (j0: Int, j1: Int)] = [:]
        func flush(_ run: ClosedRange<Int>, _ rows: (j0: Int, j1: Int)) {
            let y0 = ys[rows.j0]
            let y1 = ys[rows.j1 + 1]
            pieces.append(
                SolidPiece(
                    axis: 0, offset: (y0 + y1) / 2, from: xs[run.lowerBound], to: xs[run.upperBound + 1],
                    thickness: y1 - y0))
        }
        for j in 0..<ny {
            var current: [ClosedRange<Int>] = []
            var i = 0
            while i < nx {
                guard alongX[j * nx + i] else {
                    i += 1
                    continue
                }
                var k = i
                while k + 1 < nx, alongX[j * nx + k + 1] { k += 1 }
                current.append(i...k)
                i = k + 1
            }
            var next: [ClosedRange<Int>: (j0: Int, j1: Int)] = [:]
            for run in current {
                if let rows = open[run] { next[run] = (rows.j0, j) } else { next[run] = (j, j) }
            }
            for (run, rows) in open where next[run] == nil { flush(run, rows) }
            open = next
        }
        for (run, rows) in open { flush(run, rows) }
        open = [:]
        func flushColumn(_ run: ClosedRange<Int>, _ columns: (j0: Int, j1: Int)) {
            let x0 = xs[columns.j0]
            let x1 = xs[columns.j1 + 1]
            pieces.append(
                SolidPiece(
                    axis: 1, offset: (x0 + x1) / 2, from: ys[run.lowerBound], to: ys[run.upperBound + 1],
                    thickness: x1 - x0))
        }
        for i in 0..<nx {
            var current: [ClosedRange<Int>] = []
            var j = 0
            while j < ny {
                guard alongY[j * nx + i] else {
                    j += 1
                    continue
                }
                var k = j
                while k + 1 < ny, alongY[(k + 1) * nx + i] { k += 1 }
                current.append(j...k)
                j = k + 1
            }
            var next: [ClosedRange<Int>: (j0: Int, j1: Int)] = [:]
            for run in current {
                if let columns = open[run] { next[run] = (columns.j0, i) } else { next[run] = (i, i) }
            }
            for (run, columns) in open where next[run] == nil { flushColumn(run, columns) }
            open = next
        }
        for (run, columns) in open { flushColumn(run, columns) }
        // A piece shorter than it is thick is the end of a wall the other way, or a pier; one
        // thinner than the thinnest wall is a sliver.
        pieces = pieces.filter {
            $0.to - $0.from >= max(0.1, 0.5 * $0.thickness) && $0.thickness >= options.thinnestWall
        }
        return (pieces.sorted { ($0.axis, $0.offset, $0.from) < ($1.axis, $1.offset, $1.from) }, outline)
    }

    static func thicknessSummary(_ values: [Double]) -> String {
        guard let lo = values.min(), let hi = values.max() else { return "none" }
        let mm = { (v: Double) in String(format: "%.0f", v * 1000) }
        return lo == hi || hi - lo < 0.002 ? "\(mm(lo)) mm" : "\(mm(lo))–\(mm(hi)) mm"
    }

    // MARK: - Walls

    /// Walls cleaned up: pieces inside a longer wall the other way dropped; collinear pieces of one
    /// thickness joined across gaps a perpendicular wall fills; and each end carried on to the far
    /// face of a perpendicular wall it stops at, so that walls meet at their corners and junctions.
    static func cleaned(_ input: [Wall]) -> [Wall] {
        var walls = input.sorted { $0.length > $1.length }
        func area(_ r: (min: SIMD2<Double>, max: SIMD2<Double>)) -> Double {
            max(0, r.max.x - r.min.x) * max(0, r.max.y - r.min.y)
        }
        func overlap(
            _ a: (min: SIMD2<Double>, max: SIMD2<Double>), _ b: (min: SIMD2<Double>, max: SIMD2<Double>)
        )
            -> Double
        {
            area((simd_max(a.min, b.min), simd_min(a.max, b.max)))
        }
        var kept: [Wall] = []
        for wall in walls {
            let r = wall.rectangle
            let covered = kept.reduce(0) { $0 + overlap(r, $1.rectangle) }
            if covered < 0.5 * area(r) { kept.append(wall) }
        }
        walls = kept
        // Ends carried across a perpendicular wall they stop at: to its far face where it too ends
        // here (a corner, or a wall whose line is broken by this one's), to its midline where it
        // runs on (a T), so that the walls' midsurfaces meet.
        let before = walls
        for i in walls.indices {
            let wall = before[i]
            for other in before where other.axis != wall.axis {
                let half = other.thickness / 2
                let (lo, hi) = (other.offset - half, other.offset + half)
                // The other wall reaches this one's line.
                guard wall.offset >= other.from - wall.thickness / 2 - 0.01,
                    wall.offset <= other.to + wall.thickness / 2 + 0.01
                else { continue }
                let endsHere =
                    abs(other.from - wall.offset) <= wall.thickness + 0.01
                    || abs(other.to - wall.offset) <= wall.thickness + 0.01
                let reach = max(other.thickness, wall.thickness) + 0.02
                if wall.from > lo, wall.from <= hi + reach {
                    walls[i].from = min(walls[i].from, endsHere ? lo : other.offset)
                }
                if wall.to < hi, wall.to >= lo - reach {
                    walls[i].to = max(walls[i].to, endsHere ? hi : other.offset)
                }
            }
        }
        // Collinear pieces of a wall of one thickness, end to end, joined.
        walls.sort { ($0.axis, $0.offset, $0.from) < ($1.axis, $1.offset, $1.from) }
        var joined: [Wall] = []
        for wall in walls {
            if var last = joined.last, last.axis == wall.axis, abs(last.offset - wall.offset) < 0.005,
                abs(last.thickness - wall.thickness) < 0.005, last.layer == wall.layer,
                wall.from <= last.to + 0.005
            {
                last.to = max(last.to, wall.to)
                joined[joined.count - 1] = last
            } else {
                joined.append(wall)
            }
        }
        return joined
    }

    // MARK: - Openings

    /// Lines of one layer that touch or nearly do (within `reach`) grouped, as a window or door
    /// drawn without a block.
    static func clusters(
        _ items: [(min: SIMD2<Double>, max: SIMD2<Double>, kind: OpeningKind, layer: String)],
        reach: Double = 0.05
    ) -> [(min: SIMD2<Double>, max: SIMD2<Double>, kind: OpeningKind, layer: String)] {
        var groups = items
        var changed = true
        while changed {
            changed = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i && groups[j].layer == groups[i].layer {
                    let a = groups[i]
                    let b = groups[j]
                    let gap = simd_max(simd_max(a.min - b.max, b.min - a.max), .zero)
                    if simd_length(gap) <= reach {
                        groups[i] = (simd_min(a.min, b.min), simd_max(a.max, b.max), a.kind, a.layer)
                        groups.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return groups
    }

    /// Drawn openings placed in the walls they lie in: one in a gap already found names it (its
    /// kind and layer); one in a wall drawn by its centreline is cut into it, its extent along the
    /// wall, unless an opening on the same storey is there already. A layer given a storey in
    /// `storeys` puts its openings on that storey only.
    static func place(
        _ drawn: [(box: (min: SIMD2<Double>, max: SIMD2<Double>), kind: OpeningKind, layer: String)],
        walls: [Wall], storeys: [String: Int], openings: inout [Opening], notes: inout [String]
    ) {
        var unplaced = 0
        for item in drawn {
            let centre = (item.box.min + item.box.max) / 2
            let size = item.box.max - item.box.min
            // A frame's corner or a jamb cut on its own: too small to be an opening.
            guard max(size.x, size.y) >= 0.25 else { continue }
            // Along the wall it is in: its longer side, or for a square one the wall it lies across.
            let hosts = walls.indices.filter { index in
                let wall = walls[index]
                let across = 1 - wall.axis
                return abs(centre[across] - wall.offset) <= wall.thickness / 2 + 0.15
                    && centre[wall.axis] >= wall.from - 0.05 && centre[wall.axis] <= wall.to + 0.05
            }.sorted { a, b in
                let wa = walls[a]
                let wb = walls[b]
                let sa = size[wa.axis] >= size[1 - wa.axis] ? 0 : 1
                let sb = size[wb.axis] >= size[1 - wb.axis] ? 0 : 1
                return (sa, abs(centre[1 - wa.axis] - wa.offset)) < (sb, abs(centre[1 - wb.axis] - wb.offset))
            }
            guard let host = hosts.first else {
                unplaced += 1
                continue
            }
            let wall = walls[host]
            let from = max(item.box.min[wall.axis], wall.from)
            let to = min(item.box.max[wall.axis], wall.to)
            guard to - from > 0.1 else {
                unplaced += 1
                continue
            }
            let storey = storeys[item.layer]
            if let gap = openings.firstIndex(where: {
                $0.wall == host && $0.layer == nil && $0.from < to && $0.to > from
            }) {
                openings[gap].kind = item.kind
                openings[gap].layer = item.layer
                openings[gap].storey = storey
            } else if !openings.contains(where: {
                $0.wall == host && $0.from < to && $0.to > from
                    && ($0.storey == nil || storey == nil || $0.storey == storey)
            }) {
                openings.append(
                    Opening(
                        wall: host, from: from, to: to, kind: item.kind, layer: item.layer, storey: storey))
            }
        }
        if unplaced > 0 {
            notes.append("\(unplaced) doors or windows drawn away from any wall were left out.")
        }
    }

    /// Walls carried across doors and windows drawn on their line just past an end (within 0.3 m,
    /// a frame's width), from one to the next, where the wall stops beside an opening at a pier or a
    /// corner rather than resuming on its line. Pieces the longer walls then cover are dropped and
    /// the ends are joined again (`cleaned`).
    static func bridged(
        _ input: [Wall],
        over drawn: [(box: (min: SIMD2<Double>, max: SIMD2<Double>), kind: OpeningKind, layer: String)]
    ) -> [Wall] {
        var walls = input
        var changed = true
        var bridged = false
        while changed {
            changed = false
            for item in drawn {
                let centre = (item.box.min + item.box.max) / 2
                let size = item.box.max - item.box.min
                for n in walls.indices {
                    let wall = walls[n]
                    let along = wall.axis
                    guard size[along] >= max(0.25, size[1 - along]),
                        abs(centre[1 - along] - wall.offset) <= wall.thickness / 2 + 0.15
                    else { continue }
                    let lo = item.box.min[along]
                    let hi = item.box.max[along]
                    // Not where the wall goes on past it: that is a gap, read as one.
                    let resumes = walls.contains { other in
                        other != wall && other.axis == wall.axis && abs(other.offset - wall.offset) < 0.01
                            && other.to > hi && other.from <= hi + 0.3 && other.from >= lo - 0.3
                    }
                    let resumesBelow = walls.contains { other in
                        other != wall && other.axis == wall.axis && abs(other.offset - wall.offset) < 0.01
                            && other.from < lo && other.to >= lo - 0.3 && other.to <= hi + 0.3
                    }
                    if !resumes, lo >= wall.to - 0.15, lo <= wall.to + 0.3, hi > wall.to + 0.05 {
                        walls[n].to = hi
                        changed = true
                    } else if !resumesBelow, hi <= wall.from + 0.15, hi >= wall.from - 0.3,
                        lo < wall.from - 0.05
                    {
                        walls[n].from = lo
                        changed = true
                    }
                }
            }
            bridged = bridged || changed
        }
        return bridged ? cleaned(walls) : walls
    }

    /// Gaps between collinear pieces of a wall of one thickness, not filled by a perpendicular
    /// wall, up to `widestOpening`: the pieces joined and the gap an opening of `gapKind`.
    static func gapOpenings(_ walls: inout [Wall], options: Options) -> [Opening] {
        var openings: [Opening] = []
        guard let first = walls.first else { return [] }
        var low = first.rectangle.min
        var high = first.rectangle.max
        for wall in walls {
            low = simd_min(low, wall.rectangle.min)
            high = simd_max(high, wall.rectangle.max)
        }
        // On the walls' outer rectangle: a face within 5 cm of its edge.
        func outer(_ wall: Wall) -> Bool {
            let r = wall.rectangle
            let lo = wall.axis == 0 ? r.min.y : r.min.x
            let hi = wall.axis == 0 ? r.max.y : r.max.x
            let edge = wall.axis == 0 ? (low.y, high.y) : (low.x, high.x)
            return lo - edge.0 < 0.05 || edge.1 - hi < 0.05
        }
        var changed = true
        while changed {
            changed = false
            search: for i in walls.indices {
                for j in walls.indices where j != i {
                    let a = walls[i]
                    let b = walls[j]
                    guard a.axis == b.axis, abs(a.offset - b.offset) < 0.01,
                        abs(a.thickness - b.thickness) < 0.01,
                        a.layer == b.layer, b.from > a.to
                    else { continue }
                    let gap = b.from - a.to
                    guard gap <= options.widestOpening, gap >= 0.3 else { continue }
                    // Nothing else of the wall's line in between.
                    if walls.contains(where: {
                        $0.axis == a.axis && abs($0.offset - a.offset) < 0.01 && $0.from < b.from
                            && $0.to > a.to
                            && $0 != a && $0 != b
                    }) {
                        continue
                    }
                    // A gap in an outer wall is the kind asked; one inside, a doorway.
                    let kind = outer(a) ? options.gapKind : .door
                    walls[i].to = b.to
                    walls.remove(at: j)
                    let host = j < i ? i - 1 : i
                    for k in openings.indices where openings[k].wall == j { openings[k].wall = host }
                    for k in openings.indices where openings[k].wall > j { openings[k].wall -= 1 }
                    openings.append(Opening(wall: host, from: a.to, to: b.from, kind: kind, layer: nil))
                    changed = true
                    break search
                }
            }
        }
        return openings
    }

    // MARK: - Floors

    /// An orthogonal polygon as rectangles (strips between its distinct x coordinates, joined where
    /// alike), or nil if any edge is not square to the axes.
    static func rectangles(ofOrthogonal points: [SIMD2<Double>]) -> [(
        min: SIMD2<Double>, max: SIMD2<Double>
    )]? {
        var pts = points
        if let first = pts.first, let last = pts.last, simd_distance(first, last) < 1e-9 { pts.removeLast() }
        guard pts.count >= 4 else { return nil }
        for k in pts.indices {
            let d = pts[(k + 1) % pts.count] - pts[k]
            if abs(d.x) > 1e-6 * max(1, abs(d.y)) && abs(d.y) > 1e-6 * max(1, abs(d.x)) { return nil }
        }
        let xs = Array(Set(pts.map(\.x))).sorted()
        var strips: [(x0: Double, x1: Double, spans: [(Double, Double)])] = []
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            let mid = (x0 + x1) / 2
            var ys: [Double] = []
            for k in pts.indices {
                let p = pts[k]
                let q = pts[(k + 1) % pts.count]
                if p.x != q.x, abs(p.y - q.y) < 1e-9, min(p.x, q.x) < mid, max(p.x, q.x) > mid {
                    ys.append(p.y)
                }
            }
            ys.sort()
            var spans: [(Double, Double)] = []
            var k = 0
            while k + 1 < ys.count {
                spans.append((ys[k], ys[k + 1]))
                k += 2
            }
            if let last = strips.last, last.x1 == x0, last.spans.count == spans.count,
                zip(last.spans, spans).allSatisfy({ abs($0.0 - $1.0) < 1e-9 && abs($0.1 - $1.1) < 1e-9 })
            {
                strips[strips.count - 1].x1 = x1
            } else {
                strips.append((x0, x1, spans))
            }
        }
        return strips.flatMap { strip in strip.spans.map { (SIMD2(strip.x0, $0.0), SIMD2(strip.x1, $0.1)) } }
    }

    // MARK: - Building

    /// The building as elements an IFC import would give: each storey's walls (with their openings
    /// cut, as several boxes), windows as boxes in their openings, doors, the floors and the roof
    /// over the storeys (the walls stopping under them), and a slab on the ground. Coordinates in
    /// metres from the plan's corner, z up from the ground floor.
    public static func buildingElements(_ analysis: Analysis, options: Options) throws
        -> [ImportedMesh.BuildingElement]
    {
        var elements: [ImportedMesh.BuildingElement] = []
        let corner = analysis.bounds.min
        var serial = 0
        func box(_ lo: SIMD2<Double>, _ hi: SIMD2<Double>, _ z0: Double, _ z1: Double) -> Box {
            Box(
                min: SIMD3(Float(lo.x - corner.x), Float(lo.y - corner.y), Float(z0)),
                max: SIMD3(Float(hi.x - corner.x), Float(hi.y - corner.y), Float(z1)))
        }
        func add(
            _ name: String, _ ifcClass: String, _ storey: Int, _ boxes: [Box], _ layers: [IFCStructure.Layer]?
        )
            throws
        {
            let usable = boxes.filter { b in (0..<3).allSatisfy { b.max[$0] - b.min[$0] > 0.002 } }
            guard !usable.isEmpty else { return }
            serial += 1
            elements.append(
                .init(
                    globalID: String(format: "DXF%019d", serial), name: name, ifcClass: ifcClass,
                    storey: storeyName(storey), mesh: try mesh(usable), materials: layers))
        }
        let height = options.storeyHeight
        let slab = options.slabThickness
        // The walls on the floors' outline, which the floors sit inside when asked.
        let outer = Set(
            analysis.walls.indices.filter { index in
                options.slabsInsideWalls
                    && analysis.slabs.contains { outline in
                        onEdge(analysis.walls[index].rectangle, of: outline)
                    }
            })
        for storey in 0..<options.storeys {
            let z0 = Double(storey) * height
            let underSlab = z0 + height - slab
            for (index, wall) in analysis.walls.enumerated() {
                if let only = options.layerStoreys[wall.layer], only != storey { continue }
                // Inside the outer walls the slabs bear on the partitions too, which run up into
                // them, as a BIM model's walls of a storey's height do.
                let z1 = options.slabsInsideWalls ? z0 + height : underSlab
                let mine = analysis.openings.filter {
                    $0.wall == index && ($0.storey == nil || $0.storey == storey)
                }
                .sorted { $0.from < $1.from }
                // The wall's stretches between openings full height; under and over each opening.
                var pieces: [(Double, Double, Double, Double)] = []  // from, to, z from, z to
                var at = wall.from
                for opening in mine {
                    let sill = opening.kind == .window ? options.windowSill : 0
                    let head = min(opening.kind == .window ? options.windowHead : options.doorHead, z1 - z0)
                    if opening.from > at { pieces.append((at, opening.from, z0, z1)) }
                    if sill > 0 { pieces.append((opening.from, opening.to, z0, z0 + sill)) }
                    if z0 + head < z1 { pieces.append((opening.from, opening.to, z0 + head, z1)) }
                    at = max(at, opening.to)
                }
                if wall.to > at { pieces.append((at, wall.to, z0, z1)) }
                var boxes: [Box] = []
                for (a, b, za, zb) in pieces where b - a > 0.002 && zb - za > 0.002 {
                    var piece = wall
                    piece.from = a
                    piece.to = b
                    let r = piece.rectangle
                    var made = box(r.min, r.max, za, zb)
                    if pieces.count > 1 {
                        made.min += SIMD3(repeating: 0.0005)
                        made.max -= SIMD3(repeating: 0.0005)
                    }
                    boxes.append(made)
                }
                let partition = [Construction.block100, .studPartition].contains(wall.construction)
                let name = "\(storeyName(storey)) \(partition ? "partition" : "wall") \(index + 1)"
                try add(name, "IfcWall", storey, boxes, wall.construction.layers)
                for (n, opening) in mine.enumerated() {
                    var piece = wall
                    piece.from = opening.from
                    piece.to = opening.to
                    piece.thickness = wall.thickness / 3
                    let r = piece.rectangle
                    switch opening.kind {
                    case .window:
                        try add(
                            "\(name) window \(n + 1)", "IfcWindow", storey,
                            [
                                box(
                                    r.min, r.max, z0 + options.windowSill,
                                    z0 + min(options.windowHead, z1 - z0))
                            ],
                            [.init(name: "Glass", thickness: 0.006)])
                    case .door:
                        try add(
                            "\(name) door \(n + 1)", "IfcDoor", storey,
                            [box(r.min, r.max, z0, z0 + min(options.doorHead, z1 - z0))], nil)
                    }
                }
            }
            // The floor over this storey, or the roof over the top one.
            let top = storey == options.storeys - 1
            if top && !options.roof { continue }
            for (n, outline) in analysis.slabs.enumerated() {
                let inside =
                    options.slabsInsideWalls
                    ? inset(outline, by: outer.map { analysis.walls[$0].rectangle }) : outline
                let boxes = inside.map { box($0.min, $0.max, underSlab, z0 + height) }
                try add(
                    top
                        ? "Roof\(analysis.slabs.count > 1 ? " \(n + 1)" : "")"
                        : "\(storeyName(storey + 1)) slab",
                    top ? "IfcRoof" : "IfcSlab", storey,
                    shrunk(boxes), [.init(name: options.slabMaterial, thickness: Float(slab))])
            }
        }
        if options.groundSlab > 0 {
            for outline in analysis.slabs {
                try add(
                    "Ground-bearing slab", "IfcSlab", 0,
                    shrunk(outline.map { box($0.min, $0.max, -options.groundSlab, 0) }),
                    [.init(name: options.slabMaterial, thickness: Float(options.groundSlab))])
            }
        }
        return elements
    }

    /// A wall's footprint lies along the outline's edge: inside a rectangle of it, with one face
    /// within 5 cm of that rectangle's side.
    static func onEdge(
        _ wall: (min: SIMD2<Double>, max: SIMD2<Double>),
        of outline: [(min: SIMD2<Double>, max: SIMD2<Double>)]
    ) -> Bool {
        outline.contains { r in
            let inside = (0..<2).allSatisfy {
                wall.min[$0] >= r.min[$0] - 0.05 && wall.max[$0] <= r.max[$0] + 0.05
            }
            let side = (0..<2).contains {
                abs(wall.min[$0] - r.min[$0]) < 0.05 || abs(wall.max[$0] - r.max[$0]) < 0.05
            }
            return inside && side
        }
    }

    /// An outline's rectangles less the walls' footprints; slivers under 5 cm dropped.
    static func inset(
        _ outline: [(min: SIMD2<Double>, max: SIMD2<Double>)],
        by walls: [(min: SIMD2<Double>, max: SIMD2<Double>)]
    ) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        var pieces = outline
        for wall in walls {
            pieces = pieces.flatMap { r -> [(min: SIMD2<Double>, max: SIMD2<Double>)] in
                let lo = simd_max(r.min, wall.min)
                let hi = simd_min(r.max, wall.max)
                guard hi.x > lo.x, hi.y > lo.y else { return [r] }
                // Below, above, then left and right of the overlap.
                return [
                    (r.min, SIMD2(r.max.x, lo.y)), (SIMD2(r.min.x, hi.y), r.max),
                    (SIMD2(r.min.x, lo.y), SIMD2(lo.x, hi.y)), (SIMD2(hi.x, lo.y), SIMD2(r.max.x, hi.y)),
                ]
            }
            .filter { $0.max.x - $0.min.x >= 0.05 && $0.max.y - $0.min.y >= 0.05 }
        }
        return pieces
    }

    /// Boxes of one element drawn apart by a millimetre, as one element's mesh cannot hold
    /// touching solids.
    static func shrunk(_ boxes: [Box]) -> [Box] {
        guard boxes.count > 1 else { return boxes }
        return boxes.map {
            var b = $0
            b.min += SIMD3(repeating: 0.0005)
            b.max -= SIMD3(repeating: 0.0005)
            return b
        }
    }

    /// Closed boxes as one mesh.
    static func mesh(_ boxes: [Box]) throws -> ImportedMesh {
        var text = ""
        var base = 0
        for box in boxes {
            for k in 0..<8 {
                let x = k & 1 == 0 ? box.min.x : box.max.x
                let y = k & 2 == 0 ? box.min.y : box.max.y
                let z = k & 4 == 0 ? box.min.z : box.max.z
                text += "v \(x) \(y) \(z)\n"
            }
            for face in [
                [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
            ] {
                let v = face.map { $0 + base + 1 }
                text += "f \(v[0]) \(v[1]) \(v[2])\nf \(v[0]) \(v[2]) \(v[3])\n"
            }
            base += 8
        }
        return try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
    }

    /// A first guess at each layer's role from its name, as offices name them (A-WALL, WALLS,
    /// IFCWALL, Door, FENETRE…); walls get `wall`'s construction.
    /// A storey's name: the ground floor, then the first, second… as in British use.
    public static func storeyName(_ storey: Int) -> String {
        let names = [
            "Ground floor", "First floor", "Second floor", "Third floor", "Fourth floor", "Fifth floor",
        ]
        return storey >= 0 && storey < names.count ? names[storey] : "Floor \(storey)"
    }

    public static func guessedRoles(_ layers: [String], wall: Construction = .cavityBrickBlock) -> [String:
        Role]
    {
        var roles: [String: Role] = [:]
        for layer in layers {
            let n = layer.lowercased()
            func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
            if has("window", "fenet", "fenst", "glaz", "win") {
                roles[layer] = .window
            } else if has("door", "porte", "tür", "tuer") || n.hasPrefix("dr") {
                roles[layer] = .door
            } else if has("slab", "floor outline", "outline", "footprint") {
                roles[layer] = .slab
            } else if has("wall", "mur", "wand", "pared") {
                roles[layer] = .wall(has("int", "partition", "part") ? .block100 : wall)
            } else {
                roles[layer] = .ignore
            }
        }
        return roles
    }
}
