import Compression
import Foundation
import Metal

/// A part of the solver whose state a checkpoint saves: "the state I own". Each part names its
/// buffers' byte ranges and its scalars, with a version bumped whenever what it saves changes, so
/// that a part added to the solver is either listed here or the solver refuses to checkpoint (see
/// `BlastSolver.checkpointUnsupported`), and a checkpoint from another version is refused rather
/// than read wrong.
protocol SolverCheckpointing {
    /// Its name in the checkpoint, unique among the parts.
    var checkpointName: String { get }
    /// The version of what it saves.
    var checkpointVersion: Int { get }
    /// The state it owns, as it is between batches.
    func checkpointParts() -> [SolverCheckpoint.Part]
    /// Takes back what `checkpointParts` gave, by name. Called once the pools have grown to the
    /// sizes they had when it was saved, so that every buffer has the length it had then.
    func restoreCheckpoint(_ parts: [String: Data]) throws
}

/// The checkpoints of `BlastSolver`: its state saved between batches at a 64-step boundary and taken
/// back by a solver built from the same scene and configuration, so that the run carries on as if
/// it had never stopped (`BlastSolver.saveCheckpoint`, `restoreCheckpoint`).
///
/// On disk a checkpoint is a folder: `checkpoint.json` (the header: format, the parts and their
/// versions, the scene's and configuration's fingerprints, the grid, the step and the time) and
/// one file a part, its bytes LZFSE-compressed in chunks of 16 MB.
public enum SolverCheckpoint {
    /// The format of the folder; a different one is refused.
    public static let format = 1

    /// One piece of a part's state: a buffer's byte range, or bytes of its own (its scalars).
    enum Part {
        case buffer(String, MTLBuffer, Range<Int>)
        case bytes(String, Data)

        var name: String {
            switch self {
            case .buffer(let name, _, _), .bytes(let name, _): name
            }
        }

        /// Its bytes, copied out.
        var data: Data {
            switch self {
            case .buffer(_, let buffer, let range):
                Data(bytes: buffer.contents() + range.lowerBound, count: range.count)
            case .bytes(_, let data): data
            }
        }
    }

    /// The header written as checkpoint.json.
    public struct Header: Codable, Sendable, Hashable {
        public var format: Int
        /// The fingerprints of the scene and of the solver's configuration it was saved from.
        public var scene: String
        public var configuration: String
        /// The grid: nx, ny, nz and the cell size.
        public var grid: [Int]
        public var cellSize: Float
        public var stepCount: Int
        public var time: Double
        /// Each refinement level's pool, in patches, when it was saved.
        public var pools: [Int]
        /// What it holds (the air, its clocks, its refinement, the radiative cooling), and whether
        /// that is all the run's state: a run with parts not yet covered is refused, so true.
        public var covers: [String]
        public var complete: Bool
        /// The parts, by name, with their versions and pieces.
        public var parts: [PartRecord]
        /// Bytes before and after compression, and the seconds the save took.
        public var rawBytes: Int
        public var storedBytes: Int
        public var seconds: Double
    }

    public struct PartRecord: Codable, Sendable, Hashable {
        public var name: String
        public var version: Int
        public var pieces: [PieceRecord]
    }

    public struct PieceRecord: Codable, Sendable, Hashable {
        public var name: String
        public var file: String
        public var rawBytes: Int
        public var storedBytes: Int
    }

    /// Why a checkpoint cannot be taken or taken back.
    public struct Refusal: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: - Fingerprints

