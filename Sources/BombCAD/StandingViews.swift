import BlastCore
import SwiftUI

// The evidential standing of results (see docs/standing.md): a badge beside each result, its
// evidence in a popover, and a summary of the scene's in the Run tab.

extension ProjectRunSettings {
    /// Sets the air's charge model and refinement as these settings ask; the app's solver and
    /// the standing both take them from here.
    static func configureAir(
        _ configuration: inout SolverConfiguration, detailedCharge: Bool, sharpShocks: Bool, shockLevels: Int,
        gravity: Bool = false, shockThreshold: Float = 0.1, adaptiveSubsteps: Bool = false,
        terrainCutCells: Bool = true,
        groundStiffness: Float? = nil, ground: GroundType? = nil, outlineByOverlap: Bool = true,
        settlesStructures: Bool = true, mappedStart: Bool = false, refinementCeiling: Float? = nil,
        radiativeCooling: RadiativeCooling? = nil
    ) {
        configuration.afterburning = detailedCharge
        configuration.airModel = detailedCharge ? .thermallyPerfect : .idealGas
        // Far-field faces either way since 15 October 2026 (see `SolverConfiguration.recommended`).
        configuration.openFaces = SolverConfiguration.recommended.openFaces
        configuration.refinement = sharpShocks ? 2 : 1
        configuration.refinementLevels = sharpShocks ? shockLevels : 1
        configuration.refinementThreshold = shockThreshold
        configuration.refinementOwnSteps = sharpShocks && adaptiveSubsteps
        configuration.gravity = gravity ? AirGravity() : nil
        configuration.terrainCutCells = terrainCutCells
        configuration.groundStiffness = groundStiffness
        configuration.ground = ground
        configuration.structureMaskOverlap = outlineByOverlap
        configuration.settlesStructures = settlesStructures
        // The fine one-dimensional start, with the afterburning and hot air it was checked with.
        configuration.mappedCharge = detailedCharge && mappedStart
        // The fireball losing what it radiates, with the afterburning that makes one.
        configuration.radiativeCooling = detailedCharge ? radiativeCooling : nil
        configuration.refinementCeiling = sharpShocks ? refinementCeiling : nil
    }

    /// What the standing of a run of `scenario` under these settings is derived from.
    func standingInputs(
        _ scenario: Scenario, thermal: ThermalSpec? = nil, cloud: CloudSpec? = nil,
        fragments: FragmentSpec? = nil, groundShock: GroundShockSpec? = nil
    ) -> StandingInputs {
        var configuration = SolverConfiguration()
        Self.configureAir(
            &configuration, detailedCharge: detailedCharge, sharpShocks: sharpShocks,
            shockLevels: shockLevels ?? 1, gravity: gravity ?? false, shockThreshold: shockThreshold ?? 0.1,
            adaptiveSubsteps: adaptiveSubsteps ?? false, terrainCutCells: cutsTerrain(over: scenario),
            groundStiffness: groundStiffness, ground: ground,
            outlineByOverlap: countsByOverlap(over: scenario), mappedStart: mappedStart == true,
            refinementCeiling: refinementCeiling,
            radiativeCooling: cools ? RadiativeCooling() : nil)
        return StandingInputs(
            scenario: scenario, cellSize: (Resolution(rawValue: resolution) ?? .medium).cellSize,
            configuration: configuration, thermal: thermal, cloud: cloud, fragments: fragments,
            groundShock: groundShock, ventsGlazing: ventsGlazing ?? false)
    }
}

extension SavedSimulationRun {
    /// The standing of this run's inputs and the models run alongside it, by the current table.
    func derivedStanding() -> SceneStanding {
        SceneStanding(
            settings.standingInputs(
                scenario, thermal: thermal?.spec, cloud: cloud?.spec, fragments: fragments?.spec,
                groundShock: groundShock?.spec))
    }
}

