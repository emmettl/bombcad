import Foundation
import simd

extension ChargeFromDamage {
    /// The quick estimate's chances of damage for a district's chosen buildings, for charges on a
    /// square grid of places about a reference point and at a ladder of yields: what the network is
    /// trained on (drawn from it, `Case`), and the full posterior it is judged against
    /// (`posterior(marks:…)`), both from the same chances. Between nodes and yields a chance is
    /// interpolated, bilinearly in place and linearly in log yield.
    ///
    /// Each building's channels: its glass broken (some pane of some side, the sides' draws taken
    /// together, `FacadeLoadSurrogate.glassProbabilities`), and its walls damaged moderately or
    /// worse and heavily or worse (`structureProbabilities`), built as the scene says and again as
    /// 0.5 m unreinforced masonry, as Beirut's stone is judged (`scenebench damage-yield`).
    public struct ChanceTable: Sendable {
        public struct Header: Codable, Sendable {
            public var format: String
            public var district: String
            /// The reference point, the scene's metres; every place here is about it.
            public var reference: [Double]
            /// The first node's place about the reference, m, and the nodes' spacing.
            public var origin: [Double]
            public var spacingM: Double
            public var columns: Int
            public var rows: Int
            public var yieldsKg: [Double]
            public var channels: [String]
            /// The chosen buildings, their places about the reference.
            public var buildings: [Building]
            /// Each chosen building's index among the scene's envelope objects.
            public var objects: [Int]
            public var draws: Int
            public var cellSizeM: Double
            public var terms: String
            /// The radius about the reference the charges are drawn within, m.
            public var placeRadiusM: Double
            public var sceneRadiusM: Double
            public var seconds: Double
            /// The nodes held, `first..<first + count` of all, for a part (all, for a whole table).
            public var firstNode: Int
            public var nodeCount: Int
            /// The buildings (by index in `buildings`) whose masonry channels were worked out, where
            /// only some were (from the full look, `--masonry-only`); nil, all of them.
            public var masonryBuildings: [Int]?
        }

        public static let magic = "BCCT0001"
        public static let channels = [
            "glassBroken", "wallsModerate", "wallsHeavy", "masonryModerate", "masonryHeavy",
        ]

        public var header: Header
        /// The chances as bytes (chance × 255), node by node, then yield, building and channel.
        public var values: [UInt8]

        public var nodes: Int { header.columns * header.rows }
        public var buildingCount: Int { header.buildings.count }
        var channelCount: Int { header.channels.count }
        /// Whether the walls were judged again as masonry (the last two channels).
        public var hasMasonry: Bool { channelCount >= 5 }

        /// Whether building `b`'s walls were judged as masonry.
        public func judgesMasonry(_ b: Int) -> Bool {
            hasMasonry && (masonrySet?.contains(b) ?? true)
        }
        var masonrySet: Set<Int>? { header.masonryBuildings.map(Set.init) }

        public init(header: Header, values: [UInt8]) {
            self.header = header
            self.values = values
        }

        public func write(to url: URL) throws {
            var data = Data(Self.magic.utf8)
            let json = try JSONEncoder().encode(header)
            var length = UInt32(json.count).littleEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(json)
            while data.count % 16 != 0 { data.append(0) }
            data.append(contentsOf: values)
            try data.write(to: url)
        }

