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
        // A run's glass taken back: each side's load put e^0.5 above the surrogate's, as a run that
        // loads every side that much harder would judge it.
        let predicted = all.predictions(massKg: truth.mass, east: truth.east, north: truth.north)
        var harder: [Int: Double] = [:]
        for (k, side) in all.sides.enumerated() {
            guard let p = predicted[k], let table = all.tables[side.mix.name] else { continue }
            let logNone =
                side.areaM2
                * table.logNoneBrokenPerM2(
                    logPeak: p.logPeak + 0.5, logDuration: log(2.0) + p.logImpulse - p.logPeak, rise: p.rise)
            // Where the chance is all but certain either way, any factor near it gives it: not told.
            if logNone > -3.5, logNone < -0.05 { harder[k] = logNone }
        }
        #expect(harder.count > 10)
        var corrected = all
        corrected.correct(towardGlass: harder, massKg: truth.mass, east: truth.east, north: truth.north)
        for k in harder.keys {
            #expect(
                abs(corrected.corrections![k].x - 0.5) < 0.05, "side \(k): \(corrected.corrections![k].x)")
        }
    }

    @Test("Surveyed façades are put on the sides of the scene's buildings they lie on and face as")
    func surveyOnSides() throws {
        let layout = try DistrictLayoutTests.layout()
        let half = layout.halfSide(radius: 250, cellSize: 4)
        let (scene, _) = try layout.scene(halfSide: half, cellSize: 4)
        let sides = ChargeInference.SurrogateDamage.judgedSides(scene: scene, cellSize: 4)
        #expect(sides.count > 50)
        // Each side's middle, 2 m out from its face, facing its way; every other one broken.
        let facades = sides.enumerated().map { k, side in
            let normal = side.axis == 0 ? SIMD2(Double(side.outward), 0) : SIMD2(0, Double(side.outward))
            let face = Double(
                side.outward > 0 ? side.region.max[side.axis] : side.region.min[side.axis])
            var place = SIMD2(side.east, side.north)
            place[side.axis] = face + 2 * Double(side.outward)
            return ChargeInference.Facade(
                east: place.x, north: place.y, damaged: k % 2 == 0, normalAzimuth: atan2(normal.x, normal.y))
        }
        let observed = ChargeInference.SurrogateDamage.observed(facades: facades, sides: sides, scene: scene)
        let found = Dictionary(
            observed.map { ("\($0.owner)/\($0.axis)/\($0.outward)", $0.damaged) },
            uniquingKeysWith: { a, b in a || b })
        var matched = 0
        for (k, side) in sides.enumerated() {
            let key = "\(scene.envelopeObjects[side.owner].id)/\(side.axis)/\(side.outward)"
            if found[key] == (k % 2 == 0) { matched += 1 }
        }
        // A façade can fall nearer a neighbour's side where buildings stand close.
        #expect(Double(matched) > 0.9 * Double(sides.count), "\(matched) of \(sides.count)")
        // Turned the other way, none lies on its own side (it may on a facing neighbour's across a
        // narrow gap).
        for (k, facade) in facades.enumerated() {
            var turned = facade
            turned.normalAzimuth = facade.normalAzimuth! + .pi
            let side = sides[k]
            let own = ChargeInference.SurrogateDamage.observed(facades: [turned], sides: sides, scene: scene)
                .contains {
                    $0.owner == scene.envelopeObjects[side.owner].id && $0.axis == side.axis
                        && $0.outward == side.outward
                }
            #expect(!own, "side \(k)")
        }
    }
}
