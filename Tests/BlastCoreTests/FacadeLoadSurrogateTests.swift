import Foundation
import Testing
import simd

@testable import BlastCore

/// The façade load surrogate's first look (`FacadeLoadSurrogate`, docs/surrogate-first-look.md).
@Suite("Façade load surrogate")
struct FacadeLoadSurrogateTests {
    /// A 20 m cube with its charge 100 m off to −x, and another cube behind it at 150 m.
    static func row() throws -> Scenario {
        var scene = Scenario(
            name: "Row", domainSize: SIMD3(400, 120, 60), boxes: [],
            charge: Charge(mass: 1_000, position: SIMD3(20, 60, 1)))
        for x: Float in [120, 170] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 50, 0), max: SIMD3(x + 20, 70, 20))]))
        }
        return scene
    }

    @Test("A pulse carries the predicted peak and impulse, rising over its share")
    func pulse() throws {
        let component = try #require(
            Self.row().envelopeObjects[0].envelope?.components(owner: UUID(), cellSize: 1).first {
                $0.kind == .facade
            })
        let prediction = FacadeLoadSurrogate.Prediction(
            peakPa: 10_000, impulsePaS: 100, riseShare: 0.3, arrivalS: 0.25)
        let load = FacadeLoadSurrogate.load(component, prediction, binS: 0.5e-3)
        let impulse = load.netPa.reduce(0, +) * load.binS
        // Each rounded to 3%.
        #expect(abs(impulse / 100 - 1) < 0.03)
        #expect(abs((load.netPa.max() ?? 0) / 10_000 - 1) < 0.03)
        let duration = Double(load.netPa.count) * load.binS
        let top = Double(load.netPa.firstIndex(of: load.netPa.max()!)!) * load.binS
        #expect(abs(top / duration - 0.3) < 0.02)
        #expect(load.startS == 0.25)
    }

    @Test("The building in front is in sight; the one behind it has it in the way")
    func sight() throws {
        let scene = try Self.row()
        let objects = scene.envelopeObjects
        let raster = FacadeLoadSurrogate.Raster(objects: objects, terrain: nil, cell: 2)
        func front(_ n: Int) throws -> FacadeLoadSurrogate.Features {
            let strip = try #require(
                objects[n].envelope?.components(owner: objects[n].id, cellSize: 2).first {
                    $0.kind == .facade && $0.axis == 0 && $0.outward < 0
                })
            return FacadeLoadSurrogate.features(
                strip, owner: n, charge: scene.charge.position, raster: raster)
        }
        let first = try front(0)
        let second = try front(1)
        #expect(first.buildingsCrossed == 0 && first.blockedM == 0)
        #expect(first.cosIncidence > 0.99)
        #expect(second.buildingsCrossed == 1)
        #expect(abs(second.blockedM - 20) < 2)
        #expect(abs(second.shadowM - 30) < 2)
        // The fitted terms load the front harder than the back, and the one in sight harder.
        let mass = Double(scene.charge.mass)
        let back = try #require(
            objects[0].envelope?.components(owner: objects[0].id, cellSize: 2).first {
                $0.kind == .facade && $0.axis == 0 && $0.outward > 0
            })
        let behind = FacadeLoadSurrogate.features(
            back, owner: 0, charge: scene.charge.position, raster: raster)
        let a = FacadeLoadSurrogate.predict(first, mass: mass, cellSize: 2)
        let b = FacadeLoadSurrogate.predict(behind, mass: mass, cellSize: 2)
        let c = FacadeLoadSurrogate.predict(second, mass: mass, cellSize: 2)
        #expect(a.peakPa > b.peakPa && a.peakPa > c.peakPa)
        #expect(a.arrivalS < c.arrivalS)
    }

    @Test("A side against its neighbour has no air beside it")
    func air() throws {
        var scene = Scenario(
            name: "Terrace", domainSize: SIMD3(100, 100, 30), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(5, 50, 1)))
        for x: Float in [40, 50] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 40, 0), max: SIMD3(x + 10, 60, 9))]))
        }
        let objects = scene.envelopeObjects
        let raster = FacadeLoadSurrogate.Raster(objects: objects, terrain: nil, cell: 1)
        let strips = try #require(objects[0].envelope?.components(owner: objects[0].id, cellSize: 1))
            .filter { $0.kind == .facade && $0.axis == 0 }
        #expect(
            strips.filter { $0.outward < 0 }.allSatisfy { FacadeLoadSurrogate.facesAir($0, raster: raster) })
        #expect(
            !strips.filter { $0.outward > 0 }.contains { FacadeLoadSurrogate.facesAir($0, raster: raster) })
    }

    @Test("Remembered SDOF responses are the ones integrated")
    func memo() {
        let pane = EnvelopeDamageAssessment.annealedPane(thickness: 0.006, a: 1.2, b: 1.5)
        let pressures = (0..<80).map { 4_000 * max(0, 1 - Double($0) / 60) }
        let direct = pane.response(pressures: pressures, step: 0.5e-3)
        let (twice, memo) = SDOFResponseMemo.remembering {
            [
                pane.response(pressures: pressures, step: 0.5e-3),
                pane.response(pressures: pressures, step: 0.5e-3),
            ]
        }
        #expect(twice == [direct, direct])
        #expect(memo.misses == 1 && memo.hits == 1)
        // None set outside it.
        #expect(SDOFResponseMemo.active == nil)
    }

    @Test("A first look judges the buildings near the made-up district's charge, the nearest the worst")
    func firstLook() throws {
        var layout = try DistrictLayoutTests.layout()
        layout.mass = 20_000
        let (scene, _) = try layout.scene(halfSide: 700, cellSize: 4, radius: 250)
        let estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: 4)
        #expect(!estimate.loads.isEmpty)
        #expect(estimate.predictions.allSatisfy { $0.peakPa > 0 && $0.impulsePaS > 0 })
        let (buildings, _, memo) = FacadeLoadSurrogate.damage(
            estimate, constructions: { scene.envelopeConstruction(for: $0) })
        #expect(buildings.count == scene.envelopeObjects.count)
        #expect(memo.hits > 0)
        // The nearest building's glass breaks more than the furthest's.
        let charge = SIMD2(scene.charge.position.x, scene.charge.position.y)
        func distance(_ id: UUID) -> Float {
            let blocks = scene.object(id: id)?.envelope?.blocks ?? []
            let centre =
                blocks.map { 0.5 * ($0.min + $0.max) }.reduce(SIMD3<Float>.zero, +) / Float(blocks.count)
            return simd_distance(SIMD2(centre.x, centre.y), charge)
        }
        let sorted = buildings.filter { $0.glass != nil }.sorted { distance($0.id) < distance($1.id) }
        let near = try #require(sorted.first?.glass)
        let far = try #require(sorted.last?.glass)
        #expect(near.fraction > far.fraction)
    }

    static func facing(_ distance: Double) -> FacadeLoadSurrogate.Features {
        FacadeLoadSurrogate.Features(
            distanceM: distance, cosIncidence: 1, buildingsCrossed: 0, blockedM: 0, ridgeM: 0, groundRiseM: 0,
            heightM: 1.5, shadowM: 0, frontM: 50)
    }

    @Test("Close in, the fitted terms are held at the fitted range's end, not carried to nothing, and marked")
    func fittedRange() {
        let mass = 20_000.0
        let root = cbrt(mass)
        let range = FacadeLoadSurrogate.Coefficients.fitted.scaledRange
        func correction(_ z: Double) -> Double {
            let f = Self.facing(z * root)
            let p = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: 4)
            return p.peakPa / FacadeLoadSurrogate.base(f, mass: mass).peak
        }
        // Inside the range, its own; below it, the range's end's.
        #expect(abs(correction(1) / correction(range.lowerBound) - 1) < 1e-9)
        #expect(correction(1) > 0.2)
        #expect(FacadeLoadSurrogate.predict(Self.facing(root), mass: mass, cellSize: 4).outsideFit)
        #expect(!FacadeLoadSurrogate.predict(Self.facing(10 * root), mass: mass, cellSize: 4).outsideFit)
        #expect(FacadeLoadSurrogate.predict(Self.facing(60 * root), mass: mass, cellSize: 4).outsideFit)
    }

    @Test("Beyond the curves the shock goes on at the speed of sound; no charge gives no load")
    func farAndNone() {
        let mass = 20_000.0
        let root = cbrt(mass)
        let at40 = FacadeLoadSurrogate.base(Self.facing(40 * root), mass: mass).arrival
        let just = FacadeLoadSurrogate.base(Self.facing(40.001 * root), mass: mass).arrival
        let far = FacadeLoadSurrogate.base(Self.facing(80 * root), mass: mass).arrival
        #expect(abs(just - at40) < 1e-3)
        #expect(abs((far - at40) - 40 * root / 340.3) < 1e-9)
        let none = FacadeLoadSurrogate.predict(Self.facing(100), mass: 0, cellSize: 4)
        #expect(none.peakPa == 0 && none.impulsePaS == 0 && none.arrivalS == 0)
    }

    @Test("The memo holds up under many threads at once")
    func memoConcurrently() {
        let pane = EnvelopeDamageAssessment.annealedPane(thickness: 0.006, a: 1.2, b: 1.5)
        let loads: [[Double]] = (0..<32).map { n in
            let peak = 1_000 * Double(n + 1)
            return (0..<40).map { (k: Int) -> Double in peak * max(0, 1 - Double(k) / 30) }
        }
        let direct = loads.map { pane.response(pressures: $0, step: 0.5e-3) }
        var answers = [SDOFResponse?](repeating: nil, count: 2_000)
        let (_, memo) = SDOFResponseMemo.remembering {
            answers.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: out.count) { n in
                    out[n] = pane.response(pressures: loads[n % loads.count], step: 0.5e-3)
                }
            }
        }
        #expect(answers.indices.allSatisfy { answers[$0] == direct[$0 % loads.count] })
        #expect(memo.hits + memo.misses == answers.count)
        #expect(memo.misses >= loads.count)
    }
}
