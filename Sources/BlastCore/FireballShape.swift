import Foundation
import simd

/// How the thermal radiation sees the fireball.
public enum FireballModel: String, Codable, Sendable, CaseIterable {
    /// The luminous gas's own shape, as blocks of a metre or so (see `FireballShape`).
    case shape
    /// One equivalent sphere: the luminous gas's volume, centroid and mean T⁴.
    case sphere
}

/// The fireball's luminous gas in blocks: a box of cubes `blockSize` a side, each with the share
/// of its air that is luminous and that gas's temperature. The flame's surface is where that
/// share, interpolated between the blocks' centres, is one half, and within it the flame is solid
/// and radiates at the temperature of the block it is in: the fourth root of its luminous cells'
/// mean T⁴. The blocks are as small as the grid allows (two cells a side), doubled until the box
/// has no more than `maximumBlocks`, so a frame of it is at most 96 KB.
public struct FireballShape: Sendable, Equatable {
    /// The most blocks in the box.
    public static let maximumBlocks = 32_768
    /// The most tiles the blocks are gathered into for sampling (see `FireballTile`).
    public static let maximumTiles = 16

    /// Each block's edge, in metres.
    public let blockSize: Float
    /// The box's first block along each axis, counting from the domain's corner, and how many
    /// blocks it spans.
    public let first: SIMD3<Int32>
    public let counts: SIMD3<Int32>
    /// Each block's share of luminous air, in 255ths, x fastest, then y, then z.
    public let fills: [UInt8]
    /// Each block's luminous gas's temperature in kelvin, in the same order; zero where it has
    /// none.
    public let temperatures: [UInt16]
    /// The hottest block's temperature.
    let hottest: UInt16
    /// What sampling the shape needs, worked out from the rest once, where it is first wanted:
    /// on the receivers' queue, not on the thread that drives the GPU, which only cuts the shape
    /// out.
    private let derived = Derived()

    public init(
        blockSize: Float, first: SIMD3<Int32>, counts: SIMD3<Int32>, fills: [UInt8], temperatures: [UInt16]
    ) {
        precondition(Int(counts.x) * Int(counts.y) * Int(counts.z) == fills.count)
        precondition(fills.count == temperatures.count)
        self.blockSize = blockSize
        self.first = first
        self.counts = counts
        self.fills = fills
        self.temperatures = temperatures
        hottest = temperatures.max() ?? 0
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.blockSize == b.blockSize && a.first == b.first && a.counts == b.counts && a.fills == b.fills
            && a.temperatures == b.temperatures
    }

    /// The blocks gathered into a few compact tiles; and whether the surface may pass through
    /// each block, which it can only where it or a block round it is at least half luminous.
    struct Sampling: Sendable {
        var tiles: [FireballTile]
        var near: [Bool]
    }

    private final class Derived: @unchecked Sendable {
        let lock = NSLock()
        var sampling: Sampling?
    }

    var sampling: Sampling {
        derived.lock.lock()
        defer { derived.lock.unlock() }
        if let sampling = derived.sampling { return sampling }
        let n = SIMD3<Int>(truncatingIfNeeded: counts)
        var near = [Bool](repeating: false, count: fills.count)
        for k in 0..<n.z {
            for j in 0..<n.y {
                for i in 0..<n.x where fills[i + n.x * (j + n.y * k)] >= Self.half {
                    for c in max(k - 1, 0)...min(k + 1, n.z - 1) {
                        for b in max(j - 1, 0)...min(j + 1, n.y - 1) {
                            for a in max(i - 1, 0)...min(i + 1, n.x - 1) {
                                near[a + n.x * (b + n.y * c)] = true
                            }
                        }
                    }
                }
            }
        }
        let sampling = Sampling(
            tiles: Self.tiles(blockSize: blockSize, first: first, counts: n, fills: fills), near: near)
        derived.sampling = sampling
        return sampling
    }

    /// How many tiles the blocks are sampled in.
    public var tileCount: Int { sampling.tiles.count }

