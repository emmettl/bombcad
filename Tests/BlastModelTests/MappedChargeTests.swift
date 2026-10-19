import Foundation
import RadialBlast
import Testing
import simd

@testable import BlastModel

/// The blast's first moments solved in one dimension and mapped onto the grid.
@Suite("Mapped charge")
struct MappedChargeTests {
    @Test("The one-dimensional blast keeps its energy and spreads as Sedov and Taylor say")
    func sphericalBlast() {
        // The energy of 10 kg of TNT with almost no mass, so that it is a point blast.
        let energy = 10 * Double(Charge.energyPerKilogram)
        var blast = SphericalBlast(
            mass: 0.001, energy: energy, radius: 0.05, extent: 2, cells: 500, gamma: 1.4,
            ambientDensity: 1.225, ambientPressure: 101_325)
        func total(_ b: SphericalBlast) -> Double {
            (0..<b.density.count).reduce(0) { sum, i in
                let inner = Double(i) * b.cellSize
                let outer = inner + b.cellSize
                return sum + (b.energy[i] - 101_325 / 0.4) * 4 / 3 * Double.pi
                    * (outer * outer * outer - inner * inner * inner)
            }
        }
        let start = total(blast)
        blast.run(toShockRadius: 1.2)
        #expect(abs(total(blast) - start) / start < 0.01, "energy \(total(blast)) J against \(start) J")
        // A strong point blast: R = 1.033 (E t^2 / rho)^(1/5) for gamma = 1.4. At 1.2 m the shock
        // is still strong (some 20 atmospheres). (A real charge's mass slows it at first.)
        let sedov = 1.033 * pow(energy * blast.time * blast.time / 1.225, 0.2)
        #expect(abs(sedov - 1.2) / 1.2 < 0.08, "Sedov-Taylor radius \(sedov) m at \(blast.time) s")
    }

    @Test("With hot air and afterburning the one-dimensional blast gains just what its products burn")
    func hotAirAndAfterburning() {
        // 10 kg of TNT, its products burning in 10 ms x 10^(1/3) as the air solver's do.
        let afterburn = SphericalBlast.Afterburn(
            energy: 10e6, rate: 1 / (10e-3 * cbrt(10.0)), oxygenPerFuel: 5.25 * 32 / 227.13)
        var blast = SphericalBlast(
            mass: 10, energy: 10 * Double(Charge.energyPerKilogram),
            radius: cbrt(3 * 10 / (4 * Double.pi * 1600)),
            extent: 3, cells: 400, gamma: 1.4, ambientDensity: 1.225, ambientPressure: 101_325,
            thermallyPerfect: true, afterburn: afterburn)
        func integral(_ values: (Int) -> Double) -> Double {
            (0..<blast.density.count).reduce(0) { sum, i in
                let inner = Double(i) * blast.cellSize
                let outer = inner + blast.cellSize
                return sum + values(i) * 4 / 3 * Double.pi * (outer * outer * outer - inner * inner * inner)
            }
        }
        let energy0 = integral { blast.energy[$0] }
        let fuel0 = integral { blast.fuel[$0] }
        blast.run(toShockRadius: 2)
        let burnt = fuel0 - integral { blast.fuel[$0] }
        #expect(burnt > 0.001 * fuel0, "burnt \(burnt) kg of \(fuel0)")
        // Energy flows out of the last cell only once the shock gets there, which it has not.
        #expect(abs((integral { blast.energy[$0] } - energy0) / (burnt * 10e6) - 1) < 0.01)
        #expect(blast.fuel.allSatisfy { $0 >= 0 } && blast.oxygen.allSatisfy { $0 >= 0 })
        // Hot air: the ratio of specific heats falls in the fireball, from 1.4 in the cold air.
        let hot = SphericalBlast.Gas(gamma: 1.4, thermallyPerfect: true)
        #expect(abs(hot.ratio(density: 1.225, pressure: 101_325) - 1.4) < 0.001)
        #expect(hot.ratio(density: 1, pressure: 1e6) < 1.33)
        let p = hot.pressure(density: 2, internalEnergy: hot.internalEnergy(density: 2, pressure: 5e6))
        #expect(abs(p / 5e6 - 1) < 1e-9)
    }

    @Test("Solved once and kept: the same start gives the same solution, and a time limit stops it short")
    func keptAndLimited() {
        let blast = SphericalBlast(
            mass: 1, energy: Double(Charge.energyPerKilogram), radius: cbrt(3 / (4 * Double.pi * 1600)),
            extent: 3, cells: 300, gamma: 1.4, ambientDensity: 1.225, ambientPressure: 101_325)
        let first = blast.solved(toShockRadius: 2)
        let again = blast.solved(toShockRadius: 2)
        #expect(first.steps > 0 && again.digest == first.digest && again.steps == first.steps)
        let short = blast.solved(toShockRadius: 2, until: first.time / 2)
        #expect(short.time >= first.time / 2 && short.time < first.time && short.shockRadius < 2)
    }

    @Test(
        "The products' own equation of state: JWL alone, air alone, a sound speed that matches the isentrope")
    func productsGasLaw() {
        for thermallyPerfect in [false, true] {
            let gas = SphericalBlast.Gas(gamma: 1.4, thermallyPerfect: thermallyPerfect, products: .tnt)
            let air = SphericalBlast.Gas(gamma: 1.4, thermallyPerfect: thermallyPerfect)
            // TNT's products at its own density and energy: the constant-volume explosion, some 8 GPa
            // (A (1 − ω/R1) e^−R1 + B (1 − ω/R2) e^−R2 + ω ρ0 e0).
            let explosion = gas.pressure(density: 1630, internalEnergy: 1630 * 4.184e6, products: 1)
            #expect(explosion > 7.5e9 && explosion < 9e9, "\(explosion) Pa")
            // Without products, the air's own law, exactly.
            #expect(
                gas.pressure(density: 1.2, internalEnergy: 3e5, products: 0)
                    == air.pressure(density: 1.2, internalEnergy: 3e5))
            for (rho, p, y) in [(1630.0, 8e9, 1.0), (50, 5e7, 0.6), (2, 4e5, 0.1), (1.5, 2e5, 1)] {
                let e = gas.internalEnergy(density: rho, pressure: p, products: y)
                let back = gas.pressure(density: rho, internalEnergy: e, products: y)
                #expect(abs(back / p - 1) < 1e-9, "\(rho) kg/m³, \(p) Pa, \(y): \(back)")
                // Along the isentrope de = p/ρ² dρ the pressure rises as c² dρ.
                let step = rho * 1e-6
                let up = gas.pressure(
                    density: rho + step, internalEnergy: (rho + step) * (e / rho + p / (rho * rho) * step),
                    products: y)
                let down = gas.pressure(
                    density: rho - step, internalEnergy: (rho - step) * (e / rho - p / (rho * rho) * step),
                    products: y)
                let c2 = gas.ratio(density: rho, pressure: p, products: y) * p / rho
                #expect(abs((up - down) / (2 * step) / c2 - 1) < 1e-4, "\(rho) kg/m³, \(y)")
            }
        }
    }
}
