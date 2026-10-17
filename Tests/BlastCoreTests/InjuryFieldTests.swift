import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Blast injury from the run's own fields", .serialized, .gpuThreads)
struct InjuryFieldTests {
    @Test("On open ground the injury at standing height reaches about as far as the free field's")
    func openGround() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(48, 48, 8), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(24, 24, 0.3)))
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
            configuration: .recommended)
        try solver.configureExposurePlane(heightM: 1.5, arrivalThresholdPa: 1_000)
        _ = solver.advance(until: 0.06)
        let field = InjuryField(try #require(solver.exposureSnapshot()), centre: SIMD2(24, 24))
        let free = BlastInjury.freeFieldRadii(kilograms: 10)
        func ratio(_ level: BlastInjury.Level) throws -> Double {
            Double(try #require(field.reach(level))) / (try #require(free[level]))
        }
        // The eardrums' reach, past 6 m, within 15% (0.87–0.88 on 0.25 m cells); closer in, the
        // cells' peaks read low and the lungs' reach is short of the free field's (0.69 and 0.48),
        // the unsafe side.
        #expect(try abs(ratio(.eardrumThreshold) - 1) < 0.15 && abs(ratio(.eardrum50) - 1) < 0.15)
        #expect(try ratio(.lungThreshold) > 0.6 && ratio(.lethality50) > 0.4)
        // Against a wall, the reflected pressure reaches further.
        #expect(
            try #require(field.reach(.eardrumThreshold, stance: .againstWall)) > field.reach(
                .eardrumThreshold)!)
    }
}
