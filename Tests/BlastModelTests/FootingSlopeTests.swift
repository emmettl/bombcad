import Foundation
import Testing
import simd

@testable import BlastModel

/// Footings on a hillside (`FootingGround`): level footings stepped into the slope, their soil read
/// from the terrain, against Vesić's ground factor on the bearing capacity and Coulomb's earth
/// pressures on sloping ground.
@Suite("Footings on a slope")
struct FootingSlopeTests {
    let angle: Float = 20
    /// The ground stands 4 m up at x = 10, where the blocks stand, rising along +x from below x = 0.
    var terrain: Terrain {
        let rise = tan(angle * .pi / 180)
        return .slope(domain: SIMD3(20, 20, 10), spacing: 0.5, foot: 10 - 4 / rise, angle: angle)
    }

    @Test(
        "Coulomb's pressures are Rankine's on level ground; downhill the passive falls, uphill the active rises"
    )
    func pressures() {
        let embedment = Embedment(depth: 0.5)
        let phi = embedment.frictionAngle
        let level = embedment.sloping(rise: 0)
        #expect(
            abs(level.active / embedment.active - 1) < 1e-5
                && abs(level.passive / embedment.passive - 1) < 1e-5)
        #expect(level.atRest == embedment.atRest)
        // At the steepest slope the soil stands, both wedges lie along it: cos²φ.
        #expect(abs(embedment.sloping(rise: -tan(phi)).passive / pow(cos(phi), 2) - 1) < 1e-4)
        #expect(abs(embedment.sloping(rise: tan(phi)).active / pow(cos(phi), 2) - 1) < 1e-4)
        let down = embedment.sloping(rise: -tan(angle * .pi / 180))
        let up = embedment.sloping(rise: tan(angle * .pi / 180))
        #expect(down.passive < 0.55 * level.passive && up.passive > level.passive)
        #expect(up.active > level.active && down.active < level.active)
        #expect(up.atRest >= up.active)
    }

    @Test(
        "A plane's slope is read exactly; the uphill side is buried deeper; the ground factor is (1 − tan β)²"
    )
    func ground() {
        let ground = FootingGround(terrain: terrain, centre: SIMD2(10, 10), base: 3.5, size: SIMD2(2, 2))
        let rise = tan(angle * .pi / 180)
        #expect(abs(ground.gradient.x - rise) < 1e-4 && abs(ground.gradient.y) < 1e-5)
        #expect(abs(ground.depth(at: .zero) - 0.5) < 1e-4)
        #expect(abs(ground.depth(at: SIMD2(-1, 0)) - (0.5 - rise)) < 1e-4)
        #expect(abs(ground.rise(away: SIMD2(-1, 0)) + rise) < 1e-4)
        #expect(abs(ground.fall - rise) < 1e-4 && simd_distance(ground.downhill, SIMD2(-1, 0)) < 1e-4)
        #expect(abs(ground.bearingFactor(frictionAngle: 35 * .pi / 180) - pow(1 - rise, 2)) < 1e-4)
        // On a plateau b back from its crest (at x = 12), the fall over 4B is (1 − b/4B) of the
        // slope's: at the crest the face's, from 4B back none.
        let plateau = Terrain.sampled(domain: SIMD3(30, 20, 10), spacing: 0.5) { min(4, ($0.x - 1) * rise) }
        func fall(back b: Float) -> Float {
            FootingGround(terrain: plateau, centre: SIMD2(13 + b, 10), base: 3.5, size: SIMD2(2, 2)).fall
        }
        for b in [0, 2, 4, 6] as [Float] {
            #expect(abs(fall(back: b) / rise - max(1 - b / 8, 0)) < 0.02, "\(b): \(fall(back: b) / rise)")
        }
    }

    @Test(
        "Sides in the slope: the uphill side bears from deeper and gives more passive, and the stiffness holds"
    )
    func sides() {
        let soil = Soil(bearingCapacity: nil, cyclic: nil)
        let embedment = Embedment(depth: 0.5)
        let bed = FootingBed(width: 2, length: 2, soil: soil, embedment: embedment, thickness: 0.5)
        let level = FootingSides(
            width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment, base: bed.stiffness)
        // The ground as deep over the base everywhere as the level embedment: the same sides.
        let flat = Terrain.sampled(domain: SIMD3(20, 20, 10), spacing: 0.5) { _ in 4 }
        let even = FootingSides(
            width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment, base: bed.stiffness,
            ground: FootingGround(terrain: flat, centre: SIMD2(10, 10), base: 3.5, size: SIMD2(2, 2)))
        for (a, b) in zip(level.stiffness, even.stiffness) { #expect(abs(a / b - 1) < 1e-4) }
        let sloped = FootingSides(
            width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment, base: bed.stiffness,
            ground: FootingGround(terrain: terrain, centre: SIMD2(10, 10), base: 3.5, size: SIMD2(2, 2)))
        func deepest(_ normal: SIMD2<Float>) -> SIMD3<Float> {
            sloped.points.filter { $0.normal == normal }.map(\.pressures).max { $0.z < $1.z } ?? .zero
        }
        let uphill = deepest(SIMD2(1, 0))
        let downhill = deepest(SIMD2(-1, 0))
        #expect(uphill.x > 2 * downhill.x && uphill.z > 4 * downhill.z)
        // Every point lies within the side's height in the ground.
        #expect(sloped.points.allSatisfy { $0.place.z <= 0.5 + 1e-6 && $0.pressures.x >= 0 })
    }
}
