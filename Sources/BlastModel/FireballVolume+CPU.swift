import Foundation
import simd

/// The fireball's luminous gas cell by cell, as the volume model takes it: a box of voxels
/// `voxelSize` a side, each with the share of its air that is luminous, that gas's temperature (the
/// fourth root of its mean T⁴) and the density of its unburnt detonation products. The voxels are
/// the air's own cells, merged in twos, fours and so on only when the box would otherwise hold
/// more than `maximumVoxels`; a cell's share is then all or none.
public struct LuminousCells: Sendable, Equatable {
    /// The most voxels in the box: 5 MB a frame with the products.
    public static let maximumVoxels = 1 << 20

    /// Each voxel's edge, in metres.
    public let voxelSize: Float
    /// The box's first voxel along each axis, counting from the domain's corner, and how many it
    /// spans.
    public let first: SIMD3<Int32>
    public let counts: SIMD3<Int32>
    /// Each voxel's share of luminous air, in 255ths, x fastest, then y, then z.
    public let fills: [UInt8]
    /// Each voxel's luminous gas's temperature in kelvin; zero where it has none.
    public let temperatures: [UInt16]
    /// The density of unburnt detonation products in each voxel's luminous gas, kg/m³; nil
    /// without afterburning, which alone keeps track of them.
    public let products: [Float16]?
    /// Each voxel's luminous gas's own absorption as hot air (`HotAir`), the mean of its cells',
    /// 1/m; nil where it was not reckoned, as by frames from before 19 October 2026.
    public let airAbsorption: [Float16]?

    public init(
        voxelSize: Float, first: SIMD3<Int32>, counts: SIMD3<Int32>, fills: [UInt8], temperatures: [UInt16],
        products: [Float16]?, airAbsorption: [Float16]? = nil
    ) {
        precondition(Int(counts.x) * Int(counts.y) * Int(counts.z) == fills.count)
        precondition(fills.count == temperatures.count && (products?.count ?? fills.count) == fills.count)
        precondition((airAbsorption?.count ?? fills.count) == fills.count)
        self.voxelSize = voxelSize
        self.first = first
        self.counts = counts
        self.fills = fills
        self.temperatures = temperatures
        self.products = products
        self.airAbsorption = airAbsorption
    }

    /// The box's corner nearest the domain's, and farthest from it, in metres.
    public var low: SIMD3<Float> { SIMD3<Float>(first) * voxelSize }
    public var high: SIMD3<Float> { SIMD3<Float>(first &+ counts) * voxelSize }

    /// The luminous gas's volume, in cubic metres.
    public var volume: Double {
        Double(fills.reduce(0) { $0 + Int($1) }) / 255 * pow(Double(voxelSize), 3)
    }
}