extension [SavedSimulationRun] {
    /// How each run's recorded standing differs from `reference`'s, a line a difference, named
    /// by run; runs without a recorded standing are left out.
    func standingDifferences(from reference: SavedSimulationRun) -> [String] {
        guard let base = reference.standing else { return [] }
        return filter { $0.id != reference.id }.flatMap { run in
            (run.standing?.differences(from: base) ?? []).map { "\(run.name) · \($0)" }
        }
    }
}

extension ErrorBand {
    /// Whether two values differ by less than this band's width, so that against measurement they
    /// cannot be told apart.
    func cannotSeparate(_ value: Double, from reference: Double) -> Bool {
        abs(value - reference) < combinedHalfWidth * 2 * max(abs(value), abs(reference))
    }
}

/// The last standing worked out and its inputs: readouts redraw with every batch, and ask for it.
@MainActor private var standingCache: (inputs: StandingInputs, standing: SceneStanding)?

extension SimulationModel {
    /// The standing of the results the current inputs produce.
    var standing: SceneStanding {
        let inputs = ProjectRunSettings(model: self).standingInputs(
            settings.scenario, thermal: thermalSpec, cloud: cloudSpec, fragments: fragmentSpec,
            groundShock: groundShockSpec)
        if let cached = standingCache, cached.inputs == inputs { return cached.standing }
        let standing = SceneStanding(inputs)
        standingCache = (inputs, standing)
        return standing
    }
}

extension EvidenceLevel {
    var colour: Color {
        switch self {
        // Not green: compared is a kind of evidence, not a verdict; the bands say how far and which way.
        case .compared: .teal
        case .verified: .blue
        case .approximation: .orange
        case .illustrative: .purple
        }
    }

    var symbol: String {
        switch self {
        case .compared: "ruler"
        case .verified: "function"
        case .approximation: "plusminus.circle"
        case .illustrative: "paintbrush.pointed"
        }
    }
}

/// A page under docs/, as the repository shows it.
private func documentURL(_ document: String) -> URL? {
    URL(string: "https://github.com/emmettl/bombcad/blob/main/docs/" + document)
}

/// "validation.md#with-refinement" as "Validation › With refinement".
private func documentTitle(_ document: String) -> String {
    func words(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
    let parts = document.split(separator: "#", maxSplits: 1)
    return parts.map(words).joined(separator: " › ")
}

/// A result's value as shown, so that its band can say where the measurement would lie.
struct ShownValue: Equatable {
    var measure: BandMeasure
    var value: Double
    var unit: String
    var digits = 0

    func formatted(_ number: Double) -> String { String(format: "%.\(digits)f \(unit)", number) }

    /// To two significant figures: a band is no finer than that.
    func range(_ range: ClosedRange<Double>) -> String {
        func rounded(_ value: Double) -> String {
            guard value > 0 else { return "0" }
            let step = pow(10, floor(log10(value)) - 1)
            return ((value / step).rounded() * step).formatted(.number.precision(.significantDigits(1...2)))
        }
        return "\(rounded(range.lowerBound))–\(rounded(range.upperBound)) \(unit)"
    }

    /// "expect 100–110 mm (reads high: too flexible)", by `band`, widened by the inputs' spread
    /// where the case was run with uncertain inputs.
    func expectation(_ band: ErrorBand) -> String {
        let inputs = band.inputSpread.map { String(format: "; inputs ±%.0f%%", 164.5 * $0) } ?? ""
        let reference = band.referenceScatter.map { String(format: "; tests ±%.0f%%", 164.5 * $0) } ?? ""
        let rounding = band.roundingSpread.map { String(format: "; roundings ±%.0f%%", 100 * $0) } ?? ""
        return
            "expect \(range(band.expectedWithInputs(value))) (model \(band.reads)\(inputs)\(reference)\(rounding))"
    }
}

/// Where the measurement would lie for a value shown, by the current inputs' band; nothing when
/// no band applies.
struct ExpectedRangeLine: View {
    let model: SimulationModel
    let value: ShownValue

    var body: some View {
        if value.value > 0, let band = model.standing.band(value.measure) {
            Text(value.expectation(band))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("\(band.summary). Holds for \(band.validity).")
        }
    }
}

/// Under a gauge's peak, where the measurement would lie by that gauge's own band.
struct GaugeExpectationLine: View {
    let model: SimulationModel
    let name: String
    let peak: Double

    var body: some View {
        if peak > 0, let gauge = model.standing.gauge(name) {
            if let band = gauge.peak {
                let shown = ShownValue(measure: .peakOverpressure, value: peak, unit: "kPa")
                Text(shown.expectation(band))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("\(band.summary). Holds for \(band.validity).")
            } else if let note = gauge.note {
                Text("No band: " + note.prefix(1).lowercased() + note.dropFirst())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 14)
                    .lineLimit(2)
                    .help(note)
            }
        }
    }
}