    /// A share of 128 255ths or more is at least half.
    static let half: UInt8 = 128

    /// The blocks' corner nearest the domain's, and farthest from it, in metres.
    public var low: SIMD3<Float> { SIMD3<Float>(first) * blockSize }
    public var high: SIMD3<Float> { SIMD3<Float>(first &+ counts) * blockSize }

    /// The luminous gas's volume, in cubic metres.
    public var volume: Double {
        Double(fills.reduce(0) { $0 + Int($1) }) / 255 * pow(Double(blockSize), 3)
    }

    private func index(_ cell: SIMD3<Int>) -> Int {
        cell.x + Int(counts.x) * (cell.y + Int(counts.y) * cell.z)
    }

    private func inBox(_ cell: SIMD3<Int>) -> Bool {
        cell.x >= 0 && cell.y >= 0 && cell.z >= 0 && cell.x < Int(counts.x) && cell.y < Int(counts.y)
            && cell.z < Int(counts.z)
    }

    /// The block holding `point`, as an index into `fills`, if the box does.
    func block(containing point: SIMD3<Float>) -> Int? {
        let cell = SIMD3<Int>(floor((point - low) / blockSize))
        return inBox(cell) ? index(cell) : nil
    }

    /// The share of luminous air at `point`, in 255ths: the blocks' shares interpolated
    /// trilinearly between their centres, with none outside the box.
    func fill(at point: SIMD3<Float>) -> Float {
        let u = (point - low) / blockSize - 0.5
        let base = floor(u)
        let f = u - base
        let corner = SIMD3<Int>(base)
        var sum: Float = 0
        for dz in 0...1 {
            for dy in 0...1 {
                for dx in 0...1 {
                    let cell = corner &+ SIMD3(dx, dy, dz)
                    guard inBox(cell) else { continue }
                    let w = (dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z)
                    sum += w * Float(fills[index(cell)])
                }
            }
        }
        return sum
    }

    /// Whether `point` is within the flame.
    func isInside(_ point: SIMD3<Float>) -> Bool { fill(at: point) >= 127.5 }

    /// The block whose temperature the flame has at `point`: the one it is in if that has
    /// luminous gas, otherwise the most luminous of those whose centres are round it.
    func radiatingBlock(at point: SIMD3<Float>) -> Int? {
        let cell = SIMD3<Int>(floor((point - low) / blockSize))
        if inBox(cell), temperatures[index(cell)] > 0 { return index(cell) }
        let corner = SIMD3<Int>(floor((point - low) / blockSize - 0.5))
        var best: Int?
        for dz in 0...1 {
            for dy in 0...1 {
                for dx in 0...1 {
                    let cell = corner &+ SIMD3(dx, dy, dz)
                    guard inBox(cell), temperatures[index(cell)] > 0 else { continue }
                    if best.map({ fills[index(cell)] > fills[$0] }) ?? true { best = index(cell) }
                }
            }
        }
        return best
    }

