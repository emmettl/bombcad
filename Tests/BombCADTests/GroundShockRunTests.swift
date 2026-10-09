import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Ground shock alongside a run", .serialized)
struct GroundShockRunTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ground-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A charge just above the ground at (2, 4), a block in the far corner, off the points' line.
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Ground", domainSize: SIMD3(8, 8, 4),
            boxes: [Box(min: SIMD3(6, 6, 0), max: SIMD3(7.5, 7.5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(2, 4, 0.5)))
        scene.gauges = [Gauge("Near", at: SIMD3(3, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        return document
    }

    /// A point under the block, then points out along the ground from beside the charge.
    private var spec: GroundShockSpec {
        var spec = GroundShockSpec()
        spec.line = .init(from: SIMD2(2.5, 4), to: SIMD2(5.5, 4), count: 4)
        spec.points = [SIMD2(6.75, 6.75)]
        spec.depths = [0, 1]
        return spec
    }

    @Test("Options take a ground shock description and refuse results without one")
    func options() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "ground.json")
        try JSONEncoder().encode(spec).write(to: file)
        let results = folder.appending(path: "results.json").path
        let options = try HeadlessRun.Options.parse([
            "a.bombcad", "--ground-shock", file.path, "--ground-results", results, "--frame-interval", "2",
        ])
        #expect(options.groundShock == spec && options.groundResults?.path == results)
        #expect(options.frameInterval == 2)
        let bad = folder.appending(path: "bad.json")
        try Data(#"{"points": []}"#.utf8).write(to: bad)
        for arguments in [
            ["a", "--ground-results", results], ["a", "--ground-shock", bad.path],
            ["a", "--ground-shock", folder.appending(path: "missing.json").path],
            ["a", "--ground-shock", file.path, "--ground-results", file.path],
        ] {
            #expect(throws: (any Error).self) { try HeadlessRun.Options.parse(arguments) }
        }
    }

    @Test("A run estimates the ground's shaking frame by frame and writes it out")
    func run() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "ground.bombcad")
        try document().makeArchive().fileWrapper().write(to: project, originalContentsURL: nil)
        let file = folder.appending(path: "ground.json")
        try JSONEncoder().encode(spec).write(to: file)
        let out = folder.appending(path: "results.json")
        let result = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([
                project.path, "--ground-shock", file.path, "--ground-results", out.path,
            ]))
        let ground = try #require(result.ground)
        #expect(try JSONDecoder().decode(GroundShockResult.self, from: Data(contentsOf: out)) == ground)
        // Frames at 0 to 6 ms, a value for each at every point.
        #expect(ground.frames == 7 && ground.points.allSatisfy { $0.history.count == 7 })
        let line = Array(ground.points.dropFirst())
        #expect(line.allSatisfy { !$0.covered && $0.peakOverpressure > 0 && $0.impulse > 0 })
        // Weaker, and later, out along the ground; the stress wave reaches 1 m down 3.3 ms after
        // it starts at the top.
        for (near, far) in zip(line, line.dropFirst()) {
            #expect(near.peakOverpressure > far.peakOverpressure)
            #expect(near.responses[0].verticalVelocity > far.responses[0].verticalVelocity)
            #expect((near.arrival ?? .infinity) <= (far.arrival ?? .infinity))
        }
        for point in line {
            #expect(point.responses[1].verticalVelocity < point.responses[0].verticalVelocity)
            #expect(
                abs(point.responses[0].verticalVelocity - point.peakOverpressure / ground.soil.impedance)
                    < 1e-6)
            if let arrival = point.arrival {
                #expect(abs(point.responses[1].arrival! - arrival - 1 / 300) < 1e-9)
            }
        }
        // Under the block there is no open ground.
        #expect(ground.points[0].covered && ground.points[0].responses[0].verticalVelocity == 0)
    }

    @Test("Estimating ground shock leaves the air as a run with the same frames gives it")
    func untouched() async throws {
        var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
        options.name = "Ground"
        options.groundShock = spec
        let with = try await HeadlessRun.perform(document(), options: options)
        // The same frames asked for by fragments with none to fly.
        options.groundShock = nil
        options.fragments = FragmentSpec()
        let without = try await HeadlessRun.perform(document(), options: options)
        #expect(with.run.stepCount == without.run.stepCount && with.run.gauges == without.run.gauges)
        #expect(with.ground != nil && without.ground == nil)
    }
}
