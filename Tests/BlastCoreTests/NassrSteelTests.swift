import Foundation
import Metal
import Testing

@testable import BlastCore

/// Nassr's steel beams and columns blasted in the open (`NassrSteelTest`): the model's mid-span
/// deflection against the measured, as validation.md's table records it, so a change that moves
/// it is seen.
@Suite("Nassr's steel members", .gpuThreads)
struct NassrSteelTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("The beams of the shots near elastic and the curtain shot come within a quarter of measured")
    func beams() throws {
        for number in [1, 2, 5] {
            let shot = NassrSteelTest.shots[number - 1]
            let r = try NassrSteelTest.run(device: device, shot: shot, column: false)
            let ratio = r.peak / (r.measured ?? 1)
            print("Nassr shot \(number) beam: \(r.peak * 1000) mm, \(ratio) of measured")
            #expect(ratio > 0.8 && ratio < 1.3, "shot \(number): \(ratio)")
        }
    }

    @Test("A column bent about its weak axis under a quarter of its capacity goes further than its beam")
    func weakColumn() throws {
        let shot = NassrSteelTest.shots[1]
        let beam = try NassrSteelTest.run(device: device, shot: shot, column: false)
        let column = try NassrSteelTest.run(device: device, shot: shot, column: true)
        print("Nassr shot 2: beam \(beam.peak * 1000) mm, column \(column.peak * 1000) mm")
        // Measured 40.8 and 56.1 mm: the axial load amplifies the bending, as it did in the test.
        #expect(column.peak > 1.3 * beam.peak)
    }
}
