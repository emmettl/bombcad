import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import simd

/// One recorded moment of a run as the viewport draws it: the scene view (the blast's field and
/// every structure, `ViewFrame`), and what is drawn over it that moves, the fragments in flight and
/// the freestanding objects, and from encoding version 2 the layers that change (`TimelineLayers`).
struct TimelineFrame: Sendable, Equatable {
    var view: ViewFrame
    var fragments: FragmentLive?
    var freestanding: [SceneRenderer.OrientedBox]
    var layers = TimelineLayers()

    var time: Double { view.time }
}

/// A frame's bytes: the scene view, compactly (`compact`), then whether there are fragments
/// and if so their count, how many of them are fragments rather than tracers, and
/// `FragmentLive.payload`, then the
/// freestanding boxes (eleven floats and a flag each), little-endian; from version 2, then its
/// layers (`TimelineLayerCodec`).
enum TimelineCodec {
    /// The encoding version recordings are written in (`RunTimelineManifest.encodingVersion`).
    static let version = 2

    static func encode(_ frame: TimelineFrame, version: Int = version) -> Data {
        var out = Data()
        func integer(_ value: Int) {
            withUnsafeBytes(of: UInt64(value).littleEndian) { out.append(contentsOf: $0) }
        }
        func floats(_ values: [Float]) {
            for value in values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        let view = compact(frame.view)
        integer(view.count)
        out.append(view)
        integer(frame.fragments == nil ? 0 : 1)
        if let fragments = frame.fragments {
            integer(fragments.positions.count)
            integer(fragments.fragmentCount)
            out.append(fragments.payload)
        }
        integer(frame.freestanding.count)
        for box in frame.freestanding {
            floats([
                box.centre.x, box.centre.y, box.centre.z, box.orientation.vector.x, box.orientation.vector.y,
                box.orientation.vector.z, box.orientation.vector.w, box.size.x, box.size.y, box.size.z,
                box.isCar ? 1 : 0,
            ])
        }
        if version >= 2 {
            var writer = TimelineLayerCodec.Writer()
            TimelineLayerCodec.write(frame.layers, into: &writer)
            out.append(writer.out)
        }
        return out
    }

    /// The frame in `data`, written in encoding `version`; with `layersOnly`, its layers alone, the
    /// rest skipped and left empty.
    static func decode(_ data: Data, version: Int = version, layersOnly: Bool = false) throws -> TimelineFrame
    {
        var at = data.startIndex
        func bad() -> Error { ProjectFileError.invalid("A recorded frame is malformed.") }
        func integer() throws -> Int {
            guard data.endIndex - at >= 8 else { throw bad() }
            var value: UInt64 = 0
            for k in 0..<8 { value |= UInt64(data[at + k]) << (8 * k) }
            at += 8
            guard value <= UInt64(Int64.max) else { throw bad() }
            return Int(value)
        }
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - at >= count else { throw bad() }
            defer { at += count }
            return data[at..<(at + count)]
        }
        func float() throws -> Float {
            let raw = try bytes(4)
            var bits: UInt32 = 0
            for k in 0..<4 { bits |= UInt32(raw[raw.startIndex + k]) << (8 * k) }
            return Float(bitPattern: bits)
        }
        let viewBytes = try bytes(try integer())
        let view = layersOnly ? ViewFrame(time: 0, field: Data(), bodies: []) : try expand(viewBytes)
        var fragments: FragmentLive?
        if try integer() == 1 {
            let particles = try integer()
            let count = try integer()
            let payload = try bytes(16 * particles)
            if !layersOnly {
                var live = FragmentLive()
                try live.read(payload)
                live.fragmentCount = min(count, particles)
                live.time = view.time
                fragments = live
            }
        }
        let boxes = try integer()
        guard boxes <= (data.endIndex - at) / 44 else { throw bad() }
        if layersOnly { _ = try bytes(44 * boxes) }
        var freestanding: [SceneRenderer.OrientedBox] = []
        for _ in 0..<(layersOnly ? 0 : boxes) {
            let v = try (0..<11).map { _ in try float() }
            freestanding.append(
                .init(
                    centre: SIMD3(v[0], v[1], v[2]),
                    orientation: simd_quatf(vector: SIMD4(v[3], v[4], v[5], v[6])),
                    size: SIMD3(v[7], v[8], v[9]), isCar: v[10] != 0))
        }
        var layers = TimelineLayers()
        if version >= 2 {
            var reader = TimelineLayerCodec.Reader(data: data, at: at)
            layers = try TimelineLayerCodec.read(&reader)
            at = reader.at
        }
        guard at == data.endIndex else { throw bad() }
        return TimelineFrame(view: view, fragments: fragments, freestanding: freestanding, layers: layers)
    }

