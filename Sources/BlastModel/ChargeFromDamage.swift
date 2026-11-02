import Foundation
import simd

/// The charge read back from the damage a user marks, in milliseconds (emmettl/bombcad-work#116;
/// docs/charge-inference.md, "The charge from marked damage, learned"): amortised inference. A
/// network trained on the quick estimate's own chances of damage, drawn for charges of many places
/// and yields over Beirut's district and made-up ones, maps a set of marked buildings (each its
/// place, size and walls, and its glass seen whole or broken, its walls undamaged, damaged or
/// heavily damaged, or either unseen) to a posterior over the charge's place, on a grid about a
/// reference point, and its yield there.
///
/// The network (`Network`) is a set encoder. In the adopted kind ("distance"), each mark's
/// likelihood over the cells and the log yield depends on a cell only through the distance from the
/// mark's building to the charge there, given by a small network of that distance and the mark's own
/// features; the marks' log likelihoods are summed, as they are independent given the charge, so any
/// number is weighed alike and a new mark adds only its own. It sees no geometry beyond each marked
/// building's own, so it cannot know which buildings shield which: where the full posterior on the
/// quick estimate's chances (`ChanceTable.posterior`) is sharper, the network is wider, and it says
/// so only through its judged standing. Two other kinds, "pooled" and "surfaces", were tried first
/// and are kept readable.
public enum ChargeFromDamage {
    /// What a building's walls are built of, as the network sees it.
    public enum Walls: Int, Codable, Sendable, CaseIterable {
        /// Reinforced concrete or reinforced blockwork.
        case concrete = 0
        /// Unreinforced masonry: brick, block or stone.
        case masonry = 1
        /// Anything else: profiled sheeting, timber.
        case other = 2

        public init(_ kind: EnvelopeConstruction.Kind) {
            switch kind {
            case .reinforcedConcrete, .reinforcedBlockwork: self = .concrete
            case .unreinforcedMasonry: self = .masonry
            case .profiledSteelSheeting, .crossLaminatedTimber: self = .other
            }
        }
    }

    /// A building's glass, as seen: whole (no pane broken) or broken (some pane broken).
    public enum GlassSeen: Int, Codable, Sendable, CaseIterable {
        case whole = 1
        case broken = 2
    }

    /// A building's walls, as seen: undamaged (less than moderate), damaged (moderate or worse,
    /// heavy or not said), or heavily damaged (heavy or worse).
    public enum WallsSeen: Int, Codable, Sendable, CaseIterable {
        case undamaged = 1
        case damaged = 2
        case heavy = 3
    }

    /// What the network knows of a building, none of it depending on the charge.
    public struct Building: Codable, Sendable, Equatable {
        /// Its plan's middle, m east and north (of the scene's origin, or of a reference where said).
        public var east: Double
        public var north: Double
        /// From its base to its top, m.
        public var heightM: Double
        /// Its footprint's area, m².
        public var footprintM2: Double
        /// The share of the ground within 60 m of its middle that buildings stand on.
        public var builtShare: Double
        public var walls: Walls
        /// Whether its construction has a glazing mix (whether its glass can be judged).
        public var glazed: Bool

        public init(
            east: Double, north: Double, heightM: Double, footprintM2: Double, builtShare: Double,
            walls: Walls, glazed: Bool
        ) {
            self.east = east
            self.north = north
            self.heightM = heightM
            self.footprintM2 = footprintM2
            self.builtShare = builtShare
            self.walls = walls
            self.glazed = glazed
        }
    }

    /// A marked building: what was seen of its glass and its walls (nil, unseen).
    public struct Mark: Codable, Sendable, Equatable {
        public var building: Building
        public var glass: GlassSeen?
        public var walls: WallsSeen?

        public init(building: Building, glass: GlassSeen? = nil, walls: WallsSeen? = nil) {
            self.building = building
            self.glass = glass
            self.walls = walls
        }
    }

    /// The radius of the ground counted for a building's `builtShare`, m.
    public static let builtShareRadiusM = 60.0

