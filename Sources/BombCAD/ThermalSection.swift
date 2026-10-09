import BlastCore
import SwiftUI

/// The Run tab's Thermal radiation section: the fireball's radiant heat on the ground and the
/// scene's faces, reckoned alongside each run, here or on a Mac set for sweeps, and drawn over
/// the blast.
struct ThermalSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Section("Thermal radiation") {
            Toggle("Fireball's radiant heat", isOn: enabled)
                .help(
                    "Finds the fireball as the air's luminous gas at each moment, reduced to a sphere, and "
                        + "reckons its grey-body radiation on the ground and the faces of the scene, with what "
                        + "lies in the way. Illustrative: no comparison with measurements, and the air between "
                        + "is taken as transparent.")
            if let spec = model.thermalSpec {
                LabeledSlider(
                    title: "Emissivity",
                    value: Binding(
                        get: { Double(spec.emissivity) },
                        set: { model.thermalSpec?.emissivity = Float(($0 * 20).rounded() / 20) }),
                    range: 0.05...1, text: String(format: "%.2f", spec.emissivity)
                )
                .help("1, a black body, is the most the fireball could radiate; real fireballs radiate less.")
                LabeledSlider(
                    title: "Luminous above",
                    value: Binding(
                        get: { Double(spec.luminousTemperature) },
                        set: { model.thermalSpec?.luminousTemperature = Float(($0 / 50).rounded() * 50) }),
                    range: 800...3000, text: "\(Int(spec.luminousTemperature)) K"
                )
                .help("Gas at least this hot is part of the fireball.")
                PlacementPicker(
                    title: "Run on", host: $model.thermalHost,
                    help: "Reckons the radiation here or on a Mac set for sweeps in Settings, frame by frame."
                )
                Text(
                    model.thermalStatus.isEmpty
                        ? "Changes take effect from the next run. Afterburning makes a larger, longer fireball."
                        : model.thermalStatus
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.thermalSpec != nil },
            set: { model.thermalSpec = $0 ? ThermalSpec() : nil })
    }
}

/// The Display section's thermal setting, when the project reckons the radiation.
struct ThermalDisplaySettings: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if model.thermalSpec != nil {
            Toggle("Thermal fluence", isOn: $model.renderSettings.showThermal)
                .help(
                    "Receivers coloured by their fluence so far: grey with none, to pale yellow at 1 MJ/m².")
        }
    }
}
