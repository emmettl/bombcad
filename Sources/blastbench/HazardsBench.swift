import BlastCore
import Foundation
import Metal
import simd

// `blastbench hazards` and `blastbench fragment-throw`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The safety standards' distances and the free field's injury radii for a charge on the ground.
func runHazards() throws {
    let mass = option("mass").flatMap { Float($0) } ?? 100
    var fragments: GroundHazard?
    if let path = option("fragments") {
        let spec = try JSONDecoder().decode(
            FragmentSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let height = option("height").flatMap { Float($0) } ?? 1
        let scene = Scenario(
            name: "Hazards", domainSize: SIMD3(100, 100, 50), boxes: [],
            charge: Charge(mass: mass, position: SIMD3(50, 50, height)))
        var cloud = FragmentCloud(spec: spec, scene: FragmentScene(scene))
        cloud.land(in: Primitive(density: 1.225, pressure: 101_325))
        fragments = GroundHazard(
            impacts: cloud.impacts, centre: SIMD2(50, 50), crossings: cloud.crossings)
        print("Fragments: " + fragments!.summary)
    }
    for k in KFactorDistance.all {
        print(
            String(
                format: "%@ (%.2f m/kg^(1/3)): %6.1f m", k.name, k.metric,
                k.requiredDistance(kilograms: mass))
                + (k.overpressurePa.map { String(format: ", %.1f kPa", $0 / 1000) } ?? "") + " — " + k.use
        )
    }
    print("M" + MinimumSafeDistance(kilograms: mass, fragments: fragments).summary.dropFirst())
    for stance in [BlastInjury.Stance.open, .againstWall] {
        let radii = BlastInjury.freeFieldRadii(kilograms: Double(mass), stance: stance)
        print(
            (stance == .open ? "In the open: " : "Against a wall facing it: ")
                + BlastInjury.Level.allCases.dropFirst().map { level in
                    level.title.lowercased()
                        + (radii[level].map { String(format: " to %.1f m", $0) } ?? " nowhere")
                }.joined(separator: "; "))
    }
}

/// BombCAD's hazardous fragment distance against DoD 4145.26-M's for single items in the open.
func runFragmentThrow() throws {
    let count = option("count").flatMap { Int($0) } ?? 100_000
    for item in FragmentThrowComparison.cases {
        let hazard = FragmentThrowComparison.hazard(item, count: count)
        print(
            String(
                format: "%-34@ in flight %6.1f m, ground %5.1f m, DoD %6.1f m: %.2f (%d flown set it)",
                item.name as NSString, hazard.airDistance ?? 0, hazard.groundDistance ?? 0, item.measured,
                (hazard.hazardDistance ?? 0) / item.measured, hazard.samplesAtDistance))
        // DDESB TP-12's closed form from the same masses and speed: the flown cubes' shape
        // factor, then TP-12's natural fragments' 2.6 g/cm³, each at its drag of 1.28.
        print(
            String(
                format: "%@ TP-12's procedure %6.1f m (cubes), %6.1f m (k 2.6 g/cm³)",
                String(repeating: " ", count: 34) as NSString,
                FragmentThrowComparison.zakerDistance(
                    item, shapeFactor: 7850 / pow(1.5, 1.5), drag: 1.28),
                FragmentThrowComparison.zakerDistance(item, shapeFactor: 2600, drag: 1.28)))
    }
}
