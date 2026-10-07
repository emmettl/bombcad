import Testing
import simd

@testable import BlastCore

@Suite("Adaptive moving-box face openings")
struct AdaptiveBoxFaceSweepTests {
    @Test("Rotation matches an analytical secant face-area integral and shared-face geometry")
    func rotation() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 0.4), position: SIMD3(0, 0, 0.5))
        let duration = Double.pi / 4
        func integrate(_ lower: SIMD3<Double>) throws -> AdaptiveBoxCellSweep.Result {
            try AdaptiveBoxCellSweep.integrate(
                body: body, velocity: .zero, spin: SIMD3(0, 0, 1), lower: lower,
                cellSize: 1, duration: duration, pressure: 0, volumeTolerance: 1e-10,
                faceAreaTimeTolerance: 1e-9)
        }
        let right = try integrate(.zero)
        let left = try integrate(SIMD3(-1, 0, 0))
        // On x=0 and y=0, the blocked rectangle has area 0.08 sec(t).
        let expected = duration - 0.08 * log(sqrt(2.0) + 1)
        #expect(abs(right.integratedOpenFaceAreas[0] - expected) < 1e-9)
        #expect(abs(right.integratedOpenFaceAreas[2] - expected) < 1e-9)
        #expect(abs(right.integratedOpenFaceAreas[0] - left.integratedOpenFaceAreas[1]) < 2e-9)
        for side in [1, 3, 4, 5] {
            #expect(abs(right.integratedOpenFaceAreas[side] - duration) < 1e-12)
        }
        #expect(right.faceAreaTimeErrorEstimate <= right.faceAreaTimeTolerance)
    }

    @Test("With zero pressure, face refinement resolves a brief closure missed by initial nodes")
    func briefClosure() throws {
        let gap = 0.02
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(0, -0.3, 0.1 + gap))
        let velocity = SIMD3<Double>(0, 1, -1)
        let exact = try TranslatingBoxCellSweep.integrate(
            body: body, velocity: velocity, lower: .zero, cellSize: 1, duration: 1, pressure: 0)
        let adaptive = try AdaptiveBoxCellSweep.integrate(
            body: body, velocity: velocity, spin: .zero, lower: .zero, cellSize: 1, duration: 1,
            pressure: 0, volumeTolerance: 1e-4, faceAreaTimeTolerance: 1e-10)
        for side in 0..<6 {
            #expect(abs(exact.integratedOpenFaceAreas[side] - adaptive.integratedOpenFaceAreas[side]) < 1e-10)
        }
        #expect(adaptive.faceAreaTimeErrorEstimate <= 1e-10)
    }

    @Test("A face tolerance that exceeds the refinement budget returns an explicit failure")
    func budgetLimit() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 0.4), position: SIMD3(0, 0, 0.5))
        #expect(throws: AdaptiveBoxCellSweep.Failure.self) {
            try AdaptiveBoxCellSweep.integrate(
                body: body, velocity: .zero, spin: SIMD3(0, 0, 1), lower: .zero, cellSize: 1,
                duration: 0.05, pressure: 0, volumeTolerance: 1e-4, maximumIntervals: 1,
                faceAreaTimeTolerance: 1e-16)
        }
    }
}