    /// Where a ray from `origin` along the unit `direction` first meets the flame's surface: how
    /// far along it, and the block whose temperature it has there. Stepped through the blocks the
    /// ray crosses (Amanatides and Woo's traversal), looking for the surface in only those it may
    /// pass through, at four points across each and then by halving.
    func firstHit(from origin: SIMD3<Float>, along direction: SIMD3<Float>, near: [Bool]) -> (
        distance: Float, radiating: Int
    )? {
        let low = self.low
        let high = self.high
        // Where the ray is within the box, outside which there is no flame.
        var enter: Float = 0
        var leave = Float.infinity
        for axis in 0..<3 {
            if direction[axis] == 0 {
                if origin[axis] < low[axis] || origin[axis] > high[axis] { return nil }
                continue
            }
            var a = (low[axis] - origin[axis]) / direction[axis]
            var b = (high[axis] - origin[axis]) / direction[axis]
            if a > b { swap(&a, &b) }
            enter = max(enter, a)
            leave = min(leave, b)
        }
        guard enter <= leave else { return nil }
        let start = (origin + enter * direction - low) / blockSize
        var cell = SIMD3<Int>(
            simd_clamp(floor(start), SIMD3<Float>.zero, SIMD3<Float>(counts &- 1)))
        var step = SIMD3<Int>(repeating: 0)
        var next = SIMD3<Float>(repeating: .infinity)
        var delta = SIMD3<Float>(repeating: .infinity)
        for axis in 0..<3 where direction[axis] != 0 {
            step[axis] = direction[axis] > 0 ? 1 : -1
            let boundary = low[axis] + (Float(cell[axis]) + (direction[axis] > 0 ? 1 : 0)) * blockSize
            next[axis] = (boundary - origin[axis]) / direction[axis]
            delta[axis] = blockSize / abs(direction[axis])
        }
        var distance = enter
        // Each block's first point is the last block's last, already found outside, but for the
        // first block the ray meets that may hold the surface.
        var checked = false
        while true {
            let axis: Int
            if next.x < next.y {
                axis = next.x < next.z ? 0 : 2
            } else {
                axis = next.y < next.z ? 1 : 2
            }
            let end = min(next[axis], leave)
            if near[index(cell)] {
                var before = distance
                for n in (checked ? 1 : 0)...4 {
                    let t = distance + (end - distance) * Float(n) / 4
                    guard isInside(origin + t * direction) else {
                        before = t
                        continue
                    }
                    var (outside, inside) = (before, t)
                    if n > 0 {
                        for _ in 0..<6 {
                            let middle = 0.5 * (outside + inside)
                            if isInside(origin + middle * direction) {
                                inside = middle
                            } else {
                                outside = middle
                            }
                        }
                    }
                    guard let radiating = radiatingBlock(at: origin + inside * direction) else { return nil }
                    return (inside, radiating)
                }
                checked = true
            } else {
                checked = false
            }
            distance = next[axis]
            if distance > leave { return nil }
            cell[axis] += step[axis]
            if cell[axis] < 0 || cell[axis] >= Int(counts[axis]) { return nil }
            next[axis] += delta[axis]
        }
    }

    /// Gathers the blocks into compact tiles: starting from one tile of them all, the least
    /// compact (its luminous volume against that of the sphere round its half-luminous blocks) is
    /// cut in two across the longest side of those blocks, until every tile is at least
    /// `compactness` or there are `maximumTiles`. A sphere, a cube, a hemisphere on the ground or a
    /// box twice as long as it is wide stays one tile; a street full of fire becomes a row of them.
    static let compactness: Float = 0.2

