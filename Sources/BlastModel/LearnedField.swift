import Foundation
import simd

/// The learned field model's peak in the quick estimate (emmettl/bombcad-work#67;
/// docs/learned-models.md): a U-Net trained on BombCAD's own 4 m district runs
/// (`Scripts/ml/train_field.py`) predicts the peak overpressure 2 m over the ground on the district's
/// plan, and at each ground-floor façade strip that peak takes the place of the façade load
/// surrogate's, its impulse and rise kept. Roofs, upper storeys and every other component stay on
/// the surrogate, as the judge left them (`scenebench field-glass`, `field-walls`).
///
/// A model trained on more levels (emmettl/bombcad-work#69: its weights' header lists them) gives
/// the peak at every façade strip whose storey spans one of its heights over the ground, and over
/// the roofs from its roof level, as far as its `reach` lets it; the ground-floor model's weights
/// reach the ground floor alone, as before.
///
/// This file is what needs no GPU: the weights' file, the network's inputs laid out from a scene
/// exactly as `scenebench field-export` lays out its training inputs, the peak map and its cells in
/// front of a strip. The network itself runs on the GPU (BlastCore's `LearnedFieldNetwork`, behind
/// `LearnedField.Network`). Off, or without the weights, nothing here is reached.
public enum LearnedField {
    /// The cells the model was trained on, m: every training run was on 4 m cells.
    public static let cellSize: Float = 4
    /// How high over the ground its field is, m: the first layer of 4 m cells, which a
    /// ground-floor strip's recorder reads.
    public static let heightAboveGround: Float = 2
    /// Cells by the plan's sides left out, as the training runs' masks left them.
    public static let edgeCells = 4
    /// Peaks below this, Pa, are not the model's (the training's mask left them out).
    public static let smallestPeakPa: Float = 10

    /// The option's standing, worded from the judge's figures (docs/learned-models.md, "In the
    /// app's quick estimate (21 October 2026)").
    public static let standing: [String] = {
        let glass = ValidationTables.figure("learnedPeakGlass")
        let glassSkill = ValidationTables.figure("learnedPeakGlassSkill")
        let walls = ValidationTables.figure("learnedPeakWalls")
        let wallsApp = ValidationTables.figure("learnedPeakWallsApp")
        return [
            String(
                format:
                    "Learned field model for ground-floor peaks: illustrative. A network trained on BombCAD's own 4 m "
                    + "district runs, judged through this estimate on Beirut's 50 runs, a city it never saw. With its "
                    + "peak at the ground-floor façade strips, glass by side was exactly right on %.3f of sides against "
                    + "the surrogate's %.3f (Heidke skill %.2f against %.2f). Concrete walls damaged moderately or "
                    + "worse: Brier skill %.2f against %.2f at the app's load factor, %.2f against %.2f with the "
                    + "factor the judge chose (×0.8). Roofs, upper storeys and the impulse stay on the surrogate.",
                glass.high, glass.low, glassSkill.high, glassSkill.low, wallsApp.high, wallsApp.low,
                walls.high,
                walls.low),
            "It learned one city's runs and made-up districts on 4 m cells, with the charge on the ground: "
                + "other cells, other cities and other charges are beyond what it was judged on.",
        ]
    }()

    // MARK: - The weights

    /// A `.bcfw` file (`Scripts/ml/export_field_weights.py`): `BCFW`, a version, a JSON header and
    /// the tensors' values, little-endian.
    public struct Weights: Sendable {
        public struct Header: Codable, Sendable {
            public struct Stats: Codable, Sendable {
                public var mean: [Double]
                public var std: [Double]
            }
            public struct Entry: Codable, Sendable {
                public var name: String
                public var shape: [Int]
                public var offset: Int
                public var count: Int
            }
            /// A level the network predicts (`field-export --levels`, `--roof`): its name, what it
            /// is over ("ground", the ground under the cell, or "roof", the top of its building)
            /// and how far, m.
            public struct Level: Codable, Sendable, Equatable {
                public var name: String
                public var over: String
                public var metres: Double

                public init(name: String, over: String, metres: Double) {
                    self.name = name
                    self.over = over
                    self.metres = metres
                }
            }
            public var format: String
            public var model: String
            public var width: Int
            public var depth: Int
            public var inputs: [String]
            public var stats: Stats
            public var residual: Bool
            public var multiple: Int
            public var groupNormGroups: Int
            public var groupNormEpsilon: Double
            public var dtype: String
            public var impulse: String?
            public var sourceSHA256: String?
            public var epoch: Int?
            public var holdout: String?
            /// The levels whose log peak and log impulse the head gives in turn; nil for the 2 m
            /// field alone (the first model's weights).
            public var levels: [Level]?
            public var tensors: [Entry]

