import BlastCore
import BlastRender
import DocumentKit
import Foundation
import ImageIO
import Metal

/// A run on another Mac, watched from this one: the remote Mac's GPU runs the blast and sends,
/// frame by frame, what a viewer draws rather than the solver's state: the paint on the ground
/// (overpressure now, the peak and impulse so far) and the structure's surface. A viewer needs
/// only the latest frame, so the worker builds one only when fewer than `window` sent are still
/// unacknowledged, and the run never waits for the viewer however slow the link.
struct WatchJob: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var project: SweepWorkerArchive
    /// Whole milliseconds of simulated time between frames.
    var frameInterval = 1
    /// What to send; nil to run unwatched, for comparison.
    var view: ViewSpec?
    /// Whether a Mac nearby relaying the session keeps the run going should the connection drop,
    /// for the app to watch again or fetch the result later (`SessionRelay`); a run asked for over
    /// SSH, or by `BombCAD watch`, stops with its connection.
    var keepsRunning = false
}

struct ViewSpec: Codable, Equatable, Sendable {
    /// Frames sent but not yet acknowledged before the worker stops building more.
    var window = 2
    var compression = ViewCompression.lz4
    var structure = true
    /// With a stride, the overpressure in every `stride`-th cell of the air as well, a volume to
    /// draw.
    var volumeStride: Int?
    /// With a stride, the scene as the app's renderer draws it as well: a `ViewSetup` once, then a
    /// `ViewFrame` in each frame, the field `stride` times coarser than the solver's grid (see
    /// `SceneViewCodec`).
    var sceneStride: Int?
    /// Seconds the worker waits at the end for the frames still unacknowledged, for their lag;
    /// those not in by then go uncounted.
    var ackWait = 2.0
}

enum ViewCompression: String, Codable, Equatable, Sendable, CaseIterable {
    case none, lz4, lzfse, zlib

    var algorithm: NSData.CompressionAlgorithm? {
        switch self {
        case .none: nil
        case .lz4: .lz4
        case .lzfse: .lzfse
        case .zlib: .zlib
        }
    }
}

/// One frame for a viewer: the ground's paint over the whole grid, three half-precision values a
/// column (overpressure now and the peak so far, kPa, and positive impulse so far, Pa·s, each held
/// to half precision's ±65,504; NaN over a solid cell), then, with a structure, its surface's points (three 32-bit floats each, metres) and
/// each face's damage (half precision), and its faces (four 32-bit indices each) whenever their
/// number changed since the last frame sent; then, if asked for, the overpressure in every
/// `stride`-th cell of the air, kPa in half precision (held the same way), x fastest.
enum WatchFrame {
    /// Pascals, as kilopascals, and impulse as it is.
    static let groundScales: [Float] = [1e-3, 1e-3, 1]

    /// `value` in half precision, held to its largest finite value: a viewer's colours, and close
    /// in the peaks reach gigapascals.
    static func half(_ value: Float) -> Float16 {
        value.isNaN
            ? .nan
            : Float16(
                min(
                    max(value, -Float(Float16.greatestFiniteMagnitude)),
                    Float(Float16.greatestFiniteMagnitude)))
    }

    struct Header: Codable, Equatable, Sendable {
        var frame: Int
        var time: Double
        var cellSize: Float
        var counts: SIMD2<Int32>
        var points: Int
        var faces: Int
        var quadsIncluded: Bool
        /// The volume's samples along each axis, zero without one.
        var volume = SIMD3<Int32>.zero
        /// The scene view's bytes (`SceneViewCodec`), last, zero without one.
        var scene = 0
        /// Before compression.
        var rawBytes: Int
        var compression: ViewCompression
    }

    /// The frame's values, packed (not yet compressed), and the header's sizes.
    static func pack(
        ground: GroundSlice, surface: StructureSurface?, includeQuads: Bool, volume: AirSlice? = nil,
        scene: Data? = nil
    ) -> Data {
        var data = Data(capacity: 2 * ground.values.count + 12 * (surface?.points.count ?? 0))
        ground.values.enumerated().map { half($0.element * groundScales[$0.offset % 3]) }
            .withUnsafeBytes { data.append(contentsOf: $0) }
        if let surface {
            surface.points.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBytes { data.append(contentsOf: $0) }
            surface.damage.map(Float16.init).withUnsafeBytes { data.append(contentsOf: $0) }
            if includeQuads { surface.quads.withUnsafeBytes { data.append(contentsOf: $0) } }
        }
        if let volume {
            let ambient = volume.ambient.pressure / 1000
            Swift.stride(from: 4, to: volume.values.count, by: 5).map {
                half(Float(volume.values[$0]) * 1000 - ambient)
            }
            .withUnsafeBytes { data.append(contentsOf: $0) }
        }
        if let scene { data.append(scene) }
        return data
    }