extension LuminousCells {
    /// From each cell of the box of `counts` cells from `low`, packed as `extractLuminousCells`
    /// writes them (in x the temperature in kelvin in the low 16 bits, the products' density as a
    /// half float in the high; in y its absorption as hot air as a half) and read through `packed`
    /// by the cell's index in the box, x fastest.
    /// Cells are merged in blocks of 2, 4, … a side, aligned on the grid, until the box holds no
    /// more than `maximumVoxels`. Nil if no cell is luminous.
    package init?(
        cellSize: Float, low: SIMD3<Int>, counts: SIMD3<Int>, hasProducts: Bool,
        packed: (Int) -> SIMD2<UInt32>
    ) {
        guard counts.x > 0, counts.y > 0, counts.z > 0 else { return nil }
        var scale = 1
        func span(_ scale: Int) -> (base: SIMD3<Int>, span: SIMD3<Int>) {
            let base = low / scale
            return (base, (low &+ counts &- 1) / scale &- base &+ 1)
        }
        while true {
            let n = span(scale).span
            if n.x * n.y * n.z <= Self.maximumVoxels { break }
            scale *= 2
        }
        let (base, n) = span(scale)
        let total = n.x * n.y * n.z
        var fills = [UInt8](repeating: 0, count: total)
        var temperatures = [UInt16](repeating: 0, count: total)
        var products = [Float16](repeating: 0, count: hasProducts ? total : 0)
        var absorption = [Float16](repeating: 0, count: total)
        let perVoxel = Double(scale * scale * scale)
        let any = Flag()
        fills.withUnsafeMutableBufferPointer { fills in
            temperatures.withUnsafeMutableBufferPointer { temperatures in
                products.withUnsafeMutableBufferPointer { products in
                    absorption.withUnsafeMutableBufferPointer { absorption in
                        // A plane of voxels at a time, across the cores; each voxel's cells in order.
                        concurrently(iterations: n.z) { c in
                            var found = false
                            for b in 0..<n.y {
                                for a in 0..<n.x {
                                    let corner = (base &+ SIMD3(a, b, c)) &* scale
                                    let from = simd_max(corner, low) &- low
                                    let to = simd_min(corner &+ scale, low &+ counts) &- low
                                    var cells = 0
                                    var fourth = 0.0
                                    var density = 0.0
                                    var air = 0.0
                                    for k in from.z..<to.z {
                                        for j in from.y..<to.y {
                                            for i in from.x..<to.x {
                                                let both = packed(i + counts.x * (j + counts.y * k))
                                                let value = both.x
                                                let kelvin = value & 0xFFFF
                                                guard kelvin > 0 else { continue }
                                                cells += 1
                                                let t = Double(kelvin)
                                                fourth += t * t * t * t
                                                density += Double(Float16(bitPattern: UInt16(value >> 16)))
                                                air += Double(
                                                    Float16(bitPattern: UInt16(truncatingIfNeeded: both.y)))
                                            }
                                        }
                                    }
                                    guard cells > 0 else { continue }
                                    found = true
                                    let v = a + n.x * (b + n.y * c)
                                    fills[v] = UInt8(
                                        min(255, max(1, (255 * Double(cells) / perVoxel).rounded())))
                                    temperatures[v] = UInt16(
                                        clamping: max(
                                            1,
                                            Int((fourth / Double(cells)).squareRoot().squareRoot().rounded()))
                                    )
                                    if hasProducts { products[v] = Float16(density / Double(cells)) }
                                    absorption[v] = Float16(min(air / Double(cells), 65504))
                                }
                            }
                            if found { any.set() }
                        }
                    }
                }
            }
        }
        guard any.isSet else { return nil }
        self.init(
            voxelSize: Float(scale) * cellSize, first: SIMD3<Int32>(truncatingIfNeeded: base),
            counts: SIMD3<Int32>(truncatingIfNeeded: n), fills: fills, temperatures: temperatures,
            products: hasProducts ? products : nil, airAbsorption: absorption)
    }

    /// Bytes a voxel takes as it travels.
    public var bytesPerVoxel: Int { 3 + (products == nil ? 0 : 2) + (airAbsorption == nil ? 0 : 2) }

    /// As it travels to a worker, after the frame's JSON: the voxel's edge as a float, the first
    /// voxel and the counts as six 32-bit integers, which of the products (bit 0) and the hot air's
    /// absorption (bit 1) follow, then the shares, the temperatures, any products' densities and
    /// any absorptions, all little-endian.
    public var binary: Data {
        var data = Data(capacity: 32 + fills.count * bytesPerVoxel)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(voxelSize.bitPattern)
        for value in [first.x, first.y, first.z, counts.x, counts.y, counts.z] { append(value) }
        append(UInt32(products == nil ? 0 : 1) | UInt32(airAbsorption == nil ? 0 : 2))
        data.append(contentsOf: fills)
        for t in temperatures { append(t) }
        for p in products ?? [] { append(p.bitPattern) }
        for a in airAbsorption ?? [] { append(a.bitPattern) }
        return data
    }

