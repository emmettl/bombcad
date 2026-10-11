import Foundation
import Testing
import simd

@testable import BlastCore

/// The domain's extent: what it must hold, its headroom, and open scenes fitted to their charge.
@Suite("Scene extent")
struct SceneExtentTests {
    @Test("An open scene holds nothing but its charge; blocks and further charges are content")
    func contentBounds() {
        var scenario = ScenarioPreset.openGround.scenario
        #expect(scenario.contentBounds == nil)
        scenario.boxes = [Box(x: 40...44, y: 10...12, height: 3)]
        scenario.additionalCharges = [Charge(mass: 1, position: SIMD3(5, 50, 0))]
        let bounds = scenario.contentBounds
        #expect(bounds?.min == SIMD3(5, 10, 0) && bounds?.max == SIMD3(44, 50, 3))
    }

    @Test("Headroom is 1.5 √(R W^(1/3)), and the suggested height reaches the farthest ground")
    func headroom() {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.charge.mass = 500_000
        let scale = Float(cbrt(500_000.0))
        #expect(abs(scenario.headroom(forRange: 3175) - 1.5 * (3175 * scale).squareRoot()) < 0.01)
        // The charge at (32, 32) of a 64 m square: the far corner is 45.25 m away.
        #expect(abs(scenario.farthestGroundRange - 32 * Float(2).squareRoot()) < 1e-3)
        #expect(
            abs(scenario.suggestedHeight - scenario.headroom(forRange: scenario.farthestGroundRange)) < 1e-3)
    }

    @Test("Resizing keeps the contents, drops gauges left outside, and refuses to cut anything off")
    func resize() throws {
        var scenario = ScenarioPreset.openGround.scenario
        // Gauges at 37 to 57 m east of the origin; a 50 m domain leaves the last two out.
        let removed = try scenario.resizeDomain(to: SIMD3(50, 64, 32))
        #expect(removed == ["20 m", "25 m"] && scenario.gauges.count == 3)
        #expect(scenario.domainSize == SIMD3(50, 64, 32))
        scenario.boxes = [Box(x: 40...44, y: 10...12, height: 3)]
        #expect(throws: SceneExtentError.self) { try scenario.resizeDomain(to: SIMD3(42, 64, 32)) }
        #expect(throws: SceneExtentError.self) { try scenario.resizeDomain(to: SIMD3(50, 30, 32)) }
        #expect(throws: SceneExtentError.self) { try scenario.resizeDomain(to: SIMD3(50, 64, 0.5)) }
        #expect(scenario.domainSize == SIMD3(50, 64, 32), "a refused resize changes nothing")
    }

    @Test("Fitting an open scene centres the charge, moves the gauges with it and sizes the top")
    func fit() throws {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.charge.mass = 500_000
        try scenario.fitOpenScene(scaledReach: 10)
        let reach = 1.05 * 10 * Float(cbrt(500_000.0))
        #expect(
            abs(scenario.domainSize.x - 2 * reach) < 0.01 && scenario.domainSize.x == scenario.domainSize.y)
        #expect(scenario.charge.position == SIMD3(reach, reach, 0))
        #expect(
            abs(scenario.domainSize.z - scenario.headroom(forRange: reach * Float(2).squareRoot())) < 0.01)
        // The 5 m gauge is 5 m east of the charge still.
        #expect(
            scenario.gauges.first.map { abs($0.position.x - reach - 5) < 1e-3 && $0.position.z == 0.05 }
                == true)
        // Over a slope the charge keeps its height above the ground, and the domain clears the top.
        var sloped = ScenarioPreset.openGround.scenario
        sloped.terrain = .slope(domain: sloped.domainSize, spacing: 1, foot: 0, angle: 10)
        sloped.charge.position.z = sloped.terrain!.height(at: sloped.charge.position) + 0.5
        try sloped.fitOpenScene(scaledReach: 10)
        let ground = sloped.terrain!.height(at: sloped.charge.position)
        #expect(abs(sloped.charge.position.z - ground - 0.5) < 1e-3)
        #expect(sloped.domainSize.z > sloped.terrain!.highest)
        // A scene with contents is not fitted.
        var built = ScenarioPreset.singleBuilding.scenario
        #expect(throws: SceneExtentError.self) { try built.fitOpenScene(scaledReach: 10) }
    }

    @Test("The thermal ground receivers stand further apart over a floor larger than a square kilometre")
    func groundReceivers() {
        let spec = ThermalSpec()
        #expect(spec.groundSpacing(over: SIMD3(64, 64, 32)) == spec.groundSpacing)
        var scenario = ScenarioPreset.openGround.scenario
        scenario.domainSize = SIMD3(3334, 3334, 833)
        let ground = ThermalExposure.surfaceGrids(scene: FragmentScene(scenario), spec: spec)[0]
        #expect(ground.columns * ground.rows <= ThermalSpec.maximumGroundReceivers + 2 * ground.columns + 1)
        #expect(abs(spec.groundSpacing(over: scenario.domainSize) - 3334 / 500) < 0.01)
    }
}
