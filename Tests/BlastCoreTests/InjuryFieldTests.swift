import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Blast injury from the run's own fields", .serialized, .gpuThreads)
struct InjuryFieldTests {
    @Test("On open ground the injury at standing height reaches about as far as the free field's")
    func openGround() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(48, 48, 8), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(24, 24, 0.3)))
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            configuration: .recommended.balloonStart)
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

    @Test("Mapped from one dimension, the lungs' reach close in comes nearer the free field's")
    func mappedStart() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(48, 48, 8), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(24, 24, 0.1)))
        var configuration = SolverConfiguration.recommended
        configuration.mappedCharge = true
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
            configuration: configuration)
        // Set up after the charge was mapped: the plane takes the one-dimensional solution's peaks
        // within the mapped radius (16 m here), which the grid never sees.
        try solver.configureExposurePlane(heightM: 1.5, arrivalThresholdPa: 1_000)
        _ = solver.advance(until: 0.06)
        let field = InjuryField(try #require(solver.exposureSnapshot()), centre: SIMD2(24, 24))
        let free = BlastInjury.freeFieldRadii(kilograms: 10)
        func ratio(_ level: BlastInjury.Level) throws -> Double {
            Double(try #require(field.reach(level))) / (try #require(free[level]))
        }
        // 0.86 and 0.84 for the eardrums, as the balloon's; 0.80 and 0.65 for the lungs where the
        // balloon gives 0.69 and 0.50 (`openGround`). Standing height, 1.5 m, is still short of a
        // surface burst's ground-level curves close in, where the wave off the ground arrives apart.
        #expect(try abs(ratio(.eardrumThreshold) - 1) < 0.2 && abs(ratio(.eardrum50) - 1) < 0.2)
        #expect(try ratio(.lungThreshold) > 0.75 && ratio(.lethality50) > 0.6)
    }
}