    /// What a viewer would draw from: the ground's values back in single precision, and the
    /// surface's points and damage.
    struct Decoded {
        var ground: [Float]
        var points: [SIMD3<Float>]
        var damage: [Float]
        var quads: [Int32]?
        var volume: [Float]
        /// The scene view's frame, encoded, if sent.
        var scene: Data?

        /// The largest peak overpressure on open ground, Pa.
        var peak: Float {
            var largest: Float = 0
            for index in Swift.stride(from: 1, to: ground.count, by: 3) where !ground[index].isNaN {
                largest = max(largest, ground[index])
            }
            return largest
        }
    }

    static func decode(_ header: Header, payload: Data) throws -> Decoded {
        let raw: Data
        if let algorithm = header.compression.algorithm {
            raw = try (payload as NSData).decompressed(using: algorithm) as Data
        } else {
            raw = payload
        }
        let columns = 3 * Int(header.counts.x) * Int(header.counts.y)
        let samples = Int(header.volume.x) * Int(header.volume.y) * Int(header.volume.z)
        let expected =
            2 * columns + 12 * header.points + 2 * header.faces
            + (header.quadsIncluded ? 16 * header.faces : 0) + 2 * samples + header.scene
        guard raw.count == expected, raw.count == header.rawBytes else {
            throw ProjectFileError.invalid("A view frame held \(raw.count) bytes, not \(expected).")
        }
        return raw.withUnsafeBytes { bytes in
            var offset = 0
            func take<T: BitwiseCopyable>(_ count: Int, _: T.Type) -> [T] {
                let length = count * MemoryLayout<T>.size
                defer { offset += length }
                return [T](unsafeUninitializedCapacity: count) { values, initialized in
                    UnsafeMutableRawBufferPointer(values).copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + length]))
                    initialized = count
                }
            }
            let ground = take(columns, Float16.self).enumerated().map {
                Float($0.element) / groundScales[$0.offset % 3]
            }
            let coordinates = take(3 * header.points, Float.self)
            let points = (0..<header.points).map {
                SIMD3(coordinates[3 * $0], coordinates[3 * $0 + 1], coordinates[3 * $0 + 2])
            }
            let damage = take(header.faces, Float16.self).map(Float.init)
            let quads = header.quadsIncluded ? take(4 * header.faces, Int32.self) : nil
            let volume = take(samples, Float16.self).map(Float.init)
            // Last, and copied whole: it is most of a frame with a scene view.
            let scene = header.scene > 0 ? Data(raw.suffix(header.scene)) : nil
            return Decoded(
                ground: ground, points: points, damage: damage, quads: quads, volume: volume, scene: scene)
        }
    }
}

/// What sending a watched run's frames cost, on the worker's clock.
struct ViewStats: Codable, Equatable, Sendable {
    /// Frames the run reached, and those built and sent.
    var frames = 0
    var sent = 0
    var rawBytes = 0
    var sentBytes = 0
    /// For each frame sent, seconds from its values being read to its acknowledgement arriving
    /// (the round trip included); none for a frame never acknowledged.
    var lags: [Double] = []
    /// Seconds reading frames on the thread that drives the GPU, the run waiting, and packing and
    /// compressing them on the writer's queue, the run not waiting.
    var readSeconds = 0.0
    var packSeconds = 0.0
    /// The run's own seconds there, from start to its result.
    var runSeconds = 0.0
}

/// The worker's side of a watched run: builds a frame only while fewer than the window are
/// unacknowledged, packs and compresses it on the writer's queue, and keeps the costs.
final class ViewSender: @unchecked Sendable {
    private let id: UUID
    private let writer: SweepWorkerWriter
    private let spec: ViewSpec
    private let lock = NSLock()
    private var inFlight: [Int: ContinuousClock.Instant] = [:]
    private var stats = ViewStats()
    private var lastFaces = -1
    /// Whether the scene view's setup has gone.
    private var setupSent = false

