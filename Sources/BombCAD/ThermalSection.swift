import BlastCore
import SwiftUI

/// The Run tab's Thermal radiation section: the fireball's radiant heat on the ground and the
/// scene's faces, reckoned alongside each run, here or on a Mac set for sweeps, and painted onto
/// them under Display.
///
/// Its body is built from small typed pieces, and its texts are constants: one body holding them
/// all sat at the type checker's limit, and an operator added anywhere in the package pushed it over.
struct ThermalSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Section("Thermal radiation") {
            Toggle("Fireball's radiant heat", isOn: enabled).help(Self.enabledHelp)
            if let spec = model.thermalSpec {
                StandingRow(model: model, kinds: [.thermal])
                gas(spec)
                luminous(spec)
                ground(spec)
                heatingRows(spec)
                PlacementPicker(title: "Run on", host: $model.thermalHost, help: Self.placementHelp)
                status
            }
        }
    }

    // MARK: - Texts

    private static let enabledHelp: String =
        "Finds the fireball as the air's luminous gas at each moment, cell by cell, and reckons what it "
        + "emits and absorbs on the ground and the faces of the scene, with what lies in the way. "
        + "Illustrative: it radiates three to five times what a TNT fireball was measured to, as the gas "
        + "never loses the heat, and the air between is taken as transparent."
    private static let absorptionHelp: String =
        "The hot gas's own absorption a metre, an assumption; the emissivity follows from it. With "
        + "afterburning, the soot of the unburnt products makes the fireball opaque whatever it is."
    private static let emissivityHelp: String =
        "1, a black body, is the most the fireball could radiate; real fireballs radiate less."
    private static let luminousHelp: String = "Gas at least this hot is part of the fireball."
    private static let groundHelp: String =
        "How far apart the receivers on the ground stand. Over a floor larger than a square kilometre "
        + "they stand further apart, so that there are at most 250,000."
    private static let heatingHelp: String =
        "Conducts what each surface absorbs into its material, one dimension deep, losing heat by "
        + "convection and its own radiation, for its peak temperature; and marks timber, canvas and dry "
        + "grass past test thresholds for ignition. Illustrative: nothing melts, chars or burns, and no "
        + "fire is modelled."
    private static let placementHelp: String =
        "Reckons the radiation here or on a Mac set for sweeps in Settings, frame by frame."
    private static let materialHelp: String =
        "What these surfaces are made of, for their heating; the structure's follow its own materials."
    private static let idleStatus: String =
        "Changes take effect from the next run. Afterburning makes a larger, longer fireball. Display › "
        + "Surfaces paints its fluence, peak irradiance, the surfaces' peak temperature or illustrative "
        + "ignition."

    // MARK: - Rows

    /// The gas's absorption on a log scale, a tenth of a decade at a time, for the volume model;
    /// else the shape's emissivity in twentieths.
    @ViewBuilder private func gas(_ spec: ThermalSpec) -> some View {
        if spec.fireball == .volume {
            let absorption: Binding<Double> = Binding(
                get: { Double(log10(max(spec.absorption, 0.01))) },
                set: { (value: Double) in
                    let decades: Double = (value * 10).rounded() / 10
                    model.thermalSpec?.absorption = Float(pow(10, decades))
                })
            LabeledSlider(
                title: "Gas absorbs", value: absorption, range: -2...0,
                text: String(format: "%.2g/m", spec.absorption)
            )
            .help(Self.absorptionHelp)
        } else {
            let emissivity: Binding<Double> = Binding(
                get: { Double(spec.emissivity) },
                set: { (value: Double) in model.thermalSpec?.emissivity = Float((value * 20).rounded() / 20) }
            )
            LabeledSlider(
                title: "Emissivity", value: emissivity, range: 0.05...1,
                text: String(format: "%.2f", spec.emissivity)
            )
            .help(Self.emissivityHelp)
        }
    }

    /// The temperature above which gas is fireball, in steps of 50 K.
    private func luminous(_ spec: ThermalSpec) -> some View {
        let temperature: Binding<Double> = Binding(
            get: { Double(spec.luminousTemperature) },
            set: { (value: Double) in
                model.thermalSpec?.luminousTemperature = Float((value / 50).rounded() * 50)
            })
        let text: String = "\(Int(spec.luminousTemperature)) K"
        return LabeledSlider(title: "Luminous above", value: temperature, range: 800...3000, text: text)
            .help(Self.luminousHelp)
    }

    /// The ground's receivers' spacing on a log scale, in halves of a doubling, 0.25 m to 64 m.
    private func ground(_ spec: ThermalSpec) -> some View {
        let spacing: Binding<Double> = Binding(
            get: { Double(log2(spec.groundSpacing)) },
            set: { (value: Double) in
                let doublings: Double = (value * 2).rounded() / 2
                model.thermalSpec?.groundSpacing = Float(pow(2, doublings))
            })
        return LabeledSlider(
            title: "Ground every", value: spacing, range: -2...6, text: groundSpacingText(spec)
        )
        .help(Self.groundHelp)
    }

    @ViewBuilder private func heatingRows(_ spec: ThermalSpec) -> some View {
        Toggle("Heat the surfaces", isOn: heating(\.enabled)).help(Self.heatingHelp)
        if spec.heating.enabled {
            StandingRow(model: model, kinds: [.surfaceHeating])
            materialPicker("Ground is", \.ground, ["asphalt", "concrete", "soil", "dry grass"])
            materialPicker("Blocks are", \.blocks, ["concrete", "masonry", "steel", "glass", "timber"])
        }
    }

    private var status: some View {
        let text: String = model.thermalStatus.isEmpty ? Self.idleStatus : model.thermalStatus
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private func heating<Value>(_ path: WritableKeyPath<SurfaceHeatingSpec, Value>) -> Binding<Value> {
        Binding(
            get: { (model.thermalSpec ?? ThermalSpec()).heating[keyPath: path] },
            set: { model.thermalSpec?.heating[keyPath: path] = $0 })
    }

    /// The spacing asked for, and what is used over this domain where it is wider.
    private func groundSpacingText(_ spec: ThermalSpec) -> String {
        let asked = spec.groundSpacing
        let used = spec.groundSpacing(over: model.domainSize)
        return used > asked * 1.001
            ? String(format: "%g m (%.0f m here)", Double(asked), Double(used))
            : String(format: "%g m", Double(asked))
    }

    /// A picker of the library's materials for one kind of surface; the structure takes its own.
    private func materialPicker(
        _ title: String, _ path: WritableKeyPath<SurfaceHeatingSpec, String>, _ names: [String]
    ) -> some View {
        let current: String = (model.thermalSpec ?? ThermalSpec()).heating[keyPath: path]
        let shown: [String] = names.contains(current) ? names : names + [current]
        return Picker(title, selection: heating(path)) {
            ForEach(shown, id: \.self) { (name: String) in
                Text(name.prefix(1).uppercased() + name.dropFirst()).tag(name)
            }
        }
        .help(Self.materialHelp)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.thermalSpec != nil },
            set: { model.thermalSpec = $0 ? ThermalSpec() : nil })
    }
}