    /// The scene view for display only, about half its size: displacements and rotations as
    /// half-precision floats (to 3 significant figures, a few centimetres at 100 m), damage as a
    /// byte (to 1/255), the field's texels and the flags as they are.
    static func compact(_ view: ViewFrame) -> Data {
        var out = Data()
        func integer(_ value: Int) {
            withUnsafeBytes(of: UInt64(value).littleEndian) { out.append(contentsOf: $0) }
        }
        func halves(_ values: [Float]) {
            integer(values.count)
            for value in values {
                withUnsafeBytes(of: Float16(value).bitPattern.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        func bytes(_ values: [UInt8]) {
            integer(values.count)
            out.append(contentsOf: values)
        }
        func damage(_ values: [Float]) { bytes(values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }) }
        withUnsafeBytes(of: view.time.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        integer(view.field.count)
        out.append(view.field)
        integer(view.bodies.count)
        for body in view.bodies {
            integer(body.solids == nil ? 0 : 1)
            if let solids = body.solids {
                halves(solids.displacements.flatMap { [$0.x, $0.y, $0.z] })
                bytes(solids.flags)
                damage(solids.damage)
            }
            integer(body.shells == nil ? 0 : 1)
            if let shells = body.shells {
                halves(shells.displacements.flatMap { [$0.x, $0.y, $0.z] })
                halves(shells.rotations.flatMap { [$0.x, $0.y, $0.z, $0.w] })
                bytes(shells.flags)
                bytes(shells.beamFlags)
                damage(shells.damage)
                damage(shells.beamDamage)
            }
        }
        return out
    }

    static func expand(_ data: Data) throws -> ViewFrame {
        var at = data.startIndex
        func bad() -> Error { ProjectFileError.invalid("A recorded frame's view is malformed.") }
        func word(_ size: Int) throws -> UInt64 {
            guard data.endIndex - at >= size else { throw bad() }
            var value: UInt64 = 0
            for k in 0..<size { value |= UInt64(data[at + k]) << (8 * k) }
            at += size
            return value
        }
        func integer(limit: Int) throws -> Int {
            let value = try word(8)
            guard value <= UInt64(limit) else { throw bad() }
            return Int(value)
        }
        func halves(_ per: Int) throws -> [Float] {
            let count = try integer(limit: (data.endIndex - at) / 2)
            guard count % per == 0 else { throw bad() }
            return try (0..<count).map { _ in Float(Float16(bitPattern: UInt16(try word(2)))) }
        }
        func bytes() throws -> [UInt8] {
            let count = try integer(limit: data.endIndex - at)
            defer { at += count }
            return Array(data[at..<(at + count)])
        }
        func damage() throws -> [Float] { try bytes().map { Float($0) / 255 } }
        func vectors3(_ v: [Float]) -> [SIMD3<Float>] {
            Swift.stride(from: 0, to: v.count, by: 3).map { SIMD3(v[$0], v[$0 + 1], v[$0 + 2]) }
        }
        let time = Double(bitPattern: try word(8))
        let fieldCount = try integer(limit: data.endIndex - at)
        let field = data[at..<(at + fieldCount)]
        at += fieldCount
        let count = try integer(limit: data.endIndex - at)
        var bodies: [ViewFrame.Body] = []
        for _ in 0..<count {
            var solids: ViewFrame.Solids?
            if try integer(limit: 1) == 1 {
                solids = ViewFrame.Solids(
                    displacements: vectors3(try halves(3)), flags: try bytes(), damage: try damage())
            }
            var shells: ViewFrame.Shells?
            if try integer(limit: 1) == 1 {
                let displacements = vectors3(try halves(3))
                let r = try halves(4)
                let rotations = Swift.stride(from: 0, to: r.count, by: 4).map {
                    SIMD4(r[$0], r[$0 + 1], r[$0 + 2], r[$0 + 3])
                }
                shells = ViewFrame.Shells(
                    displacements: displacements, rotations: rotations, flags: try bytes(),
                    beamFlags: try bytes(),
                    damage: try damage(), beamDamage: try damage())
            }
            bodies.append(ViewFrame.Body(solids: solids, shells: shells))
        }
        guard at == data.endIndex else { throw bad() }
        return ViewFrame(time: time, field: Data(field), bodies: bodies)
    }

    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzfse) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzfse) as Data
    }
}

