import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("A watched run's frames")
struct ViewFrameTests {
    @Test("A frame packs and unpacks the ground's paint in half precision and the surface exactly")
    func roundTrip() throws {
        // Peaks to half precision's limit in kilopascals and past it, as close in.
        let values: [Float] = [1200, 35_000, 12.5, .nan, .nan, .nan, -400, 80_000_000, 31.25, 0, 0, 0]
        let ground = GroundSlice(
            time: 0.002, cellSize: 0.5, grid: SIMD3(2, 2, 4), first: .zero, counts: SIMD2(2, 2),
            values: values,
            ambientDensity: 1.2, ambientPressure: 101_325, gamma: 1.4)
        var surface = StructureSurface()
        surface.points = [SIMD3(0, 0, 0), SIMD3(1.25, 0, 0), SIMD3(1.25, 2, 0), SIMD3(0, 2, 0.001)]
        surface.quads = [0, 1, 2, 3]
        surface.damage = [0.5]
        for compression in ViewCompression.allCases {
            for quads in [true, false] {
                let raw = ViewFrame.pack(ground: ground, surface: surface, includeQuads: quads)
                let payload =
                    try compression.algorithm.map { try (raw as NSData).compressed(using: $0) as Data } ?? raw
                let header = ViewFrame.Header(
                    frame: 2, time: 0.002, cellSize: 0.5, counts: SIMD2(2, 2), points: 4, faces: 1,
                    quadsIncluded: quads, rawBytes: raw.count, compression: compression)
                let decoded = try ViewFrame.decode(header, payload: payload)
                for (sent, back) in zip(values, decoded.ground) {
                    let held = min(sent, 65_504_000)
                    #expect(sent.isNaN ? back.isNaN : abs(back - held) <= abs(held) / 1000)
                }
                #expect(decoded.points == surface.points && decoded.damage == [0.5])
                #expect(decoded.quads == (quads ? [0, 1, 2, 3] : nil))
                #expect(abs(decoded.peak - 65_504_000) < 100)
            }
        }
    }

    @Test("A frame's volume carries the overpressure, kPa, of each sample")
    func volume() throws {
        let ground = GroundSlice(
            time: 0, cellSize: 1, grid: SIMD3(1, 1, 2), first: .zero, counts: SIMD2(1, 1), values: [0, 0, 0],
            ambientDensity: 1.2, ambientPressure: 101_325, gamma: 1.4)
        // Density, velocity and pressure, MPa, for two samples.
        let air = AirSlice(
            time: 0, cellSize: 1, grid: SIMD3(1, 1, 2), first: .zero, counts: SIMD3(1, 1, 2), stride: 1,
            values: [1.2, 0, 0, 0, 0.101325, 2, 100, 0, 0, 0.301325].map { Float16($0) },
            ambient: Primitive(density: 1.2, pressure: 101_325))
        let raw = ViewFrame.pack(ground: ground, surface: nil, includeQuads: false, volume: air)
        let header = ViewFrame.Header(
            frame: 0, time: 0, cellSize: 1, counts: SIMD2(1, 1), points: 0, faces: 0, quadsIncluded: false,
            volume: SIMD3(1, 1, 2), rawBytes: raw.count, compression: .none)
        let decoded = try ViewFrame.decode(header, payload: raw)
        #expect(
            decoded.volume.count == 2 && abs(decoded.volume[0]) < 0.1 && abs(decoded.volume[1] - 200) < 0.5)
    }

    @Test("A frame of the wrong size is refused")
    func wrongSize() {
        let header = ViewFrame.Header(
            frame: 0, time: 0, cellSize: 1, counts: SIMD2(2, 2), points: 0, faces: 0, quadsIncluded: false,
            rawBytes: 24, compression: .none)
        #expect(throws: ProjectFileError.self) { try ViewFrame.decode(header, payload: Data(count: 20)) }
    }

    @Test("The command takes a host or standard input, and none of the outputs a run here writes")
    func options() throws {
        let options = try HeadlessWatch.Options.parse([
            "scene.bombcad", "--on", "mini.local", "--window", "3", "--compression", "zlib", "--duration",
            "0.01",
        ])
        #expect(
            options.host == "mini.local" && options.view?.window == 3 && options.view?.compression == .zlib)
        #expect(options.run.duration == 0.01)
        #expect(try HeadlessWatch.Options.parse(["scene.bombcad", "--stdio", "--no-view"]).view == nil)
        #expect(throws: ProjectFileError.self) { try HeadlessWatch.Options.parse(["scene.bombcad"]) }
        #expect(throws: ProjectFileError.self) {
            try HeadlessWatch.Options.parse(["scene.bombcad", "--stdio", "--on", "mini.local"])
        }
        #expect(throws: ProjectFileError.self) {
            try HeadlessWatch.Options.parse(["scene.bombcad", "--stdio", "--usd", "scene.usda"])
        }
    }
}

@MainActor @Suite("Watched runs on a worker", .serialized, .hangLimit)
struct WatchTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Watched", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        return document
    }

    @Test(
        "Frames come while acknowledged, the last always, and the run is the same as one stopping at them here"
    )
    func watched() async throws {
        let (worker, server) = localWorker()
        _ = try await worker.start()
        let job = WatchJob(
            id: UUID(), name: "Watched", project: SweepWorkerArchive(try document().makeArchive()),
            view: ViewSpec(window: 1, compression: .lz4))
        var headers: [ViewFrame.Header] = []
        var peaks: [Float] = []
        let result = try await worker.watch(job) { header, payload in
            headers.append(header)
            peaks.append((try? ViewFrame.decode(header, payload: payload))?.peak ?? -1)
            worker.writer.enqueue(.viewAck(job.id, header.frame))
        }
        let stats = try #require(result.stats)
        #expect(stats.sent == headers.count && stats.lags.count == stats.sent && stats.frames >= stats.sent)
        #expect(headers.map(\.frame) == headers.map(\.frame).sorted())
        #expect(abs((headers.last?.time ?? 0) - 0.004) < 1e-9)
        #expect(headers.allSatisfy { $0.counts.x > 0 && $0.counts.y > 0 && $0.faces == 0 })
        #expect(!peaks.contains(-1) && peaks.last! > 0 && peaks == peaks.sorted())
        let watched = try #require(
            try ProjectDocument(archive: result.archive.archive()).savedRuns.first { $0.name == "Watched" })

        // The same frames stopped at here, nothing sent.
        var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
        options.name = "Watched"
        let here = try await HeadlessRun.perform(document(), options: options, view: { _, _, _ in }).run
        #expect(watched.gauges == here.gauges && watched.stepCount == here.stepCount)

        // A viewer that never answers holds nothing up: the first frame and the last are sent.
        let silent = WatchJob(
            id: UUID(), name: "Silent", project: SweepWorkerArchive(try document().makeArchive()),
            view: ViewSpec(window: 1, compression: .none))
        var silentFrames: [Int] = []
        let unanswered = try await worker.watch(silent) { header, _ in silentFrames.append(header.frame) }
        #expect(silentFrames == [0, 4] && unanswered.stats?.lags.isEmpty == true)
        #expect(
            try ProjectDocument(archive: unanswered.archive.archive()).savedRuns.first?.stepCount
                == here.stepCount)
        worker.close()
        await server.value
    }
}