            /// The levels, the 2 m field alone without any.
            public var predicted: [Level] {
                levels ?? [
                    Level(name: "ground", over: "ground", metres: Double(LearnedField.heightAboveGround))
                ]
            }
        }

        public var header: Header
        /// Each tensor's values as float32, C order, by its state-dict name.
        public var tensors: [String: (shape: [Int], values: [Float])]

        /// The inputs the network was trained on, in order (train_field.py's `INPUTS`).
        public static let inputs = [
            "height", "footprint", "ground", "logScaledDistance", "logKingeryBulmashPeak",
            "logKingeryBulmashImpulse",
        ]

        public init(contentsOf url: URL) throws {
            try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
        }

        public init(data: Data) throws {
            func fail(_ why: String) -> Error { LearnedFieldError.badWeights(why) }
            guard data.count >= 12, data.prefix(4) == Data("BCFW".utf8) else {
                throw fail("not a .bcfw file")
            }
            func u32(_ at: Int) -> Int {
                data.withUnsafeBytes { raw in
                    Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                }
            }
            guard u32(4) == 1 else { throw fail("version \(u32(4)), not 1") }
            let length = u32(8)
            guard data.count >= 12 + length else { throw fail("a header longer than the file") }
            let header = try JSONDecoder().decode(
                Header.self, from: data.subdata(in: (data.startIndex + 12)..<(data.startIndex + 12 + length)))
            guard header.format == "bombcad-field-weights-1", header.model == "unet" else {
                throw fail("format \(header.format), model \(header.model)")
            }
            guard header.inputs == Self.inputs, header.stats.mean.count == 6, header.stats.std.count == 6
            else {
                throw fail("inputs \(header.inputs)")
            }
            guard header.stats.mean.allSatisfy(\.isFinite),
                header.stats.std.allSatisfy({ $0.isFinite && $0 > 0 })
            else {
                throw fail("a standardisation that is not finite and positive")
            }
            // train_field.py's U-Net: `depth` halvings, padded to 2^depth.
            guard (1...8).contains(header.depth), (1...1024).contains(header.width),
                header.multiple == 1 << header.depth
            else {
                throw fail("width \(header.width), depth \(header.depth), multiple \(header.multiple)")
            }
            let size = header.dtype == "float16" ? 2 : header.dtype == "float32" ? 4 : 0
            guard size > 0 else { throw fail("dtype \(header.dtype)") }
            let payload = data.startIndex + 12 + length
            // The values the payload holds: each tensor's offset and count within them, checked
            // without overflow, so that no header can read outside the file.
            let held = (data.endIndex - payload) / size
            var tensors: [String: (shape: [Int], values: [Float])] = [:]
            for entry in header.tensors {
                guard let elements = Self.elements(entry.shape), elements == entry.count,
                    entry.offset >= 0, entry.offset <= held, entry.count <= held - entry.offset
                else { throw fail("tensor \(entry.name) outside the file") }
                let start = payload + entry.offset * size
                let values = data.withUnsafeBytes { raw -> [Float] in
                    let base = start - data.startIndex
                    return (0..<entry.count).map { n in
                        size == 2
                            ? LearnedField.float(
                                half: UInt16(
                                    littleEndian: raw.loadUnaligned(
                                        fromByteOffset: base + 2 * n, as: UInt16.self)))
                            : Float(
                                bitPattern: UInt32(
                                    littleEndian: raw.loadUnaligned(
                                        fromByteOffset: base + 4 * n, as: UInt32.self)))
                    }
                }
                tensors[entry.name] = (entry.shape, values)
            }
            self.header = header
            self.tensors = tensors
            // The U-Net's own tensors (train_field.py's `UNet`): each level's two convolutions and
            // their norms, down then up, and the head, each of the shape its width and depth give.
            // With more levels, a log peak and a log impulse for each, the 2 m field's first.
            if let levels = header.levels {
                guard (1...64).contains(levels.count), levels[0].name == "ground", levels[0].over == "ground",
                    levels.allSatisfy({
                        ["ground", "roof"].contains($0.over) && $0.metres.isFinite && $0.metres > 0
                    })
                else { throw fail("levels \(levels.map(\.name))") }
            }
            let shapes = Self.tensorShapes(
                width: header.width, depth: header.depth, outputs: 2 * header.predicted.count)
            for name in Self.tensorNames(depth: header.depth) {
                guard let tensor = tensors[name] else { throw fail("no tensor \(name)") }
                guard tensor.shape == shapes[name] else {
                    throw fail("tensor \(name) of shape \(tensor.shape), not \(shapes[name] ?? [])")
                }
            }
        }

