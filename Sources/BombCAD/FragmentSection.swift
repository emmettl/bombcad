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
                        + "the start of each run. Illustrative: Gurney launch speeds, Mott masses, and drag "
                        + "from the blast; they do not push back on the air or the structure.")
            if model.fragmentSpec != nil {
                LabeledSlider(
                    title: "Casing",
                    value: Binding(
                        get: { log10(Double(model.fragmentSpec?.casingMass ?? 10)) },
                        set: { model.fragmentSpec?.casingMass = Float(pow(10, $0).rounded()) }),
                    range: 0...2.7,
                    text: "\(Int(model.fragmentSpec?.casingMass ?? 0)) kg, \(launchSpeed) m/s")
                Picker("Fragments", selection: spec(\.count)) {
                    ForEach(Self.counts, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Casing shape", selection: spec(\.casing)) {
                    Text("Cylinder").tag(FragmentSpec.Casing.cylinder)
                    Text("Sphere").tag(FragmentSpec.Casing.sphere)
                }
                Picker("Tracers", selection: spec(\.tracers)) {
                    ForEach(Self.tracerCounts, id: \.self) { Text($0 == 0 ? "None" : "\($0)").tag($0) }
                }
                if !host.isEmpty {
                    Toggle("Fly on \(host)", isOn: $model.fragmentsOnRemote)
                        .help(
                            "Flies the fragments on the first Mac set for sweeps in Settings, a frame behind the run."
                        )
                }
                Text(
                    model.fragmentStatus.isEmpty
                        ? "Changes take effect from the next run." : model.fragmentStatus
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.fragmentsOnRemote ? host : "") {
            await model.connectFragmentWorker(model.fragmentsOnRemote && !host.isEmpty ? host : nil)
        }
    }

    /// The first of the Macs set for sweeps.
    private var host: String { AppPreferences.hosts(sweepHosts).first ?? "" }

    private var launchSpeed: Int {
        Int(model.fragmentSpec?.launchSpeed(chargeMass: model.settings.chargeMass) ?? 0)
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

/// The Display section's fragment settings, when the project flies fragments.
struct FragmentDisplaySettings: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if model.fragmentSpec != nil {
            Toggle("Fragments and landings", isOn: $model.renderSettings.showFragments)
            Toggle("Tracers", isOn: $model.renderSettings.showTracers)
            LabeledSlider(
                title: "Dot size",
                value: Binding(
                    get: { Double(model.renderSettings.dotSize) },
                    set: { model.renderSettings.dotSize = Float($0.rounded()) }),
                range: 2...12, text: "\(Int(model.renderSettings.dotSize)) pt")
        }
    }
}
