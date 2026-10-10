import BlastCore
import SwiftUI

/// The Run tab's Thermal radiation section: the fireball's radiant heat on the ground and the
/// scene's faces, reckoned alongside each run, here or on a Mac set for sweeps, and painted onto
/// them under Display.
struct ThermalSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Section("Thermal radiation") {
            Toggle("Fireball's radiant heat", isOn: enabled)
                .help(
                    "Finds the fireball as the air's luminous gas at each moment, cell by cell, and "
                        + "reckons what it emits and absorbs on the ground and the faces of the scene, with what "
                        + "lies in the way. Illustrative: it radiates three to five times what a TNT fireball "
                        + "was measured to, as the gas never loses the heat, and the air between is taken as "
                        + "transparent.")
            if let spec = model.thermalSpec {
                if spec.fireball == .volume {
                    // On a log scale, a tenth of a decade at a time.
                    LabeledSlider(
                        title: "Gas absorbs",
                        value: Binding(
                            get: { Double(log10(max(spec.absorption, 0.01))) },
                            set: { model.thermalSpec?.absorption = Float(pow(10, ($0 * 10).rounded() / 10)) }),
                        range: -2...0, text: String(format: "%.2g/m", spec.absorption)
                    )
                    .help(
                        "The hot gas's own absorption a metre, an assumption; the emissivity follows from it. "
                            + "With afterburning, the soot of the unburnt products makes the fireball opaque "
                            + "whatever it is.")
                } else {
                    LabeledSlider(
                        title: "Emissivity",
                        value: Binding(
                            get: { Double(spec.emissivity) },
                            set: { model.thermalSpec?.emissivity = Float(($0 * 20).rounded() / 20) }),
                        range: 0.05...1, text: String(format: "%.2f", spec.emissivity)
                    )
                    .help(
                        "1, a black body, is the most the fireball could radiate; real fireballs radiate less."
                    )
                }
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
                        ? "Changes take effect from the next run. Afterburning makes a larger, longer fireball. "
                            + "Display › Surfaces paints its fluence or peak irradiance."
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
