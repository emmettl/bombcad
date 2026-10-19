import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The structures' rubble now, flown on to where it lands (`DebrisResult`); nil unless a
    /// structure makes rubble.
    public func debris(scenario: Scenario) -> DebrisResult? {
        guard bodies.contains(where: { $0.model.rubbleParticles }) else { return nil }
        let rubble = bodies.flatMap { $0.solids?.rubbleParticles().map(\.particle) ?? [] }
        return DebrisResult(
            rubble: rubble, centre: SIMD2(scenario.charge.position.x, scenario.charge.position.y),
            ambient: Primitive(density: ambientDensity, pressure: configuration.ambientPressure),
            blocks: scenario.rigidBoxes, terrain: scenario.terrain)
    }
}
