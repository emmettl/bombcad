import BlastCore
import SwiftUI
import Testing

@testable import BombCAD

/// Bindings into scene state a menu choice can take away while their controls are still read: a
/// gas cloud's pickers when the source goes back to a charge crashed the app on 16 October 2026.
@Suite("Stale-safe bindings")
@MainActor
struct StaleSafeBindingTests {
    @Test("The gas cloud's picker reads the cloud it was drawn with once the source is a charge again")
    func gasCloudPicker() {
        let model = SimulationModel()
        let cloud = SourceKindSection.defaultCloud(for: model.settings.scenario)
        model.settings.scenario.deflagration = cloud
        let gas = GasCloudSection(model: model).binding(\.gas, in: cloud)
        gas.wrappedValue = .propane
        #expect(model.settings.scenario.deflagration?.gas == .propane)
        // The source switched back to a charge: SwiftUI reads the picker once more.
        model.settings.scenario.deflagration = nil
        #expect(gas.wrappedValue == cloud.gas)
        gas.wrappedValue = .methane
        #expect(model.settings.scenario.deflagration == nil)
    }

    @Test("A removed array element reads its fallback and takes no writes")
    func removedElement() {
        var panels: [VentPanel]? = [
            VentPanel(box: Box(min: .zero, max: SIMD3(1, 1, 1)), releasePressure: 2000)
        ]
        let root = Binding(get: { panels }, set: { panels = $0 })
        let pressure = Binding<Float>.element(root, at: 0, \.releasePressure, fallback: 2000)
        pressure.wrappedValue = 3000
        #expect(panels?[0].releasePressure == 3000)
        panels?.removeAll()
        #expect(pressure.wrappedValue == 2000)
        pressure.wrappedValue = 4000
        #expect(panels?.isEmpty == true)
        panels = nil
        #expect(pressure.wrappedValue == 2000)
    }
}
