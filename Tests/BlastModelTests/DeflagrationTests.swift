import Foundation
import Testing
import simd

@testable import BlastModel

/// A premixed gas cloud burning behind a flame front, and vent panels.
@Suite("Deflagration")
struct DeflagrationTests {
    @Test(
        "The heat released takes a closed volume of stoichiometric mixture to its AICC pressure",
        arguments: FlammableGas.allCases, [AirModel.idealGas, .thermallyPerfect])
    func heatReachesAICC(gas: FlammableGas, air: AirModel) {
        let atmosphere = Atmosphere()
        let cloud = Deflagration(gas: gas, region: Box(min: .zero, max: .one), ignition: .zero)
        let pressure = cloud.modelAICCPressure(atmosphere: atmosphere, airModel: air, gamma: 1.4)
        let expected = Float(gas.stoichiometricAICCRatio) * atmosphere.pressure
        #expect(abs(pressure / expected - 1) < 0.005, "\(pressure) Pa")
        // Less of the heat of combustion is needed than all of it, and less again for an ideal gas.
        let share = Deflagration.heatShare(gas: gas, atmosphere: atmosphere, airModel: air, gamma: 1.4)
        #expect(share > 0.5 && share < 1, "\(share)")
    }

    @Test("Burning velocities follow Gülder's fit and vanish outside the flammable range")
    func burningVelocities() {
        let methane = FlammableGas.methane
        #expect(abs(methane.stoichiometricFraction - 0.095) < 0.001)
        #expect(abs(methane.laminarBurningVelocity(fraction: 0.095) - 0.41) < 0.01)
        #expect(methane.laminarBurningVelocity(fraction: 0.045) == 0)
        #expect(methane.laminarBurningVelocity(fraction: 0.16) == 0)
        #expect(abs(FlammableGas.propane.laminarBurningVelocity(fraction: 0.0403) - 0.43) < 0.01)
        let ideal = Deflagration(gas: .methane, region: Box(min: .zero, max: .one), ignition: .zero)
            .modelExpansionRatio(atmosphere: Atmosphere(), airModel: .idealGas, gamma: 1.4)
        // An ideal gas with gamma 1.4: 1 + (8.9 - 1) / 1.4.
        #expect(abs(ideal - 6.64) < 0.05, "\(ideal)")
    }

    @Test("Hydrogen and town gas take their measured burning velocities and stoichiometry")
    func tabulatedBurningVelocities() {
        let hydrogen = FlammableGas.hydrogen
        #expect(abs(hydrogen.stoichiometricFraction - 0.2953) < 0.0005)
        // Taylor's points: 2.13 m/s at stoichiometric, 2.85 m/s at its peak, φ 1.68 (41.4% H₂).
        #expect(abs(hydrogen.laminarBurningVelocity(fraction: 0.2953) - 2.13) < 0.01)
        #expect(abs(hydrogen.laminarBurningVelocity(fraction: 0.414) - 2.85) < 0.02)
        #expect(hydrogen.laminarBurningVelocity(fraction: 0.035) == 0)
        #expect(hydrogen.laminarBurningVelocity(fraction: 0.76) == 0)
        let town = FlammableGas.townGas
        // Lautkaski's stoichiometric 18.6% and peak 1.0 m/s at 25% gas.
        #expect(abs(town.stoichiometricFraction - 0.1856) < 0.0005)
        #expect(abs(town.laminarBurningVelocity(fraction: 0.25) - 1.0) < 0.01)
        #expect(abs(town.laminarBurningVelocity(fraction: 0.20) - 0.64) < 0.01)
        #expect(town.laminarBurningVelocity(fraction: 0.32) == 0)
        // Lean hydrogen turns cellular within centimetres; a stoichiometric mixture has no measurement.
        #expect(abs((hydrogen.criticalRadius(fraction: 0.15) ?? 0) - 0.023) < 0.003)
        #expect(hydrogen.criticalRadius(fraction: 0.2953) == nil)
        #expect(town.criticalRadius(fraction: 0.186) == nil)
        // Lean hydrogen's Markstein number is negative, stoichiometric's positive; others have none.
        #expect((hydrogen.marksteinNumber(fraction: 0.15) ?? 0) < -4)
        #expect(abs((hydrogen.marksteinNumber(fraction: 0.2953) ?? 0) - 2.73) < 0.05)
        #expect(town.marksteinNumber(fraction: 0.186) == nil)
    }

