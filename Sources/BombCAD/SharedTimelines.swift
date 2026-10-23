import BlastCore
import DocumentKit
import Foundation

/// A kept run's recording that a sharing Mac offers to a viewer nearby (emmettl/bombcad-work#43):
/// listed by `timelines`, fetched by `fetchTimeline`. The project is named by its package's path on
/// the sharing Mac, which offers only the projects it was told to share (`BombCAD serve --share`,
/// or the projects open in the app while it shares its GPU).
struct SharedTimeline: Codable, Equatable, Hashable, Sendable, Identifiable {
    var project: String
    var projectName: String
    var run: UUID
    var name: String
    var frames: Int
    /// The recording's bytes as stored (compressed): its setup and frames.
    var bytes: Int
    /// The last frame's simulated time, in seconds.
    var endTime: Double
    var encodingVersion: Int

    var id: String { "\(project)#\(run.uuidString)" }
}

/// What a viewer asks for: a shared run's recording, every file of it.
struct TimelineFetch: Codable, Equatable, Sendable {
    var id: UUID
    var project: String
    var run: UUID
}

/// One file of a recording as it travels, its bytes as stored in the payload: the kept run itself
/// (`SavedSimulationRun` as JSON, compressed as the frames are), the manifest, the view's setup, or
/// frame `index` of `count`, at `path` within the run's folder.
struct TimelinePart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case run, manifest, setup, frame }
    var kind: Kind
    var path: String
    var index: Int = 0
    var count: Int = 0
}

/// What sending a recording came to, from the sharing Mac's side.
struct TimelineSentStats: Codable, Equatable, Sendable {
    var parts: Int
    var bytes: Int
    var seconds: Double
    /// Frames sent ahead of their turn because the viewer asked for them.
    var preferred: Int
}

/// The sharing Mac's side: the kept runs with recordings in the shared projects, and their files.
enum SharedTimelines {
    /// Where the kept run's own record goes in a viewer's copy of its folder.
    static let runFile = "run.lzfse"

    /// The kept runs with a recording in each project package, in the projects' order.
    static func list(_ packages: [URL]) -> [SharedTimeline] {
        packages.flatMap { package -> [SharedTimeline] in
            guard let document = try? ProjectDocument(fileWrapper: FileWrapper(url: package)) else {
                return []
            }
            return document.savedRuns.compactMap { run in
                guard let manifest = try? manifest(package, run.id) else { return nil }
                let frames = manifest.entries(.frames)
                return SharedTimeline(
                    project: package.standardizedFileURL.path,
                    projectName: package.deletingPathExtension().lastPathComponent, run: run.id,
                    name: run.name,
                    frames: frames.count,
                    bytes: manifest.entries.filter { $0.kind != .checkpoint }.reduce(0) { $0 + $1.bytes },
                    endTime: frames.last?.time ?? 0, encodingVersion: manifest.encodingVersion)
            }
        }
    }

    static func folder(_ package: URL, _ run: UUID) -> URL {
        package.appending(
            path: "\(RunTimelineManifest.folder)/\(run.uuidString.lowercased())", directoryHint: .isDirectory)
    }

    static func manifest(_ package: URL, _ run: UUID) throws -> RunTimelineManifest {
        try RunTimelineManifest.decode(
            Data(contentsOf: folder(package, run).appending(path: RunTimelineManifest.fileName)))
    }