    private static func tiles(
        blockSize: Float, first: SIMD3<Int32>, counts n: SIMD3<Int>, fills: [UInt8]
    ) -> [FireballTile] {
        let origin = SIMD3<Float>(first) * blockSize
        // The tile of the region from `low` up to `high`, if any block in or next to it is half
        // luminous: the surface can pass through the region only then.
        func tile(_ low: SIMD3<Int>, _ high: SIMD3<Int>) -> FireballTile? {
            var volume = 0.0
            var sum = SIMD3<Double>.zero
            var tight = (low: high, high: low)
            for k in low.z..<high.z {
                for j in low.y..<high.y {
                    for i in low.x..<high.x {
                        let fill = fills[i + n.x * (j + n.y * k)]
                        guard fill > 0 else { continue }
                        volume += Double(fill) / 255
                        sum += Double(fill) / 255 * (SIMD3(Double(i), Double(j), Double(k)) + 0.5)
                        if fill >= half {
                            tight.low = simd_min(tight.low, SIMD3(i, j, k))
                            tight.high = simd_max(tight.high, SIMD3(i + 1, j + 1, k + 1))
                        }
                    }
                }
            }
            let centre = volume > 0 ? SIMD3<Float>(sum / volume) : SIMD3<Float>(low &+ high) / 2
            // How far the half-luminous blocks' own cubes reach from the centre, which sets the
            // tile's compactness, and how far the surface can, which sets its sphere: a point of
            // the surface is within a block's width, along each axis, of the centre of a
            // half-luminous block, which may be just outside the region.
            var core: Float = 0
            var reach: Float = -1
            let outer = (low: simd_max(low &- 1, .zero), high: simd_min(high &+ 1, n))
            for k in outer.low.z..<outer.high.z {
                for j in outer.low.y..<outer.high.y {
                    for i in outer.low.x..<outer.high.x where fills[i + n.x * (j + n.y * k)] >= half {
                        let middle = SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5
                        let offset: SIMD3<Float> = abs(middle - centre)
                        reach = max(reach, simd_length(offset + 1))
                        let within =
                            i >= low.x && j >= low.y && k >= low.z && i < high.x && j < high.y && k < high.z
                        if within { core = max(core, simd_length(offset + 0.5)) }
                    }
                }
            }
            guard reach > 0 else { return nil }
            return FireballTile(
                low: low, high: high, tight: tight, centre: origin + centre * blockSize,
                radius: reach * blockSize,
                compactness: core > 0 ? Float(volume) / (4 / 3 * .pi * core * core * core) : 1)
        }
        guard let whole = tile(.zero, n) else { return [] }
        var tiles = [whole]
        while tiles.count < maximumTiles {
            var worst: Int?
            for (t, tile) in tiles.enumerated() {
                let size = tile.tight.high &- tile.tight.low
                guard tile.compactness < compactness, size.x > 1 || size.y > 1 || size.z > 1 else { continue }
                if worst.map({ tile.compactness < tiles[$0].compactness }) ?? true { worst = t }
            }
            guard let worst else { break }
            let parent = tiles[worst]
            let size = parent.tight.high &- parent.tight.low
            let axis = size.x >= size.y ? (size.x >= size.z ? 0 : 2) : (size.y >= size.z ? 1 : 2)
            var middle = parent.high
            middle[axis] = parent.tight.low[axis] + size[axis] / 2
            var start = parent.low
            start[axis] = middle[axis]
            tiles.replaceSubrange(
                worst...worst, with: [tile(parent.low, middle), tile(start, parent.high)].compactMap { $0 })
        }
        return tiles
    }
}