    /// FNV-1a, 64 bits, of `bytes`.
    static func fnv(_ bytes: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    /// The fingerprint of a scene: its JSON with sorted keys.
    public static func fingerprint(scene: Scenario) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(scene)) ?? Data()
        return String(fnv(data), radix: 16)
    }

    /// The fingerprint of a configuration: its full description, every field at full precision.
    public static func fingerprint(configuration: SolverConfiguration) -> String {
        String(fnv(Data(String(reflecting: configuration).utf8)), radix: 16)
    }

    // MARK: - Scalars

    /// Scalars written as their exact bit patterns, in order.
    struct Writer {
        private(set) var data = Data()

        mutating func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }

        mutating func append(_ value: Bool) { append(UInt8(value ? 1 : 0)) }

        /// An array of plain values, with its count first.
        mutating func appendArray<T>(_ values: [T]) {
            append(values.count)
            values.withUnsafeBytes { data.append(contentsOf: $0) }
        }
    }

    /// Reads back what `Writer` wrote, in the same order. It does not throw: a read past the end
    /// gives zeros and sets `short`, which the reader checks once it has read all it wants
    /// (`finish()`). (Plain values are copied byte for byte.)
    struct Reader {
        let data: Data
        private var offset = 0
        private(set) var short = false

        init(_ data: Data) { self.data = data }

        mutating func read<T>(_: T.Type) -> T {
            let size = MemoryLayout<T>.size
            let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
            defer { value.deallocate() }
            memset(value, 0, MemoryLayout<T>.stride)
            if offset + size <= data.count {
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { memcpy(value, base + offset, size) }
                }
            } else {
                short = true
            }
            offset += size
            return value.pointee
        }

        mutating func readBool() -> Bool { read(UInt8.self) != 0 }

        mutating func readArray<T>(_: T.Type) -> [T] {
            let count = read(Int.self)
            guard count >= 0, count <= data.count, offset + MemoryLayout<T>.stride * count <= data.count
            else {
                short = true
                return []
            }
            return (0..<count).map { _ in
                let value = read(T.self)
                offset += MemoryLayout<T>.stride - MemoryLayout<T>.size
                return value
            }
        }

        /// Throws if anything read lay past the end.
        func finish(_ name: String) throws {
            if short { throw Refusal(description: "\(name)'s scalars are short") }
        }
    }

    /// Copies `data` into `buffer`'s bytes from `offset`, `length` of them: where it was saved from,
    /// which must be exactly as long.
    static func restore(_ data: Data?, into buffer: MTLBuffer, offset: Int, length: Int, name: String) throws
    {
        guard let data else { throw Refusal(description: "the checkpoint has no \(name)") }
        guard data.count == length, offset >= 0, offset + length <= buffer.length else {
            throw Refusal(description: "\(name) is \(data.count) bytes where the solver has \(length)")
        }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.contents() + offset, count: length))
    }

    // MARK: - Files

    static let chunk = 16 << 20

    /// `data` compressed, chunk by chunk on the CPU's cores: its length, then for each chunk its
    /// length and its compressed length and bytes (or its bytes as they are, where compressing
    /// gains nothing).
    static func compress(_ data: Data) -> Data {
        let count = (data.count + chunk - 1) / chunk
        var pieces = [Data](repeating: Data(), count: count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            pieces.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: count) { n in
                    let start = n * chunk
                    let length = min(chunk, data.count - start)
                    var stored = [UInt8](repeating: 0, count: length + 4096)
                    let size = compression_encode_buffer(
                        &stored, stored.count, base + start, length, nil, COMPRESSION_LZFSE)
                    var piece = Data()
                    withUnsafeBytes(of: UInt32(length)) { piece.append(contentsOf: $0) }
                    if size > 0 && size < length {
                        withUnsafeBytes(of: UInt32(size)) { piece.append(contentsOf: $0) }
                        piece.append(contentsOf: stored[0..<size])
                    } else {
                        withUnsafeBytes(of: UInt32(0)) { piece.append(contentsOf: $0) }
                        piece.append(base + start, count: length)
                    }
                    out[n] = piece
                }
            }
        }
        var result = Data()
        withUnsafeBytes(of: UInt64(data.count)) { result.append(contentsOf: $0) }
        for piece in pieces { result.append(piece) }
        return result
    }

    /// What `compress` wrote, back.
    static func decompress(_ stored: Data) throws -> Data {
        guard stored.count >= 8 else { throw Refusal(description: "a part's file is short") }
        let total = Int(stored.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        // Where each chunk is, read first so that they can be taken apart on several cores.
        var chunks: [(offset: Int, raw: Int, size: Int)] = []
        var at = 8
        var sum = 0
        while sum < total {
            guard at + 8 <= stored.count else { throw Refusal(description: "a part's file is short") }
            let raw = Int(stored.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) })
            let size = Int(
                stored.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self) })
            let length = size == 0 ? raw : size
            guard at + 8 + length <= stored.count else {
                throw Refusal(description: "a part's file is short")
            }
            chunks.append((at + 8, raw, size))
            at += 8 + length
            sum += raw
        }
        var result = Data(count: total)
        var failed = false
        let starts = chunks.indices.map { n in chunks[..<n].reduce(0) { $0 + $1.raw } }
        result.withUnsafeMutableBytes { out in
            guard let target = out.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            stored.withUnsafeBytes { input in
                guard let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                concurrently(iterations: chunks.count) { n in
                    let chunk = chunks[n]
                    if chunk.size == 0 {
                        memcpy(target + starts[n], source + chunk.offset, chunk.raw)
                    } else if compression_decode_buffer(
                        target + starts[n], chunk.raw, source + chunk.offset, chunk.size, nil,
                        COMPRESSION_LZFSE)
                        != chunk.raw
                    {
                        failed = true
                    }
                }
            }
        }
        if failed { throw Refusal(description: "a part's file did not decompress") }
        return result
    }

    /// Writes `parts` (each subsystem's) to `folder` with `header`'s other fields, and returns the
    /// header as written.
    static func write(_ parts: [any SolverCheckpointing], header: Header, to folder: URL) throws -> Header {
        let start = ContinuousClock.now
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var header = header
        header.parts = []
        header.rawBytes = 0
        header.storedBytes = 0
        for part in parts {
            var record = PartRecord(name: part.checkpointName, version: part.checkpointVersion, pieces: [])
            for piece in part.checkpointParts() {
                let raw = piece.data
                let stored = compress(raw)
                let file = "\(part.checkpointName).\(piece.name).lzfse"
                try stored.write(to: folder.appending(path: file))
                record.pieces.append(
                    PieceRecord(name: piece.name, file: file, rawBytes: raw.count, storedBytes: stored.count))
                header.rawBytes += raw.count
                header.storedBytes += stored.count
            }
            header.parts.append(record)
        }
        let elapsed = ContinuousClock.now - start
        header.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(header).write(to: folder.appending(path: "checkpoint.json"))
        return header
    }

    /// The header of the checkpoint in `folder`.
    public static func header(in folder: URL) throws -> Header {
        let header = try JSONDecoder().decode(
            Header.self, from: Data(contentsOf: folder.appending(path: "checkpoint.json")))
        guard header.format == format else {
            throw Refusal(
                description: "the checkpoint is format \(header.format), this build reads \(format)")
        }
        return header
    }

    /// Gives each of `parts` back its pieces from `folder`, checking that the parts and their
    /// versions are those saved.
    static func read(_ parts: [any SolverCheckpointing], header: Header, from folder: URL) throws {
        let saved = Dictionary(uniqueKeysWithValues: header.parts.map { ($0.name, $0) })
        guard Set(saved.keys) == Set(parts.map(\.checkpointName)) else {
            throw Refusal(
                description:
                    "the checkpoint holds \(saved.keys.sorted()), this solver \(parts.map(\.checkpointName).sorted())"
            )
        }
        for part in parts {
            guard let record = saved[part.checkpointName], record.version == part.checkpointVersion else {
                throw Refusal(description: "\(part.checkpointName) was saved at another version")
            }
            var pieces: [String: Data] = [:]
            for piece in record.pieces {
                let data = try decompress(Data(contentsOf: folder.appending(path: piece.file)))
                guard data.count == piece.rawBytes else {
                    throw Refusal(description: "\(piece.file) is \(data.count) bytes, not \(piece.rawBytes)")
                }
                pieces[piece.name] = data
            }
            try part.restoreCheckpoint(pieces)
        }
    }
}