    init(id: UUID, writer: SweepWorkerWriter, spec: ViewSpec) {
        self.id = id
        self.writer = writer
        self.spec = spec
    }

    /// Called on each frame the run reaches, while no batch is in flight.
    func frame(_ solver: BlastSolver, number: Int, last: Bool) {
        let wanted = lock.withLock {
            stats.frames += 1
            return last || inFlight.count < spec.window
        }
        guard wanted else { return }
        let start = ContinuousClock.now
        let extent = SIMD2(Float(solver.grid.nx), Float(solver.grid.ny)) * solver.grid.cellSize
        let ground = solver.groundSlice(low: .zero, high: extent)
        // A scene view carries the structure's meshes already.
        let surface = spec.structure && spec.sceneStride == nil ? solver.structureSurface() : nil
        let volume = spec.volumeStride.map { solver.airSlice(region: Self.domain(solver), stride: $0) }
        let scene = spec.sceneStride.flatMap { sceneFrame(solver, stride: $0) }
        let read = start.duration(to: .now)
        let faces = surface?.faceCount ?? 0
        let includeQuads = surface != nil && faces != lastFaces
        lastFaces = faces
        let columns = 3 * Int(ground.counts.x) * Int(ground.counts.y)
        let header = WatchFrame.Header(
            frame: number, time: solver.time, cellSize: ground.cellSize, counts: ground.counts,
            points: surface?.points.count ?? 0, faces: faces, quadsIncluded: includeQuads,
            volume: volume?.counts ?? .zero, scene: scene.map(SceneViewCodec.size) ?? 0,
            rawBytes: 2 * columns + 12 * (surface?.points.count ?? 0) + 2 * faces
                + (includeQuads ? 16 * faces : 0) + 2 * (volume?.values.count ?? 0) / 5
                + (scene.map(SceneViewCodec.size) ?? 0),
            compression: spec.compression)
        lock.withLock {
            inFlight[number] = start
            stats.sent += 1
            stats.readSeconds += read.seconds
        }
        writer.enqueue(.view(id, header)) { [self] in
            let packing = ContinuousClock.now
            var payload = WatchFrame.pack(
                ground: ground, surface: surface, includeQuads: includeQuads, volume: volume,
                scene: scene.map(SceneViewCodec.encode))
            let raw = payload.count
            payload = Self.compress(payload, spec.compression)
            let took = packing.duration(to: .now)
            lock.withLock {
                stats.rawBytes += raw
                stats.sentBytes += payload.count
                stats.packSeconds += took.seconds
            }
            return payload
        }
    }

    /// The scene view's frame now, its setup sent first the first time; encoded later, on the
    /// writer's queue.
    private func sceneFrame(_ solver: BlastSolver, stride: Int) -> ViewFrame? {
        if !setupSent {
            setupSent = true
            let setup = SceneViewCodec.encode(ViewSetup(solver: solver, fieldStride: stride))
            let compression = spec.compression
            writer.enqueue(.viewSetup(id)) { Self.compress(setup, compression) }
        }
        guard let field = try? solver.viewField(stride: stride) else { return nil }
        return ViewFrame(solver: solver, field: field)
    }

    static func compress(_ data: Data, _ compression: ViewCompression) -> Data {
        guard let algorithm = compression.algorithm,
            let compressed = try? (data as NSData).compressed(using: algorithm) as Data
        else { return data }
        return compressed
    }

    /// What to cut out on the GPU at the end of the next frame's batch, the volume and the scene
    /// view's field, if a frame is likely to be built then; one built without them reads them
    /// after, waiting for the GPU.
    func frameRequest(_ solver: BlastSolver) -> FrameRequest {
        var request = FrameRequest()
        guard lock.withLock({ inFlight.count < spec.window }) else { return request }
        request.airSlice = spec.volumeStride.map { AirSliceRequest(region: Self.domain(solver), stride: $0) }
        request.viewField = spec.sceneStride
        return request
    }

    private static func domain(_ solver: BlastSolver) -> Box {
        let grid = solver.grid
        return Box(
            min: .zero, max: SIMD3<Float>(Float(grid.nx), Float(grid.ny), Float(grid.nz)) * grid.cellSize)
    }