/// The level of a result, as a small capsule.
struct StandingLabel: View {
    let level: EvidenceLevel

    var body: some View {
        Label(level.badge, systemImage: level.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(level.colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(level.colour.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// The weakest standing among `kinds`, with every one's evidence in a popover; "Standing not
/// recorded" when `standing` is nil and `unrecorded` is set, as for runs kept before it was.
struct StandingBadge: View {
    let standing: SceneStanding?
    let kinds: [ResultKind]
    var unrecorded = false
    /// A value shown beside the badge, for the popover to say where the measurement would lie.
    var value: ShownValue? = nil
    @State private var showsDetail = false

    var body: some View {
        if let standing, let weakest = standing.weakest(kinds) {
            Button {
                showsDetail.toggle()
            } label: {
                StandingLabel(level: weakest.level)
            }
            .buttonStyle(.plain)
            .help(
                "\(weakest.level.title). " + (weakest.direction.map { $0 + " " } ?? "") + weakest.summary
                    + " Click for the evidence."
            )
            .accessibilityLabel("Standing: \(weakest.level.title)")
            .popover(isPresented: $showsDetail, arrowEdge: .trailing) {
                StandingDetail(standing: standing, kinds: kinds, value: value)
            }
        } else if unrecorded {
            Text("Standing not recorded")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("This run was kept before BombCAD recorded the standing of its results.")
        }
    }
}

/// The badge for the current inputs; on its own so that only it is drawn again when they change.
struct LiveStandingBadge: View {
    let model: SimulationModel
    let kinds: [ResultKind]

    var body: some View { StandingBadge(standing: model.standing, kinds: kinds) }
}

/// A Run tab row giving a section's standing.
struct StandingRow: View {
    let model: SimulationModel
    let kinds: [ResultKind]

    var body: some View {
        LabeledContent("Standing") { LiveStandingBadge(model: model, kinds: kinds) }
    }
}

/// The evidence, resolution notes, assumptions and documents behind `kinds`.
struct StandingDetail: View {
    let standing: SceneStanding
    let kinds: [ResultKind]
    var value: ShownValue? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(kinds.compactMap { standing[$0] }) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(result.kind.title).font(.headline)
                            Spacer()
                            StandingLabel(level: result.level)
                        }
                        if let direction = result.direction {
                            Label(
                                direction,
                                systemImage: result.errsUnsafe
                                    ? "exclamationmark.triangle" : "arrow.left.and.right"
                            )
                            .fontWeight(.medium)
                            .foregroundStyle(result.errsUnsafe ? .orange : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(result.summary)
                        if !result.evidence.isEmpty {
                            heading("Evidence")
                            ForEach(result.evidence, id: \.self) { evidence in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(evidence.check).fontWeight(.medium)
                                    Text(evidence.agreement).foregroundStyle(.secondary)
                                    if let url = documentURL(evidence.document) {
                                        Link(documentTitle(evidence.document), destination: url).font(
                                            .caption)
                                    }
                                }
                            }
                        }
                        bands(result)
                        regimes(result)
                        notes("Resolution", result.resolution)
                        notes("Assumptions", result.assumptions)
                        if !result.documents.isEmpty {
                            heading("Read more")
                            ForEach(result.documents, id: \.self) { document in
                                if let url = documentURL(document) {
                                    Link(documentTitle(document), destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
                Text("Judged by \(standing.tableTitle), from the validation record for these settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: 380)
        .frame(maxHeight: 520)
    }

    /// How far it has been from measurement, and where this run's value would put the measurement.
    @ViewBuilder private func bands(_ result: ResultStanding) -> some View {
        if let bands = result.bands {
            if !bands.isEmpty || !(result.unbanded ?? []).isEmpty { heading("Error bands") }
            ForEach(bands, id: \.self) { band in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(band.quantity): model \(band.ratio) of measured").fontWeight(.medium)
                    Text("Model \(band.reads), on the \(band.side).").foregroundStyle(.secondary)
                    if let spread = band.inputSpread {
                        Text(
                            String(
                                format:
                                    "Uncertain inputs spread the model by %.0f%% (5–95%%: ±%.0f%%), added to the band.",
                                spread * 100, spread * 164.5)
                        )
                        .foregroundStyle(.secondary)
                    }
                    if let rounding = band.roundingSpread {
                        Text(
                            String(
                                format:
                                    "After failure, one draw among roundings of the same arithmetic: ±%.0f%%, added to the band.",
                                rounding * 100)
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let verdict = band.againstReference {
                        Label(
                            verdict + " (One standard deviation; added to the range below.)",
                            systemImage: band.withinReference == true
                                ? "equal.circle" : "arrow.up.and.down.circle"
                        )
                        .foregroundStyle(band.withinReference == true ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let value, value.measure == band.measure {
                        Text(
                            "This run's \(value.formatted(value.value)) puts the measurement at "
                                + value.range(band.expectedWithInputs(value.value)) + ".")
                    }
                    if let mesh = band.derivedMesh {
                        Label(
                            "Derived on \(mesh); it holds only there, since no structural result converges.",
                            systemImage: "square.grid.3x3"
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Holds for \(band.validity)\(band.scaled ? ", scaled to this resolution" : "").")
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = documentURL(band.document) {
                        Link("\(band.check) · \(documentTitle(band.document))", destination: url).font(
                            .caption)
                    }
                }
            }
            ForEach(result.unbanded ?? [], id: \.self) { line in
                Text("No band: " + line.prefix(1).lowercased() + line.dropFirst()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            heading("Error bands")
            Text("Not recorded with this run.").foregroundStyle(.secondary)
        }
    }

    /// Whether the chosen options suit the regime the scene is in.
    @ViewBuilder private func regimes(_ result: ResultStanding) -> some View {
        if let advice = result.regimes, let first = advice.first {
            heading("Regime: \(first.regime)")
            ForEach(advice, id: \.self) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Label(
                        item.option
                            + (item.suits == true
                                ? ": suits it" : item.suits == false ? ": does not suit it" : ""),
                        systemImage: item.suits == true
                            ? "checkmark.circle"
                            : item.suits == false ? "exclamationmark.triangle" : "info.circle"
                    )
                    .foregroundStyle(item.suits == false ? .orange : .primary)
                    .fontWeight(.medium)
                    Text(item.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let suggestion = item.suggestion { Text(suggestion).italic() }
                    if let url = documentURL(item.document) {
                        Link(documentTitle(item.document), destination: url).font(.caption)
                    }
                }
            }
            Text("Suggestions only: no default changes.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }

    @ViewBuilder private func notes(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            heading(title)
            ForEach(lines, id: \.self) { line in
                Text("• " + line).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The Run tab's summary of what the scene's results rest on and what it leaves out.
struct SceneStandingSection: View {
    let model: SimulationModel

    var body: some View {
        let standing = model.standing
        Section("Standing of results") {
            ForEach(standing.results) { result in
                LabeledContent(result.kind.title) { StandingBadge(standing: standing, kinds: [result.kind]) }
            }
            if !standing.resolution.isEmpty {
                DisclosureGroup("Resolution (\(standing.resolution.count))") { bullets(standing.resolution) }
            }
            DisclosureGroup("Not modelled (\(standing.unsupported.count))") { bullets(standing.unsupported) }
            Text(
                "What each result rests on for these settings: comparison with measurement, verification against "
                    + "theory, an approximation or an illustration. Click a badge for the evidence."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullets(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Text("• " + line).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
