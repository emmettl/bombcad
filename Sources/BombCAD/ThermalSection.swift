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
                StandingRow(model: model, kinds: [.thermal])
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
                // On a log scale, in halves of a doubling, from 0.25 m to 64 m.
                LabeledSlider(
                    title: "Ground every",
                    value: Binding(
                        get: { Double(log2(spec.groundSpacing)) },
                        set: { model.thermalSpec?.groundSpacing = Float(pow(2, ($0 * 2).rounded() / 2)) }),
                    range: -2...6, text: groundSpacingText(spec)
                )
                .help(
                    "How far apart the receivers on the ground stand. Over a floor larger than a square "
                        + "kilometre they stand further apart, so that there are at most 250,000.")
                Toggle("Heat the surfaces", isOn: heating(\.enabled))
                    .help(
                        "Conducts what each surface absorbs into its material, one dimension deep, losing heat by "
                            + "convection and its own radiation, for its peak temperature; and marks timber, "
                            + "canvas and dry grass past test thresholds for ignition. Illustrative: nothing melts, "
                            + "chars or burns, and no fire is modelled.")
                if spec.heating.enabled {
                    StandingRow(model: model, kinds: [.surfaceHeating])
                    materialPicker("Ground is", \.ground, ["asphalt", "concrete", "soil", "dry grass"])
                    materialPicker(
                        "Blocks are", \.blocks, ["concrete", "masonry", "steel", "glass", "timber"])
                }
                PlacementPicker(
                    title: "Run on", host: $model.thermalHost,
                    help: "Reckons the radiation here or on a Mac set for sweeps in Settings, frame by frame."
                )
                Text(
                    model.thermalStatus.isEmpty
                        ? "Changes take effect from the next run. Afterburning makes a larger, longer fireball. "
                            + "Display › Surfaces paints its fluence, peak irradiance, the surfaces' peak "
                            + "temperature or illustrative ignition."
                        : model.thermalStatus
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heating<Value>(_ path: WritableKeyPath<SurfaceHeatingSpec, Value>) -> Binding<Value> {
        Binding(
            get: { (model.thermalSpec ?? ThermalSpec()).heating[keyPath: path] },
            set: { model.thermalSpec?.heating[keyPath: path] = $0 })
    }

    /// A picker of the library's materials for one kind of surface; the structure takes its own.
    private func groundSpacingText(_ spec: ThermalSpec) -> String {
        let asked = spec.groundSpacing
        let used = spec.groundSpacing(over: model.domainSize)
        return used > asked * 1.001
            ? String(format: "%g m (%.0f m here)", Double(asked), Double(used))
            : String(format: "%g m", Double(asked))
    }

    private func materialPicker(
        _ title: String, _ path: WritableKeyPath<SurfaceHeatingSpec, String>, _ names: [String]
    ) -> some View {
        let current = (model.thermalSpec ?? ThermalSpec()).heating[keyPath: path]
        return Picker(title, selection: heating(path)) {
            ForEach(names.contains(current) ? names : names + [current], id: \.self) { name in
                Text(name.prefix(1).uppercased() + name.dropFirst()).tag(name)
            }
        }
        .help("What these surfaces are made of, for their heating; the structure's follow its own materials.")
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.thermalSpec != nil },
            set: { model.thermalSpec = $0 ? ThermalSpec() : nil })
    }
}
