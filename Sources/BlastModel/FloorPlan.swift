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
        /// Metres per drawing unit (the drawing's $INSUNITS or an SVG's size, or asked).
        public var metresPerUnit: Double = 0.001
        /// The scale the plan is drawn to, 1 : `drawingScale` (a plan exported to paper at 1:100 is
        /// 100); 1 for a drawing in real lengths, as CAD's model space is.
        public var drawingScale: Double = 1
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
        /// A plan whose walls mostly run at an angle to its axes is turned square to them first.
        public var squareToWalls = true
        /// Walls at an angle to the (squared) plan, and the chords of curved ones, are raised as
        /// walls turned in plan; else left out.
        public var angledWalls = true

        public init() {}
    }

    /// A straight wall at an angle to the plan's axes, or a chord of a curved one: its midline from
    /// `a` to `b` (m).
    public struct AngledWall: Sendable, Hashable {
        public var a: SIMD2<Double>
        public var b: SIMD2<Double>
        public var thickness: Double
        public var construction: Construction
        public var layer: String
        public var centreline: Bool
        public var length: Double { simd_distance(a, b) }
        public var direction: SIMD2<Double> { (b - a) / max(length, 1e-12) }
        /// Its footprint's four corners, in order.
        public var corners: [SIMD2<Double>] {
            let n = SIMD2(-direction.y, direction.x) * (thickness / 2)
            return [a - n, b - n, b + n, a + n]
        }
    }

    /// An opening in an angled wall, `from`…`to` m along it from its `a` end.
    public struct AngledOpening: Sendable, Hashable {
        public var wall: Int
        public var from: Double
        public var to: Double
        public var kind: OpeningKind
        public var layer: String?
        public var storey: Int?
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            axis: Int,
            offset: Double,
            from: Double,
            to: Double,
            thickness: Double,
            construction: Construction,
            layer: String,
            centreline: Bool
        ) {
            self.axis = axis
            self.offset = offset
            self.from = from
            self.to = to
            self.thickness = thickness
            self.construction = construction
            self.layer = layer
            self.centreline = centreline
        }
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
        /// Lines on wall layers that are not square to the axes and were left out, and their length
        /// (m).
        public var angledLines = 0
        public var angledLength = 0.0
        /// Walls at an angle, and openings in them.
        public var angled: [AngledWall] = []
        public var angledOpenings: [AngledOpening] = []
        /// How far the plan was turned to square it to its walls, degrees (anticlockwise), and
        /// about which point (m, in the drawing).
        public var turn = 0.0
        public var turnCentre = SIMD2<Double>.zero
    }

    /// Straight pieces of a layer square to an axis: `offset` across, `from`…`to` along (m).
    struct Line: Hashable {
        var axis: Int
        var offset: Double
        var from: Double
        var to: Double
        package var length: Double { to - from }
    }

    /// Finds the walls, openings and floors in `drawing` under `options`.
    public static func analyse(_ drawing: DXFDrawing, options: Options) -> Analysis {
        var analysis = Analysis()
        let scale = options.metresPerUnit * options.drawingScale
        var segments = drawing.segments().map { s -> DXFDrawing.Segment in
            var s = s
            s.a *= scale
            s.b *= scale
            return s
        }
        guard !segments.isEmpty else {
            analysis.notes.append("The drawing has nothing in it to read.")
            return analysis
        }
        // A plan drawn turned is turned square to its walls first, about their middle.
        let isWall = { (layer: String) -> Bool in
            if case .wall = options.roles[layer] { return true }
            return false
        }
        if options.squareToWalls, let turn = dominantTurn(segments.filter { isWall($0.layer) }),
            abs(turn) > 0.5
        {
            let walls = segments.filter { isWall($0.layer) }.flatMap { [$0.a, $0.b] }
            let lo = walls.reduce(SIMD2(repeating: Double.infinity), simd_min)
            let hi = walls.reduce(SIMD2(repeating: -Double.infinity), simd_max)
            analysis.turn = turn
            analysis.turnCentre = (lo + hi) / 2
            segments = segments.map {
                var s = $0
                s.a = rotate(s.a, by: -turn, about: analysis.turnCentre)
                s.b = rotate(s.b, by: -turn, about: analysis.turnCentre)
                return s
            }
            analysis.notes.append(
                String(
                    format:
                        "The plan's walls run at %.1f° to its axes: it is turned square to them, so that the walls lie square to the air's cells.",
                    turn))
        }
        var low = SIMD2(Double.infinity, .infinity)
        var high = -low
        for s in segments where options.roles[s.layer].map({ $0 != .ignore }) ?? false {
            low = simd_min(low, simd_min(s.a, s.b))
            high = simd_max(high, simd_max(s.a, s.b))
        }
        if low.x.isFinite { analysis.bounds = (low, high) }

        // Walls, layer by layer.
        var blocksOnWalls = Set<Int>()
        for (layer, role) in options.roles.sorted(by: { $0.key < $1.key }) {
            guard case .wall(let construction) = role else { continue }
            var lines: [Line] = []
            var slanted: [(a: SIMD2<Double>, b: SIMD2<Double>)] = []
            for s in segments where s.layer == layer {
                // Blocks on a wall layer are furniture, symbols or columns, not walls.
                if s.insert != nil {
                    blocksOnWalls.insert(s.insert!)
                    continue
                }
                if let line = squareLine(s.a, s.b) {
                    lines.append(line)
                } else if simd_distance(s.a, s.b) > 1e-4 {
                    slanted.append((s.a, s.b))
                }
            }
            lines = capped(merged(lines), options: options)
            let lineLength = lines.reduce(0) { $0 + $1.length }
            let found = solidPieces(lines, options: options)
            // Drawn by both faces where the solid's outline is most of what is drawn; by centrelines
            // where the lines enclose little but rooms.
            var walls: [Wall]
            let byFaces: Bool
            if let found, found.outline >= 0.5 * lineLength, lineLength > 0 {
                byFaces = true
                walls = found.pieces.map {
                    Wall(
                        axis: $0.axis, offset: $0.offset, from: $0.from, to: $0.to, thickness: $0.thickness,
                        construction: construction, layer: layer, centreline: false)
                }
                analysis.notes.append(
                    "\(layer): read as walls drawn by their outlines, \(walls.count) pieces, thicknesses "
                        + thicknessSummary(walls.map(\.thickness)) + "; their build-up "
                        + construction.name + ".")
            } else if lineLength == 0 {
                // Only angled lines: by faces if most of them pair as faces.
                let paired = pairSlanted(slanted, options: options)
                byFaces = paired.pairedLength >= paired.leftLength
                walls = []
            } else {
                byFaces = false
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
            // Drawn by faces, short lines at an angle lying within the walls found (a mitred
            // corner's seam between two walls' solids) are the walls' joints.
            if byFaces {
                func inside(_ p: SIMD2<Double>) -> Bool {
                    walls.contains { wall in
                        let r = wall.rectangle
                        return p.x >= r.min.x - 0.01 && p.x <= r.max.x + 0.01 && p.y >= r.min.y - 0.01
                            && p.y <= r.max.y + 0.01
                    }
                }
                let seams = slanted.filter { inside($0.a) && inside($0.b) && inside(($0.a + $0.b) / 2) }
                if !seams.isEmpty {
                    slanted.removeAll { line in seams.contains { $0.a == line.a && $0.b == line.b } }
                    analysis.notes.append(
                        "\(layer): \(seams.count) short lines at an angle within the walls' corners are taken as their joints (mitred), not walls."
                    )
                }
            }
            // Lines at an angle: walls turned in plan, by the layer's way of drawing them.
            if !slanted.isEmpty {
                if options.angledWalls {
                    if byFaces {
                        let paired = pairSlanted(slanted, options: options)
                        analysis.angled += paired.walls.map {
                            AngledWall(
                                a: $0.a, b: $0.b, thickness: $0.thickness, construction: construction,
                                layer: layer,
                                centreline: false)
                        }
                        if paired.leftLength > 0.05 {
                            analysis.angledLines += paired.leftCount
                            analysis.angledLength += paired.leftLength
                        }
                    } else {
                        analysis.angled += mergedSlanted(slanted).filter {
                            simd_distance($0.a, $0.b) > construction.thickness
                        }.map {
                            AngledWall(
                                a: $0.a, b: $0.b, thickness: construction.thickness,
                                construction: construction,
                                layer: layer, centreline: true)
                        }
                    }
                } else {
                    analysis.angledLines += slanted.count
                    analysis.angledLength += slanted.reduce(0) { $0 + simd_distance($1.a, $1.b) }
                }
            }
        }
        if analysis.walls.isEmpty && analysis.angled.isEmpty {
            analysis.notes.append(
                "No walls were found on the layers marked as walls: check the layers' roles, the units, and that the walls are drawn by lines (hatching alone is not read)."
            )
        }
        if !blocksOnWalls.isEmpty {
            analysis.notes.append(
                "\(blocksOnWalls.count) blocks on wall layers (furniture, symbols, columns) are not read as walls."
            )
        }
        if analysis.angledLines > 0 {
            analysis.notes.append(
                options.angledWalls
                    ? "\(analysis.angledLines) lines on wall layers (\(String(format: "%.1f", analysis.angledLength)) m) at an angle to the plan's axes pair with no other as a wall's faces and are left out."
                    : "\(analysis.angledLines) lines on wall layers (\(String(format: "%.1f", analysis.angledLength)) m) are not square to the plan's axes and are left out (walls at an angle are turned off)."
            )
        }
        analysis.walls = cleaned(analysis.walls)
        if !analysis.angled.isEmpty {
            joinAngled(&analysis.walls, &analysis.angled)
            analysis.notes.append(
                "\(analysis.angled.count) walls at an angle to the plan's axes (or chords of curved ones), "
                    + String(format: "%.1f m", analysis.angled.reduce(0) { $0 + $1.length })
                    + ": raised as walls turned in plan, each a shell in its own plane.")
        }
        // The plan's extent takes in the walls' faces, beyond centrelines.
        for wall in analysis.walls {
            low = simd_min(low, wall.rectangle.min)
            high = simd_max(high, wall.rectangle.max)
        }
        for wall in analysis.angled {
            for corner in wall.corners {
                low = simd_min(low, corner)
                high = simd_max(high, corner)
            }
        }
        if low.x.isFinite { analysis.bounds = (low, high) }

        // Openings drawn on their layers, by INSERT or by clusters of lines, each kept with its
        // lines.
        var groups: [String: (kind: OpeningKind, layer: String, lines: [(SIMD2<Double>, SIMD2<Double>)])] =
            [:]
        var loose: [(min: SIMD2<Double>, max: SIMD2<Double>, kind: OpeningKind, layer: String)] = []
        var looseLines: [(SIMD2<Double>, SIMD2<Double>)] = []
        for s in segments {
            let kind: OpeningKind
            switch options.roles[s.layer] {
            case .door: kind = .door
            case .window: kind = .window
            default: continue
            }
            if let insert = s.insert {
                groups["\(insert)", default: (kind, s.layer, [])].lines.append((s.a, s.b))
            } else {
                loose.append((simd_min(s.a, s.b), simd_max(s.a, s.b), kind, s.layer))
                looseLines.append((s.a, s.b))
            }
        }
        var items: [(kind: OpeningKind, layer: String, lines: [(SIMD2<Double>, SIMD2<Double>)])] =
            groups.keys.sorted().map { groups[$0]! }
        for cluster in clusters(loose) {
            let lines = looseLines.enumerated().filter { n, _ in
                loose[n].layer == cluster.layer && all(loose[n].min .>= cluster.min - 1e-9)
                    && all(loose[n].max .<= cluster.max + 1e-9)
            }.map(\.element)
            items.append((cluster.kind, cluster.layer, lines))
        }
        // Each one's extent the part of its lines in the wall that holds most of them: a door's
        // leaf and swing reach into the room, its opening is where it crosses the wall.
        let drawn = items.map { item in
            (
                box: focusedBox(item.lines, walls: analysis.walls, angled: analysis.angled), kind: item.kind,
                layer: item.layer
            )
        }
        // Walls carried across what is drawn just past their ends; then gaps in the walls, then
        // what is drawn in them or in centreline walls.
        analysis.walls = bridged(analysis.walls, over: drawn)
        analysis.openings = gapOpenings(&analysis.walls, options: options)
        place(
            drawn, walls: analysis.walls, storeys: options.layerStoreys, openings: &analysis.openings,
            notes: &analysis.notes, angled: analysis.angled, angledOpenings: &analysis.angledOpenings)
        let slantedWindows = analysis.angledOpenings.filter { $0.kind == .window }.count
        if slantedWindows > 0 {
            analysis.notes.append(
                "\(slantedWindows) windows in walls at an angle are left open: their glass is not modelled there."
            )
        }
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
            let pts = points.map {
                analysis.turn == 0
                    ? $0 * scale : rotate($0 * scale, by: -analysis.turn, about: analysis.turnCentre)
            }
            // Squared, a drawn outline's corners may sit a hair off square.
            let squared = pts.map { ($0 * 1e4).rounded(.toNearestOrEven) / 1e4 }
            if let rects = rectangles(ofOrthogonal: squared) { outlines.append(rects) }
        }
        if outlines.isEmpty, let first = analysis.walls.first {
            var lo = first.rectangle.min
            var hi = first.rectangle.max
            for wall in analysis.walls {
                lo = simd_min(lo, wall.rectangle.min)
                hi = simd_max(hi, wall.rectangle.max)
            }
            for wall in analysis.angled {
                for corner in wall.corners {
                    lo = simd_min(lo, corner)
                    hi = simd_max(hi, corner)
                }
            }
            if !analysis.angled.isEmpty {
                analysis.notes.append(
                    "The floors and roof are rectangles over all the walls: past walls at an angle they reach out to the rectangle's corners."
                )
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

    // MARK: - Lines at an angle

    /// `point` turned `degrees` anticlockwise about `centre`.
    public static func rotate(_ point: SIMD2<Double>, by degrees: Double, about centre: SIMD2<Double>)
        -> SIMD2<Double>
    {
        let t = degrees * .pi / 180
        let d = point - centre
        return centre + SIMD2(d.x * cos(t) - d.y * sin(t), d.x * sin(t) + d.y * cos(t))
    }

    /// The angle, in degrees from −45 to 45, that most of the walls' length runs at to the axes
    /// (to a tenth of a degree, from a histogram smoothed over a degree); nil without walls.
    static func dominantTurn(_ segments: [DXFDrawing.Segment]) -> Double? {
        var bins = [Double](repeating: 0, count: 900)
        for s in segments {
            let d = s.b - s.a
            let length = simd_length(d)
            guard length > 1e-6 else { continue }
            var angle = atan2(d.y, d.x) * 180 / .pi
            angle = angle - 90 * (angle / 90).rounded(.down)  // 0..<90
            if angle >= 45 { angle -= 90 }  // −45..<45
            bins[min(899, max(0, Int(((angle + 45) * 10).rounded(.down))))] += length
        }
        guard bins.contains(where: { $0 > 0 }) else { return nil }
        let smoothed = bins.indices.map { i in (-5...5).reduce(0.0) { $0 + bins[(i + $1 + 900) % 900] } }
        guard let peak = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) else { return nil }
        // The weighted mean of the lines' own angles within a degree of the peak.
        let centre = Double(peak) / 10 - 45 + 0.05
        var sum = 0.0
        var weight = 0.0
        for s in segments {
            let d = s.b - s.a
            let length = simd_length(d)
            guard length > 1e-6 else { continue }
            var angle = atan2(d.y, d.x) * 180 / .pi
            angle = angle - 90 * (angle / 90).rounded(.down)
            if angle >= 45 { angle -= 90 }
            // Nearest the peak, across the ±45° seam.
            var offset = angle - centre
            if offset > 45 { offset -= 90 }
            if offset < -45 { offset += 90 }
            guard abs(offset) <= 1 else { continue }
            sum += length * (centre + offset)
            weight += length
        }
        return weight > 0 ? sum / weight : nil
    }

    /// A line at an angle: its direction (x ≥ 0, turned so), its offset across (along the normal
    /// (−u.y, u.x)) and its extent along, m.
    struct Slant {
        var direction: SIMD2<Double>
        var offset: Double
        var from: Double
        var to: Double
        package var normal: SIMD2<Double> { SIMD2(-direction.y, direction.x) }
        var a: SIMD2<Double> { direction * from + normal * offset }
        var b: SIMD2<Double> { direction * to + normal * offset }

        init(_ a: SIMD2<Double>, _ b: SIMD2<Double>) {
            var u = simd_normalize(b - a)
            if u.x < 0 || (u.x == 0 && u.y < 0) { u = -u }
            direction = u
            let n = SIMD2(-u.y, u.x)
            offset = simd_dot(a, n)
            let s = (simd_dot(a, u), simd_dot(b, u))
            from = min(s.0, s.1)
            to = max(s.0, s.1)
        }

        func parallel(to other: Slant, within degrees: Double = 0.5) -> Bool {
            abs(simd_dot(direction, other.normal)) < sin(degrees * .pi / 180)
        }
    }

    /// Lines at an angle on one line and touching or overlapping, joined.
    static func mergedSlanted(_ lines: [(a: SIMD2<Double>, b: SIMD2<Double>)]) -> [(
        a: SIMD2<Double>, b: SIMD2<Double>
    )] {
        var slants = lines.map { Slant($0.a, $0.b) }
        var merged = true
        while merged {
            merged = false
            outer: for i in slants.indices {
                for j in slants.indices where j > i {
                    let p = slants[i]
                    let q = slants[j]
                    guard p.parallel(to: q, within: 0.3), abs(simd_dot(q.a, p.normal) - p.offset) < 0.002,
                        simd_dot(q.a, p.direction) <= p.to + 0.002
                            || simd_dot(q.b, p.direction) <= p.to + 0.002
                    else { continue }
                    let qFrom = min(simd_dot(q.a, p.direction), simd_dot(q.b, p.direction))
                    let qTo = max(simd_dot(q.a, p.direction), simd_dot(q.b, p.direction))
                    guard qFrom <= p.to + 0.002, qTo >= p.from - 0.002 else { continue }
                    slants[i].from = min(p.from, qFrom)
                    slants[i].to = max(p.to, qTo)
                    slants.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return slants.map { ($0.a, $0.b) }
    }

    /// Lines at an angle paired as a wall's two faces: each with the nearest parallel line beyond
    /// it within a wall's thickness, over the stretch they share; the walls' midlines and
    /// thicknesses, and how much paired and how much (in how many lines) did not.
    static func pairSlanted(_ lines: [(a: SIMD2<Double>, b: SIMD2<Double>)], options: Options) -> (
        walls: [(a: SIMD2<Double>, b: SIMD2<Double>, thickness: Double)], pairedLength: Double,
        leftLength: Double,
        leftCount: Int
    ) {
        let slants = mergedSlanted(lines).map { Slant($0.a, $0.b) }
        var walls: [(a: SIMD2<Double>, b: SIMD2<Double>, thickness: Double)] = []
        var used = [Double](repeating: 0, count: slants.count)
        for (i, p) in slants.enumerated() {
            var best: (j: Int, gap: Double)?
            for (j, q) in slants.enumerated() where j != i && p.parallel(to: q) {
                let gap = simd_dot(q.a, p.normal) - p.offset
                let qFrom = min(simd_dot(q.a, p.direction), simd_dot(q.b, p.direction))
                let qTo = max(simd_dot(q.a, p.direction), simd_dot(q.b, p.direction))
                guard gap >= options.thinnestWall, gap <= options.thickestWall,
                    min(p.to, qTo) - max(p.from, qFrom) > 0.1
                else { continue }
                if gap < (best?.gap ?? .infinity) { best = (j, gap) }
            }
            guard let best else { continue }
            let q = slants[best.j]
            let from = max(p.from, min(simd_dot(q.a, p.direction), simd_dot(q.b, p.direction)))
            let to = min(p.to, max(simd_dot(q.a, p.direction), simd_dot(q.b, p.direction)))
            let mid = p.offset + best.gap / 2
            walls.append((p.direction * from + p.normal * mid, p.direction * to + p.normal * mid, best.gap))
            used[i] += to - from
            used[best.j] += to - from
        }
        var left = 0.0
        var count = 0
        // A short line left over, no longer than a wall is thick, is a wall's end (a curved wall's
        // cap, a jamb), not a wall.
        for (i, p) in slants.enumerated()
        where p.to - p.from - used[i] > 0.05 && p.to - p.from > options.thickestWall + 0.01 {
            left += p.to - p.from - used[i]
            count += 1
        }
        return (walls, walls.reduce(0) { $0 + simd_distance($1.a, $1.b) } * 2, left, count)
    }

    /// Angled walls' ends carried to the midline of the wall they meet (within their thicknesses
    /// and a little more), so that walls of a curve share their corners and an angled wall meets
    /// the square walls on their midsurfaces; and square walls' ends that stop at an angled wall
    /// carried to its midline.
    static func joinAngled(_ walls: inout [Wall], _ angled: inout [AngledWall]) {
        // The point where the line through `p` along `u` crosses the line through `q` along `v`, as
        // a distance along `u` from `p`; nil if they are near parallel.
        func crossing(_ p: SIMD2<Double>, _ u: SIMD2<Double>, _ q: SIMD2<Double>, _ v: SIMD2<Double>)
            -> Double?
        {
            let denominator = u.x * v.y - u.y * v.x
            guard abs(denominator) > sin(5 * Double.pi / 180) else { return nil }
            let d = q - p
            return (d.x * v.y - d.y * v.x) / denominator
        }
        let before = angled
        for (n, wall) in before.enumerated() {
            for end in 0..<2 {
                let p = end == 0 ? wall.a : wall.b
                let outward = end == 0 ? -wall.direction : wall.direction
                var best: (distance: Double, point: SIMD2<Double>)?
                func consider(_ q: SIMD2<Double>, _ v: SIMD2<Double>, length: Double, thickness: Double) {
                    guard let t = crossing(p, outward, q, v) else { return }
                    let reach = 0.5 * thickness + wall.thickness + 0.3
                    guard t >= -wall.thickness - 0.3, t <= reach else { return }
                    let point = p + t * outward
                    let along = simd_dot(point - q, v)
                    guard along >= -reach, along <= length + reach else { return }
                    if abs(t) < (best?.distance ?? .infinity) { best = (abs(t), point) }
                }
                for (m, other) in before.enumerated() where m != n {
                    consider(other.a, other.direction, length: other.length, thickness: other.thickness)
                }
                for other in walls {
                    let q =
                        other.axis == 0 ? SIMD2(other.from, other.offset) : SIMD2(other.offset, other.from)
                    let v = other.axis == 0 ? SIMD2<Double>(1, 0) : SIMD2<Double>(0, 1)
                    consider(q, v, length: other.length, thickness: other.thickness)
                }
                if let best {
                    if end == 0 { angled[n].a = best.point } else { angled[n].b = best.point }
                }
            }
        }
        // Square walls ending at an angled wall: carried to its midline.
        for n in walls.indices {
            let wall = walls[n]
            let u = wall.axis == 0 ? SIMD2<Double>(1, 0) : SIMD2<Double>(0, 1)
            let start = wall.axis == 0 ? SIMD2(wall.from, wall.offset) : SIMD2(wall.offset, wall.from)
            for other in angled {
                guard let t = crossing(start, u, other.a, other.direction) else { continue }
                let point = start + t * u
                let along = simd_dot(point - other.a, other.direction)
                guard along >= -0.05, along <= other.length + 0.05 else { continue }
                let reach =
                    other.thickness / 2
                    / max(abs(simd_dot(SIMD2(-other.direction.y, other.direction.x), u)), 0.2)
                    + 0.05
                if abs(t - (wall.to - wall.from)) <= reach { walls[n].to = wall.from + t }
                if abs(t) <= reach { walls[n].from = wall.from + t }
            }
        }
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

    /// Lines drawn by both faces whose wall is left open at an end (its two faces ending together,
    /// a wall's thickness apart, with nothing across them), closed there with a line across: an
    /// outline not closed at a corner or a jamb not drawn would otherwise let a room into the wall.
    static func capped(_ lines: [Line], options: Options, tolerance: Double = 0.006) -> [Line] {
        var caps: [Line] = []
        func covered(_ cap: Line) -> Bool {
            (lines + caps).contains { other in
                other.axis == cap.axis && abs(other.offset - cap.offset) <= tolerance
                    && other.from <= cap.from + tolerance && other.to >= cap.to - tolerance
            }
        }
        for (i, line) in lines.enumerated() {
            for (j, other) in lines.enumerated() where j > i && other.axis == line.axis {
                let gap = abs(other.offset - line.offset)
                guard gap >= options.thinnestWall, gap <= options.thickestWall else { continue }
                for end in [line.from, line.to] {
                    guard abs(other.from - end) <= tolerance || abs(other.to - end) <= tolerance else {
                        continue
                    }
                    let cap = Line(
                        axis: 1 - line.axis, offset: end, from: min(line.offset, other.offset),
                        to: max(line.offset, other.offset))
                    if !covered(cap) { caps.append(cap) }
                }
            }
        }
        return lines + caps
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
        // Lines that stop a few millimetres short of each other (untidy corners) still close.
        let snap = 0.006
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

    /// The extent of an opening drawn as `lines`: the box of their parts within the band of the
    /// wall (square or at an angle) that holds the most of them running along it (its thickness and
    /// 15 cm either side, along its line however far: an opening beside a wall's end, which the
    /// wall is carried across), of walls holding alike the nearer; the box of them all if none does.
    static func focusedBox(
        _ lines: [(SIMD2<Double>, SIMD2<Double>)], walls: [Wall], angled: [AngledWall]
    ) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
        let points = lines.flatMap { [$0.0, $0.1] }
        let whole = (
            min: points.reduce(SIMD2(repeating: Double.infinity), simd_min),
            max: points.reduce(SIMD2(repeating: -Double.infinity), simd_max)
        )
        // A wall's frame: its start, along, across, length and half width of band.
        var frames: [(origin: SIMD2<Double>, along: SIMD2<Double>, length: Double, half: Double)] = walls.map
        { wall in
            let along = wall.axis == 0 ? SIMD2<Double>(1, 0) : SIMD2<Double>(0, 1)
            let origin = wall.axis == 0 ? SIMD2(wall.from, wall.offset) : SIMD2(wall.offset, wall.from)
            return (origin, along, wall.length, wall.thickness / 2 + 0.15)
        }
        frames += angled.map { ($0.a, $0.direction, $0.length, $0.thickness / 2 + 0.15) }
        var best: (length: Double, box: (min: SIMD2<Double>, max: SIMD2<Double>))?
        for frame in frames {
            let across = SIMD2(-frame.along.y, frame.along.x)
            var inside: [SIMD2<Double>] = []
            var length = 0.0
            for (a, b) in lines {
                // In the wall's frame, clipped to its band (Liang and Barsky).
                let p = SIMD2(simd_dot(a - frame.origin, frame.along), simd_dot(a - frame.origin, across))
                let q = SIMD2(simd_dot(b - frame.origin, frame.along), simd_dot(b - frame.origin, across))
                let d = q - p
                var t0 = 0.0
                var t1 = 1.0
                var outside = false
                for (delta, low, high, start) in [
                    (d.x, -Double.infinity, Double.infinity, p.x), (d.y, -frame.half, frame.half, p.y),
                ] {
                    if abs(delta) < 1e-12 || !low.isFinite {
                        if start < low || start > high { outside = true }
                        continue
                    }
                    var ta = (low - start) / delta
                    var tb = (high - start) / delta
                    if ta > tb { swap(&ta, &tb) }
                    t0 = max(t0, ta)
                    t1 = min(t1, tb)
                }
                guard !outside, t1 > t0 else { continue }
                let c0 = a + (b - a) * t0
                let c1 = a + (b - a) * t1
                inside += [c0, c1]
                // An opening runs along its wall: its pieces counted by how nearly they do (a door's
                // leaf open square to the wall counts for nothing; its threshold, or a closed leaf, whole).
                let run = simd_length(d) > 1e-12 ? abs(d.x) / simd_length(d) : 0
                length += simd_distance(c0, c1) * run
            }
            // Of walls holding alike, the nearer: how far past its ends the pieces lie.
            let alongs = inside.map { simd_dot($0 - frame.origin, frame.along) }
            let beyond = max(0, -(alongs.min() ?? 0), (alongs.max() ?? 0) - frame.length)
            length -= 1e-3 * beyond
            guard !inside.isEmpty, length > (best?.length ?? 0.05) else { continue }
            best = (
                length,
                (
                    inside.reduce(SIMD2(repeating: Double.infinity), simd_min),
                    inside.reduce(SIMD2(repeating: -Double.infinity), simd_max)
                )
            )
        }
        return best?.box ?? whole
    }

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
        walls: [Wall], storeys: [String: Int], openings: inout [Opening], notes: inout [String],
        angled: [AngledWall] = [], angledOpenings: inout [AngledOpening]
    ) {
        var unplaced = 0
        // Off every square wall: in the angled wall it lies in, its extent along it.
        func placeAngled(
            _ item: (box: (min: SIMD2<Double>, max: SIMD2<Double>), kind: OpeningKind, layer: String)
        )
            -> Bool
        {
            let centre = (item.box.min + item.box.max) / 2
            let corners = [
                item.box.min, item.box.max, SIMD2(item.box.min.x, item.box.max.y),
                SIMD2(item.box.max.x, item.box.min.y),
            ]
            let hosts = angled.indices.filter { index in
                let wall = angled[index]
                let along = simd_dot(centre - wall.a, wall.direction)
                let across = abs(simd_dot(centre - wall.a, SIMD2(-wall.direction.y, wall.direction.x)))
                return across <= wall.thickness / 2 + 0.15 && along >= -0.05 && along <= wall.length + 0.05
            }
            guard let host = hosts.first else { return false }
            let wall = angled[host]
            let alongs = corners.map { simd_dot($0 - wall.a, wall.direction) }
            let from = max(alongs.min() ?? 0, 0)
            let to = min(alongs.max() ?? 0, wall.length)
            guard to - from > 0.1 else { return false }
            let storey = storeys[item.layer]
            if !angledOpenings.contains(where: {
                $0.wall == host && $0.from < to && $0.to > from
                    && ($0.storey == nil || storey == nil || $0.storey == storey)
            }) {
                angledOpenings.append(
                    AngledOpening(
                        wall: host, from: from, to: to, kind: item.kind, layer: item.layer, storey: storey))
            }
            return true
        }
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
                if !placeAngled(item) { unplaced += 1 }
                continue
            }
            let wall = walls[host]
            let from = max(item.box.min[wall.axis], wall.from)
            let to = min(item.box.max[wall.axis], wall.to)
            guard to - from > 0.1 else {
                if !placeAngled(item) { unplaced += 1 }
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
            // Walls at an angle: each stretch between openings, and under and over each, a wall of
            // its own turned in plan (`IFCStructure.uprightPlane`), as the stretches of a square wall
            // are its boxes. Their openings are left open.
            for (index, wall) in analysis.angled.enumerated() {
                if let only = options.layerStoreys[wall.layer], only != storey { continue }
                let z1 = options.slabsInsideWalls ? z0 + height : underSlab
                let mine = analysis.angledOpenings.filter {
                    $0.wall == index && ($0.storey == nil || $0.storey == storey)
                }
                .sorted { $0.from < $1.from }
                var pieces: [(Double, Double, Double, Double)] = []
                var at = 0.0
                for opening in mine {
                    let sill = opening.kind == .window ? options.windowSill : 0
                    let head = min(opening.kind == .window ? options.windowHead : options.doorHead, z1 - z0)
                    if opening.from > at { pieces.append((at, opening.from, z0, z1)) }
                    if sill > 0 { pieces.append((opening.from, opening.to, z0, z0 + sill)) }
                    if z0 + head < z1 { pieces.append((opening.from, opening.to, z0 + head, z1)) }
                    at = max(at, opening.to)
                }
                if wall.length > at { pieces.append((at, wall.length, z0, z1)) }
                let partition = [Construction.block100, .studPartition].contains(wall.construction)
                let name = "\(storeyName(storey)) angled \(partition ? "partition" : "wall") \(index + 1)"
                for (n, piece) in pieces.enumerated()
                where piece.1 - piece.0 > 0.05 && piece.3 - piece.2 > 0.05 {
                    let a = wall.a + piece.0 * wall.direction - corner
                    let b = wall.a + piece.1 * wall.direction - corner
                    serial += 1
                    elements.append(
                        .init(
                            globalID: String(format: "DXF%019d", serial),
                            name: pieces.count > 1 ? "\(name) part \(n + 1)" : name, ifcClass: "IfcWall",
                            storey: storeyName(storey),
                            mesh: try uprightMesh(
                                from: a, to: b, thickness: wall.thickness, z0: piece.2, z1: piece.3),
                            materials: wall.construction.layers))
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
    /// A wall's box turned in plan: its midline from `a` to `b` (m, in the plan), `thickness` across,
    /// from `z0` to `z1`, as a closed mesh.
    static func uprightMesh(
        from a: SIMD2<Double>, to b: SIMD2<Double>, thickness: Double, z0: Double, z1: Double
    ) throws -> ImportedMesh {
        let u = simd_normalize(b - a)
        let n = SIMD2(-u.y, u.x) * (thickness / 2)
        var text = ""
        // In the order `mesh` lays a box's corners: along, across, up.
        for k in 0..<8 {
            let p = (k & 1 == 0 ? a : b) + (k & 2 == 0 ? -n : n)
            let z = k & 4 == 0 ? z0 : z1
            text += "v \(Float(p.x)) \(Float(p.y)) \(Float(z))\n"
        }
        for face in [
            [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
        ] {
            let v = face.map { $0 + 1 }
            text += "f \(v[0]) \(v[1]) \(v[2])\nf \(v[0]) \(v[2]) \(v[3])\n"
        }
        return try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
    }

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
