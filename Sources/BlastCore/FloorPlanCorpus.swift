import Foundation
import simd

/// The plan importer's corpus (Fixtures/FloorPlans, `Scripts/plans/make-corpus.py`): small plans
/// that each try one thing offices' drawings hold, with the answer expected of the importer, and
/// the check of one against the other (`scenebench plan-check`, `FloorPlanCorpusTests`).
public enum FloorPlanCorpus {
    /// How to read a plan: its layers' roles ("guess" for `FloorPlan.guessedRoles`, else each
    /// layer's "wall", "wall:<construction>", "door", "window", "slab" or "ignore"), the storeys
    /// layers keep to, the units where the file gives none, and the drawing's scale.
    public struct Options: Decodable {
        public var roles: Roles
        public var layerStoreys: [String: Int]?
        public var metresPerUnit: Double?
        public var drawingScale: Double?
        public var storeys: Int?

        public enum Roles: Decodable {
            case guess
            case given([String: String])

            public init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let text = try? c.decode(String.self), text == "guess" {
                    self = .guess
                } else {
                    self = .given(try c.decode([String: String].self))
                }
            }
        }
    }

    /// What reading it should give; each part checked only where given.
    public struct Expected: Decodable {
        /// The drawing does not read.
        public var readError: Bool?
        /// The file's own units, m per unit; given as null where the file gives none.
        public var units: Double??
        public var byFaces: Bool?
        /// Square walls by thickness (m, as text, to 5 mm): how many.
        public var wallThicknesses: [String: Int]?
        public var wallsAtMost: Int?
        public var noWallThinnerThan: Double?
        /// The plan's width and depth over its walls, m.
        public var bounds: [Double]?
        public var boundsTolerance: Double?
        public var doors: Int?
        public var windows: Int?
        public var gaps: Int?
        public var gapWindows: Int?
        public var gapDoors: Int?
        public var windowsByStorey: [String: Int]?
        /// Walls at an angle (chords of curves among them).
        public var angled: Int?
        public var angledAtLeast: Int?
        public var angledThickness: Double?
        /// How far the plan was turned square, degrees.
        public var turn: Double?
        /// The building's walls (IfcWall elements) on each storey.
        public var elementWalls: [String: Int]?
        public var notes: [String]?
        public var notNotes: [String]?

        enum CodingKeys: String, CodingKey {
            case readError, units, byFaces, wallThicknesses, wallsAtMost, noWallThinnerThan, bounds,
                boundsTolerance, doors, windows, gaps, gapWindows, gapDoors, windowsByStorey, angled,
                angledAtLeast, angledThickness, turn, elementWalls, notes, notNotes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            readError = try c.decodeIfPresent(Bool.self, forKey: .readError)
            if c.contains(.units) {
                units = .some(
                    try c.decodeNil(forKey: .units) ? nil : try c.decode(Double.self, forKey: .units))
            }
            byFaces = try c.decodeIfPresent(Bool.self, forKey: .byFaces)
            wallThicknesses = try c.decodeIfPresent([String: Int].self, forKey: .wallThicknesses)
            wallsAtMost = try c.decodeIfPresent(Int.self, forKey: .wallsAtMost)
            noWallThinnerThan = try c.decodeIfPresent(Double.self, forKey: .noWallThinnerThan)
            bounds = try c.decodeIfPresent([Double].self, forKey: .bounds)
            boundsTolerance = try c.decodeIfPresent(Double.self, forKey: .boundsTolerance)
            doors = try c.decodeIfPresent(Int.self, forKey: .doors)
            windows = try c.decodeIfPresent(Int.self, forKey: .windows)
            gaps = try c.decodeIfPresent(Int.self, forKey: .gaps)
            gapWindows = try c.decodeIfPresent(Int.self, forKey: .gapWindows)
            gapDoors = try c.decodeIfPresent(Int.self, forKey: .gapDoors)
            windowsByStorey = try c.decodeIfPresent([String: Int].self, forKey: .windowsByStorey)
            angled = try c.decodeIfPresent(Int.self, forKey: .angled)
            angledAtLeast = try c.decodeIfPresent(Int.self, forKey: .angledAtLeast)
            angledThickness = try c.decodeIfPresent(Double.self, forKey: .angledThickness)
            turn = try c.decodeIfPresent(Double.self, forKey: .turn)
            elementWalls = try c.decodeIfPresent([String: Int].self, forKey: .elementWalls)
            notes = try c.decodeIfPresent([String].self, forKey: .notes)
            notNotes = try c.decodeIfPresent([String].self, forKey: .notNotes)
        }
    }

    public struct Case: Decodable {
        public var file: String
        public var description: String
        public var options: Options
        public var expect: Expected
        /// A judgement call the importer does not meet, recorded rather than failed.
        public var limitation: String?
    }

    /// What reading the case's plan gave, in brief, and where it differs from what was expected.
    public struct Result {
        public var name: String
        public var failures: [String]
        public var summary: String
        public var limitation: String?
        /// The walls, openings and notes found, line by line.
        public var detail: [String] = []
    }

    /// The plan at `url` read as `case` asks, checked against its expectation.
    public static func check(_ entry: Case, folder: URL) -> Result {
        let name = (entry.file as NSString).deletingPathExtension
        var failures: [String] = []
        let url = folder.appending(path: entry.file)
        let drawing: DXFDrawing
        do {
            let data = try Data(contentsOf: url)
            drawing =
                try url.pathExtension.lowercased() == "svg" ? DXFDrawing(svg: data) : DXFDrawing(data: data)
        } catch {
            if entry.expect.readError != true {
                failures.append("did not read: \(error.localizedDescription)")
            }
            return Result(
                name: name, failures: failures, summary: "unread (\(error.localizedDescription))",
                limitation: entry.limitation)
        }
        if entry.expect.readError == true { failures.append("read, where it should not") }
        let expect = entry.expect
        if let units = expect.units {
            switch (units, drawing.metresPerUnit) {
            case (nil, nil): break
            case (let want?, let got?) where abs(want - got) <= 1e-9 * max(1, want): break
            default:
                failures.append(
                    "units \(drawing.metresPerUnit.map { "\($0)" } ?? "none"), expected \(units.map { "\($0)" } ?? "none")"
                )
            }
        }
        var options = FloorPlan.Options()
        options.metresPerUnit = drawing.metresPerUnit ?? entry.options.metresPerUnit ?? 0.001
        options.drawingScale = entry.options.drawingScale ?? 1
        options.storeys = entry.options.storeys ?? 2
        options.layerStoreys = entry.options.layerStoreys ?? [:]
        switch entry.options.roles {
        case .guess: options.roles = FloorPlan.guessedRoles(drawing.layers)
        case .given(let given):
            options.roles = given.mapValues { text in
                let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "wall": return .wall(Self.construction(named: parts.count > 1 ? parts[1] : ""))
                case "door": return .door
                case "window": return .window
                case "slab": return .slab
                default: return .ignore
                }
            }
        }
        let plan = FloorPlan.analyse(drawing, options: options)
        let size = plan.bounds.max - plan.bounds.min
        if let byFaces = expect.byFaces, !plan.walls.isEmpty,
            plan.walls.contains(where: { $0.centreline == byFaces })
        {
            failures.append(byFaces ? "some walls read as centrelines" : "some walls read as faces")
        }
        if let wanted = expect.wallThicknesses {
            for (text, count) in wanted {
                let t = Double(text) ?? 0
                let got = plan.walls.filter { abs($0.thickness - t) <= 0.005 }.count
                if got != count { failures.append("\(got) walls \(text) m thick, expected \(count)") }
            }
        }
        if let most = expect.wallsAtMost, plan.walls.count > most {
            failures.append("\(plan.walls.count) walls, expected at most \(most)")
        }
        if let thinnest = expect.noWallThinnerThan,
            let wall = plan.walls.first(where: { $0.thickness < thinnest })
        {
            failures.append(String(format: "a wall %.3f m thick", wall.thickness))
        }
        if let bounds = expect.bounds, bounds.count == 2 {
            let tolerance = expect.boundsTolerance ?? 0.05
            if abs(size.x - bounds[0]) > tolerance || abs(size.y - bounds[1]) > tolerance {
                failures.append(
                    String(
                        format: "plan %.3f × %.3f m, expected %g × %g", size.x, size.y, bounds[0], bounds[1]))
            }
        }
        let doors =
            plan.openings.filter { $0.kind == .door && $0.layer != nil }.count
            + plan.angledOpenings.filter { $0.kind == .door }.count
        let windows =
            plan.openings.filter { $0.kind == .window && $0.layer != nil }.count
            + plan.angledOpenings.filter { $0.kind == .window }.count
        let gaps = plan.openings.filter { $0.layer == nil }
        func expectCount(_ label: String, _ got: Int, _ want: Int?) {
            if let want, got != want { failures.append("\(got) \(label), expected \(want)") }
        }
        expectCount("doors drawn", doors, expect.doors)
        expectCount("windows drawn", windows, expect.windows)
        expectCount("gaps", gaps.count, expect.gaps)
        expectCount("gaps taken as windows", gaps.filter { $0.kind == .window }.count, expect.gapWindows)
        expectCount("gaps taken as doors", gaps.filter { $0.kind == .door }.count, expect.gapDoors)
        if let byStorey = expect.windowsByStorey {
            for (text, want) in byStorey {
                let storey = Int(text) ?? 0
                let got = plan.openings.filter { $0.kind == .window && $0.storey == storey }.count
                expectCount("windows on storey \(storey)", got, want)
            }
        }
        expectCount("walls at an angle", plan.angled.count, expect.angled)
        if let least = expect.angledAtLeast, plan.angled.count < least {
            failures.append("\(plan.angled.count) walls at an angle, expected at least \(least)")
        }
        if let t = expect.angledThickness, plan.angled.contains(where: { abs($0.thickness - t) > 0.01 }) {
            failures.append("walls at an angle not \(t) m thick: \(plan.angled.map(\.thickness))")
        }
        if let turn = expect.turn, abs(plan.turn - turn) > 0.2 {
            failures.append(String(format: "turned %.2f°, expected %g°", plan.turn, turn))
        }
        if let byStorey = expect.elementWalls {
            do {
                let elements = try FloorPlan.buildingElements(plan, options: options)
                for (text, want) in byStorey {
                    let storey = FloorPlan.storeyName(Int(text) ?? 0)
                    let got = elements.filter { $0.ifcClass == "IfcWall" && $0.storey == storey }.count
                    expectCount("walls on the \(storey.lowercased())", got, want)
                }
            } catch {
                failures.append("no building: \(error.localizedDescription)")
            }
        }
        for wanted in expect.notes ?? [] where !plan.notes.contains(where: { $0.contains(wanted) }) {
            failures.append("no note saying \"\(wanted)\"")
        }
        for unwanted in expect.notNotes ?? [] {
            if let note = plan.notes.first(where: { $0.contains(unwanted) }) {
                failures.append("noted: \(note)")
            }
        }
        let summary = String(
            format: "%d walls (%@), %d at an angle, %d doors, %d windows, %d gaps, %.2f × %.2f m%@",
            plan.walls.count,
            Dictionary(grouping: plan.walls, by: { String(format: "%.3f", $0.thickness) }).sorted {
                $0.key < $1.key
            }
            .map { "\($0.value.count) × \($0.key)" }.joined(separator: ", "),
            plan.angled.count, doors, windows, gaps.count, size.x, size.y,
            plan.turn != 0 ? String(format: ", turned %.1f°", plan.turn) : "")
        var detail = plan.walls.map {
            String(
                format: "wall axis %d at %.3f from %.3f to %.3f, %.0f mm%@", $0.axis, $0.offset, $0.from,
                $0.to,
                $0.thickness * 1000, $0.centreline ? " (centreline)" : "")
        }
        detail += plan.angled.map {
            String(
                format: "angled (%.2f, %.2f) to (%.2f, %.2f), %.0f mm", $0.a.x, $0.a.y, $0.b.x, $0.b.y,
                $0.thickness * 1000)
        }
        detail += plan.openings.map {
            String(
                format: "%@ in wall %d from %.3f to %.3f (%@)", $0.kind.rawValue, $0.wall + 1, $0.from, $0.to,
                $0.layer ?? "gap")
        }
        detail += plan.notes
        return Result(
            name: name, failures: failures, summary: summary, limitation: entry.limitation, detail: detail)
    }

    static func construction(named name: String) -> FloorPlan.Construction {
        switch name {
        case "block100": .block100
        case "block215": .block215
        case "halfBrick": .halfBrick
        case "solidBrick": .solidBrick
        case "concrete200": .concrete200
        case "concrete300": .concrete300
        case "studPartition": .studPartition
        case "cavityBrickBrick": .cavityBrickBrick
        default: .cavityBrickBlock
        }
    }

    /// Every case in `folder` (its JSON files), checked.
    public static func checkAll(folder: URL) throws -> [Result] {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            $0.hasSuffix(".json")
        }.sorted()
        return try files.map { file in
            let entry = try JSONDecoder().decode(
                Case.self, from: Data(contentsOf: folder.appending(path: file)))
            return check(entry, folder: folder)
        }
    }
}
