import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Laminated glass meshed as shells", .gpuThreads)
struct LaminatedShellTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
    }

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

    private func osnes(_ test: String) throws -> LaminatedShellTest.Result {
        let shot = try #require(LaminatedGlassMeasurements.osnes.first { $0.test == test })
        let step = 1e-5
        return try LaminatedShellTest.run(
            device: device, laminate: Self.osnesPane, a: 0.3, b: 0.3, edges: .pinned,
            pressures: LaminatedGlassMeasurements.friedlander(
                pMax: shot.pMax, duration: shot.duration, b: shot.b, step: step),
            step: step, duration: 0.015)
    }

    @Test(
        "Osnes et al.'s panes: the lightest holds; a cracked one goes about as far as measured, held by its interlayer"
    )
    func osnesPanes() throws {
        let held = try osnes("A-01")
        #expect(held.crackedAt == nil && held.peak < 0.006)
        let cracked = try osnes("D-02")
        #expect(cracked.crackedAt != nil && cracked.removed == 0)
        let ratio = cracked.peak * 1e3 / 95.41
        #expect(ratio > 0.8 && ratio < 1.3, "D-02 \(cracked.peak * 1e3) mm against 95.4")
        // The pane fragments the same way every time: its flag passes between substeps.
        let again = try osnes("D-02")
        #expect(again.peak == cracked.peak && again.crackedAt == cracked.crackedAt)
    }

    @Test("Hooper's pane 4 cracks, then tears out of its silicone at about the speed measured")
    func hooperPane() throws {
        let test = try #require(LaminatedGlassMeasurements.hooper.first { $0.test == "4" })
        let laminate = LaminatedGlass(
            plies: [0.003, 0.003], interlayer: .pvb, interlayerThickness: 0.00152,
            edgeCapacity: LaminatedGlass.siliconeCapacity(bite: 0.02))
        let step = 2e-5
        let result = try LaminatedShellTest.run(
            device: device, laminate: laminate, a: test.a, b: test.b, edges: .silicone,
            pressures: LaminatedGlassMeasurements.triangle(
                peak: test.peak * 1e3, impulse: test.impulse, step: step, until: 0.03),
            step: step, duration: 0.015)
        #expect(result.crackedAt != nil)
        let released = try #require(result.releasedAt)
        #expect(released > 0.004 && released < 0.012)
        let speed = (result.speedAtRelease ?? 0) / test.speed
        #expect(speed > 0.8 && speed < 1.3)
    }
}
