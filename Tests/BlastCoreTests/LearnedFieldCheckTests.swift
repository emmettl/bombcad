import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// Whether the learned field model fits this Mac (`LearnedFieldCheck`), and a plan the GPU cannot
/// hold refused cleanly, with a message, before anything is run (emmettl/bombcad-work#69). On a
/// tiny network of the same form, from a temporary file.
@Suite("The learned field model's check on this Mac")
struct LearnedFieldCheckTests {
    static var hasGPU: Bool { MTLCreateSystemDefaultDevice() != nil }

    @Test("The check runs each network twice and says what it took", .enabled(if: hasGPU))
    func check() throws {
        let folder = try LearnedFieldDownloadTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "tiny.bcfw")
        try LearnedFieldDownloadTests.tinyWeights().write(to: file)
        let report = LearnedFieldCheck.run(ground: file, levels: file, cells: 32)
        #expect(report.problem == nil && report.timings.count == 2)
        #expect(report.timings.allSatisfy { $0.firstS > 0 && $0.secondS > 0 && $0.loadS > 0 })
        #expect(report.recommendedWorkingSet > 0 && report.footprintPeak > 0 && report.fits)
        let text = report.lines.joined(separator: "\n")
        #expect(
            text.contains("GPU: ") && text.contains("recommended working set") && text.contains("It fits"))
        #expect(text.contains("32 × 32 cells"))
    }

    @Test("A plan larger than the GPU can hold is refused with a message, never run", .enabled(if: hasGPU))
    func refused() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let network = try LearnedFieldNetwork(
            weights: LearnedField.Weights(data: LearnedFieldDownloadTests.tinyWeights()), device: device)
        let inputs = [Float](repeating: 0, count: 6 * 16 * 16)
        #expect(try network.peakChannel(inputs: inputs, rows: 16, columns: 16).count == 256)
        network.budget = LearnedFieldNetwork.bytesNeeded(rows: 16, columns: 16, width: 1) - 1
        #expect {
            try network.peakChannel(inputs: inputs, rows: 16, columns: 16)
        } throws: { error in
            "\(error)".contains("needs about") && "\(error)".contains("GPU memory")
        }
        // The estimate catches it and is the surrogate's alone.
        let scene = Scenario(
            name: "Small", domainSize: SIMD3(64, 64, 16), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(32, 32, 0.5)))
        let estimator = LearnedField.Estimator(scene: scene, network: network)
        #expect(throws: LearnedFieldError.self) {
            try estimator.peaks(charge: scene.charge.position, mass: 1)
        }
        // The need grows with the plan: 2 KB a cell at width 32, over a quarter of a gigabyte.
        #expect(LearnedFieldNetwork.bytesNeeded(rows: 1264, columns: 1264) / 1_000_000 == 3463)
    }
}