    /// Whether `path`, from a manifest or the network, stays inside a run's folder.
    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            && !path.contains("\\")
    }

    /// The order frames go in: the first and the last, then the middle of each gap in turn, so that
    /// a viewer scrubbing before they have all arrived finds one near wherever it stops.
    static func order(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [0] }
        var order = [0, count - 1]
        var gaps = [(0, count - 1)]
        while !gaps.isEmpty {
            var next: [(Int, Int)] = []
            for (low, high) in gaps where high - low > 1 {
                let middle = (low + high) / 2
                order.append(middle)
                next += [(low, middle), (middle, high)]
            }
            gaps = next
        }
        return order
    }

    /// Sends the recording of `fetch.run` in `package` to `writer`: the run, the manifest, the
    /// setup, then the frames in `order`, each frame `preferred` hands back sent ahead of its turn,
    /// until done or `cancelled`. Blocks while the link takes each part, so call it off the
    /// thread reading the worker's input.
    static func send(
        _ fetch: TimelineFetch, package: URL, writer: SweepWorkerWriter, preferred: Locked<[Int]>,
        cancelled: Locked<Bool>
    ) throws -> TimelineSentStats {
        let start = ContinuousClock.now
        let document = try ProjectDocument(fileWrapper: FileWrapper(url: package))
        guard let run = document.savedRuns.first(where: { $0.id == fetch.run }) else {
            throw ProjectFileError.invalid("That run is not kept in \(package.lastPathComponent).")
        }
        let folder = folder(package, fetch.run)
        let manifestData = try Data(contentsOf: folder.appending(path: RunTimelineManifest.fileName))
        let manifest = try RunTimelineManifest.decode(manifestData)
        let frames = manifest.entries(.frames)
        guard let setup = manifest.entries(.setup).first, !frames.isEmpty,
            ([setup] + frames).allSatisfy({ isSafe($0.path) })
        else { throw ProjectFileError.invalid("That run's recording has no frames.") }
        var stats = TimelineSentStats(parts: 0, bytes: 0, seconds: 0, preferred: 0)
        func part(_ header: TimelinePart, _ payload: Data) throws {
            try writer.send(.timelinePart(fetch.id, header), payload: payload)
            stats.parts += 1
            stats.bytes += payload.count
        }
        try part(
            TimelinePart(kind: .run, path: runFile), TimelineCodec.compress(JSONEncoder().encode(run)))
        try part(TimelinePart(kind: .manifest, path: RunTimelineManifest.fileName), manifestData)
        try part(
            TimelinePart(kind: .setup, path: setup.path), Data(contentsOf: folder.appending(path: setup.path))
        )
        var sent = Set<Int>()
        var queue = order(frames.count)[...]
        while sent.count < frames.count {
            if cancelled.value { throw CancellationError() }
            let asked = preferred.update { asked -> Int? in
                defer { asked = [] }
                return asked.last { $0 >= 0 && $0 < frames.count && !sent.contains($0) }
            }
            let n: Int
            if let asked {
                n = asked
                stats.preferred += 1
            } else {
                guard let next = queue.popFirst() else { break }
                if sent.contains(next) { continue }
                n = next
            }
            sent.insert(n)
            try part(
                TimelinePart(kind: .frame, path: frames[n].path, index: n, count: frames.count),
                Data(contentsOf: folder.appending(path: frames[n].path)))
        }
        stats.seconds = start.duration(to: .now).timelineSeconds
        return stats
    }
}

/// A viewer's copy of a shared recording, in a folder laid out as the run's own (so that
/// `RunTimelinePlayer` reads it), filled as its parts arrive.
@MainActor
final class TimelineDownload {
    let shared: SharedTimeline
    let folder: URL
    private(set) var run: SavedSimulationRun?
    private(set) var manifest: RunTimelineManifest?
    private(set) var hasSetup = false
    /// The frames arrived, by index.
    private(set) var arrived = Set<Int>()
    private(set) var bytes = 0
    private(set) var parts = 0
    let started = ContinuousClock.now
    /// When the first frame was in, and the last.
    private(set) var firstFrame: ContinuousClock.Instant?
    private(set) var finished: ContinuousClock.Instant?

    init(_ shared: SharedTimeline, cache: URL = TimelineDownload.cache) throws {
        self.shared = shared
        folder = cache.appending(path: shared.run.uuidString.lowercased(), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "frames"), withIntermediateDirectories: true)
    }

    nonisolated static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "BombCAD/viewer", directoryHint: .isDirectory)
    }

    var frameCount: Int { manifest?.entries(.frames).count ?? shared.frames }
    /// Whether a player can open it: the run, its manifest, its setup and a frame.
    var isPlayable: Bool { run != nil && manifest != nil && hasSetup && !arrived.isEmpty }
    var isComplete: Bool { finished != nil }

    /// Takes a part as it arrives, writing its bytes where the run's folder has them.
    func receive(_ part: TimelinePart, _ payload: Data) throws {
        guard SharedTimelines.isSafe(part.path) else {
            throw ProjectFileError.invalid("A recording's file was named outside its folder.")
        }
        bytes += payload.count
        parts += 1
        switch part.kind {
        case .run:
            run = try JSONDecoder().decode(SavedSimulationRun.self, from: TimelineCodec.decompress(payload))
            return
        case .manifest:
            manifest = try RunTimelineManifest.decode(payload)
        case .setup:
            hasSetup = true
        case .frame:
            guard let manifest, manifest.entries(.frames).indices.contains(part.index),
                manifest.entries(.frames)[part.index].path == part.path
            else { throw ProjectFileError.invalid("A recording's frame is not in its manifest.") }
        }
        try payload.write(to: folder.appending(path: part.path))
        if part.kind == .frame {
            arrived.insert(part.index)
            if firstFrame == nil { firstFrame = .now }
        }
    }

    func finish() { finished = .now }

    /// Of the frames arrived, the one nearest `index`, at or before it if there is one.
    func nearestArrived(to index: Int) -> Int? {
        if arrived.contains(index) { return index }
        if let before = arrived.filter({ $0 <= index }).max() { return before }
        return arrived.min()
    }
}

