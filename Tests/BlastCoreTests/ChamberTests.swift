import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The full-scale internal explosion of Shang et al. (2026).
@Suite("Chamber test")
struct ChamberTests {
    @Test("The chamber's roof is left deflected about as much as measured, and its walls hold")
    func roofResidual() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let result = try ChamberTest.run(device: device, duration: 0.3)
        // Measured: 95 mm. The model gives about 123 mm; before bars resisted sliding across
        // cracks and cracks were bridged across the section, the roof was thrown off.
        #expect(result.residual > 0.06 && result.residual < 0.2, "residual \(result.residual) m")
        let walls = result.probes.first { $0.name.hasPrefix("Side wall") }?.history.map(\.y).max() ?? 1
        #expect(walls < 0.05, "side wall \(walls) m")
    }
}
