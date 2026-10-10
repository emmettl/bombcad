import Compression
import Foundation
import simd

/// Writes float grids in OpenVDB's file format, without the OpenVDB library: enough for Blender,
/// Houdini or USD to read a sampled volume. Only what that needs is written: a standard
/// `Tree_float_5_4_3` (a root over 4096³ and 128³ internal nodes over 8³ leaves), an affine
/// transform, and the leaves that hold an active voxel. File format version 224; values zipped
/// when that makes them smaller, as OpenVDB's own ZIP compression does.
///
/// The layout follows OpenVDB's `io::Archive`, `GridDescriptor`, `RootNode`, `InternalNode` and
/// `LeafNode` writers (OpenVDB 11).
public enum OpenVDBWriter {
    /// A dense block of samples on a regular grid, voxel (0, 0, 0) centred at `origin`.
    public struct Grid {
        public var name: String
        public var dimensions: SIMD3<Int>
        public var voxelSize: Double
        public var origin: SIMD3<Double>
        /// Samples with x varying fastest, then y, then z.
        public var values: [Float]
        /// Voxels whose magnitude reaches this are active; the rest are left out at zero.
        public var threshold: Float
        /// Written as the grid's class: "fog volume" for densities, "unknown" for anything else.
        public var gridClass: String

        public init(
            name: String, dimensions: SIMD3<Int>, voxelSize: Double, origin: SIMD3<Double>, values: [Float],
            threshold: Float, gridClass: String = "unknown"
        ) {
            precondition(values.count == dimensions.x * dimensions.y * dimensions.z)
            self.name = name
            self.dimensions = dimensions
            self.voxelSize = voxelSize
            self.origin = origin
            self.values = values
            self.threshold = threshold
            self.gridClass = gridClass
        }
    }

    static let fileVersion: UInt32 = 224
    static let compressNone: UInt32 = 0
    static let compressZip: UInt32 = 1

    /// `metadata` is the file's own, as strings: names and values.
    public static func data(_ grids: [Grid], compress: Bool = true, metadata: [(String, String)] = []) -> Data
    {
        var out = Output()
        // Header: magic, file and library versions, grid offsets present, then a UUID as text.
        out.int64(0x5644_4220)
        out.uint32(fileVersion)
        out.uint32(11)
        out.uint32(0)
        out.byte(1)
        out.bytes(Array(UUID().uuidString.lowercased().utf8))
        out.uint32(UInt32(metadata.count))
        for (name, value) in metadata {
            out.string(name)
            out.string("string")
            let bytes = Array(value.utf8)
            out.uint32(UInt32(bytes.count))
            out.bytes(bytes)
        }
        out.int32(Int32(grids.count))
        for grid in grids {
            write(grid, compression: compress ? compressZip : compressNone, to: &out)
        }
        return Data(out.data)
    }

    public static func write(
        _ grids: [Grid], to url: URL, compress: Bool = true, metadata: [(String, String)] = []
    ) throws {
        try data(grids, compress: compress, metadata: metadata).write(to: url, options: .withoutOverwriting)
    }

    private struct Leaf {
        var origin: SIMD3<Int32>
        var mask: [UInt64]
        var values: [Float]
    }

