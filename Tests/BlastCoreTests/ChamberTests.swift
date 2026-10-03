import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The full-scale internal explosion of Shang et al. (2026).
@Suite("Chamber test")
struct ChamberTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test(
        "At the test's charge the roof bends up by tens of millimetres, as in the paper's model, and the walls hold"
    )
    func roofResponse() throws {
        let result = try ChamberTest.run(device: device, duration: 0.3)
        // The paper's own model peaks at 87 mm; this one at about 70 mm. With cracks across the
        // lattice planes, which count an inclined crack twice, the roof was thrown off.
        #expect(
            result.peakDeflection > 0.03 && result.peakDeflection < 0.2, "peak \(result.peakDeflection) m")
        #expect(result.residual < 0.15, "residual \(result.residual) m")
        let walls = result.probes.first { $0.name.hasPrefix("Side wall") }?.history.map(\.y).max() ?? 1
        #expect(walls < 0.05, "side wall \(walls) m")
    }
}