extension ThermalExposure {
    /// One receiver's view of the fireball's shape, adding the rays it needs tested to `rays`.
    /// The flame radiates evenly from its surface, a radiance of εσT⁴ / π at the temperature of
    /// the block it meets there, so the irradiance is the integral of that radiance times cos θ
    /// over the directions in which the receiver sees the flame. Those directions are sampled tile
    /// by tile, evenly over the cone each tile's sphere subtends (or the hemisphere above the
    /// receiver, from within the sphere), with the samples shared out by each cone's solid angle
    /// and how much of it the tile fills, at least four a tile. Where the cones overlap, a
    /// direction may be drawn from any of them, so each ray counts for its radiance times cos θ
    /// over the density of samples there from all the cones it lies in (Veach's balance
    /// heuristic): every ray that meets the flame counts, and nothing is counted twice. The flame
    /// in front hides what is behind. For one compact tile this is the sphere's sampling, over
    /// the flame's own outline.
    func view(from receiver: ThermalReceiver, _ shape: FireballShape, rays: inout [ThermalRay]) -> View {
        let scale = Float(Double(spec.emissivity) * Self.stefanBoltzmann)
        func exitance(_ temperature: UInt16) -> Float {
            let square = Float(temperature) * Float(temperature)
            return scale * square * square
        }
        let x = receiver.position
        // Within the flame, surrounded by it: the hemisphere above radiates in full.
        if shape.isInside(x) {
            return .settled(shape.radiatingBlock(at: x).map { exitance(shape.temperatures[$0]) } ?? 0)
        }
        struct Cone {
            var axis: SIMD3<Float>
            var cosHalfAngle: Float
            var solidAngle: Float
            var share: Float
        }
        var cones: [Cone] = []
        let sampling = shape.sampling
        for tile in sampling.tiles {
            let toCentre = tile.centre - x
            let d = simd_length(toCentre)
            var cone: Cone
            if d <= tile.radius {
                cone = Cone(axis: receiver.normal, cosHalfAngle: 0, solidAngle: 2 * .pi, share: 0)
            } else {
                // The whole tile is below this surface's horizon.
                if simd_dot(receiver.normal, toCentre) < -tile.radius { continue }
                let cosHalfAngle = sqrt(max(0, 1 - (tile.radius / d) * (tile.radius / d)))
                cone = Cone(
                    axis: toCentre / d, cosHalfAngle: cosHalfAngle,
                    solidAngle: 2 * .pi * (1 - cosHalfAngle), share: 0)
            }
            cone.share = cone.solidAngle * pow(min(tile.compactness, 1), 2 / 3)
            cones.append(cone)
        }
        let total = cones.reduce(0) { $0 + $1.share }
        guard total > 0 else { return .settled(0) }
        // Each cone's samples, and their density in solid angle.
        let counts = cones.map { max(4, Int((Float(spec.samples) * $0.share / total).rounded())) }
        let densities = zip(cones, counts).map { Float($1) / $0.solidAngle }
        var weights: [Float] = []
        for (c, cone) in cones.enumerated() {
            let count = counts[c]
            let axis = cone.axis
            // Two directions square to the axis, for the cone's samples.
            let helper: SIMD3<Float> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            let u = simd_normalize(simd_cross(axis, helper))
            let v = simd_cross(axis, u)
            for s in 0..<count {
                let cosine = 1 - (Float(s) + 0.5) / Float(count) * (1 - cone.cosHalfAngle)
                let sine = sqrt(max(0, 1 - cosine * cosine))
                let direction = cosine * axis + sine * (self.cone[s].y * u + self.cone[s].z * v)
                let cosReceiver = simd_dot(receiver.normal, direction)
                guard cosReceiver > 0,
                    let hit = shape.firstHit(from: x, along: direction, near: sampling.near)
                else { continue }
                // The density of samples in this direction from every cone it lies in.
                var density = densities[c]
                for (other, cone) in cones.enumerated()
                where other != c && simd_dot(direction, cone.axis) >= cone.cosHalfAngle {
                    density += densities[other]
                }
                rays.append(ThermalRay(origin: x, direction: direction, length: hit.distance))
                weights.append(cosReceiver * exitance(shape.temperatures[hit.radiating]) / .pi / density)
            }
        }
        return .weighted(weights: weights, cap: exitance(shape.hottest))
    }
}

/// A region of the fireball's blocks sampled as one: the blocks from `low` up to `high`, those at
/// least half luminous within `tight`, and the sphere within which the flame's surface in the
/// region lies.
struct FireballTile: Sendable, Equatable {
    var low: SIMD3<Int>
    var high: SIMD3<Int>
    var tight: (low: SIMD3<Int>, high: SIMD3<Int>)
    var centre: SIMD3<Float>
    var radius: Float
    /// The luminous volume against that of the sphere round its half-luminous blocks.
    var compactness: Float

    static func == (a: Self, b: Self) -> Bool {
        a.low == b.low && a.high == b.high && a.tight.low == b.tight.low && a.tight.high == b.tight.high
            && a.centre == b.centre && a.radius == b.radius && a.compactness == b.compactness
    }
}

extension FireballShape: Codable {
    private enum CodingKeys: String, CodingKey {
        case blockSize, first, counts, fills, temperatures
    }

