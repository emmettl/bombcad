import Foundation
import Testing

@testable import BlastModel

/// The coefficients and readings of a collapse's dust (`DustSettings`, `DustField`).
@Suite("A collapse's dust")
struct CollapseDustTests {
    @Test("Fines settle at Stokes's speed when small, slower than it when large")
    func settling() {
        let settings = DustSettings.standard
        let stokes = { (d: Double) in
            (settings.particleDensity - settings.airDensity) * settings.gravity * d * d
                / (18 * settings.airViscosity)
        }
        // 10 µm: Re 0.005, Stokes's law within a per cent.
        #expect(abs(settings.fineSettling / stokes(10e-6) - 1) < 0.01)
        #expect(abs(settings.fineSettling - 7.5e-3) < 0.2e-3)
        // 100 µm: Re about 4, a quarter slower than Stokes's 0.75 m/s.
        #expect(settings.coarseSettling > 0.5 && settings.coarseSettling < 0.6)
        // The drag at that speed balances the weight (Schiller and Naumann).
        let d = settings.coarseDiameter
        let v = settings.coarseSettling
        let reynolds = settings.airDensity * v * d / settings.airViscosity
        let drag = 3 * Double.pi * settings.airViscosity * d * v * (1 + 0.15 * pow(reynolds, 0.687))
        let weight =
            (settings.particleDensity - settings.airDensity) * settings.gravity * Double.pi * d * d * d / 6
        #expect(abs(drag / weight - 1) < 1e-6)
    }

    @Test("Fines from fracture work and a share of impact losses")
    func fines() {
        let settings = DustSettings.standard
        #expect(abs(settings.fines(fractureWork: 5e4) - 1) < 1e-12)
        #expect(abs(settings.fines(fractureWork: 0, impactLoss: 5e4) - settings.impactShare) < 1e-12)
        #expect(abs(settings.withEnergy(times: 2).fines(fractureWork: 1e5) - 1) < 1e-12)
    }

    @Test("A field's airborne mass, its cloud's top and reach, and its columns")
    func readings() {
        // 4 x 4 x 4 cells of 1 m; 2 g/m³ of fines in cell (3, 1, 2), 1 mg/m³ in (0, 0, 0), a solid cell
        // holding 5 g/m³.
        let dims = SIMD3(4, 4, 4)
        var fine = [Float](repeating: 0, count: 64)
        var coarse = fine
        var solid = [Bool](repeating: false, count: 64)
        fine[3 + 4 * (1 + 4 * 2)] = 1e-3
        coarse[3 + 4 * (1 + 4 * 2)] = 1e-3
        fine[0] = 1e-6
        coarse[1 + 4 * 1] = 5e-3
        solid[1 + 4 * 1] = true
        let field = DustField(dims: dims, cellSize: 1, fine: fine, coarse: coarse, solid: solid)
        let airborne = field.airborne()
        #expect(abs(airborne.all.x - 1.001e-3) < 1e-9 && abs(airborne.all.y - 6e-3) < 1e-9)
        #expect(abs(airborne.inSolids.y - 5e-3) < 1e-9 && airborne.inSolids.x == 0)
        let plan = (min: SIMD2<Double>(0, 0), max: SIMD2<Double>(2, 4))
        let dense = field.cloud(threshold: 1e-3, plan: plan)
        #expect(dense.cells == 1 && dense.top == 3 && abs(dense.reach - 1.5) < 1e-12 && dense.atOpenFace)
        #expect(abs(dense.peak - 2e-3) < 1e-9)  // the solid cell's is not the air's
        let haze = field.cloud(threshold: 1e-7, plan: plan)
        #expect(haze.cells == 2 && haze.top == 3)
        let columns = field.columnMass()
        #expect(abs(columns[3 + 4 * 1] - 2e-3) < 1e-9 && abs(columns[1 + 4 * 1] - 5e-3) < 1e-9)
        var ledger = DustLedger()
        ledger.made = SIMD2(1, 2)
        ledger.airborne = SIMD2(0.5, 1)
        ledger.onGroundOutside = SIMD2(0.25, 0.5)
        ledger.leftDomain = SIMD2(0.25, 0.5)
        #expect(ledger.unplaced == 0)
    }
}
