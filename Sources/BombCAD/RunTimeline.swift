import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import simd

/// One recorded moment of a run as the viewport draws it: the scene view (the blast's field and
/// every structure, `ViewFrame`), and what is drawn over it that moves, the fragments in flight and
/// the freestanding objects.
struct TimelineFrame: Sendable, Equatable {
    var view: ViewFrame
    var fragments: FragmentLive?
    var freestanding: [SceneRenderer.OrientedBox]

    var time: Double { view.time }
}

/// A frame's bytes: the scene view, compactly (`compact`), then whether there are fragments
/// and if so their count, how many of them are fragments rather than tracers, and
/// `FragmentLive.payload`, then the
/// freestanding boxes (eleven floats and a flag each), little-endian.
enum TimelineCodec {
    static func encode(_ frame: TimelineFrame) -> Data {
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
        return out
    }

    static func decode(_ data: Data) throws -> TimelineFrame {
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
        let view = try expand(bytes(try integer()))
        var fragments: FragmentLive?
        if try integer() == 1 {
            let particles = try integer()
            let count = try integer()
            var live = FragmentLive()
            try live.read(bytes(16 * particles))
            live.fragmentCount = min(count, particles)
            live.time = view.time
            fragments = live
        }
        let boxes = try integer()
        guard boxes <= (data.endIndex - at) / 44 else { throw bad() }
        var freestanding: [SceneRenderer.OrientedBox] = []
        for _ in 0..<boxes {
            let v = try (0..<11).map { _ in try float() }
            freestanding.append(
                .init(
                    centre: SIMD3(v[0], v[1], v[2]),
                    orientation: simd_quatf(vector: SIMD4(v[3], v[4], v[5], v[6])),
                    size: SIMD3(v[7], v[8], v[9]), isCar: v[10] != 0))
        }
        guard at == data.endIndex else { throw bad() }
        return TimelineFrame(view: view, fragments: fragments, freestanding: freestanding)
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

    let folder: URL
    /// The air's field is recorded every `stride` cells, at most about half a million texels (4 MB).
    let stride: Int
    private(set) var interval: Double
    private(set) var nextTime = 0.0
    private(set) var frames = 0
    /// Main-thread seconds spent capturing frames, and bytes written.
    private(set) var captureSeconds = 0.0
    private var cappedSeconds = 0.0
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

    init(
        solver: BlastSolver, fingerprint: String, duration: Double, frames: Int = defaultFrames,
        budgetBytes: Int = defaultBudgetBytes
    ) throws {
        folder = Self.stagingRoot.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        let grid = solver.grid
        stride = Self.stride(for: SIMD3(grid.nx, grid.ny, grid.nz))
        interval = max(duration / Double(max(frames, 1)), 1e-6)
        manifest = RunTimelineManifest(
            sceneFingerprint: fingerprint, settingsFingerprint: fingerprint, budgetBytes: budgetBytes)
        let setup = try TimelineCodec.compress(
            SceneViewCodec.encode(ViewSetup(solver: solver, fieldStride: stride)))
        try setup.write(to: folder.appending(path: "frames/setup.lzfse"))
        setupBytes = setup.count
        manifest.add(.init(kind: .setup, time: 0, step: 0, path: "frames/setup.lzfse", bytes: setup.count))
    }

    /// Records a frame if the run has reached the next frame's time, or `force` (its last).
    func recordIfDue(
        _ solver: BlastSolver, fragments: FragmentLive?, freestanding: [SceneRenderer.OrientedBox],
        force: Bool = false
    ) {
        guard !finished, solver.time >= nextTime - 1e-12 || force else { return }
        let start = ContinuousClock.now
        if !force, frames > 0, cappedSeconds >= maximumShare * (start - started).seconds {
            while nextTime <= solver.time + 1e-12 { nextTime += interval }
            return
        }
        guard let field = try? solver.viewField(stride: stride) else { return }
        let frame = TimelineFrame(
            view: ViewFrame(solver: solver, field: field), fragments: fragments, freestanding: freestanding)
        let path = String(format: "frames/f-%06d.lzfse", frames)
        let step = solver.stepCount
        writer.write(frame, to: folder.appending(path: path))
        let took = (ContinuousClock.now - start).seconds
        captureSeconds += took
        // The first frame, before any batch, also builds what cuts out the field: once a run, it is
        // left out of the cap. Each frame waits for the GPU to cut out its field (about 10 ms for
        // 25 million cells), since a batch cuts it out only when it ends on its time limit, and
        // landing batches on frames would change the run.
        if frames > 0 { cappedSeconds += took }
        frames += 1
        while nextTime <= solver.time + 1e-12 { nextTime += interval }
        // Each frame's size is known once written; the manifest takes it at the end.
        pending.append((path, frame.time, step))
        // Past half the budget with half the run or more to go: record half as often.
        let written = writer.bytesWritten + setupBytes
        if frames >= 8,
            Double(written) / Double(frames) * Double(remainingFrames(at: solver.time)) + Double(written)
                > Double(manifest.budgetBytes)
        {
            interval *= 2
        }
    }

    private var pending: [(path: String, time: Double, step: Int)] = []

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

    func discard() {
        finished = true
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Encodes, compresses and writes frames on a queue of its own, one at a time, so that the run
/// waits for none of it.
private final class TimelineWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.bombcad.timeline", qos: .utility)
    private let lock = NSLock()
    private var sizes: [String: Int] = [:]
    private var total = 0

    var bytesWritten: Int { lock.withLock { total } }

    func write(_ frame: TimelineFrame, to url: URL) {
        queue.async { [self] in
            guard let data = try? TimelineCodec.compress(TimelineCodec.encode(frame)),
                (try? data.write(to: url)) != nil
            else { return }
            lock.withLock {
                sizes[url.pathComponents.suffix(2).joined(separator: "/")] = data.count
                total += data.count
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

    /// Uploads frame `n` for drawing. Called only once the frames drawn from the last are done:
    /// the viewport draws one frame at a time and waits for none, so the upload goes between them.
    func show(_ n: Int) throws {
        let n = min(max(n, 0), entries.count - 1)
        guard n != index else { return }
        let data = try TimelineCodec.decompress(Data(contentsOf: folder.appending(path: entries[n].path)))
        let decoded = try TimelineCodec.decode(data)
        try upload.apply(decoded.view)
        frame = decoded
        index = n
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
    @ObservationIgnored private let commandQueue: MTLCommandQueue
    @ObservationIgnored private var task: Task<Void, Never>?

    init(player: RunTimelinePlayer, title: String, scenario: Scenario, commandQueue: MTLCommandQueue) {
        self.player = player
        self.title = title
        self.scenario = scenario
        self.commandQueue = commandQueue
    }

    var count: Int { player.entries.count }
    var time: Double { player.entries[index].time }
    var startTime: Double { player.entries.first?.time ?? 0 }
    var endTime: Double { player.entries.last?.time ?? 0 }
    var frame: TimelineFrame? { player.frame }

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