        /// The values a tensor of `shape` holds; nil for a negative extent or one past `Int`.
        static func elements(_ shape: [Int]) -> Int? {
            var count = 1
            for extent in shape {
                guard extent >= 0 else { return nil }
                let (product, overflow) = count.multipliedReportingOverflow(by: extent)
                guard !overflow else { return nil }
                count = product
            }
            return count
        }

        /// The shape of each tensor of train_field.py's `UNet(6, outputs, width, depth)`, by name: level
        /// n's blocks have `width` × 2^n channels, the up blocks take the level below's joined to
        /// the skip, and `up.0` is the deepest.
        public static func tensorShapes(width: Int, depth: Int, outputs: Int = 2) -> [String: [Int]] {
            let widths = (0...depth).map { width << $0 }
            var shapes: [String: [Int]] = [:]
            func block(_ prefix: String, _ input: Int, _ output: Int) {
                shapes["\(prefix).body.0.weight"] = [output, input, 3, 3]
                shapes["\(prefix).body.3.weight"] = [output, output, 3, 3]
                for name in ["0.bias", "1.weight", "1.bias", "3.bias", "4.weight", "4.bias"] {
                    shapes["\(prefix).body.\(name)"] = [output]
                }
            }
            for n in 0...depth { block("down.\(n)", n == 0 ? inputs.count : widths[n - 1], widths[n]) }
            for k in 0..<depth {
                let n = depth - 1 - k
                block("up.\(k)", widths[n + 1] + widths[n], widths[n])
            }
            shapes["head.weight"] = [outputs, widths[0], 1, 1]
            shapes["head.bias"] = [outputs]
            return shapes
        }

        /// The tensors a U-Net of `depth` halvings has, by name.
        public static func tensorNames(depth: Int) -> [String] {
            var names: [String] = []
            for (path, levels) in [("down", depth + 1), ("up", depth)] {
                for n in 0..<levels {
                    for layer in [0, 1, 3, 4] {
                        names += ["\(path).\(n).body.\(layer).weight", "\(path).\(n).body.\(layer).bias"]
                    }
                }
            }
            return names + ["head.weight", "head.bias"]
        }
    }