    /// The shares travel as bytes and the temperatures as little-endian 16-bit integers, both
    /// base64 in JSON.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let counts = try values.decode(SIMD3<Int32>.self, forKey: .counts)
        let fills = try values.decode(Data.self, forKey: .fills)
        let data = try values.decode(Data.self, forKey: .temperatures)
        let count = Int(counts.x) * Int(counts.y) * Int(counts.z)
        guard counts.x > 0, counts.y > 0, counts.z > 0, count <= Self.maximumBlocks, fills.count == count,
            data.count == 2 * count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .temperatures, in: values,
                debugDescription: "The fireball's blocks do not fill their box.")
        }
        let temperatures = data.withUnsafeBytes { bytes in
            (0..<count).map {
                UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self))
            }
        }
        self.init(
            blockSize: try values.decode(Float.self, forKey: .blockSize),
            first: try values.decode(SIMD3<Int32>.self, forKey: .first), counts: counts,
            fills: [UInt8](fills),
            temperatures: temperatures)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(blockSize, forKey: .blockSize)
        try values.encode(first, forKey: .first)
        try values.encode(counts, forKey: .counts)
        try values.encode(Data(fills), forKey: .fills)
        var data = Data(capacity: 2 * temperatures.count)
        for t in temperatures {
            withUnsafeBytes(of: t.littleEndian) { data.append(contentsOf: $0) }
        }
        try values.encode(data, forKey: .temperatures)
    }
}

/// A block of two cells a side with luminous gas in it, as the GPU (`extractFireballBlocks`) or
/// the CPU sums it: its index, `i + nx (j + ny k)` in blocks, how many of its cells are luminous,
/// the sum of their T⁴ and the hottest, the sum of their cell coordinates + 1/2, and how many of
/// its cells are air.
struct LuminousBlock: Equatable {
    var index: Int
    var cells: Float
    var fourth: Float
    var hottest: Float
    var position: SIMD3<Float>
    var air: Float

    /// How many blocks the grid spans along each axis.
    static func dimensions(_ grid: Grid) -> SIMD3<Int> {
        SIMD3((grid.nx + 1) / 2, (grid.ny + 1) / 2, (grid.nz + 1) / 2)
    }
}

extension FireballShape {
    /// The shape of the luminous gas in `blocks` (in order of their index), or nil if no block is
    /// at least half luminous.
    init?(blocks: [LuminousBlock], grid: Grid) {
        guard !blocks.isEmpty else { return nil }
        let dims = LuminousBlock.dimensions(grid)
        let cellsAcross = SIMD3(grid.nx, grid.ny, grid.nz)
        func coordinates(_ index: Int) -> SIMD3<Int> {
            SIMD3(index % dims.x, (index / dims.x) % dims.y, index / (dims.x * dims.y))
        }
        // Cells of the grid in a block of `edge` cells a side at `corner`, in cells.
        func cellsWithin(_ corner: SIMD3<Int>, _ edge: Int) -> Int {
            let top = simd_min(corner &+ edge, cellsAcross)
            let span = simd_max(top &- corner, .zero)
            return span.x * span.y * span.z
        }
        // The small blocks' box.
        var lowest = coordinates(blocks[0].index)
        var highest = lowest
        for block in blocks {
            let at = coordinates(block.index)
            lowest = simd_min(lowest, at)
            highest = simd_max(highest, at)
        }
        var scale = 1
        while true {
            // Blocks of `scale` small blocks a side, over the small blocks' box: their luminous
            // cells, the sum of their T⁴, and the cells known to be solid, added in the small
            // blocks' order. The small blocks with no luminous gas are taken to be all air.
            let base = lowest / scale
            let span = highest / scale &- base &+ 1
            var cells = [Double](repeating: 0, count: span.x * span.y * span.z)
            var fourth = cells
            var solid = cells
            for block in blocks {
                let at = coordinates(block.index)
                let key = at / scale &- base
                let index = key.x + span.x * (key.y + span.y * key.z)
                cells[index] += Double(block.cells)
                fourth[index] += Double(block.fourth)
                solid[index] += Double(cellsWithin(2 &* at, 2)) - Double(block.air)
            }
            var low = span
            var high = SIMD3<Int>(repeating: -1)
            var half = false
            var fills = [UInt8](repeating: 0, count: cells.count)
            for k in 0..<span.z {
                for j in 0..<span.y {
                    for i in 0..<span.x {
                        let index = i + span.x * (j + span.y * k)
                        guard cells[index] > 0 else { continue }
                        let air =
                            Double(cellsWithin(2 * scale &* (base &+ SIMD3(i, j, k)), 2 * scale))
                            - solid[index]
                        guard air > 0 else { continue }
                        fills[index] = UInt8(min(255, max(1, (255 * cells[index] / air).rounded())))
                        half = half || fills[index] >= Self.half
                        low = simd_min(low, SIMD3(i, j, k))
                        high = simd_max(high, SIMD3(i, j, k))
                    }
                }
            }
            guard half else { return nil }
            let counts = high &- low &+ 1
            if counts.x * counts.y * counts.z <= Self.maximumBlocks {
                var kept = [UInt8](repeating: 0, count: counts.x * counts.y * counts.z)
                var temperatures = [UInt16](repeating: 0, count: kept.count)
                for k in 0..<counts.z {
                    for j in 0..<counts.y {
                        for i in 0..<counts.x {
                            let index = (low.x + i) + span.x * ((low.y + j) + span.y * (low.z + k))
                            guard fills[index] > 0 else { continue }
                            let n = i + counts.x * (j + counts.y * k)
                            kept[n] = fills[index]
                            let temperature = (fourth[index] / cells[index]).squareRoot().squareRoot()
                            temperatures[n] = UInt16(clamping: max(1, Int(temperature.rounded())))
                        }
                    }
                }
                self.init(
                    blockSize: Float(2 * scale) * grid.cellSize,
                    first: SIMD3<Int32>(truncatingIfNeeded: base &+ low),
                    counts: SIMD3<Int32>(truncatingIfNeeded: counts), fills: kept, temperatures: temperatures)
                return
            }
            scale *= 2
        }
    }
}

