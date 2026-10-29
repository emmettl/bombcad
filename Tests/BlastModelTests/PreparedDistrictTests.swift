import Foundation
import Testing
import simd

@testable import BlastModel

/// A district laid out once for many places of the charge (`FacadeLoadSurrogate.Prepared`,
/// emmettl/bombcad-work#34): the same answers as laying it out each time, and a preview of a tenth
/// of the components.
@Suite("Prepared district")
struct PreparedDistrictTests {
    @Test("Laid out once, a charge anywhere gives what laying it out again gives, to the bit")
    func sameAsScene() throws {
        var scene = try FacadeGlassProbabilityTests.row()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        for place in [scene.charge.position, scene.charge.position + SIMD3(6, -4, 0)] {
            scene.charge.position = place
            let whole = FacadeLoadSurrogate.estimate(scene: scene, cellSize: 2)
            let mine = prepared.estimate(charge: place, mass: Double(scene.charge.mass))
            #expect(whole.loads.map(\.id) == mine.loads.map(\.id))
            #expect(whole.loads.map(\.outerPa) == mine.loads.map(\.outerPa))
            #expect(whole.features == mine.features)
            let sides = FacadeLoadSurrogate.glassSides(scene: scene, cellSize: 2)
            let mySides = prepared.glassSides(mine)
            #expect(sides.map(\.owner) == mySides.map(\.owner))
            #expect(sides.map { $0.strips.map(\.features) } == mySides.map { $0.strips.map(\.features) })
            #expect(sides.map { $0.strips.map(\.areaM2) } == mySides.map { $0.strips.map(\.areaM2) })
        }
    }

