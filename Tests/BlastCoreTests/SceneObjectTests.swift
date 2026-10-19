import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Scene object ownership", .gpuThreads)
struct SceneObjectTests {
    private let a = Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))
    private let b = Box(min: SIMD3(3, 1, 0), max: SIMD3(4, 2, 1))

    private func scene() -> Scenario {
        Scenario(
            name: "Ownership", domainSize: SIMD3(repeating: 6), boxes: [a, b],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 1)),
            structure: StructureModel(solids: [a, b], elementSize: 0.5))
    }

    @Test("The ownership adapter produces the same air fields as a legacy input")
    func solverParity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var original = scene()
        original.structure = nil
        original.charge.mass = 0.1
        let encoder = JSONEncoder()
        encoder.userInfo[Scenario.physicsInputEncoding] = true
        let migrated = try JSONDecoder().decode(Scenario.self, from: encoder.encode(original))
        let first = try BlastSolver(device: device, scenario: original, cellSize: 0.5)
        let second = try BlastSolver(device: device, scenario: migrated, cellSize: 0.5)
        first.advance(until: 0.002)
        second.advance(until: 0.002)
        for k in 0..<first.grid.nz {
            for j in 0..<first.grid.ny {
                for i in 0..<first.grid.nx {
                    #expect(first.primitive(i, j, k) == second.primitive(i, j, k))
                }
            }
        }
    }
}
