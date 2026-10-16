import Foundation
import Metal
import Testing

@testable import BlastCore

/// A batch that would pass its time limit stops short, and its remaining steps are of zero length;
/// the step after it is shortened to land on the limit. Steps of zero length change nothing.
@Suite("Steps of zero length", .timeLimit(.minutes(30)))
struct ZeroLengthStepTests {
    /// Hupfauf's SN144 slab, with crushed bare concrete removed and the kernels unfused, ending at
    /// 0.5 ms: the last batch takes one step and three of zero length, and the structure's outline
    /// moves in them (elements removed in the step before). A second level's ghost cells beside a
    /// cell its outline had just freed read the level's halo, saved at the last real step while the
    /// cell was solid, and the fine sweep's fluxes were not finite; times a step of zero, the
    /// air beside the slab, and the slab, became NaN.
    @Test("A run whose last batch has steps of zero length stays finite")
    func clippedEnd() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let test = try #require(ContactSlabTest.tests.first { $0.name == "SN144" })
        var structure: StructureSolver?
        let result = try KernelRounding.$current.withValue(.unfused) {
            try ContactSlabTest.run(
                device: device, test: test, duration: 0.0005,
                adjust: { $0.structure?.erodesCrushedBare = true },
                inspect: { solver, _ in structure = solver })
        }
        let slab = try #require(structure)
        let last = try #require(result.momentum.last)
        #expect(abs(last.x - 0.0005) < 1e-9)
        #expect(result.momentum.allSatisfy { $0.y.isFinite }, "\(result.momentum.suffix(4))")
        let momentum = slab.momentum()
        #expect(momentum.x.isFinite && momentum.y.isFinite && momentum.z.isFinite)
        #expect(result.kineticEnergy.isFinite)
    }
}