        public init(contentsOf url: URL) throws {
            let data = try Data(contentsOf: url)
            guard data.count > 12, String(decoding: data.prefix(8), as: UTF8.self) == Self.magic else {
                throw BlastError.allocationFailed("\(url.lastPathComponent): not a chance table")
            }
            let length = data.subdata(in: 8..<12).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length)))
            let start = (12 + length + 15) / 16 * 16
            values = [UInt8](data.subdata(in: start..<data.count))
            let expected =
                header.nodeCount * header.yieldsKg.count * header.buildings.count * header.channels.count
            guard values.count == expected else {
                throw BlastError.allocationFailed(
                    "\(url.lastPathComponent): \(values.count) values, not \(expected)")
            }
        }

        /// Parts written node by node (`--part`), joined in their nodes' order into a whole table.
        public static func merge(_ parts: [ChanceTable]) throws -> ChanceTable {
            let sorted = parts.sorted { $0.header.firstNode < $1.header.firstNode }
            guard var header = sorted.first?.header else { throw BlastError.allocationFailed("no parts") }
            var next = 0
            var values: [UInt8] = []
            var seconds = 0.0
            for part in sorted {
                guard part.header.firstNode == next, part.header.buildings == header.buildings,
                    part.header.yieldsKg == header.yieldsKg
                else { throw BlastError.allocationFailed("parts that do not join at node \(next)") }
                next += part.header.nodeCount
                values += part.values
                seconds += part.header.seconds
            }
            guard next == header.columns * header.rows else {
                throw BlastError.allocationFailed(
                    "parts end at node \(next) of \(header.columns * header.rows)")
            }
            header.firstNode = 0
            header.nodeCount = next
            header.seconds = seconds
            return ChanceTable(header: header, values: values)
        }

        // MARK: Interpolation

        /// The four nodes round `place` (m about the reference) and their weights.
        func corners(_ place: SIMD2<Double>) -> [(node: Int, weight: Double)] {
            let x = (place.x - header.origin[0]) / header.spacingM
            let y = (place.y - header.origin[1]) / header.spacingM
            let i = min(max(Int(x.rounded(.down)), 0), header.columns - 2)
            let j = min(max(Int(y.rounded(.down)), 0), header.rows - 2)
            let s = min(max(x - Double(i), 0), 1)
            let t = min(max(y - Double(j), 0), 1)
            let c = header.columns
            return [
                (j * c + i, (1 - s) * (1 - t)), (j * c + i + 1, s * (1 - t)), ((j + 1) * c + i, (1 - s) * t),
                ((j + 1) * c + i + 1, s * t),
            ]
        }

        /// The yield ladder's step below ln `massKg` and the share of the way to the next.
        func yieldStep(_ logMass: Double) -> (Int, Double) {
            let y = header.yieldsKg
            let low = log(y[0])
            let step = (log(y[y.count - 1]) - low) / Double(y.count - 1)
            let x = min(max((logMass - low) / step, 0), Double(y.count - 1))
            let k = min(Int(x), y.count - 2)
            return (k, x - Double(k))
        }

        @inline(__always) func value(node: Int, yield k: Int, building b: Int, channel c: Int) -> Double {
            Double(values[((node * header.yieldsKg.count + k) * buildingCount + b) * channelCount + c]) / 255
        }

        /// Building `b`'s chance on `channel` from a charge of ln `logMass` kg at `place`.
        public func chance(building b: Int, channel c: Int, place: SIMD2<Double>, logMass: Double) -> Double {
            let (k, u) = yieldStep(logMass)
            var sum = 0.0
            for (node, w) in corners(place) where w > 0 {
                sum +=
                    w
                    * ((1 - u) * value(node: node, yield: k, building: b, channel: c) + u
                        * value(node: node, yield: k + 1, building: b, channel: c))
            }
            return sum
        }

        /// A marked building of the table: which, whether it is taken as masonry (its walls judged
        /// on the masonry channels), and what was seen.
        public struct TableMark: Sendable, Equatable {
            public var building: Int
            public var masonry: Bool
            public var glass: GlassSeen?
            public var walls: WallsSeen?

            public init(building: Int, masonry: Bool, glass: GlassSeen?, walls: WallsSeen?) {
                self.building = building
                self.masonry = masonry
                self.glass = glass
                self.walls = walls
            }
        }

        /// The mark as the network sees it, its place about the reference.
        public func mark(_ m: TableMark) -> Mark {
            var b = header.buildings[m.building]
            if m.masonry { b.walls = .masonry }
            return Mark(building: b, glass: m.glass, walls: m.walls)
        }

        /// The log likelihood of what `m` saw, given its chances.
        static func logLikelihood(_ m: TableMark, glass: Double, moderate: Double, heavy: Double) -> Double {
            var sum = 0.0
            if let seen = m.glass {
                let q = glassClasses(broken: glass)
                sum += log(seen == .whole ? q.whole : q.broken)
            }
            if let seen = m.walls {
                let q = wallsClasses(moderate: moderate, heavy: heavy)
                sum += log(seen == .undamaged ? q.undamaged : seen == .damaged ? q.damaged : q.heavy)
            }
            return sum
        }

        /// The full posterior of `marks` on the chances, its place on the network's cells (`grid` ×
        /// `grid`, half side `halfWidthM`, the disc of `placeRadiusM`), each cell's likelihood the
        /// mean over `sub` × `sub` points in it, and the yield on `yieldSteps` steps between each
        /// pair of the ladder's; the prior uniform over the disc's cells (or `only` those) and in log
        /// yield.
        public func posterior(
            marks: [TableMark], grid: Int, halfWidthM: Double, placeRadiusM: Double, sub: Int = 2,
            yieldSteps: Int = 3, only cellsHeld: Set<Int>? = nil
        ) -> Posterior {
            let y = header.yieldsKg
            let count = (y.count - 1) * yieldSteps + 1
            let logYields = (0..<count).map {
                log(y[0]) + (log(y[y.count - 1]) - log(y[0])) * Double($0) / Double(count - 1)
            }
            let cells = grid * grid
            let size = 2 * halfWidthM / Double(grid)
            let masonry = masonrySet
            // Each cell's log likelihood at each log yield, by its sub-points.
            var table = [Double](repeating: -.infinity, count: cells * count)
            table.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: cells) { c in
                    let middle = Network.cellMiddle(c, grid: grid, halfWidthM: halfWidthM)
                    guard simd_length(middle) <= placeRadiusM, cellsHeld?.contains(c) ?? true else { return }
                    var points: [[Double]] = []
                    for a in 0..<sub {
                        for b in 0..<sub {
                            let place =
                                middle
                                + size
                                * SIMD2(
                                    (Double(a) + 0.5) / Double(sub) - 0.5,
                                    (Double(b) + 0.5) / Double(sub) - 0.5)
                            let around = corners(place)
                            var logL = [Double](repeating: 0, count: count)
                            for m in marks {
                                let glassChannel = 0
                                let asMasonry =
                                    m.masonry && hasMasonry && (masonry?.contains(m.building) ?? true)
                                let moderateChannel = asMasonry ? 3 : 1
                                let heavyChannel = asMasonry ? 4 : 2
                                // The chances at the ladder's yields, then between them.
                                var at = [SIMD3<Double>](repeating: .zero, count: y.count)
                                for k in 0..<y.count {
                                    var v = SIMD3<Double>.zero
                                    for (node, w) in around where w > 0 {
                                        v +=
                                            w
                                            * SIMD3(
                                                m.glass != nil
                                                    ? value(
                                                        node: node, yield: k, building: m.building,
                                                        channel: glassChannel)
                                                    : 0,
                                                m.walls != nil
                                                    ? value(
                                                        node: node, yield: k, building: m.building,
                                                        channel: moderateChannel)
                                                    : 0,
                                                m.walls != nil
                                                    ? value(
                                                        node: node, yield: k, building: m.building,
                                                        channel: heavyChannel)
                                                    : 0)
                                    }
                                    at[k] = v
                                }
                                for n in 0..<count {
                                    let k = min(n / yieldSteps, y.count - 2)
                                    let u = Double(n - k * yieldSteps) / Double(yieldSteps)
                                    let v = (1 - u) * at[k] + u * at[k + 1]
                                    logL[n] += Self.logLikelihood(m, glass: v.x, moderate: v.y, heavy: v.z)
                                }
                            }
                            points.append(logL)
                        }
                    }
                    for n in 0..<count {
                        let most = points.map { $0[n] }.max()!
                        let mean = points.reduce(0.0) { $0 + exp($1[n] - most) } / Double(points.count)
                        out[c * count + n] = most + log(mean)
                    }
                }
            }
            let most = table.max() ?? 0
            let weights = table.map { $0.isFinite ? exp($0 - most) : 0 }
            let total = weights.reduce(0, +)
            var cellProbabilities = [Double](repeating: 0, count: cells)
            var marginal = [Double](repeating: 0, count: count)
            for c in 0..<cells {
                for n in 0..<count {
                    let w = weights[c * count + n] / total
                    cellProbabilities[c] += w
                    marginal[n] += w
                }
            }
            return Posterior(
                grid: grid, halfWidthM: halfWidthM, reference: .zero, cellProbabilities: cellProbabilities,
                logYields: logYields, yieldProbabilities: marginal)
        }

        // MARK: Drawn cases

        /// A charge drawn and the marks it gave.
        public struct Case: Sendable {
            /// m about the reference.
            public var place: SIMD2<Double>
            public var logMass: Double
            public var marks: [TableMark]
        }

        /// The rules every case is drawn by, here and in the training script
        /// (Scripts/ml/train_charge.py, `draw_cases`): the charge uniform over the disc's cells and in
        /// log yield over the ladder; `markCount` marks (or, nil, ⌊e^U(0, ln 65)⌋, at most 64); a
        /// focus uniform within `focusRadiusM` of the reference and a length e^U(ln 100, ln 1500) m,
        /// the buildings chosen without replacement with weights e^(−distance from the focus /
        /// length), whatever the charge; each seen for both (0.45), its glass alone (0.30) or its
        /// walls alone (0.25), its walls alone if it has no glazing; its walls taken as masonry with
        /// chance 0.3 where they are concrete, if the table judged them so (`judgesMasonry`); and what was seen drawn from its chances
        /// (`glassClasses`, `wallsClasses`).
        public func drawCase(
            _ random: inout SplitMix, grid: Int, halfWidthM: Double, placeRadiusM: Double, markCount: Int?,
            focusRadiusM: Double = 1000
        ) -> Case {
            let size = 2 * halfWidthM / Double(grid)
            let disc = (0..<(grid * grid)).filter {
                simd_length(Network.cellMiddle($0, grid: grid, halfWidthM: halfWidthM)) <= placeRadiusM
            }
            let cell = disc[min(Int(random.uniform() * Double(disc.count)), disc.count - 1)]
            let place =
                Network.cellMiddle(cell, grid: grid, halfWidthM: halfWidthM)
                + size * SIMD2(random.uniform() - 0.5, random.uniform() - 0.5)
            let y = header.yieldsKg
            let logMass = log(y[0]) + random.uniform() * (log(y[y.count - 1]) - log(y[0]))
            let n = min(markCount ?? Int(exp(random.uniform() * log(65.0))), 64, buildingCount)
            // The focus.
            let angle = 2 * Double.pi * random.uniform()
            let radius = focusRadiusM * random.uniform().squareRoot()
            let focus = radius * SIMD2(cos(angle), sin(angle))
            let length = exp(log(100.0) + random.uniform() * (log(1500.0) - log(100.0)))
            // Without replacement, by exponential keys (Efraimidis and Spirakis).
            let keys = header.buildings.indices.map { b -> (Double, Int) in
                let d = simd_distance(SIMD2(header.buildings[b].east, header.buildings[b].north), focus)
                let weight = exp(-d / length)
                return (weight > 0 ? -log(max(random.uniform(), 1e-300)) / weight : .infinity, b)
            }
            let chosen = keys.sorted { $0.0 < $1.0 }.prefix(n).map(\.1)
            var marks: [TableMark] = []
            for b in chosen {
                let building = header.buildings[b]
                let u = random.uniform()
                let glass = building.glazed && u < 0.75
                let walls = !building.glazed || u < 0.45 || u >= 0.75
                let masonry =
                    judgesMasonry(b)
                    && (building.walls == .masonry || (building.walls == .concrete && random.uniform() < 0.3))
                var mark = TableMark(building: b, masonry: masonry, glass: nil, walls: nil)
                if glass {
                    let q = glassClasses(
                        broken: chance(building: b, channel: 0, place: place, logMass: logMass))
                    mark.glass = random.uniform() < q.whole ? .whole : .broken
                }
                if walls {
                    let q = wallsClasses(
                        moderate: chance(
                            building: b, channel: masonry ? 3 : 1, place: place, logMass: logMass),
                        heavy: chance(building: b, channel: masonry ? 4 : 2, place: place, logMass: logMass))
                    let v = random.uniform()
                    mark.walls =
                        v < q.undamaged ? .undamaged : v < q.undamaged + q.damaged ? .damaged : .heavy
                }
                marks.append(mark)
            }
            return Case(place: place, logMass: logMass, marks: marks)
        }
    }

    /// SplitMix64: a small, seeded generator for drawn cases.
    public struct SplitMix: Sendable {
        var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        public mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }
    }
}

