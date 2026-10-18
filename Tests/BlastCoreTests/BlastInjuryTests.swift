import Foundation
import Testing

@testable import BlastCore

@Suite("Blast injury and the safety distances")
struct BlastInjuryTests {
    /// Teland (FFI-rapport 2012/00539) Table 12.1: the distances at which TNT in free air gives 50%
    /// lethality by Bass's curves (standing in the open or against a wall) and by Bowen's against a
    /// wall, from ConWep's blast parameters, to the rear of the dummy.
    let teland: [(kg: Double, bass: Double, bowenWall: Double)] = [
        (0.5, 1.01, 1.01), (1, 1.35, 1.35), (9, 3.40, 3.40), (20, 4.90, 4.70), (200, 12.40, 11.65),
        (400, 16.60, 15.10), (1_500, 26.60, 24.50),
    ]

    @Test("Bass's 50% lethality from Kingery–Bulmash's free field: Teland's distances within 6%")
    func bassAgainstTeland() throws {
        for row in teland {
            let radius = try #require(
                BlastInjury.freeFieldRadii(kilograms: row.kg, surfaceBurst: false)[.lethality50])
            #expect(abs(radius / row.bass - 1) < 0.06, "\(row.kg) kg: \(radius) m against \(row.bass) m")
        }
    }

    @Test("Bowen's 50% lethality against a wall: Teland's distances within 5%")
    func bowenAgainstTeland() {
        for row in teland {
            // Where the free field's reflected overpressure meets Bowen's near-wall curve.
            let scale = cbrt(row.kg / 1.8)
            var low = 0.2 * scale
            var high = 40 * scale
            for _ in 0..<60 {
                let r = (low + high) / 2
                let z = r / scale
                let point = KingeryBulmash.point(at: z)!
                let t = BlastInjury.scaledDuration(KingeryBulmash.scaledDuration(at: z)! * scale)
                if point.reflectedPressure >= BlastInjury.bowenLethality50(duration: t) {
                    low = r
                } else {
                    high = r
                }
            }
            let radius = (low + high) / 2
            #expect(
                abs(radius / row.bowenWall - 1) < 0.05, "\(row.kg) kg: \(radius) m against \(row.bowenWall) m"
            )
        }
    }

    @Test("UFC 3-340-02's eardrum rupture: 5 psi and 15 psi")
    func eardrum() {
        #expect(abs(BlastInjury.eardrumThresholdPa / 6_894.757 - 5) < 0.001)
        #expect(abs(BlastInjury.eardrum50Pa / 6_894.757 - 15) < 0.001)
        // A long pulse of 30 kPa incident: in the open its dose, with the dynamic pressure, is
        // 32.9 kPa, under the threshold; against a wall, reflected, 72 kPa, over it.
        #expect(!BlastInjury.meets(.eardrumThreshold, peak: 30_000, duration: 0.05))
        #expect(BlastInjury.meets(.eardrumThreshold, peak: 30_000, duration: 0.05, stance: .againstWall))
        #expect(BlastInjury.level(peak: 30_000, duration: 0.05, stance: .againstWall) == .eardrumThreshold)
        // Further out than the lethality radius, in that order, for 100 kg on the ground.
        let radii = BlastInjury.freeFieldRadii(kilograms: 100)
        let order = BlastInjury.Level.allCases.dropFirst().compactMap { radii[$0] }
        #expect(order.count == 4 && radii[.eardrumThreshold]! > radii[.lethality50]!)
    }

    @Test("DoD 4145.26-M's K-factor distances, and the overpressures it names at them")
    func kFactors() {
        for k in KFactorDistance.all {
            #expect(abs(k.metric / (k.k * 0.3967) - 1) < 0.005, "\(k.name)")
        }
        #expect(abs(KFactorDistance.k40.distance(kilograms: 100) - 73.66) < 0.05)
        // K328 is never shown under the standard's 381 m: 20 kg scales to 353 m.
        #expect(abs(KFactorDistance.k328.distance(kilograms: 20) - 353) < 1)
        #expect(KFactorDistance.k328.requiredDistance(kilograms: 20) == 381)
        #expect(
            KFactorDistance.k328.requiredDistance(kilograms: 100)
                == KFactorDistance.k328.distance(kilograms: 100))
        #expect(
            KFactorDistance.k40.requiredDistance(kilograms: 20) == KFactorDistance.k40.distance(kilograms: 20)
        )
        // Kingery–Bulmash's surface burst at those scaled distances: within a fifth of the
        // pressures the standard names.
        for k in [KFactorDistance.k18, .k24, .k40] {
            let point = KingeryBulmash.point(at: Double(k.metric))!
            #expect(
                abs(point.incidentPressure / Double(k.overpressurePa!) - 1) < 0.2,
                "\(k.name): \(point.incidentPressure)")
        }
    }

    @Test(
        "The minimum safe distance is never shorter than the published distances, BombCAD's an estimate beside them"
    )
    func minimumSafeDistance() {
        let bare = MinimumSafeDistance(kilograms: 100, fragments: nil)
        #expect(bare.governedBy == "overpressure (K40)" && abs(bare.distanceM - 73.66) < 0.05)
        // DoD 4145.26-M Table AP2.T2: 100 lb (45.4 kg) 200.4 m, 300 lb (136.1 kg) 330.6 m, over 450 lb 381 m.
        #expect(abs(MinimumSafeDistance.defaultFragmentDistance(kilograms: 45.4) - 200.4) < 1)
        #expect(abs(MinimumSafeDistance.defaultFragmentDistance(kilograms: 136.1) - 330.6) < 1)
        #expect(MinimumSafeDistance.defaultFragmentDistance(kilograms: 500) == 381)
        #expect(abs(MinimumSafeDistance.defaultFragmentDistance(kilograms: 0.45) - 88.8) < 1)
        func impacts(at range: Float) -> [FragmentImpact] {
            (0..<1_000).map { _ in
                FragmentImpact(
                    fragment: 0, time: 0, position: SIMD3(range, 0, 0), speed: 300, energy: 500,
                    surface: "ground")
            }
        }
        // BombCAD's 150 m, short of DoD's default 294 m for 100 kg: the default governs.
        let cased = MinimumSafeDistance(
            kilograms: 100, fragments: GroundHazard(impacts: impacts(at: 150), centre: .zero))
        #expect(cased.governedBy == "DoD's default fragment distance" && abs(cased.distanceM - 294.1) < 0.5)
        #expect(cased.summary.contains("an estimate"))
        // Where BombCAD's is the larger, it governs.
        let far = MinimumSafeDistance(
            kilograms: 100, fragments: GroundHazard(impacts: impacts(at: 400), centre: .zero))
        #expect(far.governedBy == "BombCAD's fragment distance" && far.distanceM > 400)
    }
}