    private static func write(_ grid: Grid, compression: UInt32, to out: inout Output) {
        let leaves = self.leaves(grid)
        let bounds = leaves.isEmpty ? nil : activeBounds(leaves)

        // Grid descriptor: unique name, tree type, instance parent, then three stream offsets
        // filled in once known.
        out.string(grid.name)
        out.string("Tree_float_5_4_3")
        out.string("")
        let offsets = out.data.count
        out.int64(0)
        out.int64(0)
        out.int64(0)
        let gridStart = out.data.count

        out.uint32(compression)
        var metadata: [(String, String, [UInt8])] = [
            ("class", "string", Array(grid.gridClass.utf8)),
            ("name", "string", Array(grid.name.utf8)),
        ]
        if let bounds {
            var low = Output()
            for v in [bounds.low.x, bounds.low.y, bounds.low.z] { low.int32(v) }
            var high = Output()
            for v in [bounds.high.x, bounds.high.y, bounds.high.z] { high.int32(v) }
            metadata += [("file_bbox_min", "vec3i", low.data), ("file_bbox_max", "vec3i", high.data)]
        }
        out.uint32(UInt32(metadata.count))
        for (name, type, value) in metadata {
            out.string(name)
            out.string(type)
            out.uint32(UInt32(value.count))
            out.bytes(value)
        }

        // Transform: an affine map, OpenVDB's row-vector matrix with the translation in the last row.
        out.string("AffineMap")
        let h = grid.voxelSize
        for row in [
            SIMD4(h, 0, 0, 0), SIMD4(0, h, 0, 0), SIMD4(0, 0, h, 0),
            SIMD4(grid.origin.x, grid.origin.y, grid.origin.z, 1),
        ] {
            for n in 0..<4 { out.double(row[n]) }
        }

        // Topology: one buffer; the root's background, its tiles and its children, each child an
        // internal node over 4096³ with its masks, values and own children, down to the leaves'
        // value masks.
        let tree = Tree(leaves)
        out.int32(1)
        out.float(0)
        out.uint32(0)
        out.uint32(UInt32(tree.upper.count))
        for upper in tree.upper {
            for v in [upper.origin.x, upper.origin.y, upper.origin.z] { out.int32(v) }
            writeInternal(childMask: upper.childMask, count: 32_768, compression: compression, to: &out)
            for lower in upper.children {
                writeInternal(childMask: lower.childMask, count: 4096, compression: compression, to: &out)
                for leaf in lower.leaves { out.words(leaves[leaf].mask) }
            }
        }
        let blockStart = out.data.count

        // Buffers: every leaf again, in the same order, with its mask and values.
        for upper in tree.upper {
            for lower in upper.children {
                for index in lower.leaves {
                    let leaf = leaves[index]
                    out.words(leaf.mask)
                    out.byte(6)  // all values follow, no mask compression
                    out.values(leaf.values, compression: compression)
                }
            }
        }
        let end = out.data.count
        out.setInt64(Int64(gridStart), at: offsets)
        out.setInt64(Int64(blockStart), at: offsets + 8)
        out.setInt64(Int64(end), at: offsets + 16)
    }

    /// An internal node's topology: its child mask, an empty value mask, and its values (all zero,
    /// the background, since every slot is either a child or an inactive tile).
    private static func writeInternal(
        childMask: [UInt64], count: Int, compression: UInt32, to out: inout Output
    ) {
        out.words(childMask)
        out.words([UInt64](repeating: 0, count: count / 64))
        out.byte(6)
        out.values([Float](repeating: 0, count: count), compression: compression)
    }

    /// The 8³ leaves holding at least one active voxel. Within a leaf, z varies fastest.
    private static func leaves(_ grid: Grid) -> [Leaf] {
        let d = grid.dimensions
        let blocks = (d &+ 7) / 8
        var leaves: [Leaf] = []
        for bx in 0..<blocks.x {
            for by in 0..<blocks.y {
                for bz in 0..<blocks.z {
                    var mask = [UInt64](repeating: 0, count: 8)
                    var values = [Float](repeating: 0, count: 512)
                    var any = false
                    for x in 0..<8 {
                        let i = bx * 8 + x
                        guard i < d.x else { break }
                        for y in 0..<8 {
                            let j = by * 8 + y
                            guard j < d.y else { break }
                            for z in 0..<8 {
                                let k = bz * 8 + z
                                guard k < d.z else { break }
                                let value = grid.values[i + d.x * (j + d.y * k)]
                                guard abs(value) >= grid.threshold, value.isFinite else { continue }
                                let offset = (x << 6) | (y << 3) | z
                                mask[offset >> 6] |= 1 << UInt64(offset & 63)
                                values[offset] = value
                                any = true
                            }
                        }
                    }
                    if any {
                        leaves.append(
                            Leaf(
                                origin: SIMD3(Int32(bx * 8), Int32(by * 8), Int32(bz * 8)), mask: mask,
                                values: values))
                    }
                }
            }
        }
        return leaves
    }

