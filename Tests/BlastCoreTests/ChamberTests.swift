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

    @Test("The chamber's roof is left deflected about as much as measured, and its walls hold")
    func roofResidual() throws {
        let result = try ChamberTest.run(device: device, duration: 0.3)
        // Measured: 95 mm. The model gives about 100 mm (with a gas that is too weak; see the
        // validation notes); before bars resisted sliding across cracks and cracks were bridged
        // across the section, the roof was thrown off.
        #expect(result.residual > 0.06 && result.residual < 0.2, "residual \(result.residual) m")
        let walls = result.probes.first { $0.name.hasPrefix("Side wall") }?.history.map(\.y).max() ?? 1
        #expect(walls < 0.05, "side wall \(walls) m")
    }

    @Test("With oriented cracks the roof bends up by tens of millimetres, as in the paper's model")
    func orientedCracks() throws {
        let result = try ChamberTest.run(device: device, orientedCracks: true, duration: 0.3)
        // The paper's own model peaks at 87 mm; this one at about 65 mm, settling to about 10 mm.
        #expect(
            result.peakDeflection > 0.03 && result.peakDeflection < 0.2, "peak \(result.peakDeflection) m")
        #expect(result.residual < 0.15, "residual \(result.residual) m")
    }
}