    /// Every envelope building of `scene`, by its index among `scene.envelopeObjects`: its middle in
    /// the scene's metres, height, footprint (its blocks' plan on 2 m cells), the share of the
    /// ground built on round it, its walls and whether it is glazed.
    public static func buildings(scene: Scenario) -> [Building] {
        let objects = scene.envelopeObjects
        let cell = 2.0
        // Each building's plan cells, and every building's together.
        var cellsOf = [Set<SIMD2<Int32>>](repeating: [], count: objects.count)
        cellsOf.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: objects.count) { n in
                var cells = Set<SIMD2<Int32>>()
                for block in objects[n].envelope?.blocks ?? [] {
                    let i0 = Int32((Double(block.min.x) / cell).rounded(.down))
                    let i1 = Int32((Double(block.max.x) / cell).rounded(.up)) - 1
                    let j0 = Int32((Double(block.min.y) / cell).rounded(.down))
                    let j1 = Int32((Double(block.max.y) / cell).rounded(.up)) - 1
                    guard i1 >= i0, j1 >= j0 else { continue }
                    for i in i0...i1 { for j in j0...j1 { cells.insert(SIMD2(i, j)) } }
                }
                out[n] = cells
            }
        }
        var built = Set<SIMD2<Int32>>()
        for cells in cellsOf { built.formUnion(cells) }
        let reach = Int32((builtShareRadiusM / cell).rounded(.up))
        var result = [Building?](repeating: nil, count: objects.count)
        result.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: objects.count) { n in
                let blocks = objects[n].envelope?.blocks ?? []
                guard !blocks.isEmpty else { return }
                let low = blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
                    simd_min($0, $1)
                }
                let high = blocks.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
                    simd_max($0, $1)
                }
                let middle = 0.5 * SIMD2(Double(low.x + high.x), Double(low.y + high.y))
                let ci = Int32((middle.x / cell).rounded(.down))
                let cj = Int32((middle.y / cell).rounded(.down))
                var inside = 0
                var covered = 0
                let limit = builtShareRadiusM * builtShareRadiusM
                for di in -reach...reach {
                    for dj in -reach...reach {
                        let dx = Double(di) * cell
                        let dy = Double(dj) * cell
                        guard dx * dx + dy * dy <= limit else { continue }
                        inside += 1
                        if built.contains(SIMD2(ci + di, cj + dj)) { covered += 1 }
                    }
                }
                let construction = scene.envelopeConstruction(for: objects[n].id)
                out[n] = Building(
                    east: middle.x, north: middle.y, heightM: Double(high.z - low.z),
                    footprintM2: max(Double(cellsOf[n].count) * cell * cell, cell * cell),
                    builtShare: inside > 0 ? Double(covered) / Double(inside) : 0,
                    walls: Walls(construction.walls), glazed: construction.glazing != nil)
            }
        }
        return result.map {
            $0
                ?? Building(
                    east: 0, north: 0, heightM: 0, footprintM2: 0, builtShare: 0, walls: .concrete,
                    glazed: false)
        }
    }

    // MARK: - The marks' likelihood

    /// The chance that a mark's glass or walls are misread (a flip to another class, spread evenly
    /// over the classes): it keeps every chance at least 0.02 from 0 and 1, as the full
    /// inference's floor does (`SurrogateDamage.logLikelihood`).
    public static let glassMisread = 0.04
    public static let wallsMisread = 0.06

    /// The chance of each glass class (whole, broken) given the chance some pane breaks.
    public static func glassClasses(broken p: Double) -> (whole: Double, broken: Double) {
        let q = min(max(p, 0), 1)
        let e = glassMisread
        return ((1 - e) * (1 - q) + e / 2, (1 - e) * q + e / 2)
    }

    /// The chance of each walls class (undamaged, damaged, heavy) given the chances of moderate or
    /// worse and of heavy or worse: a building damaged heavily is said heavy half the time and
    /// damaged otherwise, as a survey that does not always tell them apart.
    public static func wallsClasses(moderate m: Double, heavy h: Double) -> (
        undamaged: Double, damaged: Double, heavy: Double
    ) {
        let pm = min(max(m, 0), 1)
        let ph = min(max(h, 0), pm)
        let e = wallsMisread
        return (
            (1 - e) * (1 - pm) + e / 3, (1 - e) * (pm - 0.5 * ph) + e / 3, (1 - e) * 0.5 * ph + e / 3
        )
    }

    // MARK: - The network

    /// The set encoder: each mark's features (`features(_:reference:)`) through `phi`, a stack of
    /// dense layers with SiLU between them; the outputs' mean and maximum over the marks, with
    /// ln(count + 1) / ln 65, through `rho`, its last layer giving, for each cell of a `grid` ×
    /// `grid` square of half side `halfWidthM` about the reference, a logit, the mean of the log
    /// yield there and the log of its standard deviation. Cells whose middle lies beyond
    /// `placeRadiusM` are left out.
    public struct Network: Sendable {
        public struct Header: Codable, Sendable {
            public var format: String
            public var name: String
            public var inputs: Int
            public var phi: [Int]
            public var rho: [Int]
            public var grid: Int
            public var halfWidthM: Double
            public var placeRadiusM: Double
            /// The yields trained over, kg.
            public var yieldRangeKg: [Double]
            /// The log yield's standardisation: ln W = mid + scale × output.
            public var logYieldMid: Double
            public var logYieldScale: Double
            public var maxMarks: Int
            /// "pooled" (nil: the set's mean and maximum through `rho` to the grid), or "surfaces":
            /// each mark's own log likelihood over the cells and `yieldBins` bins of the log yield,
            /// `surfaces` terms of log sigmoid(a + b t) each, summed over the marks.
            public var kind: String?
            public var surfaces: Int?
            public var yieldBins: Int?
            /// "distance": the distances (from, to, m) the mark's network is evaluated at, evenly
            /// in their logarithm, and how many; and the likelihood's floor.
            public var distanceRangeM: [Double]?
            public var distanceNodes: Int?
            public var floor: Double?
            /// The districts trained on, and the checkpoint's SHA-256.
            public var trainedOn: [String]
            public var source: String
            public var tensors: [Tensor]
            /// Marks and the posterior PyTorch gave them, for the test against PyTorch.
            public var references: [Reference]?
        }

        public struct Tensor: Codable, Sendable {
            public var name: String
            public var shape: [Int]
            /// Its first value's index among the file's float16 values.
            public var offset: Int
        }

        public struct Reference: Codable, Sendable {
            public var marks: [Mark]
            /// For a summed network, the cells given (each with all its bins, in `logits`); nil, all.
            public var cells: [Int]?
            public var logits: [Double]
            public var mu: [Double]
            public var logSigma: [Double]
        }

        public let header: Header
        /// Each layer's weights (out × in, row by row) and biases: `phi`'s, then `rho`'s.
        let phiLayers: [(weights: [Float], bias: [Float], inputs: Int, outputs: Int)]
        let rhoLayers: [(weights: [Float], bias: [Float], inputs: Int, outputs: Int)]
        /// The surfaces' head (`kind` "surfaces"): from `phi`'s last width to each term's offsets
        /// and slopes over the cells.
        let headLayer: (weights: [Float], bias: [Float], inputs: Int, outputs: Int)?
        /// Whether the marks' log likelihoods are summed over the cells and bins ("surfaces" or
        /// "distance") rather than pooled.
        public var summed: Bool { header.kind == "surfaces" || header.kind == "distance" }
        /// The "distance" network: from a mark's features beside its place and its distance to two
        /// offsets and slopes.
        let distanceLayers: [(weights: [Float], bias: [Float], inputs: Int, outputs: Int)]
        /// The first layer's part from each tabulated distance (its last two inputs), node by node.
        let distanceInputs: [Float]
        /// Whether each cell's middle lies within the place radius.
        public let inDisc: [Bool]

        public static let magic = "BCCD0001"

        /// Reads a `.bccd` file: the magic, a little-endian UInt32 header length, the JSON header,
        /// padding to 8 bytes, then float16 values.
        public init(contentsOf url: URL) throws {
            try self.init(data: Data(contentsOf: url), name: url.lastPathComponent)
        }

        /// A `.bccd` file's bytes; `name` for its errors.
        public init(data: Data, name: String = "network") throws {
            guard data.count > 12, String(decoding: data.prefix(8), as: UTF8.self) == Self.magic else {
                throw BlastError.allocationFailed("\(name): not a charge-from-damage network")
            }
            let length = data.subdata(in: 8..<12).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard data.count >= 12 + length else {
                throw BlastError.allocationFailed("\(name): cut short")
            }
            let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length)))
            let start = (12 + length + 7) / 8 * 8
            let values: [Float] = data.subdata(in: start..<data.count).withUnsafeBytes { raw in
                let halves = raw.bindMemory(to: UInt16.self)
                return halves.map { Float(Float16(bitPattern: UInt16(littleEndian: $0))) }
            }
            try self.init(header: header, values: values)
        }

        /// The network built in (`ChargeFromDamage+Embedded.swift`, written by
        /// Scripts/ml/embed_charge.py): `charge-net-2`, trained on Beirut and four made-up
        /// districts; nil if there is none.
        public static let builtIn: Network? = embeddedWeights.flatMap {
            Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
        }.flatMap { try? Network(data: $0, name: "the built-in network") }

        /// The network in `path`, else the built-in one.
        public static func named(_ path: String?) throws -> Network {
            if let path { return try Network(contentsOf: URL(filePath: path)) }
            guard let network = builtIn else {
                throw BlastError.allocationFailed(
                    "no charge-from-damage network built in: --weights net.bccd")
            }
            return network
        }

        /// From the header and its float16 values, widened.
        public init(header: Header, values: [Float]) throws {
            self.header = header
            let named = Dictionary(header.tensors.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            func layers(_ prefix: String, _ widths: [Int], inputs: Int) throws -> [(
                weights: [Float], bias: [Float], inputs: Int, outputs: Int
            )] {
                var list: [(weights: [Float], bias: [Float], inputs: Int, outputs: Int)] = []
                var width = inputs
                for (k, out) in widths.enumerated() {
                    guard let w = named["\(prefix).\(k).weight"], let b = named["\(prefix).\(k).bias"],
                        w.shape == [out, width], b.shape == [out],
                        w.offset + out * width <= values.count, b.offset + out <= values.count
                    else { throw BlastError.allocationFailed("charge-from-damage network: \(prefix).\(k)") }
                    list.append(
                        (
                            Array(values[w.offset..<(w.offset + out * width)]),
                            Array(values[b.offset..<(b.offset + out)]), width, out
                        ))
                    width = out
                }
                return list
            }
            switch header.kind {
            case "distance":
                guard header.yieldBins.map({ $0 > 1 }) ?? false, (header.distanceRangeM?.count ?? 0) == 2,
                    (header.distanceNodes ?? 0) > 1
                else {
                    throw BlastError.allocationFailed(
                        "charge-from-damage network: distance without its bins or nodes")
                }
                distanceLayers = try layers("mlp", header.phi + [4], inputs: header.inputs - 4 + 2)
                phiLayers = []
                rhoLayers = []
                headLayer = nil
            case "surfaces":
                guard let terms = header.surfaces, let bins = header.yieldBins, terms > 0, bins > 1 else {
                    throw BlastError.allocationFailed(
                        "charge-from-damage network: surfaces without terms or bins")
                }
                distanceLayers = []
                phiLayers = try layers("phi", header.phi, inputs: header.inputs)
                rhoLayers = []
                headLayer = try layers(
                    "head", [2 * terms * header.grid * header.grid], inputs: header.phi.last ?? header.inputs)[
                        0]
            default:
                distanceLayers = []
                phiLayers = try layers("phi", header.phi, inputs: header.inputs)
                let pooled = 2 * (header.phi.last ?? 0) + 1
                rhoLayers = try layers("rho", header.rho + [3 * header.grid * header.grid], inputs: pooled)
                headLayer = nil
            }
            if header.kind == "distance", let first = distanceLayers.first, let nodes = header.distanceNodes,
                let range = header.distanceRangeM
            {
                let step = (log(range[1]) - log(range[0])) / Double(nodes - 1)
                distanceInputs = (0..<nodes).flatMap { n -> [Float] in
                    let r = exp(log(range[0]) + Double(n) * step)
                    let d = [Float(log((r + 10) / 1000)), Float(r / 1000)]
                    return (0..<first.outputs).map { o in
                        first.weights[o * first.inputs + first.inputs - 2] * d[0]
                            + first.weights[o * first.inputs + first.inputs - 1] * d[1]
                    }
                }
            } else {
                distanceInputs = []
            }
            let g = header.grid
            inDisc = (0..<(g * g)).map { c in
                let p = Self.cellMiddle(c, grid: g, halfWidthM: header.halfWidthM)
                return simd_length(p) <= header.placeRadiusM
            }
        }

        /// Cell `c`'s middle (row by row from the south-west), m east and north of the reference.
        public static func cellMiddle(_ c: Int, grid: Int, halfWidthM: Double) -> SIMD2<Double> {
            let size = 2 * halfWidthM / Double(grid)
            return SIMD2(
                -halfWidthM + (Double(c % grid) + 0.5) * size, -halfWidthM + (Double(c / grid) + 0.5) * size)
        }

        /// A mark's features, its place taken about `reference` (m east and north, the scene's
        /// metres): east and north over 1 km, its distance over 1 km and ln((distance + 25 m) /
        /// 1 km), ln(height / 10 m), ln(footprint / 200 m²), the share built round it, its walls'
        /// kind (three, one hot), its glass seen (whole, broken) and its walls seen (undamaged,
        /// damaged, heavy), each one hot and all zero where unseen.
        public static func features(_ mark: Mark, reference: SIMD2<Double>) -> [Float] {
            let b = mark.building
            let x = (b.east - reference.x) / 1000
            let y = (b.north - reference.y) / 1000
            let r = (x * x + y * y).squareRoot()
            var f: [Double] = [
                x, y, r, log(r + 0.025), log(max(b.heightM, 1) / 10), log(max(b.footprintM2, 4) / 200),
                b.builtShare,
            ]
            f += Walls.allCases.map { $0 == b.walls ? 1 : 0 }
            f += GlassSeen.allCases.map { $0 == mark.glass ? 1 : 0 }
            f += WallsSeen.allCases.map { $0 == mark.walls ? 1 : 0 }
            return f.map(Float.init)
        }

        static func silu(_ x: Float) -> Float { x / (1 + exp(-x)) }

        static func dense(
            _ layer: (weights: [Float], bias: [Float], inputs: Int, outputs: Int), _ input: [Float],
            activate: Bool
        ) -> [Float] {
            var out = layer.bias
            let n = layer.inputs
            let wide = n / 8 * 8
            layer.weights.withUnsafeBufferPointer { w in
                input.withUnsafeBufferPointer { x in
                    for o in 0..<layer.outputs {
                        let row = o * n
                        // Eight at a time, then the rest.
                        var lanes = SIMD8<Float>.zero
                        var i = 0
                        while i < wide {
                            lanes += SIMD8(w[(row + i)..<(row + i + 8)]) * SIMD8(x[i..<(i + 8)])
                            i += 8
                        }
                        var sum = lanes.sum()
                        while i < n {
                            sum += w[row + i] * x[i]
                            i += 1
                        }
                        out[o] += sum
                    }
                }
            }
            return activate ? out.map(silu) : out
        }

        /// The network's raw outputs for `marks` about `reference`: each cell's logit (−∞ outside the
        /// disc), log-yield mean (ln kg) and log-yield standard deviation. Up to `maxMarks` marks
        /// are taken, the first ones.
        public func outputs(marks: [Mark], reference: SIMD2<Double>) -> (
            logits: [Double], mu: [Double], sigma: [Double]
        ) {
            let used = Array(marks.prefix(header.maxMarks))
            let width = header.phi.last ?? 0
            var mean = [Float](repeating: 0, count: width)
            var most = [Float](repeating: used.isEmpty ? 0 : -.greatestFiniteMagnitude, count: width)
            for mark in used {
                var h = Self.features(mark, reference: reference)
                for (k, layer) in phiLayers.enumerated() {
                    h = Self.dense(layer, h, activate: k < phiLayers.count - 1)
                }
                for i in 0..<width {
                    mean[i] += h[i] / Float(used.count)
                    most[i] = max(most[i], h[i])
                }
            }
            var h = mean + most + [Float(log(Double(used.count) + 1) / log(65.0))]
            for (k, layer) in rhoLayers.enumerated() {
                h = Self.dense(layer, h, activate: k < rhoLayers.count - 1)
            }
            let cells = header.grid * header.grid
            let logits = (0..<cells).map { inDisc[$0] ? Double(h[$0]) : -.infinity }
            let mu = (0..<cells).map { header.logYieldMid + header.logYieldScale * Double(h[cells + $0]) }
            let sigma = (0..<cells).map {
                header.logYieldScale * exp(min(max(Double(h[2 * cells + $0]), -7), 3))
            }
            return (logits, mu, sigma)
        }

        @inline(__always) static func logSigmoid(_ x: Float) -> Float {
            x >= 0 ? -log1p(exp(-x)) : x - log1p(exp(x))
        }

        /// log sigmoid tabulated every 0.005 over ±40, read linearly between (within 1e-6): the
        /// surfaces take it some fifty thousand times a mark.
        static let logSigmoidTable: [Float] = (0...16_000).map { logSigmoid(-40 + Float($0) * 0.005) }

        @inline(__always) static func tabulatedLogSigmoid(_ x: Float, _ table: UnsafeBufferPointer<Float>)
            -> Float
        {
            if x >= 40 { return 0 }
            if x <= -40 { return x }
            let q = (x + 40) * 200
            let i = min(Int(q), 15_999)
            let f = q - Float(i)
            return table[i] + f * (table[i + 1] - table[i])
        }

        /// A mark's log likelihood (`kind` "distance") over the cells, bin by bin within each
        /// cell, added to `joint` (times `weight`: −1 takes a mark out again, `Marking`): its network
        /// at each of the distances tabulated, read linearly in ln r for each cell's distance from it.
        func addDistance(_ mark: Mark, reference: SIMD2<Double>, to joint: inout [Float], weight: Float = 1) {
            let cells = header.grid * header.grid
            let bins = header.yieldBins ?? 1
            let nodes = header.distanceNodes ?? 2
            let range = header.distanceRangeM ?? [1, 8000]
            let floor = Float(header.floor ?? 0.02)
            let t = (0..<bins).map { Float(-1 + (2 * Double($0) + 1) / Double(bins)) }
            let own = Array(Self.features(mark, reference: reference).dropFirst(4))
            let logLow = log(range[0])
            let step = (log(range[1]) - logLow) / Double(nodes - 1)
            // The network at each tabulated distance: its first layer is the mark's own part, once,
            // and the distance's (`distanceInputs`), worked out with the network.
            var table = [Float](repeating: 0, count: nodes * 4)
            let first = distanceLayers[0]
            var mine = first.bias
            for o in 0..<first.outputs {
                for i in 0..<own.count { mine[o] += first.weights[o * first.inputs + i] * own[i] }
            }
            for n in 0..<nodes {
                var h = (0..<first.outputs).map { o in mine[o] + distanceInputs[n * first.outputs + o] }
                if distanceLayers.count > 1 { h = h.map(Self.silu) }
                for (k, layer) in distanceLayers.enumerated().dropFirst() {
                    h = Self.dense(layer, h, activate: k < distanceLayers.count - 1)
                }
                for j in 0..<4 { table[n * 4 + j] = h[j] }
            }
            let x = mark.building.east - reference.x
            let y = mark.building.north - reference.y
            Self.sigmoidTable.withUnsafeBufferPointer { sigmoid in
                Self.logTable.withUnsafeBufferPointer { logs in
                    joint.withUnsafeMutableBufferPointer { j in
                        for c in 0..<cells where inDisc[c] {
                            let m = Self.cellMiddle(c, grid: header.grid, halfWidthM: header.halfWidthM)
                            let r = max(
                                ((m.x - x) * (m.x - x) + (m.y - y) * (m.y - y)).squareRoot(), range[0])
                            let q = min(max((log(r) - logLow) / step, 0), Double(nodes - 1))
                            let i = min(Int(q), nodes - 2)
                            let f = Float(q - Double(i))
                            var v = SIMD4<Float>(table[(i * 4)..<(i * 4 + 4)])
                            v += f * (SIMD4<Float>(table[((i + 1) * 4)..<((i + 1) * 4 + 4)]) - v)
                            for k in 0..<bins {
                                let s1 = Self.tabulatedSigmoid(v[0] + v[1] * t[k], sigmoid)
                                let s2 = Self.tabulatedSigmoid(v[2] + v[3] * t[k], sigmoid)
                                j[c * bins + k] +=
                                    weight * Self.tabulatedLog(floor + (1 - floor) * s1 * s2, logs)
                            }
                        }
                    }
                }
            }
        }

        /// The sigmoid tabulated every 0.005 over ±40, read linearly between.
        static let sigmoidTable: [Float] = (0...16_000).map { 1 / (1 + exp(-(-40 + Float($0) * 0.005))) }

        @inline(__always) static func tabulatedSigmoid(_ x: Float, _ table: UnsafeBufferPointer<Float>)
            -> Float
        {
            if x >= 40 { return 1 }
            if x <= -40 { return 0 }
            let q = (x + 40) * 200
            let i = min(Int(q), 15_999)
            return table[i] + (q - Float(i)) * (table[i + 1] - table[i])
        }

        /// ln x for x in [0.001, 1], tabulated at 4,096 even steps, read linearly between (within 2e-5
        /// above 0.02, which the likelihood's floor keeps every value over).
        static let logTable: [Float] = (0...4096).map { log(0.001 + 0.999 * Float($0) / 4096) }

        @inline(__always) static func tabulatedLog(_ x: Float, _ table: UnsafeBufferPointer<Float>) -> Float {
            let q = min(max((x - 0.001) / 0.999 * 4096, 0), 4096)
            let i = min(Int(q), 4095)
            return table[i] + (q - Float(i)) * (table[i + 1] - table[i])
        }

        /// The surfaces' summed log likelihood (`kind` "surfaces" or "distance") over the cells, bin
        /// by bin within each cell: −∞ outside the disc.
        public func joint(marks: [Mark], reference: SIMD2<Double>) -> [Float] {
            let cells = header.grid * header.grid
            let bins = header.yieldBins ?? 1
            let terms = header.surfaces ?? 1
            let t = (0..<bins).map { Float(-1 + (2 * Double($0) + 1) / Double(bins)) }
            var joint = [Float](repeating: 0, count: cells * bins)
            if header.kind == "distance" {
                for mark in marks { addDistance(mark, reference: reference, to: &joint) }
                for c in 0..<cells where !inDisc[c] {
                    for k in 0..<bins { joint[c * bins + k] = -.infinity }
                }
                return joint
            }
            guard let head = headLayer else { return joint }
            for mark in marks {
                var h = Self.features(mark, reference: reference)
                for layer in phiLayers { h = Self.dense(layer, h, activate: true) }
                let out = Self.dense(head, h, activate: false)
                joint.withUnsafeMutableBufferPointer { j in
                    out.withUnsafeBufferPointer { o in
                        Self.logSigmoidTable.withUnsafeBufferPointer { table in
                            for term in 0..<terms {
                                let a = (2 * term) * cells
                                let b = (2 * term + 1) * cells
                                for c in 0..<cells where inDisc[c] {
                                    let offset = o[a + c]
                                    let slope = o[b + c]
                                    for k in 0..<bins {
                                        j[c * bins + k] += Self.tabulatedLogSigmoid(
                                            offset + slope * t[k], table)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for c in 0..<cells where !inDisc[c] {
                for k in 0..<bins { joint[c * bins + k] = -.infinity }
            }
            return joint
        }

        /// The posterior for `marks` about `reference` (the scene's metres). More marks than the
        /// network takes at once (`maxMarks`) are weighed in groups as even as can be, each group's
        /// posterior taken as independent evidence, as the marks are given the charge: in each cell
        /// the groups' weights and their log yields' normals multiplied, the uniform prior divided out.
        public func posterior(marks: [Mark], reference: SIMD2<Double>) -> Posterior {
            if summed {
                return posterior(joint: joint(marks: marks, reference: reference), reference: reference)
            }
            return pooledPosterior(marks: marks, reference: reference)
        }

        /// A summed network's (`summed`) posterior from its marks' log likelihood over the cells
        /// and bins (`joint(marks:reference:)`): a mark added later adds its own `joint([mark])`,
        /// so the app pays for the new mark alone.
        public func posterior(joint: [Float], reference: SIMD2<Double>, only held: Set<Int>? = nil)
            -> Posterior
        {
            var joint = joint
            if let held {
                let bins = header.yieldBins ?? 1
                for c in 0..<(header.grid * header.grid) where !held.contains(c) {
                    for k in 0..<bins { joint[c * bins + k] = -.infinity }
                }
            }
            do {
                let cells = header.grid * header.grid
                let bins = header.yieldBins ?? 1
                let most = joint.max() ?? 0
                var cellProbabilities = [Double](repeating: 0, count: cells)
                var marginal = [Double](repeating: 0, count: bins)
                for c in 0..<cells where inDisc[c] {
                    for k in 0..<bins where joint[c * bins + k].isFinite {
                        let w = Double(exp(joint[c * bins + k] - most))
                        cellProbabilities[c] += w
                        marginal[k] += w
                    }
                }
                let total = cellProbabilities.reduce(0, +)
                let range = header.yieldRangeKg
                let width = (log(range[1]) - log(range[0])) / Double(bins)
                return Posterior(
                    grid: header.grid, halfWidthM: header.halfWidthM, reference: reference,
                    cellProbabilities: cellProbabilities.map { $0 / total },
                    logYields: (0..<bins).map { log(range[0]) + (Double($0) + 0.5) * width },
                    yieldProbabilities: marginal.map { $0 / total })
            }
        }

        func pooledPosterior(marks: [Mark], reference: SIMD2<Double>) -> Posterior {
            let size = max(header.maxMarks, 1)
            let groupCount = max(1, (marks.count + size - 1) / size)
            let groups = (0..<groupCount).map { g in
                Array(marks[(g * marks.count / groupCount)..<((g + 1) * marks.count / groupCount)])
            }
            let cells = header.grid * header.grid
            var logWeight = [Double](repeating: 0, count: cells)
            var precision = [Double](repeating: 0, count: cells)
            var weighted = [Double](repeating: 0, count: cells)
            var square = [Double](repeating: 0, count: cells)
            for group in groups {
                let (logits, mu, sigma) = outputs(marks: group, reference: reference)
                let most = logits.max() ?? 0
                let total = logits.reduce(0.0) { $0 + ($1.isFinite ? exp($1 - most) : 0) }
                for c in 0..<cells {
                    logWeight[c] += logits[c] - most - log(total) - log(sigma[c])
                    let p = 1 / (sigma[c] * sigma[c])
                    precision[c] += p
                    weighted[c] += mu[c] * p
                    square[c] += mu[c] * mu[c] * p
                }
            }
            // Each cell's product of normals: its weight's share and the normal it makes.
            var mean = [Double](repeating: 0, count: cells)
            var sd = [Double](repeating: 1, count: cells)
            var logCell = [Double](repeating: -.infinity, count: cells)
            for c in 0..<cells where logWeight[c].isFinite {
                mean[c] = weighted[c] / precision[c]
                sd[c] = 1 / precision[c].squareRoot()
                logCell[c] =
                    logWeight[c] - 0.5 * (square[c] - weighted[c] * mean[c]) + log(sd[c])
            }
            let most = logCell.max() ?? 0
            let weights = logCell.map { $0.isFinite ? exp($0 - most) : 0 }
            let total = weights.reduce(0, +)
            let range = header.yieldRangeKg
            let logYields = Posterior.logYieldGrid(low: range[0], high: range[1])
            // The marginal of the log yield on the grid: each cell's normal, cut to the range.
            var marginal = [Double](repeating: 0, count: logYields.count)
            for c in weights.indices where weights[c] > 1e-9 * total {
                let w = weights[c] / total
                var row = logYields.map { x -> Double in
                    let z = (x - mean[c]) / sd[c]
                    return exp(-0.5 * z * z)
                }
                let sum = row.reduce(0, +)
                guard sum > 0 else { continue }
                row = row.map { $0 * w / sum }
                for k in row.indices { marginal[k] += row[k] }
            }
            return Posterior(
                grid: header.grid, halfWidthM: header.halfWidthM, reference: reference,
                cellProbabilities: weights.map { $0 / total }, logYields: logYields,
                yieldProbabilities: marginal,
                cellLogYield: mean, cellLogYieldSD: sd)
        }
    }

    // MARK: - The posterior

    /// A posterior over the charge's place, by cells of a square about `reference`, and its log
    /// yield's marginal, on a grid of log yields.
    public struct Posterior: Sendable {
        public var grid: Int
        public var halfWidthM: Double
        /// The square's middle, the scene's metres.
        public var reference: SIMD2<Double>
        /// Each cell's probability, row by row from the south-west; they sum to 1.
        public var cellProbabilities: [Double]
        /// ln kg, evenly spaced.
        public var logYields: [Double]
        /// The marginal probability of each of `logYields` (they sum to 1).
        public var yieldProbabilities: [Double]
        /// Each cell's log yield, mean and standard deviation, where known (the network's).
        public var cellLogYield: [Double]?
        public var cellLogYieldSD: [Double]?

        /// 241 log yields from `low` to `high` kg.
        public static func logYieldGrid(low: Double, high: Double, count: Int = 241) -> [Double] {
            (0..<count).map { log(low) + (log(high) - log(low)) * Double($0) / Double(count - 1) }
        }

        public var cellSizeM: Double { 2 * halfWidthM / Double(grid) }

        /// Cell `c`'s middle, the scene's metres.
        public func middle(_ c: Int) -> SIMD2<Double> {
            reference + Network.cellMiddle(c, grid: grid, halfWidthM: halfWidthM)
        }

        /// The cell holding `place` (the scene's metres), nil outside the square.
        public func cell(_ place: SIMD2<Double>) -> Int? {
            let q = (place - reference + halfWidthM) / cellSizeM
            let i = Int(q.x.rounded(.down))
            let j = Int(q.y.rounded(.down))
            guard (0..<grid).contains(i), (0..<grid).contains(j) else { return nil }
            return j * grid + i
        }

        /// The place's mean, the scene's metres.
        public var meanPlace: SIMD2<Double> {
            cellProbabilities.indices.reduce(SIMD2<Double>.zero) { $0 + cellProbabilities[$1] * middle($1) }
        }

        /// The most probable cell's middle.
        public var mostProbablePlace: SIMD2<Double> {
            middle(cellProbabilities.indices.max { cellProbabilities[$0] < cellProbabilities[$1] } ?? 0)
        }

        /// The fewest cells, most probable first, that hold `mass` of the probability.
        public func region(_ mass: Double) -> [Int] {
            let order = cellProbabilities.indices.sorted { cellProbabilities[$0] > cellProbabilities[$1] }
            var sum = 0.0
            var cells: [Int] = []
            for c in order {
                cells.append(c)
                sum += cellProbabilities[c]
                if sum >= mass { break }
            }
            return cells
        }

        /// The radius of the disc whose area is the region's that holds `mass`, m.
        public func regionRadius(_ mass: Double) -> Double {
            (Double(region(mass).count) * cellSizeM * cellSizeM / .pi).squareRoot()
        }

        /// Whether `place` lies in the region holding `mass`.
        public func regionHolds(_ place: SIMD2<Double>, mass: Double) -> Bool {
            guard let c = cell(place) else { return false }
            return region(mass).contains(c)
        }

        /// The yield's quantile `q`, kg.
        public func yieldQuantile(_ q: Double) -> Double {
            var sum = 0.0
            for (k, p) in yieldProbabilities.enumerated() {
                if sum + p >= q {
                    let t = p > 0 ? (q - sum) / p : 0
                    let step = logYields.count > 1 ? logYields[1] - logYields[0] : 0
                    return exp(logYields[k] - 0.5 * step + t * step)
                }
                sum += p
            }
            return exp(logYields.last ?? 0)
        }

        /// The share of the yield's probability below `massKg`.
        public func yieldCDF(_ massKg: Double) -> Double {
            let x = log(massKg)
            let step = logYields.count > 1 ? logYields[1] - logYields[0] : 1
            var sum = 0.0
            for (k, p) in yieldProbabilities.enumerated() {
                let low = logYields[k] - 0.5 * step
                if x >= low + step {
                    sum += p
                } else if x > low {
                    sum += p * (x - low) / step
                }
            }
            return sum
        }

        /// The posterior's standing and spread in words: the yield's median and 90% interval, the
        /// place's most probable cell and the radius holding half and nine tenths of it.
        public func summary(standing: String = ChargeFromDamage.standing) -> String {
            let place = mostProbablePlace - reference
            return String(
                format:
                    "Yield %@ (90%%: %@–%@); most likely %.0f m east, %.0f m north of the reference, half within %.0f m, 90%% within %.0f m. %@",
                Self.mass(yieldQuantile(0.5)) as NSString, Self.mass(yieldQuantile(0.05)) as NSString,
                Self.mass(yieldQuantile(0.95)) as NSString, place.x, place.y, regionRadius(0.5),
                regionRadius(0.9), standing as NSString)
        }

        /// A TNT mass in words: kg, t or kt.
        public static func mass(_ kg: Double) -> String {
            if kg >= 1e6 { return String(format: "%.2f kt", kg / 1e6) }
            if kg >= 1e3 { return String(format: "%.1f t", kg / 1e3) }
            return String(format: "%.0f kg", kg)
        }
    }

    /// The learned posterior's standing, in words (docs/charge-inference.md, "The charge from marked
    /// damage, learned").
    public static let standing =
        "Illustrative: learned from the quick estimate's own chances. On charges drawn from them its 50% and 90% regions hold the truth as often as they say, within about 10–20% of the full posterior's yield, on a district it never saw too. On Beirut it is as good as those chances: right from stone walls (0.7 kt), 15–30 times low from glass."
}
