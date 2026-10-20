import Foundation
import Testing
import simd

@testable import BlastModel

/// The glass seen on a scene's own buildings as evidence of the charge
/// (`ChargeInference.SurrogateDamage`), on the made-up district.
@Suite("Charge inference from the scene's own glass")
struct SurrogateDamageTests {
    @Test("The likelihood of glass the model itself breaks is highest at the true yield and place")
    func peaksAtTheTruth() throws {
        var layout = try DistrictLayoutTests.layout()
        layout.mass = 1_000
        let half = layout.halfSide(radius: 250, cellSize: 4)
        let (scene, _) = try layout.scene(halfSide: half, cellSize: 4)
        let every = scene.envelopeObjects.flatMap { object in
            [(0, -1), (0, 1), (1, -1), (1, 1)].map {
                (owner: object.id, axis: $0.0, outward: $0.1, damaged: false)
            }
        }
        let centre = SIMD2<Float>(half, half)
        // Coarse breakage tables: the debug build takes long over the full ones.
        func damage(_ observed: [(owner: UUID, axis: Int, outward: Int, damaged: Bool)])
            -> ChargeInference.SurrogateDamage
        {
            ChargeInference.SurrogateDamage(
                scene: scene, observed: observed, reference: centre, placeRadius: 120, spacing: 60,
                cellSize: 4,
                maximumSides: 120, strengthLogSD: 0.25, coefficients: .fitted, tableCoarsening: 6)
        }
        let all = damage(every)
        #expect(all.sides.count > 50)
        // 300 kg, 40 m east and 30 m south of the centre: a side counts broken where the model's chance
        // is over a half.
        let truth = (mass: 300.0, east: 40.0, north: -30.0)
        let chances = all.chances(massKg: truth.mass, east: truth.east, north: truth.north)
        let broken = chances.filter { $0 > 0.5 }.count
        #expect(broken > 5 && broken < chances.count - 5, "\(broken) of \(chances.count)")
        let observed = zip(all.sides, chances).map {
            (owner: scene.envelopeObjects[$0.owner].id, axis: $0.axis, outward: $0.outward, damaged: $1 > 0.5)
        }
        let seen = damage(observed)
        func value(_ mass: Double, _ east: Double, _ north: Double) -> Double {
            seen.logLikelihood(massKg: mass, east: east, north: north, perSide: true)
        }
        let atTruth = value(truth.mass, truth.east, truth.north)
        #expect(atTruth > value(truth.mass / 3, truth.east, truth.north))
        #expect(atTruth > value(truth.mass * 3, truth.east, truth.north))
        #expect(atTruth > value(truth.mass, truth.east - 80, truth.north + 60))
    }
}
