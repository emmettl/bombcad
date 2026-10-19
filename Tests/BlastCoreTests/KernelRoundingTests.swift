import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// A run can build the kernels with another rounding (`KernelRounding`), for the rounding
/// ensemble: each rounds differently, and all agree closely before anything fails.
@Suite("The kernels' rounding, chosen per run", .gpuThreads)
struct KernelRoundingTests {
    @Test("Each rounding reaches the kernels: different bits, the same wall to within 1% before it fails")
    func roundings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let wall = Box(min: .zero, max: SIMD3(0.2, 2, 2))
        var model = StructureModel(solids: [wall], elementSize: 0.1, fixedBase: true)
        model.addMat(to: wall, thicknessAxis: 0, areaPerMetre: 4e-4, depth: 0.04)
        let load = PressureLoad(
            axis: 0, positiveSide: false,
            history: [SIMD2(0, 0), SIMD2(0.0005, 3e6), SIMD2(0.004, 0), SIMD2(10, 0)])
        /// The nodes' displacements after 300 substeps, and the largest.
        func run(_ rounding: KernelRounding?) throws -> (nodes: [Float], largest: Float, failed: Int) {
            let solver = try KernelRounding.$current.withValue(rounding) {
                try StructureSolver(device: device, model: model)
            }
            solver.appliedLoad = load
            solver.advance(steps: 300)
            var nodes: [Float] = []
            solver.mutateNodes { all in for n in all { nodes += [n.ux, n.uy, n.uz] } }
            let summary = solver.summary()
            return (nodes, summary.maxDisplacement, summary.erodedElements)
        }
        let plain = try run(nil)
        let standard = try run(.standard)
        #expect(plain.nodes.map(\.bitPattern) == standard.nodes.map(\.bitPattern))
        #expect(plain.largest > 0 && plain.failed == 0)
        for rounding in [KernelRounding.unfused, .relaxed] {
            let other = try run(rounding)
            #expect(other.nodes.map(\.bitPattern) != plain.nodes.map(\.bitPattern), "\(rounding)")
            #expect(
                abs(other.largest / plain.largest - 1) < 0.01,
                "\(rounding): \(other.largest) \(plain.largest)")
        }
    }

    @Test("A case's rounding samples are its middle run, once with each rounding, the default first")
    func samples() throws {
        let middle = try ValidationEnsemble.samples(case: "janney", count: 0, seed: 0)[0]
        let samples = try ValidationEnsemble.roundingSamples(case: "janney")
        #expect(samples.map(\.rounding) == [.standard, .unfused, .relaxed])
        #expect(samples.map(\.index) == [0, 1, 2])
        #expect(samples.allSatisfy { $0.values == middle.values && $0.caseID == "janney" })
        // A sample written before roundings were chosen reads back with none.
        let old = #"{"caseID":"janney","index":3,"values":{"fc":3.1e7}}"#
        let decoded = try JSONDecoder().decode(EnsembleSample.self, from: Data(old.utf8))
        #expect(decoded.rounding == nil && decoded.index == 3)
    }
}