    @Test("Methane's critical radius follows Bauwens et al.'s measurements; propane has none")
    func criticalRadius() {
        let methane = FlammableGas.methane
        // Their Table 1: 0.225 m at φ 1.00, 0.204 m at 0.81 and 0.324 m at 1.22.
        let stoichiometric = methane.criticalRadius(fraction: methane.fraction(equivalenceRatio: 1)) ?? 0
        #expect(abs(stoichiometric - 0.225) < 0.001)
        #expect(methane.criticalRadius(fraction: methane.fraction(equivalenceRatio: 0.7)) == 0.204)
        #expect(methane.criticalRadius(fraction: methane.fraction(equivalenceRatio: 1.3)) == 0.324)
        #expect(FlammableGas.propane.criticalRadius(fraction: 0.04) == nil)
        #expect(FlameInstability.measured.radius(gas: .propane, fraction: 0.04) == nil)
        #expect(FlameInstability.onset(0.5).radius(gas: .propane, fraction: 0.04) == 0.5)
    }

    @Test("The thin-flame model's steepest rise is the deflagration index's formula")
    func thinFlameIndex() {
        let r = 0.5
        let history = DeflagrationReference.closedSphere(
            radius: r, initialPressure: 1e5, maximumPressure: 8e5, gamma: 1.4, burningVelocity: 0.4)
        let index = DeflagrationReference.deflagrationIndex(
            initialPressure: 1e5, maximumPressure: 8e5, gamma: 1.4, burningVelocity: 0.4)
        let volume = 4 / 3 * Double.pi * r * r * r
        #expect(abs(history.peakRate * cbrt(volume) / index - 1) < 0.01)
        #expect(abs(history.pressures.last! - 8e5) < 1)
    }

    @Test("The vent correlations agree with hand working for FM Global's chamber")
    func ventCorrelations() {
        // Bauwens et al.'s test 1: 63.7 m³, a 5.4 m² open vent, methane.
        let c = VentCorrelations(
            volume: 4.6 * 4.6 * 3, surfaceArea: 2 * (4.6 * 4.6 + 2 * 4.6 * 3), ventArea: 5.4,
            releasePressure: 0,
            gas: .methane)
        // NFPA 68 (2002): (0.037 x 97.52 / 5.4)^2 bar.
        #expect(abs((c.nfpa68 ?? 0) / 1e5 - 0.4465) < 0.001)
        // Bartknecht with K_G 55: 5.4 = (0.1265 log 55 - 0.0567) P^-0.5817 V^(2/3).
        #expect(abs((c.bartknecht ?? 0) / 1e5 - 0.285) < 0.002)
        // Molkov: Br 44.0, chi/mu 10.6, Br_t 2.0, so pi_red 0.18.
        #expect(abs(c.molkov / 1e5 - 0.185) < 0.005, "\(c.molkov)")
    }

    @Test("Saves with a deflagration and vent panels round-trip, and older saves still open")
    func coding() throws {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(4, 4, 3), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 2, 1)))
        let plain = try JSONEncoder().encode(scenario)
        #expect(!String(decoding: plain, as: UTF8.self).contains("deflagration"))
        #expect(try JSONDecoder().decode(Scenario.self, from: plain).deflagration == nil)
        scenario.deflagration = Deflagration(
            gas: .propane, concentration: 0.05, region: Box(min: .zero, max: SIMD3(4, 4, 1)),
            ignition: SIMD3(2, 2, 0.5),
            acceleration: FlameAcceleration(
                factor: 2, instability: .onset(1), turbulence: FlameTurbulence(scale: 1)))
        scenario.ventPanels = [
            VentPanel(box: Box(min: SIMD3(3.9, 1, 1), max: SIMD3(4, 2, 2)), releasePressure: 5000)
        ]
        let decoded = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        #expect(decoded.deflagration == scenario.deflagration)
        #expect(decoded.ventPanels == scenario.ventPanels)
    }
}