    /// An IEEE half's bits as a float.
    static func float(half bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x03FF)
        if exponent == 0 {
            // Zero or subnormal: mantissa × 2^-24.
            let magnitude = Float(mantissa) * 0x1p-24
            return sign == 0 ? magnitude : -magnitude
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | UInt32(exponent - 15 + 127) << 23 | (mantissa << 13))
    }

    // MARK: - The network

    /// The network itself, run where it can be (BlastCore's `LearnedFieldNetwork` on the GPU).
    public protocol Network: AnyObject, Sendable {
        /// What the weights say of the network's inputs and outputs.
        var header: Weights.Header { get }
        /// The network's first output (the correction to Kingery–Bulmash's log peak, or with
        /// `residual` false the log peak itself) over a plan `rows` × `columns`, from its
        /// standardised inputs, channels × rows × columns in C order, already padded to a multiple
        /// of `header.multiple` each way.
        func peakChannel(inputs: [Float], rows: Int, columns: Int) throws -> [Float]
        /// The same for each of `header.predicted`'s levels in turn: the outputs 0, 2, 4….
        func peakChannels(inputs: [Float], rows: Int, columns: Int) throws -> [[Float]]
    }

    /// Which components a model with more levels gives its peak to (`PeakMap.reach`).
    public struct Reach: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Ground-floor façade strips, at the 2 m field.
        public static let groundFloor = Reach(rawValue: 1)
        /// Façade strips of the storeys above, at the height level each spans.
        public static let upperStoreys = Reach(rawValue: 2)
        /// Roofs, at the roof level over them.
        public static let roofs = Reach(rawValue: 4)
        public static let all: Reach = [.groundFloor, .upperStoreys, .roofs]
    }

    // MARK: - The plan

    /// What the network sees of a scene that does not depend on the charge: on the 4 m plan over
    /// the scene's domain from its origin, rows north, columns east, the tallest block over each
    /// cell's centre above the ground there, and the ground. As `scenebench field-export` lays out
    /// its training inputs, to the bit (`LearnedFieldTests`).
    public struct Plan: Sendable {
        public let columns: Int
        public let rows: Int
        public let cell: Float
        /// Each cell's buildings' height over the ground, m (0 with none), and its ground, m.
        public let height: [Float]
        public let ground: [Float]
        let terrain: Terrain?

        public init(scene: Scenario) {
            let grid = scene.grid(cellSize: LearnedField.cellSize)
            let (nx, ny) = (grid.nx, grid.ny)
            let dx = LearnedField.cellSize
            var ground = [Float](repeating: 0, count: nx * ny)
            for j in 0..<ny {
                for i in 0..<nx {
                    ground[i + nx * j] =
                        scene.terrain?.height(at: SIMD2((Float(i) + 0.5) * dx, (Float(j) + 0.5) * dx)) ?? 0
                }
            }
            // The buildings' tops over the cells whose centres their blocks cover, as the air holds them.
            var top = [Float](repeating: -.greatestFiniteMagnitude, count: nx * ny)
            for block in scene.envelopeObjects.flatMap({ $0.envelope?.blocks ?? [] }) + scene.boxes {
                let i0 = max(0, Int((block.min.x / dx - 0.5).rounded(.up)))
                let i1 = min(nx - 1, Int((block.max.x / dx - 0.5).rounded(.up)) - 1)
                let j0 = max(0, Int((block.min.y / dx - 0.5).rounded(.up)))
                let j1 = min(ny - 1, Int((block.max.y / dx - 0.5).rounded(.up)) - 1)
                guard i0 <= i1, j0 <= j1 else { continue }
                for j in j0...j1 {
                    for i in i0...i1 { top[i + nx * j] = max(top[i + nx * j], block.max.z) }
                }
            }
            columns = nx
            rows = ny
            cell = dx
            self.ground = ground
            height = zip(top, ground).map { $0 > $1 ? $0 - $1 : 0 }
            terrain = scene.terrain
        }

        /// The six channels of `field-export`'s `inputs.npy` for a charge of `mass` kg at
        /// `charge`: the height, the ground over the ground under the charge, the distance in plan,
        /// ln Z, and Kingery–Bulmash's incident peak and impulse at Z (channels × rows × columns).
        public func exportChannels(charge: SIMD3<Float>, mass: Double) -> [Float] {
            let plan = columns * rows
            let chargeGround = terrain?.height(at: SIMD2(charge.x, charge.y)) ?? 0
            let root = cbrt(mass)
            var inputs = [Float](repeating: 0, count: 6 * plan)
            inputs.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: rows) { j in
                    for i in 0..<columns {
                        let n = i + columns * j
                        let x = (Float(i) + 0.5) * cell
                        let y = (Float(j) + 0.5) * cell
                        let distance = Double(simd_distance(SIMD2(x, y), SIMD2(charge.x, charge.y)))
                        let z = max(distance, Double(cell) / 2) / root
                        let kb = LearnedField.kingeryBulmash(z: z, mass: mass)
                        out[0 * plan + n] = height[n]
                        out[1 * plan + n] = ground[n] - chargeGround
                        out[2 * plan + n] = Float(distance)
                        out[3 * plan + n] = Float(log(z))
                        out[4 * plan + n] = Float(kb.peak)
                        out[5 * plan + n] = Float(kb.impulse)
                    }
                }
            }
            return inputs
        }

        /// The rows and columns padded to `multiple`.
        public func padded(_ multiple: Int) -> (rows: Int, columns: Int) {
            ((rows + multiple - 1) / multiple * multiple, (columns + multiple - 1) / multiple * multiple)
        }
    }

    /// The network's standardised inputs from `field-export`'s six channels (`exportChannels`, or a
    /// run's `inputs.npy`) on a plan `rows` × `columns`: train_field.py's features (the height, the
    /// footprint, the ground, ln Z and the logs of Kingery–Bulmash's peak and impulse), each less
    /// the training runs' mean over their standard deviation, padded at the north and east to a
    /// multiple of `header.multiple` by repeating the edge, as judge_field.py pads them. With them,
    /// Kingery–Bulmash's log peak on the plan, which the network corrects.
    public static func networkInputs(
        exportChannels raw: [Float], rows: Int, columns: Int, header: Weights.Header
    ) -> (inputs: [Float], rows: Int, columns: Int, kbLogPeak: [Float]) {
        let plan = rows * columns
        precondition(raw.count == 6 * plan, "six channels over the plan")
        let multiple = max(1, header.multiple)
        let paddedRows = (rows + multiple - 1) / multiple * multiple
        let paddedColumns = (columns + multiple - 1) / multiple * multiple
        let mean = header.stats.mean.map(Float.init)
        let std = header.stats.std.map(Float.init)
        var kb = [Float](repeating: 0, count: plan)
        var inputs = [Float](repeating: 0, count: 6 * paddedRows * paddedColumns)
        let area = paddedRows * paddedColumns
        inputs.withUnsafeMutableBufferPointer { out in
            kb.withUnsafeMutableBufferPointer { kbOut in
                concurrently(iterations: paddedRows) { r in
                    let j = min(r, rows - 1)
                    for c in 0..<paddedColumns {
                        let n = min(c, columns - 1) + columns * j
                        let height = raw[n]
                        let peak = log(max(raw[4 * plan + n], 1))
                        let at = c + paddedColumns * r
                        func put(_ k: Int, _ value: Float) { out[k * area + at] = (value - mean[k]) / std[k] }
                        put(0, height)
                        put(1, height > 0 ? 1 : 0)
                        put(2, raw[plan + n])
                        put(3, raw[3 * plan + n])
                        put(4, peak)
                        put(5, log(max(raw[5 * plan + n], 1e-6)))
                        if r < rows, c < columns { kbOut[n] = peak }
                    }
                }
            }
        }
        return (inputs, paddedRows, paddedColumns, kb)
    }

    /// Kingery–Bulmash's incident peak (Pa) and impulse (Pa s) at scaled distance `z` for `mass`
    /// kg, as the training inputs give them: held at its fits' near end (0.2 m/kg^(1/3)) and carried
    /// on beyond the far end (40) by the slope of its last stretch in log-log.
    public static func kingeryBulmash(z: Double, mass: Double) -> (peak: Double, impulse: Double) {
        func at(_ z: Double) -> (Double, Double) {
            guard let p = KingeryBulmash.point(at: z) else { return (0, 0) }
            return (p.incidentPressure, p.incidentImpulse(mass: mass))
        }
        if z < 0.2 { return at(0.2) }
        if z <= 40 { return at(z) }
        let (p40, i40) = at(40)
        let (p36, i36) = at(36)
        let span = log(40.0 / 36)
        let sp = log(p40 / p36) / span
        let si = log(i40 / i36) / span
        return (p40 * pow(z / 40, sp), i40 * pow(z / 40, si))
    }

    // MARK: - The peak map

    /// The network's peak over a plan for one charge: its log, Pa, and where it is to be read (no
    /// building over the cell's centre, away from the plan's sides, above `smallestPeakPa`); with
    /// more levels, the same at each (`logPeaks`, `opens`): over a cell whose building, if any, is
    /// no taller than a height level, and over a cell with a building for the roof's.
    public struct PeakMap: Sendable {
        public let columns: Int
        public let rows: Int
        public let cell: Float
        /// The 2 m field's: `logPeaks[0]` and `opens[0]`.
        public let logPeak: [Float]
        public let open: [Bool]
        /// The levels, and the log peak and where to read it at each, in the levels' order.
        public let levels: [Weights.Header.Level]
        public let logPeaks: [[Float]]
        public let opens: [[Bool]]
        /// The components given the network's peak.
        public var reach: Reach = .groundFloor
        let terrain: Terrain?
        let height: [Float]
        /// How long the network took, s, and its inputs before it.
        public var seconds: (inputs: Double, network: Double) = (0, 0)

        public init(plan: Plan, logPeak: [Float]) {
            self.init(
                plan: plan, logPeaks: [logPeak],
                levels: [
                    .init(name: "ground", over: "ground", metres: Double(LearnedField.heightAboveGround))
                ])
        }

        public init(
            plan: Plan, logPeaks: [[Float]], levels: [Weights.Header.Level], reach: Reach = .groundFloor
        ) {
            precondition(
                logPeaks.count == levels.count && levels.first?.name == "ground"
                    && logPeaks.allSatisfy { $0.count == plan.columns * plan.rows },
                "a peak for every cell at every level, the 2 m field's first")
            columns = plan.columns
            rows = plan.rows
            cell = plan.cell
            self.levels = levels
            self.logPeaks = logPeaks
            self.reach = reach
            terrain = plan.terrain
            height = plan.height
            let edge = LearnedField.edgeCells
            let smallest = log(LearnedField.smallestPeakPa)
            opens = zip(levels, logPeaks).map { level, logPeak in
                (0..<(plan.columns * plan.rows)).map { n in
                    let (i, j) = (n % plan.columns, n / plan.columns)
                    let air =
                        level.name == "ground"
                        ? plan.height[n] == 0
                        : level.over == "roof" ? plan.height[n] > 0 : Double(plan.height[n]) <= level.metres
                    return air && i >= edge && j >= edge && i < plan.columns - edge && j < plan.rows - edge
                        && logPeak[n] > smallest
                }
            }
            logPeak = logPeaks[0]
            open = opens[0]
        }

        /// The plan's cells of air beside `component`'s outer face, along its width: the first
        /// cells whose centres lie beyond the face, over the cells whose centres its width covers
        /// (its middle one if it is narrower than a cell), as judge_field.py's `front_cells`. Only
        /// those in the plan.
        public func frontCells(_ component: EnvelopeComponent) -> [Int] {
            let axis = component.axis
            guard axis < 2 else { return [] }
            let region = component.region
            let face = component.outward > 0 ? region.max[axis] : region.min[axis]
            let first = Int((face / cell - 0.5).rounded(.up))
            let across = component.outward > 0 ? first : first - 1
            let other = 1 - axis
            var a = Int((region.min[other] / cell - 0.5).rounded(.up))
            var b = Int((region.max[other] / cell - 0.5).rounded(.up)) - 1
            if b < a {
                a = Int((0.5 * (region.min[other] + region.max[other]) / cell).rounded(.down))
                b = a
            }
            return (a...b).compactMap { along in
                let (column, row) = axis == 0 ? (across, along) : (along, across)
                guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
                return column + columns * row
            }
        }

        /// Whether `component` is a ground-floor façade strip: its storey spans the field's height
        /// over the ground under its outer face's middle, within a centimetre (the judge read the
        /// strips' boxes and the ground to the centimetre, so a storey ending at that height
        /// counted on both sides of it).
        public func isGroundFloor(_ component: EnvelopeComponent) -> Bool {
            guard component.kind == .facade, component.axis < 2 else { return false }
            let ground = terrain?.height(at: FacadeLoadSurrogate.outerFace(component).centre) ?? 0
            let level = ground + LearnedField.heightAboveGround
            return component.region.min.z <= level + 0.01 && level - 0.01 <= component.region.max.z
        }

        /// The level a façade strip's storey spans above the ground floor: the first height level
        /// whose height over the ground under its outer face's middle the storey spans, within a
        /// centimetre; nil for none.
        public func upperLevel(_ component: EnvelopeComponent) -> Int? {
            guard component.kind == .facade, component.axis < 2, !isGroundFloor(component) else { return nil }
            let ground = terrain?.height(at: FacadeLoadSurrogate.outerFace(component).centre) ?? 0
            return levels.indices.dropFirst().first { l in
                let level = levels[l]
                guard level.over == "ground" else { return false }
                let at = ground + Float(level.metres)
                return component.region.min.z <= at + 0.01 && at - 0.01 <= component.region.max.z
            }
        }

        /// The plan cells whose centres a roof's region covers (its middle one if none).
        public func roofCells(_ component: EnvelopeComponent) -> [Int] {
            let region = component.region
            func span(_ axis: Int) -> ClosedRange<Int> {
                let a = Int((region.min[axis] / cell - 0.5).rounded(.up))
                let b = Int((region.max[axis] / cell - 0.5).rounded(.up)) - 1
                if b < a {
                    let m = Int((0.5 * (region.min[axis] + region.max[axis]) / cell).rounded(.down))
                    return m...m
                }
                return a...b
            }
            var cells: [Int] = []
            for row in span(1) where row >= 0 && row < rows {
                for column in span(0) where column >= 0 && column < columns {
                    cells.append(column + columns * row)
                }
            }
            return cells
        }

        /// The network's peak at `component`, Pa: the mean over its cells that are open at its
        /// level, the front cells of a façade strip, the roof level's cells under a roof; nil where
        /// `reach` leaves it to the surrogate (by default all but the ground floor's façade strips)
        /// or there is none.
        public func peak(at component: EnvelopeComponent) -> Double? {
            let level: Int
            let cells: [Int]
            if reach.contains(.groundFloor), isGroundFloor(component) {
                (level, cells) = (0, frontCells(component))
            } else if reach.contains(.upperStoreys), let l = upperLevel(component) {
                (level, cells) = (l, frontCells(component))
            } else if reach.contains(.roofs), component.kind == .roof,
                let l = levels.firstIndex(where: { $0.over == "roof" })
            {
                (level, cells) = (l, roofCells(component))
            } else {
                return nil
            }
            var sum = 0.0
            var count = 0
            for n in cells where opens[level][n] {
                sum += Double(exp(logPeaks[level][n]))
                count += 1
            }
            return count > 0 ? sum / Double(count) : nil
        }

        /// `features` with the network's peak in place of the surrogate's for `component` (its
        /// `learnedPeakFactor`, the network's peak over the surrogate's for a charge of `mass` kg),
        /// or as they were where the network gives none.
        public func adjusted(
            _ features: FacadeLoadSurrogate.Features, of component: EnvelopeComponent, mass: Double,
            cellSize: Double, coefficients: FacadeLoadSurrogate.Coefficients = .fitted
        ) -> FacadeLoadSurrogate.Features {
            guard let peak = peak(at: component) else { return features }
            var plain = features
            plain.learnedPeakFactor = 1
            let surrogate = FacadeLoadSurrogate.predict(
                plain, mass: mass, cellSize: cellSize, coefficients: coefficients
            ).peakPa
            guard surrogate > 0, surrogate.isFinite, peak.isFinite else { return features }
            plain.learnedPeakFactor = peak / surrogate
            return plain
        }
    }

    /// A district's plan with the network to run on it, for any place of the charge: laid out once
    /// (`Plan`), the network run again for each.
    public final class Estimator: Sendable {
        public let plan: Plan
        public let network: any Network
        /// The components given the network's peak: the ground floor's façade strips for the
        /// first model's weights, and with more levels what `reach` allows of them.
        public let reach: Reach
        /// How long laying out the plan took, s.
        public let seconds: Double

        public init(scene: Scenario, network: any Network, reach: Reach = .all) {
            let start = ContinuousClock.now
            plan = Plan(scene: scene)
            self.network = network
            self.reach = network.header.levels == nil ? .groundFloor : reach
            let took = start.duration(to: .now)
            seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        }

        /// The network's peak over the plan for a charge of `mass` kg at `charge`.
        public func peaks(charge: SIMD3<Float>, mass: Double) throws -> PeakMap {
            func since(_ start: ContinuousClock.Instant) -> Double {
                let took = start.duration(to: .now)
                return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            }
            var clock = ContinuousClock.now
            let header = network.header
            let raw = plan.exportChannels(charge: charge, mass: mass)
            let (inputs, rows, columns, kb) = LearnedField.networkInputs(
                exportChannels: raw, rows: plan.rows, columns: plan.columns, header: header)
            let inputsS = since(clock)
            clock = .now
            let levels = header.predicted
            // The first model's weights: its first output alone, as before.
            let outs =
                header.levels == nil
                ? [try network.peakChannel(inputs: inputs, rows: rows, columns: columns)]
                : try network.peakChannels(inputs: inputs, rows: rows, columns: columns)
            guard outs.count == levels.count, outs.allSatisfy({ $0.count == rows * columns }) else {
                throw LearnedFieldError.network(
                    "\(outs.map(\.count)) outputs for \(levels.count) levels of \(rows) × \(columns)")
            }
            let logPeaks = outs.map { out in
                var logPeak = [Float](repeating: 0, count: plan.rows * plan.columns)
                for j in 0..<plan.rows {
                    for i in 0..<plan.columns {
                        let n = i + plan.columns * j
                        logPeak[n] = out[i + columns * j] + (header.residual ? kb[n] : 0)
                    }
                }
                return logPeak
            }
            var map = PeakMap(plan: plan, logPeaks: logPeaks, levels: levels, reach: reach)
            map.seconds = (inputsS, since(clock))
            return map
        }
    }

    // MARK: - Files

    /// NumPy's `.npy` files of little-endian float32 in C order (`scenebench field-export`'s and
    /// the export script's references): the values and the shape.
    public static func readNPY(_ url: URL) throws -> (values: [Float], shape: [Int]) {
        let data = try Data(contentsOf: url)
        let s = data.startIndex
        guard data.count >= 10, data[s] == 0x93, data[(s + 1)..<(s + 6)] == Data("NUMPY".utf8) else {
            throw LearnedFieldError.badWeights("\(url.lastPathComponent) is not a .npy file")
        }
        let lengthBytes = data[s + 6] == 1 ? 2 : 4
        guard data.count >= 8 + lengthBytes else {
            throw LearnedFieldError.badWeights("\(url.lastPathComponent) is short")
        }
        var length = 0
        for k in 0..<lengthBytes { length |= Int(data[s + 8 + k]) << (8 * k) }
        let headerStart = s + 8 + lengthBytes
        guard data.endIndex - headerStart >= length else {
            throw LearnedFieldError.badWeights("\(url.lastPathComponent) is short")
        }
        guard let text = String(data: data[headerStart..<(headerStart + length)], encoding: .ascii),
            text.contains("'<f4'"), text.contains("'fortran_order': False"),
            let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")")
        else {
            throw LearnedFieldError.badWeights(
                "\(url.lastPathComponent): not little-endian float32 in C order")
        }
        let shape = text[text.index(after: open)..<close].split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        let body = headerStart + length - s
        guard let count = Weights.elements(shape), count <= (data.count - body) / 4 else {
            throw LearnedFieldError.badWeights("\(url.lastPathComponent) is short")
        }
        let values = data.withUnsafeBytes { raw in
            (0..<count).map { n in
                Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(fromByteOffset: body + 4 * n, as: UInt32.self)))
            }
        }
        return (values, shape)
    }

    // MARK: - Where the weights are

    /// The environment variable naming the weights' file, and the setting that does (the app's).
    public static let environmentKey = "BOMBCAD_FIELD_MODEL"
    public static let fileName = "field-unet-fp-strict.bcfw"

    /// The weights' file: `BOMBCAD_FIELD_MODEL` if set, else `setting` if given, else
    /// `~/Library/Application Support/BombCAD/LearnedModels/field-unet-fp-strict.bcfw`.
    public static func weightsURL(
        setting: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: URL = defaultWeightsURL
    ) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath)
        }
        if let setting, !setting.isEmpty { return URL(filePath: (setting as NSString).expandingTildeInPath) }
        return fallback
    }

    public static var defaultWeightsURL: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "BombCAD/LearnedModels").appending(path: fileName)
    }
}

