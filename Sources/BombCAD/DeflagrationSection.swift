import BlastCore
import SwiftUI
import simd

/// The scene's source: a high-explosive charge or a cloud of flammable gas lit at a point.
struct SourceKindSection: View {
    @Bindable var model: SimulationModel
    /// The cloud last set up, restored when the source goes back to a gas cloud.
    @State private var stashed: Deflagration?

    var body: some View {
        Section("Source") {
            Picker("Kind", selection: isGas) {
                Text("Charge (TNT)").tag(false)
                Text("Gas cloud").tag(true)
            }
            .help(
                "A high-explosive charge, or a premixed cloud of methane or propane in air that burns "
                    + "from an ignition point: a deflagration, not a detonation.")
        }
    }

    private var isGas: Binding<Bool> {
        Binding(
            get: { model.settings.scenario.deflagration != nil },
            set: { gas in
                if gas {
                    model.settings.scenario.deflagration =
                        stashed ?? Self.defaultCloud(for: model.settings.scenario)
                } else {
                    stashed = model.settings.scenario.deflagration
                    model.settings.scenario.deflagration = nil
                }
            })
    }

    /// A stoichiometric methane cloud 3 m high over a 6 m square around the charge, lit there.
    static func defaultCloud(for scenario: Scenario) -> Deflagration {
        let centre = scenario.charge.position
        let low = simd_max(SIMD3(centre.x - 3, centre.y - 3, 0), .zero)
        let high = simd_min(SIMD3(centre.x + 3, centre.y + 3, 3), scenario.domainSize)
        return Deflagration(
            gas: .methane, region: Box(min: low, max: high),
            ignition: SIMD3(centre.x, centre.y, max(centre.z, 0.5)))
    }
}

/// The gas cloud's mixture, extent, ignition point and how fast its flame may burn.
struct GasCloudSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if let cloud = model.settings.scenario.deflagration {
            Section("Gas cloud") {
                Picker("Gas", selection: binding(\.gas)) {
                    ForEach(FlammableGas.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: cloud.gas) {
                    model.settings.scenario.deflagration?.concentration = cloud.gas.stoichiometricFraction
                }
                let range = cloud.gas.flammableRange
                LabeledSlider(
                    title: "Concentration",
                    value: Binding(
                        get: { Double(cloud.concentration * 100) },
                        set: {
                            model.settings.scenario.deflagration?.concentration = Float(
                                ($0 * 10).rounded() / 1000)
                        }),
                    range: Double(range.lowerBound * 100)...Double(range.upperBound * 100),
                    text: String(
                        format: "%.1f%% (φ %.2f)", cloud.concentration * 100, cloud.equivalenceRatio))
                LabeledContent(
                    "Laminar burning velocity",
                    value: String(format: "%.2f m/s", cloud.laminarBurningVelocity))
                Toggle("Hot air", isOn: $model.settings.detailedCharge)
                    .help(
                        "Lets hot gas store energy in molecular vibration, as hot air does. The heat released is "
                            + "set either way so that a closed room of the stoichiometric mixture reaches its "
                            + "AICC pressure (8.9 bar for methane).")

                Text("Filled region").font(.subheadline)
                regionSliders(cloud)
                Text("Ignition point").font(.subheadline)
                pointSliders(\.ignition)
                if model.chargeIsBlocked {
                    warning("The ignition point is inside a block or wall: nothing will burn.")
                } else if !cloud.region.contains(cloud.ignition) {
                    warning("The ignition point is outside the cloud: nothing will burn.")
                }

                Text("Flame").font(.subheadline)
                LabeledSlider(
                    title: "Turbulence factor",
                    value: Binding(
                        get: { Double(cloud.acceleration.factor) },
                        set: {
                            model.settings.scenario.deflagration?.acceleration.factor = Float(
                                ($0 * 4).rounded() / 4)
                        }),
                    range: 1...10, text: String(format: "× %.2f", cloud.acceleration.factor)
                )
                .help(
                    "Multiplies the burning velocity for turbulence and instabilities the grid does not "
                        + "resolve: the venting literature's turbulence factor, often 2 to 5 in rooms.")
                Toggle(
                    "Wrinkling as it grows",
                    isOn: Binding(
                        get: { cloud.acceleration.wrinklingRadius != nil },
                        set: {
                            model.settings.scenario.deflagration?.acceleration.wrinklingRadius = $0 ? 1 : nil
                        })
                )
                .help("The burning velocity rises as the cube root of the flame's radius beyond 1 m.")
                Toggle(
                    "Turbulence from the flow",
                    isOn: Binding(
                        get: { cloud.acceleration.subgridCoefficient != nil },
                        set: {
                            model.settings.scenario.deflagration?.acceleration.subgridCoefficient =
                                $0 ? 0.2 : nil
                        })
                )
                .help(
                    "Adds turbulence estimated from the resolved flow's shear, as behind obstacles and through "
                        + "openings.")
                Text(
                    "Illustrative: the flame's acceleration is modelled, not resolved. See the deflagration "
                        + "page of the documentation for what has been checked."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
    }

    private func binding<T>(_ path: WritableKeyPath<Deflagration, T>) -> Binding<T> {
        Binding(
            get: { model.settings.scenario.deflagration![keyPath: path] },
            set: { model.settings.scenario.deflagration?[keyPath: path] = $0 })
    }

    @ViewBuilder
    private func regionSliders(_ cloud: Deflagration) -> some View {
        let size = model.domainSize
        ForEach(0..<3, id: \.self) { axis in
            let name = ["X", "Y", "Height"][axis]
            LabeledSlider(
                title: "\(name) from",
                value: snapped(\.region.min, axis: axis),
                range: 0...Double(size[axis]), text: String(format: "%.2f m", cloud.region.min[axis]))
            LabeledSlider(
                title: "\(name) to",
                value: snapped(\.region.max, axis: axis),
                range: 0...Double(size[axis]), text: String(format: "%.2f m", cloud.region.max[axis]))
        }
    }

    @ViewBuilder
    private func pointSliders(_ path: WritableKeyPath<Deflagration, SIMD3<Float>>) -> some View {
        let size = model.domainSize
        ForEach(0..<3, id: \.self) { axis in
            LabeledSlider(
                title: ["X", "Y", "Height"][axis], value: snapped(path, axis: axis),
                range: 0...Double(size[axis]),
                text: String(
                    format: "%.2f m", model.settings.scenario.deflagration?[keyPath: path][axis] ?? 0))
        }
    }

    /// One coordinate, snapped to 0.25 m so that it lies on every grid.
    private func snapped(_ path: WritableKeyPath<Deflagration, SIMD3<Float>>, axis: Int) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.scenario.deflagration?[keyPath: path][axis] ?? 0) },
            set: {
                model.settings.scenario.deflagration?[keyPath: path][axis] = Float(($0 * 4).rounded() / 4)
            })
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
    }
}

