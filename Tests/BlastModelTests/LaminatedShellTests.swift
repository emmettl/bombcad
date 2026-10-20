import Foundation
import Testing

@testable import BlastModel

@Suite("Laminated glass meshed as shells")
struct LaminatedShellTests {
    static let osnesPane = LaminatedGlass(
        plies: [0.0038, 0.0038], interlayer: .pvb, interlayerThickness: 0.00152)

    @Test(
        "The cracked laminate's curve is Hooper's Johnson–Cook fit, and the envelope's tear ratio is as it was"
    )
    func curve() {
        let atReference = Interlayer.pvb.crackedLaminateCurve(thickness: 0.00152, rate: 1)
        #expect(abs(atReference.curve[0].y - 6.72e6) < 1e3)
        #expect(abs(atReference.modulus - 0.55e9) < 1)
        // 10% plastic strain at 1 s⁻¹: 6.72 + 10.6 × 0.1^0.303 = 12.0 MPa.
        let tenth = atReference.curve.first { abs($0.x - 0.1) < 1e-9 }!
        #expect(abs(tenth.y / 1e6 - 12.0) < 0.05)
        // At 10 s⁻¹, 1 + 0.248 ln 10 = 1.571 times as strong.
        let fast = Interlayer.pvb.crackedLaminateCurve(thickness: 0.00152, rate: 10)
        #expect(abs(fast.curve[0].y / atReference.curve[0].y - 1.571) < 1e-3)
        // It ends where the total strain reaches the failure strain, 150%.
        let end = fast.curve.last!
        #expect(abs(end.x + end.y / fast.modulus - 1.5) < 1e-6)
        // The envelope's tear ratio, from the shared failure strain: (3 × 1.5 / 8)^(1/2).
        #expect(abs(Self.osnesPane.tearRatio() - (3 * 1.5 / 8).squareRoot()) < 1e-12)
    }
}
