import Foundation
import simd

/// BombCAD's hazardous fragment distance against the test-derived distances DoD 4145.26-M (2008)
/// lists for single items in the open (Table AP2.T3: "The test protocol for determining the HFD
/// is described in" DDESB TP-16): items described only by public overall figures, the charge as
/// TNT, lying level just off the ground, their fragments flown in still air to landing.
public enum FragmentThrowComparison {
    public struct Case: Sendable {
        public var name: String
        /// kg of explosive (as TNT) and of steel casing; the casing's wall and bore, m.
        public var charge: Float
        public var casing: Float
        public var wall: Float
        public var bore: Float
        /// The item's HFD in the open, m (DoD 4145.26-M Table AP2.T3, one unit).
        public var measured: Float
    }

    /// A 155 mm projectile (6.6 kg TNT in some 36 kg of steel, 155 mm across) and a 500 lb
    /// general-purpose bomb (87 kg of filler in some 130 kg of steel, 273 mm across), each with
    /// walls from the casing helper's estimate (`FragmentSpec.casingDimensions`) to thinner ones
    /// nearer the items' own diameters.
    public static let cases: [Case] = [
        Case(
            name: "155 mm projectile, helper's wall", charge: 6.62, casing: 36, wall: 0.0383, bore: 0.138,
            measured: 126.5),
        Case(
            name: "155 mm projectile, 20 mm wall", charge: 6.62, casing: 36, wall: 0.020, bore: 0.115,
            measured: 126.5),
        Case(
            name: "155 mm projectile, 12 mm wall", charge: 6.62, casing: 36, wall: 0.012, bore: 0.131,
            measured: 126.5),
        Case(
            name: "500 lb bomb, helper's wall", charge: 87, casing: 130, wall: 0.0248, bore: 0.326,
            measured: 204.2),
        Case(
            name: "500 lb bomb, 15 mm wall", charge: 87, casing: 130, wall: 0.015, bore: 0.243,
            measured: 204.2),
        Case(
            name: "500 lb bomb, 10 mm wall", charge: 87, casing: 130, wall: 0.010, bore: 0.253,
            measured: 204.2),
    ]

    /// `item`'s hazard with `count` fragments flown, its axis along x, half its diameter up.
    public static func hazard(_ item: Case, count: Int = 100_000) -> GroundHazard {
        let height = (item.bore + 2 * item.wall) / 2
        let scene = Scenario(
            name: item.name, domainSize: SIMD3(100, 100, 50), boxes: [],
            charge: Charge(mass: item.charge, position: SIMD3(50, 50, height)))
        var spec = FragmentSpec()
        spec.casingMass = item.casing
        spec.count = count
        spec.tracers = 0
        spec.axis = SIMD3(1, 0, 0)
        spec.wallThickness = item.wall
        spec.innerDiameter = item.bore
        var cloud = FragmentCloud(spec: spec, scene: FragmentScene(scene))
        cloud.land(in: Primitive(density: 1.225, pressure: 101_325))
        return GroundHazard(impacts: cloud.impacts, centre: SIMD2(50, 50), crossings: cloud.crossings)
    }
}
