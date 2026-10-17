import BlastCore
import SwiftUI

/// The Run tab's Fragments section: a cased charge's fragments and tracers flown alongside each
/// run, one way, here or on the Mac set for sweeps, and drawn over the blast.
struct FragmentSection: View {
    @Bindable var model: SimulationModel
    @AppStorage(AppPreferences.Key.sweepHosts) private var sweepHosts = ""

    private static let counts = [200, 500, 1000, 2000, 5000, 10_000, 20_000]

    private static let tracerCounts = [0, 100, 300, 1000, 3000]

    var body: some View {
        Section("Fragments") {
            Toggle("Cased charge", isOn: enabled)
                .help(
                    "Flies the casing's fragments, and tracers that follow the air, through the blast from "
                        + "the start of each run: Gurney launch speeds, Mott masses, and drag from the blast; they "
                        + "do not push back on the air or the structure. Illustrative, or an approximation given "
                        + "the casing's dimensions.")
            if model.fragmentSpec != nil {
                StandingRow(model: model, kinds: [.fragments])
                LabeledSlider(
                    title: "Casing",
                    value: Binding(
                        get: { log10(Double(model.fragmentSpec?.casingMass ?? 10)) },
                        set: { model.fragmentSpec?.casingMass = Float(pow(10, $0).rounded()) }),
                    range: 0...2.7,
                    text: "\(Int(model.fragmentSpec?.casingMass ?? 0)) kg, \(launchSpeed) m/s")
                Picker("Fragments", selection: spec(\.count)) {
                    ForEach(pickerChoices(Self.counts, holding: spec(\.count).wrappedValue), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                Picker("Casing shape", selection: spec(\.casing)) {
                    Text("Cylinder").tag(FragmentSpec.Casing.cylinder)
                    Text("Sphere").tag(FragmentSpec.Casing.sphere)
                }
                Picker("Casing metal", selection: metal) {
                    ForEach(CasingMetal.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    if model.fragmentSpec?.metal == nil {
                        Text("As its description says").tag(CasingMetal?.none)
                    }
                }
                .help(
                    "Steel breaks as Mott's distribution says; cast iron, brittle, as Grady's exponential, which "
                        + "fits a counted cast-iron bomb within a factor of 1.12 where Mott's is within 1.36."
                )
                Toggle("Casing dimensions", isOn: dimensioned)
                    .help(
                        "The casing's wall thickness and inside diameter. With them the fragments' number and "
                            + "sizes follow Mott's scaling, and their standing is an approximation; without, the "
                            + "number is chosen and they are illustrative. Turned on, it starts from a casing "
                            + "that holds the charge and weighs the casing's mass.")
                if let thickness = model.fragmentSpec?.wallThickness,
                    let diameter = model.fragmentSpec?.innerDiameter
                {
                    LabeledSlider(
                        title: "Wall thickness",
                        value: Binding(
                            get: { log10(Double(thickness)) },
                            set: { model.fragmentSpec?.wallThickness = Self.rounded(Float(pow(10, $0))) }),
                        range: log10(0.0005)...log10(0.1), text: String(format: "%.1f mm", thickness * 1000))
                    LabeledSlider(
                        title: "Inside diameter",
                        value: Binding(
                            get: { log10(Double(diameter)) },
                            set: { model.fragmentSpec?.innerDiameter = Self.rounded(Float(pow(10, $0))) }),
                        range: log10(0.02)...log10(3), text: String(format: "%.0f mm", diameter * 1000))
                    Text(mottCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Tracers", selection: spec(\.tracers)) {
                    ForEach(
                        pickerChoices(Self.tracerCounts, holding: spec(\.tracers).wrappedValue), id: \.self
                    ) { Text($0 == 0 ? "None" : "\($0)").tag($0) }
                }
                PlacementPicker(
                    title: "Fly on", host: $model.fragmentsHost,
                    help:
                        "Flies the fragments here or on a Mac set for sweeps in Settings, a frame behind the run."
                )
                FragmentStatus(model: model)
            }
        }
        // One connection to each Mac the companions run on, shared by those on the same one.
        // Choosing Automatic probes the Macs again, though they are the same.
        .task(id: wantedHosts.sorted() + [model.thermalHost == ConsumerPlacement.automatic ? "probe" : ""]) {
            await model.connectWorkers(wantedHosts)
        }
    }

    /// The Macs the companions are set to run on, of those still set for sweeps.
    private var wantedHosts: Set<String> { model.wantedHosts.intersection(AppPreferences.hosts(sweepHosts)) }

    private var launchSpeed: Int {
        Int(model.fragmentSpec?.launchSpeed(chargeMass: model.settings.chargeMass) ?? 0)
    }

    private var metal: Binding<CasingMetal?> {
        Binding(get: { model.fragmentSpec?.metal }, set: { model.fragmentSpec?.metal = $0 })
    }

    private var dimensioned: Binding<Bool> {
        Binding(
            get: { model.fragmentSpec?.wallThickness != nil },
            set: { on in
                guard var spec = model.fragmentSpec else { return }
                if on, let size = spec.casingDimensions(chargeMass: model.settings.chargeMass) {
                    spec.wallThickness = Self.rounded(size.thickness)
                    spec.innerDiameter = Self.rounded(size.diameter)
                } else {
                    spec.wallThickness = nil
                    spec.innerDiameter = nil
                }
                model.fragmentSpec = spec
            })
    }

    /// Three significant figures, in metres.
    private static func rounded(_ metres: Float) -> Float {
        let step = pow(10, floor(log10(metres)) - 2)
        return (metres / step).rounded() * step
    }

    /// What Mott's scaling makes of the casing: how many fragments, their mean mass, and what each
    /// one flown stands for.
    private var mottCaption: String {
        guard let spec = model.fragmentSpec, let mean = spec.mottMeanMass else { return "" }
        let real = spec.realFragmentCount
        let each = spec.count > 0 ? real / Double(spec.count) : 0
        return String(
            format:
                "Mott's scaling: about %@ fragments of %@ on average; each of the %@ flown stands for %@.",
            Int(real.rounded()).formatted(),
            mean >= 1 ? String(format: "%.2f kg", mean) : String(format: "%.1f g", mean * 1000),
            spec.count.formatted(), each >= 10 ? String(format: "%.0f", each) : String(format: "%.2f", each))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.fragmentSpec != nil },
            set: { model.fragmentSpec = $0 ? Self.defaultSpec(for: model.settings.scenario) : nil })
    }

    private func spec<Value>(_ path: WritableKeyPath<FragmentSpec, Value>) -> Binding<Value> {
        Binding(
            get: { (model.fragmentSpec ?? Self.defaultSpec(for: model.settings.scenario))[keyPath: path] },
            set: { model.fragmentSpec?[keyPath: path] = $0 })
    }

    /// A tenth of the charge's mass as casing, in 2,000 fragments, and 300 tracers across 16 m
    /// round the charge.
    static func defaultSpec(for scenario: Scenario) -> FragmentSpec {
        var spec = FragmentSpec()
        spec.casingMass = max(1, (scenario.charge.mass / 10).rounded())
        spec.count = 2000
        spec.tracers = 300
        let centre = scenario.charge.position
        let low = SIMD3<Float>(max(centre.x - 8, 0), max(centre.y - 8, 0), 0.5)
        let high = SIMD3<Float>(
            min(centre.x + 8, scenario.domainSize.x), min(centre.y + 8, scenario.domainSize.y),
            min(6, scenario.domainSize.z))
        spec.tracerRegion = Box(min: low, max: high)
        return spec
    }
}

/// What the fragments are doing, on its own so that, as it changes during a run, the section's
/// controls are not drawn again.
private struct FragmentStatus: View {
    let model: SimulationModel

    var body: some View {
        Text(model.fragmentStatus.isEmpty ? "Changes take effect from the next run." : model.fragmentStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Display section's fragment settings, when the project flies fragments.
struct FragmentDisplaySettings: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if model.fragmentSpec != nil {
            Toggle("Fragments and landings", isOn: $model.renderSettings.showFragments)
            Toggle("Tracers", isOn: $model.renderSettings.showTracers)
            Toggle("Hazardous fragment distance", isOn: $model.renderSettings.showHazard)
                .help(
                    "Where hazardous fragments (79 J or more) fall below one per 55.7 m² of ground, once a run's fragments have landed"
                )
            LabeledSlider(
                title: "Dot size",
                value: Binding(
                    get: { Double(model.renderSettings.dotSize) },
                    set: { model.renderSettings.dotSize = Float($0.rounded()) }),
                range: 2...12, text: "\(Int(model.renderSettings.dotSize)) pt")
        }
    }
}

/// A picker's choices, with the value held among them if it is not one: a project can hold any
/// number, and a picker whose value matches no choice shows nothing.
func pickerChoices(_ choices: [Int], holding value: Int) -> [Int] {
    choices.contains(value) ? choices : (choices + [value]).sorted()
}
