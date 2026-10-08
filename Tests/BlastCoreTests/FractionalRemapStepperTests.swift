import Testing
import simd

@testable import BlastCore

@Suite("Fractional remap motion substeps")
struct FractionalRemapStepperTests {
    private let faces = [FractionalVolumeRemap.Face(a: 0, b: 1, openArea: 1), .init(a: 1, b: 2, openArea: 1)]
    private func volumes(_ time: Double) -> [Double] { [0.02 * (1 - time), 0.001, 0.02 * time] }
    private var initial: [FractionalGasTransport.Cell] {
        volumes(0).map { .init(volume: $0, density: 1.225, pressure: 101325) }
    }
    @Test("Capacity rejection automatically becomes conservative smaller steps")
    func automaticSubsteps() throws {
        let result = try FractionalRemapStepper.advance(
            initial, duration: 1,
            volumesAt: volumes, facesBetween: { _, _ in faces })
        #expect(result.steps.count == 32 && result.rejectedIntervals == 31)
        #expect(result.steps.first!.start == 0 && result.steps.last!.end == 1)
        for n in 1..<result.steps.count { #expect(result.steps[n - 1].end == result.steps[n].start) }
        #expect(result.steps.allSatisfy { $0.maximumOutflowFraction <= 1 })
        let before = initial.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = result.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        for axis in 0..<5 { #expect(abs(before[axis] - after[axis]) < 1e-10) }
        #expect(result.cells[0].amount == .zero)
        for cell in result.cells where cell.volume > 0 { #expect(abs(cell.pressure() - 101325) < 1e-6) }
    }
    @Test("Exhausted refinement budget fails without changing the input state")
    func budgetLimit() throws {
        let old = initial
        #expect(throws: FractionalRemapStepper.Failure.self) {
            try FractionalRemapStepper.advance(
                old, duration: 1, maximumSubsteps: 8,
                volumesAt: volumes, facesBetween: { _, _ in faces })
        }
        #expect(old.map(\.amount) == initial.map(\.amount))
    }
    @Test("Wrong initial geometry and nonconservative volume changes are not retried")
    func badGeometry() throws {
        #expect(throws: FractionalRemapStepper.Failure.self) {
            try FractionalRemapStepper.advance(
                initial, duration: 1,
                volumesAt: { _ in [0.01, 0.001, 0.01] }, facesBetween: { _, _ in faces })
        }
        #expect(throws: FractionalVolumeRemap.Failure.self) {
            try FractionalRemapStepper.advance(
                initial, duration: 1,
                volumesAt: { t in [0.02, 0.001, 0.02 * t] }, facesBetween: { _, _ in faces })
        }
    }
}