    private static func activeBounds(_ leaves: [Leaf]) -> (low: SIMD3<Int32>, high: SIMD3<Int32>) {
        var low = SIMD3<Int32>(repeating: .max)
        var high = SIMD3<Int32>(repeating: .min)
        for leaf in leaves {
            for offset in 0..<512 where leaf.mask[offset >> 6] & (1 << UInt64(offset & 63)) != 0 {
                let p = leaf.origin &+ SIMD3(Int32(offset >> 6), Int32((offset >> 3) & 7), Int32(offset & 7))
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        return (low, high)
    }

    /// The internal nodes over the leaves, each list in the order OpenVDB writes them: the root's
    /// children by origin (x, then y, then z), an internal node's children by their slot, in
    /// which x is the most significant.
    private struct Tree {
        struct Lower {
            var origin: SIMD3<Int32>
            var childMask = [UInt64](repeating: 0, count: 64)
            var leaves: [Int] = []
        }
        struct Upper {
            var origin: SIMD3<Int32>
            var childMask = [UInt64](repeating: 0, count: 512)
            var children: [Lower] = []
        }
        var upper: [Upper] = []

        init(_ leaves: [Leaf]) {
            func slot(_ p: SIMD3<Int32>, _ shift: Int32, _ bits: Int32) -> Int {
                let mask = Int32((1 << bits) - 1)
                let c = (p &>> shift) & mask
                return Int((c.x << (2 * bits)) | (c.y << bits) | c.z)
            }
            func lexicographic(_ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> Bool {
                (a.x, a.y, a.z) < (b.x, b.y, b.z)
            }
            var lowers: [SIMD3<Int32>: Lower] = [:]
            for (index, leaf) in leaves.enumerated() {
                let origin = leaf.origin & ~127
                lowers[origin, default: Lower(origin: origin)].leaves.append(index)
            }
            var uppers: [SIMD3<Int32>: Upper] = [:]
            for var lower in lowers.values {
                lower.leaves.sort { slot(leaves[$0].origin, 3, 4) < slot(leaves[$1].origin, 3, 4) }
                for index in lower.leaves {
                    let s = slot(leaves[index].origin, 3, 4)
                    lower.childMask[s >> 6] |= 1 << UInt64(s & 63)
                }
                let origin = lower.origin & ~4095
                uppers[origin, default: Upper(origin: origin)].children.append(lower)
            }
            upper = uppers.values.sorted { lexicographic($0.origin, $1.origin) }.map { node in
                var node = node
                node.children.sort { slot($0.origin, 7, 5) < slot($1.origin, 7, 5) }
                for child in node.children {
                    let s = slot(child.origin, 7, 5)
                    node.childMask[s >> 6] |= 1 << UInt64(s & 63)
                }
                return node
            }
        }
    }

    /// Little-endian output.
    struct Output {
        var data: [UInt8] = []

        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func bytes(_ values: [UInt8]) { data.append(contentsOf: values) }
        mutating func uint32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        mutating func int32(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        mutating func int64(_ value: Int64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        mutating func float(_ value: Float) { uint32(value.bitPattern) }
        mutating func double(_ value: Double) { int64(Int64(bitPattern: value.bitPattern)) }
        mutating func words(_ values: [UInt64]) {
            for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        }
        /// A length-prefixed string, as OpenVDB's `writeString`.
        mutating func string(_ value: String) {
            let bytes = Array(value.utf8)
            uint32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
        mutating func setInt64(_ value: Int64, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 8, with: $0) }
        }

        /// Float values, raw or, as OpenVDB's `zipToStream`, zlib-compressed behind their
        /// compressed size (or uncompressed behind their negated size when that is no smaller).
        mutating func values(_ values: [Float], compression: UInt32) {
            let raw = values.withUnsafeBytes { Array($0) }
            guard compression & OpenVDBWriter.compressZip != 0 else {
                data.append(contentsOf: raw)
                return
            }
            if let zipped = zlib(raw), zipped.count < raw.count {
                int64(Int64(zipped.count))
                data.append(contentsOf: zipped)
            } else {
                int64(-Int64(raw.count))
                data.append(contentsOf: raw)
            }
        }
    }

    /// A zlib stream (RFC 1950): the Compression framework's raw deflate between zlib's header and
    /// its Adler-32 checksum.
    static func zlib(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 16 + 64
        var deflated = [UInt8](repeating: 0, count: capacity)
        let size = input.withUnsafeBufferPointer { source in
            deflated.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(
                    destination.baseAddress!, capacity, source.baseAddress!, input.count, nil,
                    COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { return nil }
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0
        while index < input.count {
            // Reduce at most every 5552 bytes, as zlib does, so the sums cannot overflow.
            let end = min(index + 5552, input.count)
            for n in index..<end {
                a += UInt32(input[n])
                b += a
            }
            a %= 65521
            b %= 65521
            index = end
        }
        let checksum = (b << 16) | a
        return [0x78, 0x9C] + deflated[0..<size]
            + [
                UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF),
                UInt8(checksum & 0xFF),
            ]
    }
}