    public init(binary data: Data) throws {
        let bad = CocoaError(
            .coderReadCorrupt,
            userInfo: [NSLocalizedDescriptionKey: "The fireball's cells arrived cut short."])
        guard data.count >= 32 else { throw bad }
        let words = data.withUnsafeBytes { raw in
            (0..<8).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)) }
        }
        let first = SIMD3<Int32>(
            Int32(bitPattern: words[1]), Int32(bitPattern: words[2]), Int32(bitPattern: words[3]))
        let counts = SIMD3<Int32>(
            Int32(bitPattern: words[4]), Int32(bitPattern: words[5]), Int32(bitPattern: words[6]))
        let hasProducts = words[7] & 1 != 0
        let hasAbsorption = words[7] & 2 != 0
        guard counts.x > 0, counts.y > 0, counts.z > 0, words[7] < 4 else { throw bad }
        let count = Int(counts.x) * Int(counts.y) * Int(counts.z)
        let perVoxel = 3 + (hasProducts ? 2 : 0) + (hasAbsorption ? 2 : 0)
        guard count <= Self.maximumVoxels, data.count == 32 + count * perVoxel else { throw bad }
        let (fills, temperatures, products, absorption) = data.withUnsafeBytes { raw in
            let fills = [UInt8](raw[32..<32 + count])
            let temperatures = (0..<count).map {
                UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 32 + count + 2 * $0, as: UInt16.self))
            }
            let products: [Float16]? =
                hasProducts
                ? (0..<count).map {
                    Float16(
                        bitPattern: UInt16(
                            littleEndian: raw.loadUnaligned(
                                fromByteOffset: 32 + 3 * count + 2 * $0, as: UInt16.self)))
                } : nil
            let from = 32 + (hasProducts ? 5 : 3) * count
            let absorption: [Float16]? =
                hasAbsorption
                ? (0..<count).map {
                    Float16(
                        bitPattern: UInt16(
                            littleEndian: raw.loadUnaligned(fromByteOffset: from + 2 * $0, as: UInt16.self)))
                } : nil
            return (fills, temperatures, products, absorption)
        }
        self.init(
            voxelSize: Float(bitPattern: words[0]), first: first, counts: counts, fills: fills,
            temperatures: temperatures, products: products, airAbsorption: absorption)
    }
}

extension LuminousCells: Codable {
    private enum CodingKeys: String, CodingKey {
        case cells
    }

    /// As JSON, the binary form in base64.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(binary: try values.decode(Data.self, forKey: .cells))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(binary, forKey: .cells)
    }
}

/// The cones a receiver's directions are drawn from, one a tile, as `ThermalExposure.view` draws
/// them for the shape: each tile's sphere, or the hemisphere above the receiver from within it,
/// with the samples shared by each cone's solid angle and how much of it the tile fills, at least
/// four a cone.
package struct SamplingCone {
    package var axis: SIMD3<Float>
    package var cosHalfAngle: Float
    package var solidAngle: Float
    package var count: Int
    /// Samples a steradian.
    package var density: Float

    package static func cones(at x: SIMD3<Float>, normal: SIMD3<Float>, tiles: [FireballTile], samples: Int)
        -> [SamplingCone]
    {
        var cones: [SamplingCone] = []
        var shares: [Float] = []
        for tile in tiles {
            let toCentre = tile.centre - x
            let d = simd_length(toCentre)
            var cone: SamplingCone
            if d <= tile.radius {
                cone = SamplingCone(axis: normal, cosHalfAngle: 0, solidAngle: 2 * .pi, count: 0, density: 0)
            } else {
                if simd_dot(normal, toCentre) < -tile.radius { continue }
                let cosHalfAngle = sqrt(max(0, 1 - (tile.radius / d) * (tile.radius / d)))
                cone = SamplingCone(
                    axis: toCentre / d, cosHalfAngle: cosHalfAngle, solidAngle: 2 * .pi * (1 - cosHalfAngle),
                    count: 0, density: 0)
            }
            cones.append(cone)
            shares.append(cone.solidAngle * pow(min(tile.compactness, 1), 2 / 3))
        }
        let total = shares.reduce(0, +)
        guard total > 0 else { return [] }
        for c in cones.indices {
            cones[c].count = max(4, Int((Float(samples) * shares[c] / total).rounded()))
            cones[c].density = Float(cones[c].count) / cones[c].solidAngle
        }
        return cones
    }

    /// The `s`th of the cone's directions, `spiral` the spread of `ThermalExposure.spread`.
    package func direction(_ s: Int, spiral: [SIMD3<Float>]) -> SIMD3<Float> {
        let helper: SIMD3<Float> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(axis, helper))
        let v = simd_cross(axis, u)
        let cosine = 1 - (Float(s) + 0.5) / Float(count) * (1 - cosHalfAngle)
        let sine = sqrt(max(0, 1 - cosine * cosine))
        return cosine * axis + sine * (spiral[s].y * u + spiral[s].z * v)
    }
}

/// Receivers the march is asked about again and again, kept on the GPU once there.
package final class ThermalReceiverSet: @unchecked Sendable {
    package let receivers: [ThermalReceiver]
    package let lock = NSLock()
    /// Whatever the GPU keeps of them.
    package var cached: AnyObject?

    package init(_ receivers: [ThermalReceiver]) {
        self.receivers = receivers
    }
}
