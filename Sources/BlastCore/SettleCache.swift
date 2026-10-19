import BlastModel
import ContactSearchMetal
import CryptoKit
import Foundation
import MachO
import Metal

/// Structures already brought to rest under their own weight, kept between runs
/// (`BlastSolver.settleStructures`). Settling runs a body alone, without the air, so a body loaded
/// the same way, with the same settings, by the same build on the same Mac settles to the same
/// state to the bit: that state (the body's checkpoint parts, `SolverCheckpoint`) is taken back
/// instead of settling again. The office tower's settle takes over a minute.
///
/// The key covers the build (its executable's UUID and the shaders' source), the OS and the GPU,
/// settling's constants, every byte of the body's state as loaded, and its parts' settings
/// (`settings(of:)`). Kept in `~/Library/Caches/BombCAD/SettledStructures`, the least recently
/// used thinned out past `budget`. `BOMBCAD_SETTLE_CACHE=off` in the environment turns it off,
/// and a path puts it there.
enum SettleCache {
    /// The most the cache keeps, in bytes stored.
    static let budget = 4 << 30

    /// A folder in place of the usual one, or `.some(nil)` for none, for a task (tests).
    @TaskLocal static var override: URL??

    /// Where it is kept; nil when it is off.
    static var folder: URL? {
        if let override { return override }
        return switch ProcessInfo.processInfo.environment["BOMBCAD_SETTLE_CACHE"] {
        case "off": nil
        case let path? where !path.isEmpty: URL(filePath: path)
        default:
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "BombCAD/SettledStructures")
        }
    }

    /// The build's identity: the UUID of the image this code is linked into, and a digest of the
    /// shaders' source as `ShaderLibrary.make` compiles it.
    static let build: String = {
        var parts = [imageUUID ?? "no image UUID"]
        var hash = SHA256()
        for name in shaderFiles {
            if let url = Bundle.module.url(
                forResource: name, withExtension: "metal", subdirectory: "Shaders"),
                let data = try? Data(contentsOf: url)
            {
                hash.update(data: data)
            }
        }
        if let contact = try? MetalContactSearch.functionSource() { hash.update(data: Data(contact.utf8)) }
        hash.update(data: Data(String(describing: BuildProbe.current).utf8))
        parts.append(hash.finalize().map { String(format: "%02x", $0) }.joined())
        return parts.joined(separator: " ")
    }()

    /// Every shader file in the package's Shaders folder, by name.
    private static var shaderFiles: [String] {
        (Bundle.module.urls(forResourcesWithExtension: "metal", subdirectory: "Shaders") ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// The LC_UUID of the Mach-O image holding this code.
    private static var imageUUID: String? {
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        var command = UnsafeRawPointer(#dsohandle).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    /// The key a body as loaded settles under, or nil with the cache off.
    static func key(for body: StructuralBody, device: MTLDevice) -> String? {
        guard folder != nil else { return nil }
        var hash = SHA256()
        func add(_ text: String) { hash.update(data: Data((text + "\n").utf8)) }
        add(build)
        add(ProcessInfo.processInfo.operatingSystemVersionString)
        add(device.name)
        add(String(describing: KernelRounding.current))
        add(
            "\(BlastSolver.settleDamping) \(BlastSolver.settleMinimum) \(BlastSolver.settleLimit) "
                + "\(BlastSolver.settleTolerance) \(body.gravity) \(body.damping)")
        add(settings(of: body))
        for part in body.checkpointParts() {
            add(part.name)
            switch part {
            case .buffer(_, let buffer, let range):
                hash.update(
                    bufferPointer: UnsafeRawBufferPointer(
                        start: buffer.contents() + range.lowerBound, count: range.count))
            case .bytes(_, let data): hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The settings of a body's parts that its buffers do not hold: each scalar, short array and
    /// enumeration stored on it, its solvers and their sub-systems, by path. The buffers, the
    /// pipelines and long arrays (the mesh, which the buffers hold) are left out.
    static func settings(of body: StructuralBody) -> String {
        let names =
            StructureSolver.checkpointSubsystems.union(ShellSolver.checkpointSubsystems)
            .union(["StructureSolver", "ShellSolver", "MixedStructure"])
        var lines: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, _ path: String, depth: Int) {
            if value is MTLBuffer || value is MTLComputePipelineState || value is MTLDevice
                || value is MTLCommandQueue || value is MTLLibrary || value is MTLTexture
            {
                return
            }
            let mirror = Mirror(reflecting: value)
            switch mirror.displayStyle {
            case .optional:
                if let child = mirror.children.first {
                    visit(child.value, path, depth: depth)
                } else {
                    lines.append("\(path)=nil")
                }
            case .collection:
                guard mirror.children.count <= 64 else {
                    lines.append("\(path).count=\(mirror.children.count)")
                    return
                }
                for (n, child) in mirror.children.enumerated() {
                    visit(child.value, "\(path)[\(n)]", depth: depth + 1)
                }
            case .set, .dictionary:
                // In no order of their own (it changes from one process to the next): sorted.
                guard mirror.children.count <= 64 else {
                    lines.append("\(path).count=\(mirror.children.count)")
                    return
                }
                lines += mirror.children.map { "\(path){\(String(describing: $0.value))}" }.sorted()
            case .class, .struct:
                let typeName = String(describing: type(of: value))
                if typeName.hasPrefix("SIMD") {
                    lines.append("\(path)=\(String(describing: value))")
                    return
                }
                // The body, its solvers and their sub-systems, and the values they hold.
                let held = mirror.displayStyle == .struct && depth < 6
                guard depth == 0 || names.contains(typeName) || held else { return }
                if mirror.displayStyle == .class, let object = value as AnyObject?,
                    !seen.insert(ObjectIdentifier(object)).inserted
                {
                    return
                }
                var level: Mirror? = mirror
                while let current = level {
                    // The mesh is in the buffers; the body's identity is no setting.
                    for child in current.children where !["model", "id", "name"].contains(child.label) {
                        let label = child.label ?? "?"
                        visit(child.value, path.isEmpty ? label : "\(path).\(label)", depth: depth + 1)
                    }
                    level = current.superclassMirror
                }
            default:
                // Enumerations, tuples and plain values; a closure's description is its type, its
                // behaviour the build's.
                lines.append("\(path)=\(String(describing: value))")
            }
        }
        visit(body, "", depth: 0)
        return lines.joined(separator: "\n")
    }

    /// The settled state under `key`, given to `body`, and how it settled; nil if there is none
    /// (or it cannot be read).
    static func load(_ key: String, into body: StructuralBody) -> BlastSolver.Settlement? {
        guard let entry = folder?.appending(path: key) else { return nil }
        do {
            let record = try JSONDecoder().decode(
                Record.self, from: Data(contentsOf: entry.appending(path: "settled.json")))
            guard record.version == body.checkpointVersion else { return nil }
            var pieces: [String: Data] = [:]
            for piece in record.pieces {
                let data = try SolverCheckpoint.decompress(
                    Data(contentsOf: entry.appending(path: piece.file)))
                guard data.count == piece.rawBytes else { return nil }
                pieces[piece.name] = data
            }
            try body.restoreCheckpoint(pieces)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
            var settlement = record.settlement
            settlement.name = body.name
            settlement.cached = true
            return settlement
        } catch {
            return nil
        }
    }

    /// Keeps `body`'s settled state under `key`, then thins the cache to its budget. Written to
    /// a folder of its own and moved into place, so a run reading it never sees half of one.
    static func store(_ key: String, body: StructuralBody, settlement: BlastSolver.Settlement) {
        guard let folder else { return }
        let manager = FileManager.default
        let entry = folder.appending(path: key)
        guard !manager.fileExists(atPath: entry.path) else { return }
        let staging = folder.appending(path: ".\(key)-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            var record = Record(version: body.checkpointVersion, settlement: settlement, pieces: [])
            for (n, piece) in body.checkpointParts().enumerated() {
                let raw = piece.data
                let file = "\(n).lzfse"
                try SolverCheckpoint.compress(raw).write(to: staging.appending(path: file))
                record.pieces.append(.init(name: piece.name, file: file, rawBytes: raw.count))
            }
            try JSONEncoder().encode(record).write(to: staging.appending(path: "settled.json"))
            try manager.moveItem(at: staging, to: entry)
        } catch {
            try? manager.removeItem(at: staging)
            return
        }
        thin(folder)
    }

    /// Removes the least recently used entries until the rest fit `budget`.
    static func thin(_ folder: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard
            let entries = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        var sized: [(url: URL, date: Date, bytes: Int)] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            let files = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: keys)) ?? []
            let bytes = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
            }
            let date =
                (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            sized.append((entry, date ?? .distantPast, bytes))
        }
        var total = sized.reduce(0) { $0 + $1.bytes }
        for entry in sized.sorted(by: { $0.date < $1.date }) where total > budget {
            try? manager.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    /// An entry's record: the body's checkpoint version, how it settled, and its pieces' files.
    struct Record: Codable {
        struct Piece: Codable {
            var name: String
            var file: String
            var rawBytes: Int
        }
        var version: Int
        var settlement: BlastSolver.Settlement
        var pieces: [Piece]
    }
}