extension LearnedField.Network {
    /// A network of the 2 m field alone: its first output.
    public func peakChannels(inputs: [Float], rows: Int, columns: Int) throws -> [[Float]] {
        [try peakChannel(inputs: inputs, rows: rows, columns: columns)]
    }
}

public enum LearnedFieldError: Error, CustomStringConvertible {
    case badWeights(String)
    case network(String)
    case download(String)
    case checksum(expected: String, found: String)
    case cancelled

    public var description: String {
        switch self {
        case .badWeights(let why): "The learned field model's weights could not be read: \(why)."
        case .network(let why): "The learned field model could not be run: \(why)."
        case .download(let why): "The learned field model could not be downloaded: \(why)."
        case .checksum(let expected, let found):
            "The downloaded learned field model is not the file the app expects (SHA-256 \(found.prefix(12))…, not \(expected.prefix(12))…), so it was not kept."
        case .cancelled: "The learned field model's download was cancelled."
        }
    }
}

extension LearnedField {
    /// The weights' release: the file the app offers to download the first time the option is
    /// turned on (never without the user's click), from the repository's release `tag`, checked
    /// against `sha256` before it is kept (emmettl/bombcad-work#67; docs/learned-models.md).
    public enum Release {
        public static let tag = "field-model-1"
        public static let file = LearnedField.fileName
        public static let bytes = 15_716_144
        public static let sha256 = "d544d80f5a3985c56e0035475b4ebf95f8b16ffc2057619a7f7b621935370440"
        public static var url: URL {
            URL(string: "https://github.com/emmettl/bombcad/releases/download/\(tag)/\(file)")!
        }
        /// What the download is for, in the words the app asks with.
        public static var offer: String {
            "The learned field model gives the quick estimate its peak at ground-floor façades, for their "
                + "damage, glass and walls (illustrative). Its weights, "
                + String(format: "%.1f", Double(bytes) / 1e6) + " MB, are downloaded once from "
                + url.absoluteString + " and kept in Application Support."
        }
    }
}
