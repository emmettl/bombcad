import Foundation
import Testing

@testable import BlastCore

/// The regime a structure is in, and the defaults it chooses (`StructuralRegime`).
@Suite("Structural regimes")
struct StructuralRegimeTests {
    /// A 1 m cube from (5, 5, 0), and 1 kg of TNT `distance` metres in front of its face.
    private func scene(distance: Float, mass: Float = 1) -> (StructureModel, Scenario) {
        let model = StructureModel(solids: [Box(min: SIMD3(5, 5, 0), max: SIMD3(6, 6, 1))], elementSize: 0.25)
        let scenario = Scenario(
            name: "Test", domainSize: SIMD3(12, 12, 4), boxes: [],
            charge: Charge(mass: mass, position: SIMD3(5 - distance, 5.5, 0.5)))
        return (model, scenario)
    }

    @Test("Scaled distance sets far field, close in and in contact; a charge inside it, confined")
    func detection() {
        for (distance, mass, regime) in [
            (Float(2), Float(1), StructuralRegime.farField), (0.5, 1, .closeIn), (0.1, 1, .inContact),
            (1.2, 8, .closeIn),
        ] {
            let (model, scenario) = scene(distance: distance, mass: mass)
            #expect(StructuralRegime.detect(model, in: scenario) == regime, "\(distance) m, \(mass) kg")
        }
        var (model, scenario) = scene(distance: -0.5)
        #expect(StructuralRegime.detect(model, in: scenario) == .confined)
        (model, scenario) = scene(distance: 2)
        scenario.reflectiveFaces = .all
        #expect(StructuralRegime.detect(model, in: scenario) == .confined)
        scenario.charge.mass = 0
        #expect(StructuralRegime.detect(model, in: scenario) == nil)
    }

    @Test("A confined scene turns pressed interlock on, unless the user chose otherwise")
    func pressedInterlock() {
        let (model, scenario) = scene(distance: -0.5)
        var run = model.detectingRegime(in: scenario)
        #expect(run.regime == .confined && run.appliesPressedInterlock && run.pressedInterlockFromRegime)
        run.regimeOverride = .farField
        #expect(!run.appliesPressedInterlock)
        run.regimeOverride = nil
        run.regimeDefaults = false
        #expect(!run.appliesPressedInterlock)
        run.pressedInterlock = true
        #expect(run.appliesPressedInterlock && !run.pressedInterlockFromRegime)
        // Far from the charge it stays off.
        let (open, openScene) = scene(distance: 2)
        #expect(!open.detectingRegime(in: openScene).appliesPressedInterlock)
    }

    @Test("Beams check their sections' shear when pushed slowly, not under a blast or a blow")
    func beamSectionShear() {
        let (model, scenario) = scene(distance: 2)
        #expect(model.loading == .quasiStatic && model.appliesBeamSectionShear)
        var run = model.detectingRegime(in: scenario)
        #expect(run.loading == .impulsive && !run.appliesBeamSectionShear)
        run.loadingOverride = .quasiStatic
        #expect(run.appliesBeamSectionShear)
        run.loadingOverride = nil
        run.regimeDefaults = false
        #expect(run.appliesBeamSectionShear)
    }

    @Test("The user's regime is saved; the detected one is not")
    func saved() throws {
        let (model, scenario) = scene(distance: -0.5)
        var run = model.detectingRegime(in: scenario)
        run.loadingOverride = .quasiStatic
        let read = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(run))
        #expect(read.regime == nil && read.loadingOverride == .quasiStatic && read.regimeDefaults)
        var chosen = model
        chosen.regimeOverride = .closeIn
        chosen.regimeDefaults = false
        let again = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(chosen))
        #expect(again.regime == .closeIn && !again.regimeDefaults)
    }
}