/// Records a run's timeline while it goes: the view's setup when it starts, then a frame each
/// `interval` of simulated time, each compressed off the main thread into its own file in a
/// staging folder, listed in `run.json` (`RunTimelineManifest`). When the frames would pass the
/// budget, the interval doubles, so that the timeline still spans the run, more coarsely.
@MainActor
final class RunTimelineRecorder {
    /// Where staged timelines are kept until their run is kept or forgotten.
    nonisolated static var stagingRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "BombCAD/timelines", directoryHint: .isDirectory)
    }

    /// Removes staged recordings untouched for a week: runs never kept, or kept in projects
    /// closed without saving. A project saved since holds its own copy.
    nonisolated static func removeStaleStaging(olderThan age: TimeInterval = 7 * 86_400) {
        let manager = FileManager.default
        guard
            let folders = try? manager.contentsOfDirectory(
                at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for folder in folders {
            let modified =
                (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? manager.removeItem(at: folder) }
        }
    }

    /// Frames recorded over a run by default, and the budget a run's timeline keeps within.
    nonisolated static let defaultFrames = 240
    nonisolated static let defaultBudgetBytes = 256 << 20
    /// The space a run's checkpoints keep within by default, beside its frames'.
    nonisolated static let defaultCheckpointBudgetBytes = 512 << 20

    let folder: URL
    /// The air's field is recorded every `stride` cells, at most about half a million texels (4 MB).
    let stride: Int
    private(set) var interval: Double
    private(set) var nextTime = 0.0
    private(set) var frames = 0
    /// Main-thread seconds spent capturing frames, and those after the first (which also builds
    /// what cuts the field out), and bytes written.
    private(set) var captureSeconds = 0.0
    private(set) var cappedSeconds = 0.0
    private(set) var setupBytes = 0
    private var manifest: RunTimelineManifest
    private let writer = TimelineWriter()
    private var finished = false
    private let started = ContinuousClock.now
    /// The share of the run's own time that capturing frames may take: past it, frames are skipped
    /// until the run has caught up, so a quick run records fewer.
    var maximumShare = 0.02

    /// The stride along each axis that leaves the field at most `texels`.
    nonisolated static func stride(for grid: SIMD3<Int>, texels: Int = 1 << 19) -> Int {
        let cells = Double(grid.x) * Double(grid.y) * Double(grid.z)
        return max(1, Int(cbrt(cells / Double(texels)).rounded(.up)))
    }

    /// The frames' share of the budget, and the checkpoints'.
    let framesBudget: Int
    let checkpointBudget: Int

    init(
        solver: BlastSolver, fingerprint: String, duration: Double, frames: Int = defaultFrames,
        budgetBytes: Int = defaultBudgetBytes, checkpointBudgetBytes: Int = 0
    ) throws {
        framesBudget = budgetBytes
        checkpointBudget = checkpointBudgetBytes
        folder = Self.stagingRoot.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        let grid = solver.grid
        stride = Self.stride(for: SIMD3(grid.nx, grid.ny, grid.nz))
        interval = max(duration / Double(max(frames, 1)), 1e-6)
        manifest = RunTimelineManifest(
            sceneFingerprint: fingerprint, settingsFingerprint: fingerprint,
            budgetBytes: budgetBytes + checkpointBudgetBytes)
        manifest.encodingVersion = TimelineCodec.version
        let setup = try TimelineCodec.compress(
            SceneViewCodec.encode(ViewSetup(solver: solver, fieldStride: stride)))
        try setup.write(to: folder.appending(path: "frames/setup.lzfse"))
        setupBytes = setup.count
        manifest.add(.init(kind: .setup, time: 0, step: 0, path: "frames/setup.lzfse", bytes: setup.count))
    }

    /// Records a frame if the run has reached the next frame's time, or `force` (its last), with
    /// `layers` as they are then, each a value or none; each is stored only when it has changed.
    func recordIfDue(
        _ solver: BlastSolver, fragments: FragmentLive?, freestanding: [SceneRenderer.OrientedBox],
        layers: () -> TimelineLayers = { TimelineLayers() }, force: Bool = false
    ) {
        guard !finished, solver.time >= nextTime - 1e-12 || force else { return }
        let start = ContinuousClock.now
        // The next frame's field is cut out by the batch that passes its time, while the GPU is
        // there anyway; set here, between batches, for the next.
        defer { solver.viewFieldCapture = finished ? nil : ViewFieldCapture(stride: stride, from: nextTime) }
        if !force, frames > 0, cappedSeconds >= maximumShare * (start - started).seconds {
            while nextTime <= solver.time + 1e-12 { nextTime += interval }
            return
        }
        let step = solver.stepCount
        // The last frame forced at the moment of the one before it takes its place, with its field.
        let again = frames > 0 && last?.step == step && pending.last?.time == solver.time
        guard let field = again ? last?.field : try? solver.viewField(stride: stride) else { return }
        if again {
            frames -= 1
            pending.removeLast()
        }
        let frame = TimelineFrame(
            view: ViewFrame(solver: solver, field: field), fragments: fragments, freestanding: freestanding,
            layers: keeper.store(layers(), frame: frames))
        let path = String(format: "frames/f-%06d.lzfse", frames)
        last = (step, field)
        writer.write(frame, to: folder.appending(path: path))
        let took = (ContinuousClock.now - start).seconds
        captureSeconds += took
        // The first frame, before any batch, also builds what cuts out the field, and waits for the
        // GPU to cut it out: once a run, it is left out of the cap. The others read the field the
        // batch that passed their time cut out (`ViewFieldCapture`), waiting for nothing; a frame
        // forced off its time, the last, may wait (about 10 ms for 25 million cells).
        if frames > 0 { cappedSeconds += took }
        frames += 1
        while nextTime <= solver.time + 1e-12 { nextTime += interval }
        // Each frame's size is known once written; the manifest takes it at the end.
        pending.append((path, frame.time, step))
        // Past the budget at this rate, the frames recorded and those to come each the size of those
        // written so far: record half as often. The writer may lag behind on a busy Mac, so the
        // frames still to be written count at that size too, not as nothing.
        let (written, count) = writer.progress
        if frames >= 8, count > 0,
            Double(written) / Double(count) * Double(frames + remainingFrames(at: solver.time))
                + Double(setupBytes)
                > Double(framesBudget)
        {
            interval *= 2
        }
    }

    private var pending: [(path: String, time: Double, step: Int)] = []
    /// The last frame's step and field.
    private var last: (step: Int, field: Data)?
    private var keeper = TimelineLayerKeeper()

    private func remainingFrames(at time: Double) -> Int {
        max(0, Int(((endTime - time) / interval).rounded(.up)))
    }

    /// The run's end, for the budget's projection.
    var endTime = 0.0

    /// Waits for every frame to be written and writes the manifest; the folder, or nil if nothing
    /// could be written.
    func finish() async -> URL? {
        finished = true
        let sizes = await writer.drain()
        for frame in pending {
            guard let bytes = sizes[frame.path] else { continue }
            manifest.add(
                .init(
                    kind: .frames, time: frame.time, step: frame.step, path: frame.path, bytes: bytes,
                    endTime: frame.time, count: 1))
        }
        guard !manifest.entries(.frames).isEmpty, let data = try? manifest.encoded(),
            (try? data.write(to: folder.appending(path: RunTimelineManifest.fileName))) != nil
        else { return nil }
        return folder
    }

    /// The bytes the timeline takes so far: its setup and every frame written.
    var bytes: Int { setupBytes + writer.bytesWritten }

    /// The checkpoints saved so far, in time order.
    var checkpoints: [RunTimelineManifest.Entry] { manifest.entries(.checkpoint) }

    /// Where the checkpoint at `step` goes, relative to the folder.
    static func checkpointPath(step: Int) -> String { String(format: "checkpoints/step-%06d", step) }

    /// Lists a checkpoint saved into the folder at `entry.path`. Past the checkpoints' budget,
    /// every other one is removed, keeping the first and the last and those saved by hand; the
    /// entries removed (an unpinned checkpoint that alone passes the budget among them).
    @discardableResult
    func addCheckpoint(_ entry: RunTimelineManifest.Entry) -> [RunTimelineManifest.Entry] {
        guard !finished else { return [] }
        manifest.add(entry)
        var removed: [RunTimelineManifest.Entry] = []
        while manifest.checkpointBytes > checkpointBudget {
            var thin = manifest.checkpointsToThin
            if thin.isEmpty, entry.pinned != true, manifest.entries(.checkpoint).contains(entry) {
                thin = [entry]
            }
            guard !thin.isEmpty else { break }
            for old in thin {
                manifest.remove(path: old.path)
                try? FileManager.default.removeItem(at: folder.appending(path: old.path))
            }
            removed += thin
        }
        return removed
    }

    func discard() {
        finished = true
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Encodes, compresses and writes frames on a queue of its own, one at a time, so that the run
/// waits for none of it.
final class TimelineWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.bombcad.timeline", qos: .utility)
    private let lock = NSLock()
    private var sizes: [String: Int] = [:]
    private var total = 0

    var bytesWritten: Int { lock.withLock { total } }
    /// The bytes written so far and the frames they are.
    var progress: (bytes: Int, frames: Int) { lock.withLock { (total, sizes.count) } }

    func write(_ frame: TimelineFrame, to url: URL) {
        queue.async { [self] in
            guard let data = try? TimelineCodec.compress(TimelineCodec.encode(frame)),
                (try? data.write(to: url)) != nil
            else { return }
            lock.withLock {
                // A frame written again in place of another counts once.
                let path = url.pathComponents.suffix(2).joined(separator: "/")
                total += data.count - (sizes[path] ?? 0)
                sizes[path] = data.count
            }
        }
    }

    func drain() async -> [String: Int] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: lock.withLock { sizes }) }
        }
    }
}