extension BlastSolver {
    /// The luminous gas in blocks of two cells a side, read from the state on the CPU as the GPU's
    /// `extractFireballBlocks` sums it, spread across the CPU's cores.
    func cpuLuminousBlocks(luminousTemperature: Float) -> [LuminousBlock] {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let dims = LuminousBlock.dimensions(grid)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var planes = [[LuminousBlock]](repeating: [], count: dims.z)
        withState { cells in
            planes.withUnsafeMutableBufferPointer { planes in
                DispatchQueue.concurrentPerform(iterations: dims.z) { bk in
                    var plane: [LuminousBlock] = []
                    for bj in 0..<dims.y {
                        for bi in 0..<dims.x {
                            var block = LuminousBlock(
                                index: bi + dims.x * (bj + dims.y * bk), cells: 0, fourth: 0, hottest: 0,
                                position: .zero, air: 0)
                            for k in 2 * bk..<min(2 * bk + 2, nz) {
                                for j in 2 * bj..<min(2 * bj + 2, ny) {
                                    for i in 2 * bi..<min(2 * bi + 2, nx) {
                                        let index = grid.index(i, j, k)
                                        guard mask[index] == 0 else { continue }
                                        block.air += 1
                                        let air = Self.primitive(
                                            of: cells[index], gamma: gamma, airModel: airModel)
                                        // Dissociating air is never hotter than this, so it bounds
                                        // the search.
                                        let bound = air.pressure / (air.density * AirModel.gasConstant)
                                        guard bound >= luminousTemperature else { continue }
                                        let t =
                                            airModel == .dissociating
                                            ? airModel.temperature(
                                                density: air.density, pressure: air.pressure)
                                            : bound
                                        guard t >= luminousTemperature, t.isFinite else { continue }
                                        block.cells += 1
                                        block.position += SIMD3(Float(i), Float(j), Float(k)) + 0.5
                                        let square = t * t
                                        block.fourth += square * square
                                        block.hottest = max(block.hottest, t)
                                    }
                                }
                            }
                            if block.cells > 0 { plane.append(block) }
                        }
                    }
                    planes[bk] = plane
                }
            }
        }
        return planes.flatMap { $0 }
    }
}
