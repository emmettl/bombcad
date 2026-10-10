import BlastCore
import SwiftUI

// The evidential standing of results (see docs/standing.md): a badge beside each result, its
// evidence in a popover, and a summary of the scene's in the Run tab.

extension ProjectRunSettings {
    /// Sets the air's charge model and refinement as these settings ask; the app's solver and
    /// the standing both take them from here.
    static func configureAir(
        _ configuration: inout SolverConfiguration, detailedCharge: Bool, sharpShocks: Bool, shockLevels: Int
    ) {
        configuration.afterburning = detailedCharge
        configuration.airModel = detailedCharge ? .thermallyPerfect : .idealGas
        configuration.refinement = sharpShocks ? 2 : 1
        configuration.refinementLevels = sharpShocks ? shockLevels : 1
    }

    /// What the standing of a run of `scenario` under these settings is derived from.
    func standingInputs(
        _ scenario: Scenario, thermal: ThermalSpec? = nil, cloud: CloudSpec? = nil,
        fragments: FragmentSpec? = nil, groundShock: GroundShockSpec? = nil
    ) -> StandingInputs {
        var configuration = SolverConfiguration()
        Self.configureAir(
            &configuration, detailedCharge: detailedCharge, sharpShocks: sharpShocks,
            shockLevels: shockLevels ?? 1)
        return StandingInputs(
            scenario: scenario, cellSize: (Resolution(rawValue: resolution) ?? .medium).cellSize,
            configuration: configuration, thermal: thermal, cloud: cloud, fragments: fragments,
            groundShock: groundShock)
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

extension SimulationModel {
    /// The standing of the results the current inputs produce.
    var standing: SceneStanding {
        SceneStanding(
            ProjectRunSettings(model: self).standingInputs(
                settings.scenario, thermal: thermalSpec, cloud: cloudSpec, fragments: fragmentSpec,
                groundShock: groundShockSpec))
    }
}

extension EvidenceLevel {
    var colour: Color {
        switch self {
        case .measured: .green
        case .verified: .blue
        case .approximation: .orange
        case .illustrative: .purple
        }
    }

    var symbol: String {
        switch self {
        case .measured: "checkmark.seal"
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
    @State private var showsDetail = false

    var body: some View {
        if let standing, let weakest = standing.weakest(kinds) {
            Button {
                showsDetail.toggle()
            } label: {
                StandingLabel(level: weakest.level)
            }
            .buttonStyle(.plain)
            .help("\(weakest.level.title). \(weakest.summary) Click for the evidence.")
            .accessibilityLabel("Standing: \(weakest.level.title)")
            .popover(isPresented: $showsDetail, arrowEdge: .trailing) {
                StandingDetail(standing: standing, kinds: kinds)
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
                Text("Judged by \(standing.table), from the validation record for these settings.")
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
                "What each result rests on for these settings: measured agreement, verification against "
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