    func acknowledge(_ frame: Int) {
        let now = ContinuousClock.now
        lock.withLock {
            if let start = inFlight.removeValue(forKey: frame) {
                stats.lags.append(start.duration(to: now).seconds)
            }
        }
    }

    /// The costs, once every frame sent is acknowledged or `spec.ackWait` has passed.
    func finish(runSeconds: Double) async -> ViewStats {
        let deadline = ContinuousClock.now + .seconds(spec.ackWait)
        while lock.withLock({ !inFlight.isEmpty }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock {
            stats.runSeconds = runSeconds
            return stats
        }
    }
}

/// `BombCAD watch`: runs a project on another Mac and watches it from this one (see `WatchJob`).
@MainActor
enum HeadlessWatch {
    static let usage = """
        Usage: BombCAD watch (<project.bombcad | layout.json> | --preset <layout>)
                             (--on <ssh host> | --stdio) [--window <frames>]
                             [--compression none|lz4|lzfse|zlib] [--no-structure] [--volume <stride>]
                             [--scene <stride>] [--render <folder> [--render-every <frames>]]
                             [--no-view] [--frame-interval <ms>] [--name <name>] [--out <new.bombcad>]
                             [--resolution coarse|medium|fine|<metres>] [--mass <kg TNT>] [--duration <seconds>]

        Runs the project on another Mac, as a thin client would: that Mac's GPU runs the blast and
        sends back, every --frame-interval milliseconds of simulated time (1 by default), what a
        viewer draws: the ground's paint over the whole grid (overpressure, peak, impulse, in half
        precision) and, unless --no-structure or --scene, the structure's surface; --volume adds the
        overpressure in every stride-th cell of the air, a volume to draw. --scene adds the scene as
        the app's renderer draws it (the blast's field, stride times coarser than the solver's grid,
        and every structure's mesh), and --render draws it here with that renderer, writing a PNG
        image every --render-every frames (10) and the last to the folder; --render alone takes a
        stride of 2. A frame is built only while fewer than --window (2) are unacknowledged, so the
        run never waits for this Mac.
        Frames are compressed with --compression (lz4 by default). --no-view runs it unwatched, for
        comparison. The run comes back at the end, written with --out. --preset runs a built-in
        layout (streetCanyon, officeTower, …) for its default duration in place of a project.
        --on starts the worker over SSH, copying this build there first; --stdio talks to a worker
        on this process's standard input and output, as when a worker on another Mac is piped to
        this command over SSH, and then writes everything else to standard error. Prints what
        crossing the link cost.
        """

    struct Options {
        var run: HeadlessRun.Options
        var host: String?
        var stdio = false
        var view: ViewSpec? = ViewSpec()
        /// A built-in layout to run in place of a project, with its own duration.
        var preset: ScenarioPreset?
        /// Where to write the scene view as the app's renderer draws it here, every `renderEvery`
        /// frames and the last.
        var render: URL?
        var renderEvery = 10

