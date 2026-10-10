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
