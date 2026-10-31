import BlastCore
import SwiftUI

/// Fire after the blast (emmettl/bombcad-work#38, stage 3; docs/fire-spread.md): the fire spread over
/// the envelope buildings for hours, from the quick estimate's broken glass and walls or a run's
/// damage, with the seeds and the wind chosen here. Each building is coloured by its chance of
/// catching from a neighbour by the hour on the slider, over the draws in which it was not a starting
/// fire, or by its chance of catching at all (the earlier map). Illustrative, and said so first.
struct FireSection: View {
    @Bindable var model: SimulationModel
    @State private var showsAssumptions: Bool

    init(model: SimulationModel, showsAssumptions: Bool = false) {
        self.model = model
        _showsAssumptions = State(initialValue: showsAssumptions)
    }

    static let nearRadii: [Double] = [25, 50, 100, 150, 250, 500]
    static let randomCounts = [0, 5, 10, 20, 50, 100]
    static let bandFrom: [Double] = [0, 250, 500, 1000, 1500, 2000]
    static let bandTo: [Double] = [250, 500, 1000, 1500, 2000, 2500, 5000]

    var body: some View {
        if model.fireSource != nil {
            Section("Fire after the blast") {
                // Before anything else: what this is.
                Label(FireSpread.note, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Standing") { StandingLabel(level: .illustrative) }
                    .accessibilityElement(children: .combine)
                Text(
                    model.envelopeDamageIsEstimate
                        ? "Through the quick estimate's broken glass and failed walls."
                        : "Through the run's broken glass and walls heavily damaged."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                seeds
                wind
                Picker("Over", selection: $model.fireSettings.hours) {
                    ForEach(SimulationModel.fireHorizons, id: \.self) {
                        Text(String(format: "%.0f h", $0)).tag($0)
                    }
                }
                .help("How long after the blast the fire is followed. No firefighting is modelled.")
                DisclosureGroup("Assumptions", isExpanded: $showsAssumptions) {
                    Picker("Construction", selection: $model.fireSettings.cladding) {
                        Text("As each building's").tag(FireSpread.Cladding?.none)
                        Text("Every building timber-clad").tag(FireSpread.Cladding?.some(.combustible))
                    }
                    .help(
                        "Timber-clad buildings burn from outside; concrete, masonry and steel only through their windows. "
                            + "Every building timber-clad is a contrast, as Halifax's wooden North End was.")
                    Picker("Untagged buildings", selection: $model.fireSettings.untaggedUse) {
                        ForEach(BuildingUse.allCases) { Text($0.label).tag($0) }
                    }
                    .help(
                        "The use, and so the fire load, of buildings whose map tags say none (EN 1991-1-2 Annex E)."
                    )
                }
                progress
                if let layer = model.fireLayer {
                    results(layer)
                }
                ForEach(FireSpread.standing, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            .monospacedDigit()
        }
    }

    // MARK: - Where fires start

    @ViewBuilder private var seeds: some View {
        Text("Where fires start").font(.subheadline.weight(.medium))
        Toggle("Pick buildings in the view", isOn: $model.firePicksSeeds)
            .help(
                "Click a building in the view to start a fire there, and again to take it away. A selected "
                    + "building's panel has the same switch.")
        let picked = model.fireSettings.picked.count
        if picked > 0 {
            HStack {
                Text(picked == 1 ? "1 building picked" : "\(picked) buildings picked").font(.caption)
                Spacer()
                Button("Clear") { model.fireSettings.picked = [] }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear the buildings picked to start fires")
            }
        } else if model.firePicksSeeds {
            Text("Click a building in the view.").font(.caption).foregroundStyle(.secondary)
        }
        Toggle(
            "Near the charge",
            isOn: Binding(
                get: { model.fireSettings.nearChargeM != nil },
                set: { model.fireSettings.nearChargeM = $0 ? 50 : nil })
        )
        .help("Every building within a distance of the charge alight at the blast.")
        if let radius = model.fireSettings.nearChargeM {
            Picker(
                "Within",
                selection: Binding(get: { radius }, set: { model.fireSettings.nearChargeM = $0 })
            ) {
                ForEach(pickerChoices(Self.nearRadii, holding: radius), id: \.self) {
                    Text(String(format: "%.0f m", $0)).tag($0)
                }
            }
            .accessibilityLabel("Buildings alight within this distance of the charge")
        }
        Picker("At random", selection: $model.fireSettings.randomCount) {
            ForEach(pickerChoices(Self.randomCounts, holding: model.fireSettings.randomCount), id: \.self) {
                Text($0 == 0 ? "None" : "\($0) a draw").tag($0)
            }
        }
        .help(
            "So many buildings set alight at the blast, chosen afresh in each draw, as the Wellington model was run "
                + "from its history's ignitions.")
        if model.fireSettings.randomCount > 0 {
            Picker("From", selection: $model.fireSettings.randomFromM) {
                ForEach(pickerChoices(Self.bandFrom, holding: model.fireSettings.randomFromM), id: \.self) {
                    Text(String(format: "%.0f m", $0)).tag($0)
                }
            }
            .accessibilityLabel("Random fires from this distance of the charge")
            Picker("To", selection: $model.fireSettings.randomToM) {
                ForEach(pickerChoices(Self.bandTo, holding: model.fireSettings.randomToM), id: \.self) {
                    Text(String(format: "%.0f m", $0)).tag($0)
                }
            }
            .accessibilityLabel("Random fires to this distance of the charge")
            if let layer = model.fireLayer, layer.randomCandidates < model.fireSettings.randomCount {
                Text("Only \(layer.randomCandidates) buildings lie that far from the charge.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        let thermal = model.fireThermal
        Toggle(
            "The run's surface heating",
            isOn: Binding(
                get: { model.fireSettings.thermal != nil },
                set: { model.fireSettings.thermal = $0 ? .fluence : nil })
        )
        .disabled(thermal == nil && model.fireSettings.thermal == nil)
        .help(
            "The buildings whose faces or roofs the surface heating flags as ignited: test thresholds, illustrative."
        )
        if model.fireSettings.thermal != nil {
            Picker(
                "Flagged past",
                selection: Binding(
                    get: { model.fireSettings.thermal ?? .fluence }, set: { model.fireSettings.thermal = $0 })
            ) {
                Text("The ignition fluence").tag(FireSpread.ThermalSeeding.fluence)
                Text("Either threshold").tag(FireSpread.ThermalSeeding.either)
            }
        }
        if thermal == nil {
            Text("A run with the thermal radiation's surface heating flags buildings; there is none here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The wind

    @ViewBuilder private var wind: some View {
        let w = model.fireSettings.wind
        LabeledContent("Wind") {
            Text(
                w.speedMS == 0
                    ? "Calm"
                    : String(
                        format: "%.1f m/s from %.0f° (%@)", w.speedMS, w.fromDegrees,
                        Self.compass(w.fromDegrees)))
        }
        Slider(value: $model.fireSettings.wind.speedMS, in: 0...25, step: 0.5) {
            Text("Speed")
        } onEditingChanged: {
            model.fireAdjusting = $0
        }
        .accessibilityLabel("Wind speed")
        .accessibilityValue(String(format: "%.1f metres a second", w.speedMS))
        Slider(value: $model.fireSettings.wind.fromDegrees, in: 0...355, step: 5) {
            Text("From")
        } onEditingChanged: {
            model.fireAdjusting = $0
        }
        .accessibilityLabel("Wind from")
        .accessibilityValue(String(format: "%.0f degrees, %@", w.fromDegrees, Self.compass(w.fromDegrees)))
        .disabled(w.speedMS == 0)
        Text("The wind carries sparks and brands, which ignite only buildings that burn from outside.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// A bearing's point of the compass, of sixteen.
    static func compass(_ degrees: Double) -> String {
        let names = [
            "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW",
            "NNW",
        ]
        let k = Int((degrees.truncatingRemainder(dividingBy: 360) + 360 + 11.25) / 22.5) % 16
        return names[k]
    }

    // MARK: - The fire

    @ViewBuilder private var progress: some View {
        if let progress = model.fireProgress {
            ProgressView(value: Double(progress.done), total: Double(max(progress.of, 1))) {
                Text("Drawing the fire: \(progress.done) of \(progress.of) draws").font(.caption)
            }
            .accessibilityLabel("Drawing the fire")
            .accessibilityValue("\(progress.done) of \(progress.of) draws")
        }
        if !model.fireStatus.isEmpty {
            Text(model.fireStatus).font(.caption)
                .foregroundStyle(
                    model.fireLayer?.preview == true || model.fireLayer == nil ? .orange : .secondary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func results(_ layer: FireSpread.Layer) -> some View {
        let hours = layer.horizonS / 3600
        let hour = min(model.fireHour, hours)
        Slider(value: $model.fireHour, in: 0...max(hours, 0.25), step: 0.25) {
            Text("Hour")
        } minimumValueLabel: {
            Text("0").font(.caption)
        } maximumValueLabel: {
            Text(String(format: "%.0f h", hours)).font(.caption)
        }
        .accessibilityLabel("Hour after the blast")
        .accessibilityValue(String(format: "%.2g hours", hour))
        Picker("Show", selection: $model.fireShowsAlight) {
            Text("Caught by then").tag(false)
            Text("Alight then").tag(true)
        }
        .pickerStyle(.segmented)
        .help("Colour each building by its chance of having caught by the hour, or of burning at it.")
        Picker("Caught", selection: $model.fireMapChance) {
            ForEach(FireSpread.MapChance.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .help(
            "From a neighbour: over the draws in which a building was not itself a starting fire, the share in "
                + "which it caught, so that random fires do not colour where they land. At all: over every "
                + "draw, its own starting fires with them, as the map was before 31 October 2026.")
        Picker("Scale", selection: $model.fireMapScale) {
            ForEach(FireSpread.MapScale.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .help(
            "Log: the colours step at 1%, 2%, 5%, 10%, 20%, 50% and 90%, so that small chances separate. Linear: "
                + "in eighths, as the other chance maps and this one before 31 October 2026.")
        if let step = layer.step(at: hour * 3600) {
            Text(
                String(
                    format: "At %.2g h after the blast, over %d draws (median, 5–95%%):", hour, layer.members)
            )
            .font(.caption)
            LabeledContent("Alight") { Text(Self.band(step.burning)).foregroundStyle(.secondary) }
                .font(.caption)
            LabeledContent("Burnt out") { Text(Self.band(step.burnt)).foregroundStyle(.secondary) }
                .font(.caption)
            LabeledContent("Floor reached") {
                Text(Self.band(step.affectedFloorM2, unit: " m²")).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        let caught = layer.ensemble.caught
        Text(
            String(
                format: "By %.0f h, %@ of %@ buildings caught, the seeds with them; %@ more likely than not.",
                hours, Self.band(caught), layer.ids.count.formatted(),
                layer.likely(at: layer.horizonS).formatted())
        )
        .font(.caption).fixedSize(horizontal: false, vertical: true)
        let modes = FireSpread.Mode.allCases.filter { $0 != .seed }.compactMap { mode -> String? in
            guard let mean = layer.ensemble.modes[mode.rawValue], mean >= 0.05 else { return nil }
            return String(format: "%@ %.1f", mode.label, mean)
        }
        if !modes.isEmpty {
            Text("Caught, a draw on average: " + modes.joined(separator: ", ") + ".")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if model.envelopeColouring == .fire {
            if model.fireMapScale == .log {
                LogRampLegend()
            } else {
                EnvelopeDamageSection.ChanceLegend()
            }
            NoChanceLegend(alight: model.fireShowsAlight, measure: model.fireMapChance)
            Text(Self.caption(alight: model.fireShowsAlight, measure: model.fireMapChance))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Button("Colour Buildings by Fire") {
                model.showsEnvelopeDamage = true
                model.envelopeColouring = .fire
            }
            .help(
                "Colour each building by its chance of catching from a neighbour by the hour on the slider, or "
                    + "under Caught, of catching at all.")
        }
    }

    /// The log ramp's colours, each labelled with its range of chance, in two rows of four.
    struct LogRampLegend: View {
        var body: some View {
            let names = FireSpread.MapScale.log.bandNames
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<4, id: \.self) { column in
                            let n = row * 4 + column
                            let c = EnvelopeChanceColour.ramp[n]
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                                    )
                                    .frame(width: 14, height: 12)
                                Text(names[n]).font(.caption).lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Chance on a log scale, from up to 1 percent, light yellow, through 2, 5, 10, 20, 50 and 90 "
                    + "percent, to above 90 percent, dark purple")
        }
    }

    /// What the view's colours measure, under the legend.
    static func caption(alight: Bool, measure: FireSpread.MapChance) -> String {
        switch (measure, alight) {
        case (.neighbour, false):
            "Each building by its chance of catching from a neighbour by the hour on the slider: of the draws in "
                + "which it was not itself a starting fire, the share in which it caught. Grey where none has it "
                + "caught so. The seeds outlined; one that starts a fire in every draw is in the top colour, certain."
        case (.neighbour, true):
            "Each building by its chance of burning at the hour on the slider from a neighbour's fire: of the "
                + "draws in which it was not itself a starting fire, the share in which it is alight then. Grey "
                + "where none has it so. The seeds outlined; one that starts a fire in every draw is in the top "
                + "colour while it burns."
        case (.caught, false):
            "Each building by its chance of having caught by the hour on the slider, over every draw, its own "
                + "starting fires with them; grey where no draw has it caught; the seeds outlined."
        case (.caught, true):
            "Each building by its chance of burning at the hour on the slider, over every draw, its own starting "
                + "fires with them; grey where no draw has it burning then; the seeds outlined."
        }
    }

    /// The neutral grey of buildings that no draw counted sets alight, beside the chance legend: the
    /// grey the close calls' settled buildings take, the same in light and dark.
    struct NoChanceLegend: View {
        let alight: Bool
        var measure = FireSpread.MapChance.neighbour

        var text: String {
            switch (measure, alight) {
            case (.neighbour, false): "Grey: caught from a neighbour in no draw"
            case (.neighbour, true): "Grey: burning from a neighbour in no draw"
            case (.caught, false): "Grey: caught in no draw"
            case (.caught, true): "Grey: burning in no draw"
            }
        }

        var body: some View {
            let c = EnvelopeChanceColour.neutralColour
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5)))
                    .frame(width: 14, height: 12)
                Text(text).font(.caption)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A percentile band as "112 (63–181)".
    static func band(_ v: SIMD3<Double>, unit: String = "") -> String {
        func n(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0))) }
        return v.x == v.z ? n(v.y) + unit : "\(n(v.y))\(unit) (\(n(v.x))–\(n(v.z)))"
    }

    /// A selected building's switch to start a fire in it, and its chance by the hour shown, by the
    /// map's measure, with the draws it was a starting fire in.
    struct SeedToggle: View {
        @Bindable var model: SimulationModel
        let id: UUID

        var body: some View {
            Toggle(
                "Start a fire here",
                isOn: Binding(get: { model.firePicked(id) }, set: { _ in model.toggleFireSeed(id) })
            )
            .help("Set this building alight at the blast, for the fire after it (illustrative).")
            if let layer = model.fireLayer, let n = layer.ids.firstIndex(of: id) {
                let hour = min(model.fireHour, layer.horizonS / 3600)
                let seeded = layer.ensemble.buildings[n].seedDraws
                switch model.fireMapChance {
                case .neighbour:
                    LabeledContent(String(format: "Caught from a neighbour by %.2g h", hour)) {
                        Text(
                            layer.neighbourDraws(n) > 0
                                ? String(format: "%.0f%%", layer.neighbourChance(n, at: hour * 3600) * 100)
                                : "—")
                    }
                    .font(.caption)
                case .caught:
                    LabeledContent(String(format: "Caught at all by %.2g h", hour)) {
                        Text(String(format: "%.0f%%", layer.chance(n, at: hour * 3600) * 100))
                    }
                    .font(.caption)
                }
                if seeded > 0 {
                    Text(
                        seeded == layer.members
                            ? "A starting fire in every draw: drawn in the top colour, certain."
                            : model.fireMapChance == .neighbour
                                ? "A starting fire in \(seeded) of \(layer.members) draws; the chance is over the other "
                                    + "\(layer.neighbourDraws(n))."
                                : "A starting fire in \(seeded) of \(layer.members) draws, counted in the chance."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