/// A kept recording's bytes taken apart (emmettl/bombcad-work#43): what each frame carries, so
/// that a viewer's link can be judged.
enum TimelineWeights {
    static func measure(package: URL) throws -> String {
        let shared = SharedTimelines.list([package])
        var lines: [String] = []
        for timeline in shared {
            let folder = SharedTimelines.folder(package, timeline.run)
            let manifest = try SharedTimelines.manifest(package, timeline.run)
            let setup = try manifest.entries(.setup).first.map {
                try Data(contentsOf: folder.appending(path: $0.path)).count
            }
            var stored: [Int] = []
            var raw: [Int] = []
            var field = 0
            var bodies = 0
            var fragments = 0
            var freestanding = 0
            var layerBytes = [0, 0, 0, 0]
            var held = [0, 0, 0, 0]
            var decode: [Double] = []
            for entry in manifest.entries(.frames) {
                let data = try Data(contentsOf: folder.appending(path: entry.path))
                stored.append(data.count)
                let start = ContinuousClock.now
                let bytes = try TimelineCodec.decompress(data)
                let frame = try TimelineCodec.decode(bytes, version: manifest.encodingVersion)
                decode.append(start.duration(to: .now).timelineSeconds)
                raw.append(bytes.count)
                field += frame.view.field.count
                bodies += TimelineCodec.compact(frame.view).count - frame.view.field.count
                fragments += frame.fragments.map { 16 * $0.positions.count } ?? 0
                freestanding += 44 * frame.freestanding.count
                let layers = frame.layers
                func alone(_ keep: (inout TimelineLayers) -> Void) -> Int {
                    var only = TimelineLayers()
                    keep(&only)
                    var writer = TimelineLayerCodec.Writer()
                    TimelineLayerCodec.write(only, into: &writer)
                    var none = TimelineLayerCodec.Writer()
                    TimelineLayerCodec.write(TimelineLayers(), into: &none)
                    return writer.out.count - none.out.count
                }
                layerBytes[0] += alone { $0.vents = layers.vents }
                layerBytes[1] += alone { $0.envelopeCodes = layers.envelopeCodes }
                layerBytes[2] += alone { $0.thermal = layers.thermal }
                layerBytes[3] += alone { $0.cloud = layers.cloud }
                for (n, here) in [
                    layers.vents.value != nil, layers.envelopeCodes.value != nil, layers.thermal.value != nil,
                    layers.cloud.value != nil,
                ].enumerated() where here {
                    held[n] += 1
                }
            }
            let runBytes = try document(package)?.savedRuns.first { $0.id == timeline.run }.map {
                try TimelineCodec.compress(JSONEncoder().encode($0)).count
            }
            let count = max(stored.count, 1)
            let sorted = stored.sorted()
            func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1e6) }
            func kb(_ bytes: Int) -> String { String(format: "%.1f kB", Double(bytes) / 1e3) }
            lines.append(
                "\(timeline.projectName) / \(timeline.name): \(stored.count) frames to \(String(format: "%.3f", timeline.endTime)) s, encoding \(manifest.encodingVersion)"
            )
            lines.append(
                "  stored: \(mb(stored.reduce(0, +))) in all; a frame \(mb(stored.reduce(0, +) / count)) on average, median \(mb(sorted[sorted.count / 2])), largest \(mb(sorted.last ?? 0)); setup \(mb(setup ?? 0)); the kept run's record \(mb(runBytes ?? 0))"
            )
            lines.append(
                "  raw, a frame on average: \(mb(raw.reduce(0, +) / count)) (compressed \(String(format: "%.1f", Double(raw.reduce(0, +)) / Double(max(stored.reduce(0, +), 1))))x); the field \(mb(field / count)), the structures \(mb(bodies / count)), fragments \(kb(fragments / count)), freestanding \(kb(freestanding / count))"
            )
            lines.append(
                "  layers in all, raw: vents \(kb(layerBytes[0])) (held by \(held[0]) frames), envelope damage \(kb(layerBytes[1])) (\(held[1])), thermal paint \(kb(layerBytes[2])) (\(held[2])), cloud \(kb(layerBytes[3])) (\(held[3]))"
            )
            let decodes = decode.sorted()
            lines.append(
                String(
                    format: "  decompressing and decoding a frame here: median %.1f ms, largest %.1f ms",
                    1000 * decodes[decodes.count / 2], 1000 * (decodes.last ?? 0)))
        }
        return lines.joined(separator: "\n")
    }

    private static func document(_ package: URL) throws -> ProjectDocument? {
        try ProjectDocument(fileWrapper: FileWrapper(url: package))
    }
}

extension Duration {
    var timelineSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
