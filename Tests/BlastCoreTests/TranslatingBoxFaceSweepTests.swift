import Testing
import simd

@testable import BlastCore

@Suite("Time-integrated translating box face openings")
struct TranslatingBoxFaceSweepTests {
    @Test("A crossing integrates the blocked time and agrees across a shared face")
    func sharedFace() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(-0.3, 0.5, 0.5))
        let right = try TranslatingBoxCellSweep.integrate(
            body: body, velocity: SIMD3(1, 0, 0), lower: .zero, cellSize: 1, duration: 1, pressure: 0)
        let left = try TranslatingBoxCellSweep.integrate(
            body: body, velocity: SIMD3(1, 0, 0), lower: SIMD3(-1, 0, 0), cellSize: 1, duration: 1,
            pressure: 0)
        #expect(abs(right.integratedOpenFaceAreas[0] - (1 - 0.04 * 0.2)) < 1e-13)
        #expect(abs(left.integratedOpenFaceAreas[1] - right.integratedOpenFaceAreas[0]) < 1e-13)
        for side in 1..<6 { #expect(abs(right.integratedOpenFaceAreas[side] - 1) < 1e-13) }
    }

    @Test("Two transverse overlaps integrate a quadratic blocked area")
    func quadraticArea() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(0, -0.3, -0.3))
        let result = try TranslatingBoxCellSweep.integrate(
            body: body, velocity: SIMD3(0, 1, 1), lower: .zero, cellSize: 1, duration: 1, pressure: 0)
        let blocked = pow(0.2, 3) / 3 + 0.6 * 0.04
        #expect(abs(result.integratedOpenFaceAreas[0] - (1 - blocked)) < 1e-13)
    }

    @Test("Event splitting recovers a brief closure missed by endpoint and midpoint sampling")
    func briefClosure() throws {
        let gap = 0.02
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(0, -0.3, 0.1 + gap))
        let velocity = SIMD3<Double>(0, 1, -1)
        for time in [0.0, 0.5, 1.0] {
            let sample = try RigidBoxBody(mass: 1, size: body.size, position: body.position + time * velocity)
            #expect(
                abs(FractionalBoxGeometry(sample).openFaceFractions(lower: .zero, cellSize: 1)[0] - 1) < 1e-13
            )
        }
        let result = try TranslatingBoxCellSweep.integrate(
            body: body, velocity: velocity, lower: .zero, cellSize: 1, duration: 1, pressure: 0)
        #expect(abs(result.integratedOpenFaceAreas[0] - (1 - pow(gap, 3) / 6)) < 1e-13)
    }
}