        static func parse(_ arguments: [String]) throws -> Options {
            var rest: [String] = []
            var host: String?
            var stdio = false
            var view: ViewSpec? = ViewSpec()
            var spec = ViewSpec()
            var preset: ScenarioPreset?
            var render: URL?
            var renderEvery = 10
            var index = 0
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw ProjectFileError.invalid("Give \(arguments[index]) a value.")
                }
                index += 1
                return arguments[index]
            }
            while index < arguments.count {
                switch arguments[index] {
                case "--on": host = try value()
                case "--stdio": stdio = true
                case "--preset":
                    let name = try value()
                    guard let named = ScenarioPreset(rawValue: name) else {
                        throw ProjectFileError.invalid(
                            "--preset takes one of \(ScenarioPreset.allCases.map(\.rawValue).joined(separator: ", "))."
                        )
                    }
                    preset = named
                case "--no-view": view = nil
                case "--no-structure": spec.structure = false
                case "--scene":
                    guard let stride = Int(try value()), stride >= 1 else {
                        throw ProjectFileError.invalid(
                            "--scene takes the field's stride, a whole number of cells, 1 or more.")
                    }
                    spec.sceneStride = stride
                case "--render": render = URL(filePath: try value())
                case "--render-every":
                    guard let every = Int(try value()), every >= 1 else {
                        throw ProjectFileError.invalid(
                            "--render-every takes a whole number of frames, 1 or more.")
                    }
                    renderEvery = every
                case "--volume":
                    guard let stride = Int(try value()), stride >= 1 else {
                        throw ProjectFileError.invalid(
                            "--volume takes a stride, a whole number of cells, 1 or more.")
                    }
                    spec.volumeStride = stride
                case "--window":
                    guard let window = Int(try value()), window >= 1 else {
                        throw ProjectFileError.invalid("--window takes a whole number of frames, 1 or more.")
                    }
                    spec.window = window
                case "--compression":
                    guard let compression = ViewCompression(rawValue: try value()) else {
                        throw ProjectFileError.invalid("--compression takes none, lz4, lzfse or zlib.")
                    }
                    spec.compression = compression
                default: rest.append(arguments[index])
                }
                index += 1
            }
            guard (host == nil) != !stdio else {
                throw ProjectFileError.invalid("Give either --on <ssh host> or --stdio.")
            }
            if let host { try RemoteSweepWorker.validate(host) }
            let run = try HeadlessRun.Options.parse(preset == nil ? rest : rest + ["/dev/null"])
            for (option, given) in [
                ("--usd", run.usd != nil), ("--vdb", run.vdb != nil), ("--fragments", run.fragments != nil),
                ("--thermal", run.thermal != nil), ("--cloud", run.cloud != nil),
                ("--ground-shock", run.groundShock != nil), ("--consumer", !run.consumers.isEmpty),
                ("--csv", run.csv != nil), ("--advise", run.advise != nil),
            ] where given {
                throw ProjectFileError.invalid("\(option) is not for a watched run.")
            }
            if render != nil, spec.sceneStride == nil { spec.sceneStride = 2 }
            if render != nil, view == nil {
                throw ProjectFileError.invalid("--render needs a view; drop --no-view.")
            }
            return Options(
                run: run, host: host, stdio: stdio, view: view.map { _ in spec }, preset: preset,
                render: render,
                renderEvery: renderEvery)
        }
    }

    static func main(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let options: Options
        do {
            options = try Options.parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n\n\(usage)\n".utf8))
            return 2
        }
        // With --stdio, standard output is the worker's.
        let say: (String) -> Void =
            options.stdio
            ? { FileHandle.standardError.write(Data(($0 + "\n").utf8)) } : { print($0) }
        do {
            for line in try await watch(options) { say(line) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Watch failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Runs the watched job and returns the summary's lines.
    static func watch(_ options: Options) async throws -> [String] {
        var document: ProjectDocument
        if let preset = options.preset {
            document = ProjectDocument(scenario: preset.scenario)
            document.runSettings?.duration = SimulationModel.defaultDuration(for: preset.scenario)
        } else {
            document = try ProjectDocument.read(from: options.run.project)
        }
        let original = document
        let inputs = try HeadlessRun.inputs(for: document, options: options.run)
        document.scenario = inputs.scenario
        document.runSettings = inputs.settings
        let earlier = document.savedRuns
        document.savedRuns = []
        let name = options.run.name ?? HeadlessRun.defaultName(avoiding: earlier)
        let connected = ContinuousClock.now
        let client: SweepWorkerClient
        if let host = options.host {
            client = try await RemoteSweepWorker.connect(host: host)
        } else {
            client = SweepWorkerClient(
                name: "standard input", input: .standardInput, output: .standardOutput)
            _ = try await client.start()
        }
        defer { client.close() }
        let connecting = connected.duration(to: .now)
        let archive = try document.makeArchive()
        let job = WatchJob(
            id: UUID(), name: name, project: SweepWorkerArchive(archive),
            frameInterval: options.run.frameInterval,
            view: options.view)
        let projectBytes = archive.files.values.reduce(0) { $0 + $1.count }
        let progressStream = options.stdio ? FileHandle.standardError : FileHandle.standardOutput

        let watcher = Watcher()
        if options.view?.sceneStride != nil {
            watcher.scene = try SceneWatcher(
                scenario: inputs.scenario, render: options.render, every: options.renderEvery)
        }
        let start = ContinuousClock.now
        let compression = options.view?.compression ?? .none
        let result = try await client.watch(
            job,
            setup: { payload in
                do {
                    try watcher.scene?.start(decompressing: payload, compression)
                } catch {
                    watcher.scene?.failure = error.localizedDescription
                }
            },
            frame: { header, payload in
                watcher.take(header, payload: payload, client: client, id: job.id, start: start)
                if ContinuousClock.now - watcher.printed > .seconds(1) {
                    watcher.printed = .now
                    progressStream.write(
                        Data(
                            String(
                                format: "  %.1f ms: frame %d, peak on the ground %.0f kPa, %d frames shown\n",
                                header.time * 1000, header.frame, watcher.lastPeak / 1000,
                                watcher.arrivals.count
                            ).utf8))
                }
            })
        let total = start.duration(to: .now).seconds
        let returned = try ProjectDocument(archive: result.archive.archive())
        guard let run = returned.savedRuns.first(where: { $0.name == name }) else {
            throw ProjectFileError.invalid("The worker on \(client.name) returned no result for \(name).")
        }
        guard
            run.inputSHA256
                == (try SavedSimulationRun.fingerprint(inputs.scenario, settings: inputs.settings))
        else {
            throw ProjectFileError.invalid("The worker on \(client.name) ran different inputs for \(name).")
        }
        if let out = options.run.out {
            var kept = original
            kept.savedRuns.append(run)
            try kept.makeArchive().fileWrapper().write(to: out, originalContentsURL: nil)
        }
        let resultBytes = result.archive.files.values.reduce(0) { $0 + $1.count }
        let device = client.hello?.device ?? "unknown GPU"
        var lines = [
            String(
                format:
                    "Watched %@ on %@ (%@): %d steps, %.3f s simulated, %.1f s from the job sent to the result back",
                name, client.name, device, run.stepCount, inputs.settings.duration, total),
            String(
                format: "  Connecting %.1f s; the project out %.0f kB, the result back %.2f MB in %.2f s",
                connecting.seconds, Double(projectBytes) / 1e3, Double(resultBytes) / 1e6,
                result.statsArrived.map { $0.duration(to: result.finished).seconds } ?? .nan),
        ]
        guard let stats = result.stats else {
            lines.append(String(format: "  Unwatched: the run took %.1f s there", total))
            return lines
        }
        let intervals = zip(watcher.arrivals.dropFirst(), watcher.arrivals).map { $0.0 - $0.1 }
        lines += [
            String(
                format:
                    "  The run took %.1f s there; reading frames held it %.2f s (%.2f ms a frame sent), packing them %.2f s off its thread",
                stats.runSeconds, stats.readSeconds, 1000 * stats.readSeconds / Double(max(stats.sent, 1)),
                stats.packSeconds),
            String(
                format:
                    "  Frames: %d of %d sent (window %d), %.1f MB raw, %.1f MB sent (%@, %.1f×), %.1f MB/s on average, %.0f kB a frame",
                stats.sent, stats.frames, options.view?.window ?? 0, Double(stats.rawBytes) / 1e6,
                Double(stats.sentBytes) / 1e6, options.view?.compression.rawValue ?? "",
                Double(stats.rawBytes) / Double(max(stats.sentBytes, 1)),
                Double(stats.sentBytes) / 1e6 / total,
                Double(stats.sentBytes) / 1e3 / Double(max(stats.sent, 1))),
            "  Shown here: \(watcher.arrivals.count) frames, an update every "
                + describe(intervals.map { $0 * 1000 }, unit: "ms")
                + String(
                    format: "; decoding %.2f ms a frame",
                    1000 * watcher.decodeSeconds / Double(max(watcher.arrivals.count, 1))),
            "  Lag, frame read there to its acknowledgement back: "
                + describe(stats.lags.map { $0 * 1000 }, unit: "ms"),
        ]
        if let scene = watcher.scene {
            scene.finish()
            lines.append(scene.summary(stride: options.view?.sceneStride ?? 1))
        }
        return lines
    }

    /// The median, or nil for none.
    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// Median, 95th percentile and largest.
    nonisolated static func describe(_ values: [Double], unit: String) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double {
            sorted[min(Int((Double(sorted.count - 1) * q).rounded()), sorted.count - 1)]
        }
        return String(
            format: "median %.1f %@, 95%% %.1f %@, largest %.1f %@", at(0.5), unit, at(0.95), unit,
            sorted.last!, unit)
    }

    /// This side's record of the frames as they arrive.
    @MainActor private final class Watcher {
        var arrivals: [Double] = []
        var decodeSeconds = 0.0
        var lastPeak: Float = 0
        var printed = ContinuousClock.now
        var scene: SceneWatcher?

        func take(
            _ header: WatchFrame.Header, payload: Data, client: SweepWorkerClient, id: UUID,
            start: ContinuousClock.Instant
        ) {
            let arrived = ContinuousClock.now
            arrivals.append(start.duration(to: arrived).seconds)
            if let decoded = try? WatchFrame.decode(header, payload: payload) {
                lastPeak = decoded.peak
                decodeSeconds += arrived.duration(to: .now).seconds
                if let bytes = decoded.scene { scene?.take(bytes, frame: header.frame) }
            } else {
                decodeSeconds += arrived.duration(to: .now).seconds
            }
            client.writer.enqueue(.viewAck(id, header.frame))
        }
    }
}

/// The watcher's scene view: the run elsewhere drawn by the app's own renderer here, from the
/// `ViewSetup` and `ViewFrame`s it sends, uploaded into a `ViewUpload`, every `every` frames and
/// the last written to `render` as PNG images if given.
@MainActor
final class SceneWatcher {
    private let scenario: Scenario
    private let render: URL?
    private let every: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SceneRenderer
    private var upload: ViewUpload?
    private var lastFrame: Int?
    private var lastRendered: Int?
    var failure: String?
    private(set) var setupBytes = 0
    private(set) var frames = 0
    private(set) var rendered = 0
    private var decodeSeconds = 0.0
    private var applySeconds = 0.0
    private var renderSeconds = 0.0
    private var fieldSize = SIMD3<Int>.zero

    init(scenario: Scenario, render: URL?, every: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ProjectFileError.invalid("Drawing the scene here needs a Metal device.")
        }
        if let render {
            try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        }
        self.scenario = scenario
        self.render = render
        self.every = every
        self.device = device
        self.queue = queue
        renderer = try SceneRenderer(device: device)
    }

    func start(decompressing payload: Data, _ compression: ViewCompression) throws {
        let raw =
            try compression.algorithm.map { try (payload as NSData).decompressed(using: $0) as Data }
            ?? payload
        setupBytes = payload.count
        let setup = try SceneViewCodec.decodeSetup(raw)
        fieldSize = setup.fieldSize
        let upload = try ViewUpload(device: device, setup: setup)
        renderer.setScene(scenario, view: upload.view)
        self.upload = upload
    }

    /// Uploads a frame; snapshots run synchronously, so the GPU is done with the last one.
    func take(_ bytes: Data, frame: Int) {
        guard let upload, failure == nil else { return }
        do {
            let start = ContinuousClock.now
            let decoded = try SceneViewCodec.decodeFrame(bytes)
            let decodedAt = ContinuousClock.now
            try upload.apply(decoded)
            applySeconds += decodedAt.duration(to: .now).seconds
            decodeSeconds += start.duration(to: decodedAt).seconds
            frames += 1
            lastFrame = frame
            if render != nil, frame % every == 0 { snapshot(frame) }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Draws the last frame, if it was not drawn already.
    func finish() {
        if render != nil, let lastFrame, lastRendered != lastFrame { snapshot(lastFrame) }
    }

    private func snapshot(_ frame: Int) {
        guard let render else { return }
        let start = ContinuousClock.now
        guard
            let image = renderer.snapshot(
                commandQueue: queue, width: 1280, height: 720, camera: .framing(scenario))?.image
        else {
            failure = "The renderer drew nothing."
            return
        }
        let url = render.appending(path: String(format: "frame-%04d.png", frame))
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        renderSeconds += start.duration(to: .now).seconds
        rendered += 1
        lastRendered = frame
    }

    func summary(stride: Int) -> String {
        if let failure { return "  Scene view failed: \(failure)" }
        let perFrame = { (seconds: Double) in 1000 * seconds / Double(max(self.frames, 1)) }
        return String(
            format:
                "  Scene view: field %d × %d × %d (every %d cells), setup %.2f MB; %d frames, decoding %.1f ms and uploading %.1f ms a frame%@",
            fieldSize.x, fieldSize.y, fieldSize.z, stride, Double(setupBytes) / 1e6, frames,
            perFrame(decodeSeconds),
            perFrame(applySeconds),
            rendered > 0
                ? String(
                    format: "; %d drawn here to %@, %.0f ms each", rendered, render?.path ?? "",
                    1000 * renderSeconds / Double(rendered)) : "")
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
