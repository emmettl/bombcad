import Compression
import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("OpenVDB writer")
struct OpenVDBWriterTests {
    /// Reads back what the writer writes: the header, one float grid's descriptor, metadata and
    /// affine transform, its topology, and its leaves' values. Only the subset the writer uses.
    struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(_ data: Data) { bytes = Array(data) }

        mutating func take(_ count: Int) -> ArraySlice<UInt8> {
            defer { position += count }
            return bytes[position..<position + count]
        }
        mutating func uint32() -> UInt32 { take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func int32() -> Int32 { Int32(bitPattern: uint32()) }
        mutating func int64() -> Int64 {
            Int64(bitPattern: take(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        mutating func double() -> Double { Double(bitPattern: UInt64(bitPattern: int64())) }
        mutating func string() -> String { String(decoding: take(Int(uint32())), as: UTF8.self) }
        mutating func words(_ count: Int) -> [UInt64] {
            (0..<count).map { _ in UInt64(bitPattern: int64()) }
        }
        mutating func values(_ count: Int, zipped: Bool) -> [Float] {
            var raw: [UInt8]
            if zipped {
                let size = int64()
                if size < 0 {
                    raw = Array(take(Int(-size)))
                } else {
                    let stream = Array(take(Int(size)))
                    // Strip zlib's header and checksum, and inflate the raw deflate between.
                    let deflated = Array(stream[2..<stream.count - 4])
                    raw = [UInt8](repeating: 0, count: count * 4)
                    let decoded = deflated.withUnsafeBufferPointer { source in
                        raw.withUnsafeMutableBufferPointer { destination in
                            compression_decode_buffer(
                                destination.baseAddress!, count * 4, source.baseAddress!, deflated.count, nil,
                                COMPRESSION_ZLIB)
                        }
                    }
                    precondition(decoded == count * 4)
                    #expect(Array(stream.suffix(4)) == OpenVDBWriter.zlib(raw).map { Array($0.suffix(4)) })
                }
            } else {
                raw = Array(take(count * 4))
            }
            return stride(from: 0, to: raw.count, by: 4).map { n in
                Float(bitPattern: raw[n..<n + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            }
        }
    }

    struct File {
        var voxels: [SIMD3<Int32>: Float] = [:]
        var name = ""
        var matrix: [Double] = []
        var end = 0
        var size = 0
    }

    /// Every active voxel of the file's only grid, by index coordinate.
    func read(_ data: Data) -> File {
        var r = Reader(data)
        var file = File(size: data.count)
        #expect(r.int64() == 0x5644_4220)
        #expect(r.uint32() == 224)
        _ = r.take(8 + 1 + 36)
        #expect(r.uint32() == 0)
        #expect(r.int32() == 1)
        file.name = r.string()
        #expect(r.string() == "Tree_float_5_4_3")
        #expect(r.string() == "")
        let gridPos = r.int64()
        let blockPos = r.int64()
        file.end = Int(r.int64())
        #expect(Int(gridPos) == r.position)
        let zipped = r.uint32() == 1
        for _ in 0..<r.uint32() {
            _ = r.string()
            _ = r.string()
            _ = r.take(Int(r.uint32()))
        }
        #expect(r.string() == "AffineMap")
        file.matrix = (0..<16).map { _ in r.double() }

        #expect(r.int32() == 1)
        _ = r.take(4)
        #expect(r.uint32() == 0)
        var leafOrigins: [SIMD3<Int32>] = []
        for _ in 0..<r.uint32() {
            let upper = SIMD3(r.int32(), r.int32(), r.int32())
            let upperChildren = r.words(512)
            _ = r.words(512)
            _ = r.take(1)
            #expect(r.values(32_768, zipped: zipped).allSatisfy { $0 == 0 })
            for slot in 0..<32_768 where upperChildren[slot >> 6] & (1 << UInt64(slot & 63)) != 0 {
                let lower =
                    upper &+ SIMD3(Int32(slot >> 10), Int32((slot >> 5) & 31), Int32(slot & 31)) &* 128
                let lowerChildren = r.words(64)
                _ = r.words(64)
                _ = r.take(1)
                _ = r.values(4096, zipped: zipped)
                for leaf in 0..<4096 where lowerChildren[leaf >> 6] & (1 << UInt64(leaf & 63)) != 0 {
                    leafOrigins.append(
                        lower &+ SIMD3(Int32(leaf >> 8), Int32((leaf >> 4) & 15), Int32(leaf & 15)) &* 8)
                    _ = r.words(8)
                }
            }
        }
        #expect(Int(blockPos) == r.position)
        for origin in leafOrigins {
            let mask = r.words(8)
            #expect(r.take(1).first == 6)
            let values = r.values(512, zipped: zipped)
            for offset in 0..<512 where mask[offset >> 6] & (1 << UInt64(offset & 63)) != 0 {
                let voxel = origin &+ SIMD3(Int32(offset >> 6), Int32((offset >> 3) & 7), Int32(offset & 7))
                file.voxels[voxel] = values[offset]
            }
        }
        #expect(file.end == r.position)
        return file
    }

    @Test("Active voxels across several internal nodes read back in place, zipped or not")
    func roundTrip() {
        // 300 cells along x spans three 128-cell internal nodes, 140 along y two.
        let d = SIMD3(300, 140, 20)
        var values = [Float](repeating: 0, count: d.x * d.y * d.z)
        var expected: [SIMD3<Int32>: Float] = [:]
        for k in 0..<d.z {
            for j in 0..<d.y {
                for i in 0..<d.x where (i * 7 + j * 3 + k) % 11 == 0 || (i > 250 && j > 120) {
                    let value = Float(i) + Float(j) / 1000 + 0.5
                    values[i + d.x * (j + d.y * k)] = value
                    expected[SIMD3(Int32(i), Int32(j), Int32(k))] = value
                }
            }
        }
        values[1] = 0.01  // below the threshold
        let grid = OpenVDBWriter.Grid(
            name: "test", dimensions: d, voxelSize: 0.25, origin: SIMD3(0.125, 0.125, 0.125), values: values,
            threshold: 0.1)
        for compress in [false, true] {
            let file = read(OpenVDBWriter.data([grid], compress: compress))
            #expect(file.name == "test")
            #expect(file.voxels == expected)
            #expect(file.matrix == [0.25, 0, 0, 0, 0, 0.25, 0, 0, 0, 0, 0.25, 0, 0.125, 0.125, 0.125, 1])
            #expect(file.end == file.size)
        }
        let zipped = OpenVDBWriter.data([grid], compress: true).count
        #expect(zipped < OpenVDBWriter.data([grid], compress: false).count / 2)
    }

    @Test("A grid with nothing active is its descriptor and an empty root")
    func empty() {
        let grid = OpenVDBWriter.Grid(
            name: "still", dimensions: SIMD3(4, 4, 4), voxelSize: 1, origin: .zero,
            values: [Float](repeating: 0, count: 64), threshold: 0.1)
        #expect(read(OpenVDBWriter.data([grid])).voxels.isEmpty)
    }

    @Test("zlib streams carry zlib's header and Adler-32 checksum")
    func zlib() throws {
        let stream = try #require(OpenVDBWriter.zlib(Array("Wikipedia".utf8)))
        #expect(stream.prefix(2) == [0x78, 0x9C])
        #expect(stream.suffix(4) == [0x11, 0xE6, 0x03, 0x98])
    }
}