    @Test("A look gives the quick estimate's damage and chances, again alike with its responses kept")
    func look() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let constructions = { (id: UUID) in scene.envelopeConstruction(for: id) }
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: 0.2, samples: 8)
        let estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: 2)
        let (damage, _, _) = FacadeLoadSurrogate.damage(estimate, constructions: constructions)
        let (glass, _) = FacadeLoadSurrogate.glassProbabilities(
            scene: scene, cellSize: 2, uncertainty: uncertainty)
        let (structure, _) = FacadeLoadSurrogate.structureProbabilities(
            estimate, mass: Double(scene.charge.mass), cellSize: 2, constructions: constructions,
            uncertainty: uncertainty)
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        for _ in 0..<2 {
            let look = prepared.look(
                charge: scene.charge.position, mass: Double(scene.charge.mass), constructions: constructions,
                uncertainty: uncertainty)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            #expect(try encoder.encode(look.damage) == encoder.encode(damage))
            #expect(look.glass == glass)
            #expect(look.structure == structure)
        }
        // Previews keep their responses between looks.
        for _ in 0..<2 {
            _ = prepared.look(
                charge: scene.charge.position, mass: Double(scene.charge.mass), constructions: constructions,
                uncertainty: uncertainty, preview: true)
        }
        #expect(prepared.memo.hits > 0)
    }

    @Test(
        "A preview judges each building's nearest component of each kind and side, its glass on the side's area"
    )
    func preview() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let charge = scene.charge.position
        let full = prepared.estimate(charge: charge, mass: Double(scene.charge.mass))
        let (preview, sides) = prepared.preview(charge: charge, mass: Double(scene.charge.mass))
        func group(_ c: EnvelopeComponent) -> String { "\(c.owner)/\(c.kind)/\(c.axis)/\(c.outward)" }
        // One of each group, and the nearest of it.
        let groups = Dictionary(grouping: full.components.indices, by: { group(full.components[$0]) })
        #expect(preview.components.count == groups.count)
        #expect(preview.components.count < full.components.count)
        for (k, component) in preview.components.enumerated() {
            let members = try #require(groups[group(component)])
            let nearest = members.map { full.features[$0].distanceM }.min()!
            #expect(preview.features[k].distanceM == nearest)
        }
        // Each glazed side's area is its strips' together.
        let fullSides = prepared.glassSides(full)
        #expect(sides.count == fullSides.count)
        for (a, b) in zip(sides, fullSides) {
            #expect(a.strips.count == 1)
            #expect(abs(a.strips[0].areaM2 - b.strips.reduce(0) { $0 + $1.areaM2 }) < 1e-6)
        }
    }

    @Test(
        "Facing as its outline, a side's strips on differently facing edges each have a strip in the preview")
    func previewByOutlineFacing() throws {
        // A block turned 45° to the cells: each of its cells' sides (thin along one axis, out one way)
        // holds the strips of two fronts at a right angle, one facing the charge and one away
        // (emmettl/bombcad-work#110).
        let scene = try SurrogateOutlineIncidenceTests.block(degrees: 45)
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        #expect(prepared.raster.incidence == .outline)
        let charge = scene.charge.position
        let mass = Double(scene.charge.mass)
        let full = prepared.estimate(charge: charge, mass: mass)
        let (preview, sides) = prepared.preview(charge: charge, mass: mass)
        let fullSides = prepared.glassSides(full)
        try #require(!fullSides.isEmpty)
        #expect(sides.count == fullSides.count)
        // Each façade strip's facing, rounded: its outline edge's, else its cells' face's.
        func facing(_ k: Int) -> SIMD2<Int> {
            let c = full.components[k]
            var n = SIMD3<Float>.zero
            n[c.axis] = Float(c.outward)
            n =
                prepared.raster.outlineNormal(region: c.region, axis: c.axis, outward: c.outward, owner: 0)
                ?? n
            return SIMD2(Int((n.x * 1000).rounded()), Int((n.y * 1000).rounded()))
        }
        for (a, b) in zip(sides, fullSides) {
            #expect(a.axis == b.axis && a.outward == b.outward)
            let members = full.components.indices.filter {
                full.components[$0].kind == .facade && full.components[$0].axis == a.axis
                    && full.components[$0].outward == a.outward
            }
            let byFacing = Dictionary(grouping: members, by: facing)
            #expect(byFacing.count >= 2)
            // One strip for each facing: the nearest of it, standing for its area.
            #expect(a.strips.count == byFacing.count)
            for strip in a.strips {
                let group = try #require(
                    byFacing.values.first { group in
                        group.contains { full.features[$0] == strip.features }
                    })
                #expect(strip.features.distanceM == group.map { full.features[$0].distanceM }.min()!)
                let area = group.reduce(0.0) {
                    let spans = full.components[$1].spans
                    return $0 + Double(spans.x * spans.y)
                }
                #expect(abs(strip.areaM2 - area) < 1e-6)
            }
        }
        // The estimate itself still takes the nearest of each kind and side, whichever way it faces.
        func group(_ c: EnvelopeComponent) -> String { "\(c.kind)/\(c.axis)/\(c.outward)" }
        let groups = Dictionary(grouping: full.components.indices, by: { group(full.components[$0]) })
        #expect(preview.components.count == groups.count)
        for (k, component) in preview.components.enumerated() {
            let members = try #require(groups[group(component)])
            #expect(preview.features[k].distanceM == members.map { full.features[$0].distanceM }.min()!)
        }
        // Without its outline, one strip a side, as facing as the cells.
        let plain = try SurrogateOutlineIncidenceTests.block(degrees: 45, keepsOutlines: false)
        let (_, plainSides) = FacadeLoadSurrogate.Prepared(scene: plain, cellSize: 2).preview(
            charge: charge, mass: mass)
        #expect(!plainSides.isEmpty && plainSides.allSatisfy { $0.strips.count == 1 })
    }

    @Test(
        "Stratified, a few draws spread evenly over their distributions, the yields' middle on the charge's")
    func stratified() {
        var uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: 0.25, samples: 10)
        uncertainty.stratified = true
        let masses = uncertainty.masses(base: 1_000, draws: 10)
        #expect(masses == masses.sorted())
        let logMean = masses.reduce(0) { $0 + log($1 / 1_000) } / 10
        #expect(abs(logMean) < 1e-9)
        // Each the mirror of its partner about the charge's yield.
        for k in 0..<5 { #expect(abs(log(masses[k] / 1_000) + log(masses[9 - k] / 1_000)) < 1e-9) }
        // Each item's other draws: the same quantiles, in an order of its own.
        let quantiles = (0..<10).map { EnsembleDistribution.inverseNormal((Double($0) + 0.5) / 10) }
        let first = (0..<10).map { uncertainty.normal(2, $0, 7, draws: 10) }
        let second = (0..<10).map { uncertainty.normal(2, $0, 8, draws: 10) }
        #expect(first.sorted() == quantiles && second.sorted() == quantiles)
        #expect(first != second)
    }

    @Test("A preview works out only the parts asked for")
    func parts() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let look = prepared.look(
            charge: scene.charge.position, mass: Double(scene.charge.mass),
            constructions: { scene.envelopeConstruction(for: $0) },
            uncertainty: FacadeLoadSurrogate.Uncertainty(samples: 4), preview: true, parts: .glass)
        #expect(look.preview)
        #expect(look.damage.isEmpty && look.structure.isEmpty)
        #expect(!look.glass.isEmpty)
    }
}
