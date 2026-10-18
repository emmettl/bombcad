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

    /// `item`'s casing as flown (`hazard`).
    public static func spec(_ item: Case, count: Int = 100_000) -> FragmentSpec {
        var spec = FragmentSpec()
        spec.casingMass = item.casing
        spec.count = count
        spec.tracers = 0
        spec.axis = SIMD3(1, 0, 0)
        spec.wallThickness = item.wall
        spec.innerDiameter = item.bore
        return spec
    }

    /// `item`'s hazardous fragment distance by DDESB TP-12's suggested procedure (Zaker, 1975,
    /// pp. 13–14), from the same Mott masses, Gurney speed and spray as BombCAD flies: fragments of
    /// shape factor `shapeFactor` (kg/m³, m = k A^(3/2)) and constant drag `drag`, slowed as
    /// v = V exp(−R/L) with L = 2 (k² m)^(1/3) / (C_d ρ), or at their free-fall speed √(g L) where
    /// that is more; the lightest hazardous mass at R the smaller of the two; and the density of
    /// those heavier, q = (Q₀/R²) exp(−√(2m/m₀)), Q₀ the fragments per steradian side-on. The
    /// distance is the furthest R where q reaches one per 55.7 m². Gravity bends no path, as in
    /// TP-12.
    public static func zakerDistance(_ item: Case, shapeFactor: Float, drag: Float, air: Float = 1.225)
        -> Float
    {
        let spec = spec(item)
        guard let meanMass = spec.mottMeanMass else { return 0 }
        let m0 = Double(meanMass)
        let speed = Double(spec.launchSpeed(chargeMass: item.charge))
        // The cylinder's spray, even in angle within `spread` of square to its axis.
        let perSteradian = spec.realFragmentCount / (2 * .pi * 2 * Double(spec.spread))
        let l1 = 2 * pow(Double(shapeFactor), 2.0 / 3) / (Double(drag) * Double(air))
        let energy = Double(HazardCriteria.hazardousEnergyJ)
        let freeFall = pow(2 * energy / (9.81 * l1), 0.75)
        func lightest(at r: Double) -> Double {
            // m V² exp(−2R / (L₁ m^(1/3))) = 2E rises with m: bisect on log m.
            var (low, high) = (log(1e-6), log(1e3))
            for _ in 0..<80 {
                let m = exp((low + high) / 2)
                if m * speed * speed * exp(-2 * r / (l1 * cbrt(m))) >= 2 * energy {
                    high = (low + high) / 2
                } else {
                    low = (low + high) / 2
                }
            }
            return min(exp(high), freeFall)
        }
        let criterion = 1 / Double(HazardCriteria.hazardousAreaM2)
        var furthest: Double = 0
        for step in 1...20_000 {
            let r = Double(step) * 0.25
            if perSteradian / (r * r) * exp(-(2 * lightest(at: r) / m0).squareRoot()) >= criterion {
                furthest = r
            }
        }
        return Float(furthest)
    }

    /// `item`'s hazard with `count` fragments flown, its axis along x, half its diameter up.
    public static func hazard(_ item: Case, count: Int = 100_000) -> GroundHazard {
        let height = (item.bore + 2 * item.wall) / 2
        let scene = Scenario(
            name: item.name, domainSize: SIMD3(100, 100, 50), boxes: [],
            charge: Charge(mass: item.charge, position: SIMD3(50, 50, height)))
        var cloud = FragmentCloud(spec: spec(item, count: count), scene: FragmentScene(scene))
        cloud.land(in: Primitive(density: 1.225, pressure: 101_325))
        return GroundHazard(impacts: cloud.impacts, centre: SIMD2(50, 50), crossings: cloud.crossings)
    }
}