/// Plays a recorded timeline back: its setup uploaded once for the renderer, then any frame
/// uploaded over it on request, decoded from its file.
@MainActor
final class RunTimelinePlayer {
    let folder: URL
    let manifest: RunTimelineManifest
    let upload: ViewUpload
    /// The frames, in time order.
    let entries: [RunTimelineManifest.Entry]
    private(set) var index = -1
    private(set) var frame: TimelineFrame?

    var times: [Double] { entries.map(\.time) }

    init(folder: URL, device: MTLDevice) throws {
        self.folder = folder
        manifest = try RunTimelineManifest.decode(
            Data(contentsOf: folder.appending(path: RunTimelineManifest.fileName)))
        entries = manifest.entries(.frames)
        guard let setup = manifest.entries(.setup).first, !entries.isEmpty else {
            throw ProjectFileError.invalid("This run's timeline has no frames.")
        }
        let raw = try TimelineCodec.decompress(Data(contentsOf: folder.appending(path: setup.path)))
        upload = try ViewUpload(device: device, setup: SceneViewCodec.decodeSetup(raw))
    }

    /// The last frame at or before `time`.
    func index(at time: Double) -> Int {
        var low = 0
        var high = entries.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if entries[middle].time <= time + 1e-12 { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Whether its frames carry the layers that change (encoding version 2 on); a recording of
    /// 0.6.0 does not, and its layers are drawn as the run left them.
    var recordsLayers: Bool { manifest.encodingVersion >= 2 }

    /// Uploads frame `n` for drawing. Called only once the frames drawn from the last are done:
    /// the viewport draws one frame at a time and waits for none, so the upload goes between them.
    func show(_ n: Int) throws {
        let n = min(max(n, 0), entries.count - 1)
        guard n != index else { return }
        let data = try TimelineCodec.decompress(Data(contentsOf: folder.appending(path: entries[n].path)))
        var decoded = try TimelineCodec.decode(data, version: manifest.encodingVersion)
        decoded.layers = resolve(decoded.layers)
        try upload.apply(decoded.view)
        frame = decoded
        index = n
    }

    /// The layers of frames read for the layers they hold, by their file's number: the last few.
    private var held: [(frame: Int, layers: TimelineLayers)] = []

    /// `layers` with each layer that points to another frame taken from it, or none if that frame
    /// cannot be read.
    private func resolve(_ layers: TimelineLayers) -> TimelineLayers {
        func source(_ frame: Int) -> TimelineLayers? {
            if let found = held.first(where: { $0.frame == frame }) { return found.layers }
            let path = String(format: "frames/f-%06d.lzfse", frame)
            guard
                let data = try? TimelineCodec.decompress(Data(contentsOf: folder.appending(path: path))),
                let decoded = try? TimelineCodec.decode(
                    data, version: manifest.encodingVersion, layersOnly: true)
            else { return nil }
            held.append((frame, decoded.layers))
            if held.count > 4 { held.removeFirst() }
            return decoded.layers
        }
        func from<V>(_ layer: TimelineStored<V>, _ path: KeyPath<TimelineLayers, TimelineStored<V>>)
            -> TimelineStored<V>
        {
            guard case .sameAs(let frame) = layer else { return layer }
            return source(frame).flatMap { $0[keyPath: path].value }.map { .here($0) } ?? .none
        }
        var resolved = layers
        resolved.vents = from(layers.vents, \.vents)
        resolved.envelopeCodes = from(layers.envelopeCodes, \.envelopeCodes)
        resolved.thermal = from(layers.thermal, \.thermal)
        resolved.cloud = from(layers.cloud, \.cloud)
        return resolved
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// A timeline being replayed in the view: which frame is shown, and whether it plays on.
@MainActor @Observable
final class TimelinePlayback {
    let player: RunTimelinePlayer
    let title: String
    let scenario: Scenario
    /// Frames shown a second while playing.
    static let framesPerSecond = 24.0
    private(set) var index = 0
    private(set) var isPlaying = false
    /// For a kept run, its cloud (nil if it followed none), drawn from the frame it was handed
    /// over in; nil for the last run, whose cloud is the model's.
    let kept: CloudResult??
    /// The craters the replayed run's charges dig, whole: the view shades each as dug by the time
    /// shown (`CraterEstimate.grown(atTime:)`).
    let craters: [CraterEstimate]
    /// Called once each frame shown is uploaded, to draw its layers.
    @ObservationIgnored var onShow: (() -> Void)?
    @ObservationIgnored private let commandQueue: MTLCommandQueue
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        player: RunTimelinePlayer, title: String, scenario: Scenario, kept: CloudResult?? = nil,
        craters: [CraterEstimate] = [], commandQueue: MTLCommandQueue
    ) {
        self.player = player
        self.title = title
        self.scenario = scenario
        self.kept = kept
        self.craters = craters
        self.commandQueue = commandQueue
    }

    var count: Int { player.entries.count }
    var time: Double { player.entries[index].time }
    var startTime: Double { player.entries.first?.time ?? 0 }
    var endTime: Double { player.entries.last?.time ?? 0 }
    var frame: TimelineFrame? { player.frame }
    var recordsLayers: Bool { player.recordsLayers }
    var layers: TimelineLayers { player.frame?.layers ?? TimelineLayers() }

    /// Shows frame `n`, once the GPU has finished every frame drawn from the last: the queue runs
    /// in order, so an empty buffer's completion says they are done.
    func show(_ n: Int) throws {
        let n = min(max(n, 0), count - 1)
        if let fence = commandQueue.makeCommandBuffer() {
            fence.commit()
            fence.waitUntilCompleted()
        }
        try player.show(n)
        index = player.index
        onShow?()
    }

    func seek(to time: Double) { try? show(player.index(at: time)) }

    func step(_ frames: Int) {
        pause()
        try? show(index + frames)
    }

    func play() {
        guard !isPlaying else { return }
        if index >= count - 1 { try? show(0) }
        isPlaying = true
        task = Task { [weak self] in
            while let self, self.isPlaying, self.index < self.count - 1 {
                try? await Task.sleep(for: .seconds(1 / Self.framesPerSecond))
                guard self.isPlaying else { return }
                try? self.show(self.index + 1)
            }
            self?.isPlaying = false
        }
    }

    func pause() {
        isPlaying = false
        task?.cancel()
        task = nil
    }
}