extension FacadeLoadSurrogate.Prepared {
    /// As `estimate(charge:mass:)` for the envelope objects `chosen` alone (their indices among the
    /// scene's), every other building still shielding them in the raster: their components'
    /// features, which do not depend on the mass. The predictions and loads are left empty: the
    /// chances (`glassSides(_:)`, `structureProbabilities`) predict from the features at each
    /// yield they draw.
    func chosenFeatures(charge: SIMD3<Float>, chosen: [Int]) -> FacadeLoadSurrogate.Estimate {
        let open = raster.openReach(around: charge)
        var perObject = [[FacadeLoadSurrogate.Features]](repeating: [], count: chosen.count)
        perObject.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: chosen.count) { k in
                let n = chosen[k]
                out[k] = components[n].map { component in
                    var f = FacadeLoadSurrogate.features(component, owner: n, charge: charge, raster: raster)
                    f.chargeOpenM = open
                    return f
                }
            }
        }
        var result = FacadeLoadSurrogate.Estimate(
            components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
        result.ownerKeys = objects.map(\.drawKey)
        for (k, n) in chosen.enumerated() {
            for (component, f) in zip(components[n], perObject[k]) {
                result.components.append(component)
                result.owners.append(n)
                result.features.append(f)
            }
        }
        return result
    }

    /// As `preview(charge:mass:)` for the envelope objects `chosen` alone: of each building's
    /// components of one kind on one side, the one nearest the charge, and the glazed sides, each
    /// group's nearest strip standing for its area, as a drag's preview judges them; their features
    /// alone, which do not depend on the mass.
    func chosenPreview(charge: SIMD3<Float>, chosen: [Int]) -> (
        estimate: FacadeLoadSurrogate.Estimate, sides: [FacadeLoadSurrogate.GlassSideStrips]
    ) {
        let open = raster.openReach(around: charge)
        typealias Picked = (
            component: EnvelopeComponent, features: FacadeLoadSurrogate.Features, area: Double, judged: Bool
        )
        var perObject = [[Picked]](repeating: [], count: chosen.count)
        perObject.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: chosen.count) { k in
                let n = chosen[k]
                var nearest: [Int: (index: Int, distance: Float, area: Double)] = [:]
                for (c, component) in components[n].enumerated() {
                    let key = previewGroups[n][c]
                    let d = simd_distance_squared(FacadeLoadSurrogate.outerFace(component).centre, charge)
                    let spans = component.spans
                    let area = Double(spans.x * spans.y)
                    if let current = nearest[key] {
                        nearest[key] = (
                            d < current.distance ? c : current.index, min(d, current.distance),
                            current.area + area
                        )
                    } else {
                        nearest[key] = (c, d, area)
                    }
                }
                var nearestOfSide: [Int: (index: Int, distance: Float)] = [:]
                for (key, picked) in nearest {
                    let side = key >> 16
                    if let current = nearestOfSide[side],
                        current.distance < picked.distance
                            || (current.distance == picked.distance && current.index < picked.index)
                    {
                        continue
                    }
                    nearestOfSide[side] = (picked.index, picked.distance)
                }
                out[k] = nearest.sorted { $0.key < $1.key }.map { key, picked -> Picked in
                    let component = components[n][picked.index]
                    var f = FacadeLoadSurrogate.features(component, owner: n, charge: charge, raster: raster)
                    f.chargeOpenM = open
                    return (component, f, picked.area, nearestOfSide[key >> 16]?.index == picked.index)
                }
            }
        }
        var result = FacadeLoadSurrogate.Estimate(
            components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
        result.ownerKeys = objects.map(\.drawKey)
        var sides: [FacadeLoadSurrogate.GlassSideStrips] = []
        for (k, list) in perObject.enumerated() {
            let n = chosen[k]
            var side: [Int: Int] = [:]
            for picked in list {
                let component = picked.component
                if picked.judged {
                    result.components.append(component)
                    result.owners.append(n)
                    result.features.append(picked.features)
                }
                guard component.kind == .facade, let mix = mixes[n] else { continue }
                let key = component.axis * 2 + (component.outward > 0 ? 1 : 0)
                if let s = side[key] {
                    sides[s].strips.append((picked.features, picked.area))
                } else {
                    side[key] = sides.count
                    sides.append(
                        FacadeLoadSurrogate.GlassSideStrips(
                            owner: objects[n].id, ownerKey: objects[n].drawKey, axis: component.axis,
                            outward: component.outward, mix: mix, strips: [(picked.features, picked.area)]))
                }
            }
        }
        return (result, sides)
    }
}