/// Panels closing openings until the overpressure beside them reaches their release pressure.
struct VentPanelSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Section("Vent panels") {
            let panels = model.settings.scenario.ventPanels ?? []
            ForEach(panels.indices, id: \.self) { index in
                panelRows(index, panels[index])
            }
            Button("Add vent panel") { add() }
                .help(
                    "A panel filling an opening until the overpressure beside it reaches its release "
                        + "pressure, when it goes at once (it has no mass). Place it in a gap in a wall.")
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func panelRows(_ index: Int, _ panel: VentPanel) -> some View {
        DisclosureGroup(
            String(
                format: "Panel %d · %.1f m² · %.1f kPa", index + 1, panel.area, panel.releasePressure / 1000)
        ) {
            LabeledSlider(
                title: "Release pressure",
                value: Binding(
                    get: { Double(panel.releasePressure / 1000) },
                    set: {
                        model.settings.scenario.ventPanels?[index].releasePressure =
                            Float(($0 * 2).rounded() / 2) * 1000
                    }),
                range: 0...50, text: String(format: "%.1f kPa", panel.releasePressure / 1000))
            ForEach(0..<3, id: \.self) { axis in
                LabeledSlider(
                    title: ["X", "Y", "Height"][axis] + " from", value: coordinate(index, \.min, axis),
                    range: 0...Double(model.domainSize[axis]),
                    text: String(format: "%.2f m", panel.box.min[axis]))
                LabeledSlider(
                    title: ["X", "Y", "Height"][axis] + " to", value: coordinate(index, \.max, axis),
                    range: 0...Double(model.domainSize[axis]),
                    text: String(format: "%.2f m", panel.box.max[axis]))
            }
            if panel.releasePressure <= 0 {
                Text("An open vent: nothing fills the opening.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove", role: .destructive) { model.settings.scenario.ventPanels?.remove(at: index) }
        }
    }

    private func coordinate(_ index: Int, _ corner: WritableKeyPath<Box, SIMD3<Float>>, _ axis: Int)
        -> Binding<Double>
    {
        Binding(
            get: { Double(model.settings.scenario.ventPanels?[index].box[keyPath: corner][axis] ?? 0) },
            set: {
                model.settings.scenario.ventPanels?[index].box[keyPath: corner][axis] = Float(
                    ($0 * 4).rounded() / 4)
            })
    }

    /// A 2 m square panel, half a metre thick, on the cloud's (or the charge's) side facing +x.
    private func add() {
        let scenario = model.settings.scenario
        let centre =
            scenario.deflagration.map { 0.5 * ($0.region.min + $0.region.max) } ?? scenario.charge.position
        let x = scenario.deflagration?.region.max.x ?? min(centre.x + 3, scenario.domainSize.x - 1)
        let box = Box(
            min: SIMD3(x, centre.y - 1, max(centre.z - 1, 0)),
            max: SIMD3(x + 0.5, centre.y + 1, max(centre.z - 1, 0) + 2))
        model.settings.scenario.ventPanels =
            (scenario.ventPanels ?? []) + [VentPanel(box: box, releasePressure: 2000)]
    }
}
