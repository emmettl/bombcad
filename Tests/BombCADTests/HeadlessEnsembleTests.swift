import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Ensembles of validation cases, here and on workers", .serialized)
struct HeadlessEnsembleTests {
    @Test("BombCAD ensemble takes its cases, samples, seed and Macs")
    func parsing() throws {
        let options = try HeadlessEnsemble.Options.parse(
            [
                "contest-slab,kb-wall", "--samples", "24", "--seed", "9", "--worker", "mini",
                "--local-workers", "1",
            ])
        #expect(options.cases == ["contest-slab", "kb-wall"] && options.samples == 24 && options.seed == 9)
        #expect(options.workers == ["mini"] && options.localWorkers == 1)
        for bad in [
            ["nothing"], ["kb-wall,kb-wall"], ["kb-wall", "--samples", "-1"], ["kb-wall", "--worker", "-oX"],
            ["kb-wall", "--worker", "mini", "--worker", "mini"], ["kb-wall", "--seed", "1", "--seed", "2"],
            [],
        ] {
            #expect(throws: ProjectFileError.self, "\(bad)") { try HeadlessEnsemble.Options.parse(bad) }
        }
    }

    @Test("An ensemble shared with a worker gives the same samples and results as here alone")
    func shared() async throws {
        var options = try HeadlessEnsemble.Options.parse(["kb-curve", "--samples", "12", "--seed", "4"])
        let here = try await HeadlessEnsemble.run(options)
        #expect(here.failures.isEmpty && here.cases[0].outcomes.allSatisfy { $0 != nil })
        #expect(here.cases[0].places.allSatisfy { $0 == "here" })

        options.workers = ["mini"]
        let (worker, server) = localWorker(name: "mini")
        var lines: [String] = []
        // Slow here, so that the worker takes some of the samples.
        let there = try await HeadlessEnsemble.run(
            options, log: { lines.append($0) },
            connect: { _ in worker },
            runHere: { sample in
                Thread.sleep(forTimeInterval: 0.05)
                return try ValidationEnsemble.run(sample)
            })
        await server.value
        #expect(there.failures.isEmpty)
        #expect(there.cases[0].samples == here.cases[0].samples)
        #expect(there.cases[0].outcomes.map { $0?.outputs } == here.cases[0].outcomes.map { $0?.outputs })
        #expect(there.cases[0].places.contains("mini"))
        // The case is reported once its samples are all in, against the reference.
        #expect(lines.first?.hasPrefix("The Kingery–Bulmash curves themselves") == true)
        #expect(lines.contains { $0.contains("reflected impulse") && $0.contains("within") })

        let folder = FileManager.default.temporaryDirectory.appending(path: "ensemble-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try HeadlessEnsemble.write(there, to: folder)
        let kept = try JSONDecoder().decode(
            HeadlessEnsemble.Report.Case.self, from: Data(contentsOf: folder.appending(path: "kb-curve.json"))
        )
        #expect(kept.samples == there.cases[0].samples)
    }
}

@MainActor @Suite("An ensemble cut short carries on from its results", .serialized)
struct EnsembleResumeTests {
    @Test("Results already in the output folder are not run again, and the report is the same")
    func resume() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ensemble-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = try HeadlessEnsemble.Options.parse(["kb-curve", "--samples", "6", "--out", folder.path])
        let whole = try await HeadlessEnsemble.run(options)
        let progress = folder.appending(path: "progress.jsonl")
        let lines = try String(contentsOf: progress, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 7)
        // Cut short after four: three are run again, and only those.
        try (lines.prefix(4).joined(separator: "\n") + "\n").write(
            to: progress, atomically: true, encoding: .utf8)
        options = try HeadlessEnsemble.Options.parse(["kb-curve", "--samples", "6", "--out", folder.path])
        let ran = Counter()
        let resumed = try await HeadlessEnsemble.run(
            options,
            runHere: { sample in
                ran.add()
                return try ValidationEnsemble.run(sample)
            })
        #expect(ran.count == 3)
        #expect(resumed.cases[0].outcomes.map { $0?.outputs } == whole.cases[0].outcomes.map { $0?.outputs })
        // A folder that is not an ensemble's is refused.
        #expect(throws: ProjectFileError.self) {
            try HeadlessEnsemble.Options.parse([
                "kb-curve", "--out", FileManager.default.temporaryDirectory.path,
            ])
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
}
