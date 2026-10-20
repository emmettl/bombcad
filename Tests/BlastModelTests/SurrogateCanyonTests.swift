import Foundation
import Testing
import simd

@testable import BlastModel

/// The façade surrogate's street canyon, knife edge and close-in branch (emmettl/bombcad-work#4,
/// docs/surrogate-first-look.md): the features `Raster.sight` and `Raster.canyon` read off a plan,
/// and the branch's join to the fitted terms.
@Suite("Façade surrogate: canyons, knife edges and the close-in branch")
struct SurrogateCanyonTests {
    /// A radial street 10 m wide between walls 15 m tall and 20 m deep, from 60 to 260 m out along
    /// x, as `blastbench canyon` lays it (both sides here).
    static let walls = [
        Box(min: SIMD3(60, 5, 0), max: SIMD3(260, 25, 15)),
        Box(min: SIMD3(60, -25, 0), max: SIMD3(260, -5, 15)),
    ]
    static let charge = SIMD3<Float>(0, 0, 0.5)

    static func features(_ region: Box, axis: Int, outward: Int, blocks: [Box], cell: Float = 1)
        -> FacadeLoadSurrogate.Features
    {
        let raster = FacadeLoadSurrogate.Raster(objects: [], blocks: blocks, terrain: nil, cell: cell)
        return FacadeLoadSurrogate.features(
            region: region, axis: axis, outward: outward, owner: 0, charge: charge, raster: raster)
    }

    @Test("A façade on a street wall sees the street from its mouth, at the walls' height")
    func streetWall() {
        // On the +y wall's face, 100 m into the street.
        let f = Self.features(
            Box(min: SIMD3(150, 5, 0), max: SIMD3(170, 5.2, 3)), axis: 1, outward: -1, blocks: Self.walls)
        #expect(abs(f.canyonM - 100) < 3, "\(f.canyonM)")
        #expect(abs(f.canyonHeightM - 15) < 0.01)
        // Nothing stands under its line: no knife edge.
        #expect(f.edgeM == -.infinity && f.buildingsCrossed == 0)
        // Its gain at 1 t: 0.683 u e^(−ℓ/8h), u = log(Z / (Z − ℓ)), each over W^(1/3) = 10 m.
        let z = f.distanceM / 10
        let expected = 0.683 * log(z / (z - f.canyonM / 10)) * exp(-(f.canyonM / 10) / (8 * 1.5))
        let terms = FacadeLoadSurrogate.terms(f, mass: 1_000, cellSize: 1)
        #expect(abs(terms[FacadeLoadSurrogate.geometryTerms] * 0.683 - expected) < 1e-9)
        // At 500 t the walls are 0.19 W^(1/3): the impulse's term is nothing, the peak's small.
        let kt = FacadeLoadSurrogate.terms(f, mass: 500_000, cellSize: 4)
        #expect(kt[FacadeLoadSurrogate.geometryTerms + 1] == 0)
        #expect(kt[FacadeLoadSurrogate.geometryTerms] * 0.683 < 0.02)
    }

    @Test("A façade in the open, or across a gap behind another block, is in no street")
    func noStreet() {
        let open = Self.features(
            Box(min: SIMD3(40, -6, 0), max: SIMD3(40.2, 6, 3)), axis: 0, outward: -1, blocks: [])
        #expect(open.canyonM == 0 && open.edgeM == -.infinity && open.edgeSideM == 0)
        // Behind a block 20 m wide and 10 m tall, 10 m in front of it (layout L2's first arm).
        let front = Box(min: SIMD3(15, -10, 0), max: SIMD3(25, 10, 10))
        let behind = Self.features(
            Box(min: SIMD3(35, -6, 0), max: SIMD3(35.2, 6, 3)), axis: 0, outward: -1, blocks: [front])
        #expect(behind.canyonM == 0)
        #expect(behind.buildingsCrossed == 1 && behind.edgeM > 8 && behind.edgeM < 10)
        #expect(abs(behind.lastTopM - 10) < 0.01 && abs(behind.edgeTopM - 10) < 0.01)
        #expect(behind.edgeToTargetM > 9 && behind.edgeToTargetM < 11.5)
        // The block reaches 10 m to either side of the line through its middle.
        #expect(abs(behind.edgeSideM - 10) <= 1)
    }

    @Test("The close-in branch joins the fitted terms without a step, and covers Z 1.5 to 4.6")
    func closeInJoins() throws {
        let coefficients = FacadeLoadSurrogate.Coefficients.fitted
        let close = try #require(coefficients.closeIn)
        let mass = 1_000.0
        func at(_ z: Double) -> FacadeLoadSurrogate.Prediction {
            let f = FacadeLoadSurrogate.Features(
                distanceM: z * 10, cosIncidence: 1, buildingsCrossed: 0, blockedM: 0, ridgeM: 0,
                groundRiseM: 0,
                heightM: 1.5, shadowM: 0, frontM: 200)
            return FacadeLoadSurrogate.predict(f, mass: mass, cellSize: 0.5)
        }
        for z in [coefficients.scaledRange.lowerBound, close.blendTo] {
            let below = at(z * (1 - 1e-6))
            let above = at(z * (1 + 1e-6))
            #expect(abs(log(below.peakPa / above.peakPa)) < 1e-4, "peak steps at Z \(z)")
            #expect(abs(log(below.impulsePaS / above.impulsePaS)) < 1e-4, "impulse steps at Z \(z)")
        }
        // Below the fit's range, the branch on its reference cells: Kingery–Bulmash's reflected
        // peak times e^(a0 + a1 log Z + a2 (log Z)²).
        let z = 3.0
        let f = FacadeLoadSurrogate.Features(
            distanceM: z * 10, cosIncidence: 1, buildingsCrossed: 0, blockedM: 0, ridgeM: 0, groundRiseM: 0,
            heightM: 1.5, shadowM: 0, frontM: 200)
        let reference = close.referenceCell * 10
        let p = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: reference)
        let base = FacadeLoadSurrogate.base(f, mass: mass)
        let ratio = exp(close.peak[0] + close.peak[1] * log(z) + close.peak[2] * log(z) * log(z))
        #expect(abs(p.peakPa / base.peak / ratio - 1) < 1e-9)
        #expect(!at(2).outsideFit && at(1).outsideFit && !at(10).outsideFit)
    }
}
