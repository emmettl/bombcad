import Foundation
import Metal
import Testing

@testable import BlastCore

/// Kenny's drop-hammer tests on slender strips (`KennyImpactTest`): the final deflection of the
/// peak buckle against the measured, as shell-model.md's table records it, so a change that moves
/// it is seen.
@Suite("Kenny's struck strips", .gpuThreads)
struct KennyImpactTests {
    @Test(
        "A steel and an aluminium strip struck by the hammer buckle within half to twice the measured",
        arguments: ["SIa", "AIc"])
    func struck(name: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let series = try #require(KennyImpactTest.series.first { $0.name == name })
        let r = try KennyImpactTest.run(device: device, series: series)
        let ratio = r.deflection / series.deflection
        print("Kenny \(name): \(r.deflection * 1000) mm at \(r.position * 1000) mm, \(ratio) of measured")
        // 1.44 and 0.91 when recorded.
        #expect(ratio > 0.5 && ratio < 2)
    }
}
