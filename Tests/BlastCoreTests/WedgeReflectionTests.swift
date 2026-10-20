import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// A plane shock on a slope: the theory, and the air solver against it.
@Suite("Wedge reflection", .gpuThreads)
struct WedgeReflectionTests {
    @Test(
        "On smooth ground the triple point follows three-shock theory; above transition it reflects regularly"
    )
    func solver() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let mach = try WedgeReflectionStudy(wedge: 30, surface: .tilted, cellSize: 0.01).run(device: device)
        #expect(abs(mach.chi - 8.5) < 1, "χ \(mach.chi)°")
        let regular = try WedgeReflectionStudy(wedge: 55, surface: .tilted, cellSize: 0.01).run(
            device: device)
        #expect(regular.lead < 2 * 0.01, "lead \(regular.lead / 0.01) cells")
        // The staircase of a terrain slope delays Mach reflection: at 45°, on 100 cells, it is regular.
        let stairs = try WedgeReflectionStudy(wedge: 45, surface: .terrain, cellSize: 0.01).run(
            device: device)
        #expect(stairs.lead < 0.01, "lead \(stairs.lead / 0.01) cells")
    }
}
