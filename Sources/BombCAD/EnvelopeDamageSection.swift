import BlastCore
import SwiftUI

/// Each envelope building's one-way damage: its concrete panels' levels between fixed and
/// simply supported edges, the panes broken and when, and the inside through them.
struct EnvelopeDamageSection: View {
    @Bindable var model: SimulationModel
    @State private var expanded: Set<UUID>
    @State private var export: EnvelopeResultsDocument?
    @State private var exportError: String?

    /// `expanded`: the buildings whose components are shown to begin with.
    init(model: SimulationModel, expanded: Set<UUID> = []) {
        self.model = model
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        if !model.settings.scenario.envelopeObjects.isEmpty {
            Section("Envelope building damage") {
                StandingRow(model: model, kinds: [.envelopeDamage])
                Toggle("Show damage in the view", isOn: $model.showsEnvelopeDamage)
                    .help("Colour each envelope by its damage instead of the air's pressure.")
                let chances = !model.envelopeGlassChances.isEmpty || !model.farFieldGlass.isEmpty
                let doubt = model.canJudgeEnvelopeDoubt || model.envelopeDoubt != nil
                // The damage's colours whenever the chosen colouring has nothing to show yet.
                let colouring = model.envelopeColouring
                // The walls' and roofs' chances colour the view once the full estimate has them.
                let structure = colouring.isStructure && !model.envelopeStructureChances.isEmpty
                if colouring == .damage || (colouring.isStructure && !structure)
                    || (colouring == .couldFlip ? model.envelopeDoubt == nil : !chances)
                {
                    Legend()
                }
                if chances || doubt {
                    // On a row of its own: the choices' names are too long to share one with the label.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Colour by")
                        Picker("Colour by", selection: $model.envelopeColouring) {
                            ForEach(
                                SimulationModel.EnvelopeColouring.allCases.filter {
                                    $0 == .damage || ($0 == .couldFlip ? doubt : chances)
                                }
                            ) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    .help(
                        "Each building side's glass chance, from the quick estimate's draws or, beyond the hand-over, "
                            + "the far field's; each building's walls' or roof's chance, or the share of its people "
                            + "hurt, from the quick estimate; or whether cells twice as fine could change each "
                            + "building's outcome.")
                }
                if chances, colouring.isChance || structure {
                    ChanceLegend()
                    Text(
                        (colouring.note.map { $0 + " " } ?? "")
                            + (structure
                                ? "Each building by its walls' or roof's chance, from the quick estimate's draws over the "
                                    + "yield and an assumed strength scatter: not to be relied on (their standing is below)."
                                : "Chances for the glass, drawn over the yield, each building's glass strength and the "
                                    + "estimate's own scatter. The walls' and roofs' are under Colour by and each "
                                    + "building; they are not to be relied on.")
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.envelopeColouring == .couldFlip {
                    DoubtSummary(model: model)
                }
                if model.settings.scenario.envelopeObjects.contains(where: {
                    model.settings.scenario.envelopeConstruction(for: $0.id).glazing != nil
                }) {
                    Picker("Yield known to within", selection: $model.quickEstimateYieldWithin) {
                        Text("Exactly").tag(1.0)
                        Text("×1.25").tag(1.25)
                        Text("×1.5").tag(1.5)
                        Text("×2").tag(2.0)
                        Text("×3").tag(3.0)
                    }
                    .help(
                        "For Quick Estimate's glass chances: the charge's yield within this factor either way, nine times in ten."
                    )
                }
                if model.envelopeDamageIsEstimate || model.isRefiningCloseCalls
                    || !model.closeCallStatus.isEmpty
                {
                    CloseCallsRow(model: model)
                }
                Toggle(
                    "Façade terms of 23 October (earlier estimates)",
                    isOn: $model.quickEstimateFirstFitTerms
                )
                .help(
                    "For Quick Estimate and the far field: the surrogate's terms and scatter fitted on runs "
                        + "whose top drained the far loads, in use until 25 October 2026, to reproduce an earlier "
                        + "estimate. Off, the terms in use (docs/surrogate-first-look.md)."
                )
                Toggle(
                    "Façade terms of 25 October (earlier estimates)", isOn: $model.quickEstimateClearTopTerms
                )
                .disabled(model.quickEstimateFirstFitTerms)
                .help(
                    "For Quick Estimate and the far field: the terms refitted on clear-top runs without the far "
                        + "terms for façades deep in a city, in use on 25 October 2026 until those were adopted, "
                        + "to reproduce an earlier estimate. Off, the terms in use, which raise façade peaks behind "
                        + "more than 30 buildings and on faces turned away beyond 1.75 km "
                        + "(docs/surrogate-first-look.md)."
                )
                Toggle("Glass pulses with a front (candidate)", isOn: $model.quickEstimateGlassFront)
                    .disabled(model.quickEstimateFirstFitTerms)
                    .help(
                        "For Quick Estimate's glass chances and the far field's glass: each pulse arrives with a share "
                            + "of its peak at once, as the runs' loads do, which breaks more glass far out "
                            + "(docs/glass-probability.md). A candidate, off by default."
                    )
                Toggle(
                    "Learned field model for façade peaks",
                    isOn: Binding(
                        get: { model.quickEstimateLearnedPeaks }, set: { model.setLearnedPeaks($0) })
                )
                .disabled(model.learnedDownloadInFlight)
                .help(
                    "For Quick Estimate: networks trained on BombCAD's own 4 m district runs give the peak at "
                        + "each façade strip, the ground floor's from one and the storeys' above from another, "
                        + "for its damage, glass and walls; the impulse and roofs stay on the surrogate. "
                        + "Illustrative. Their weights are read from "
                        + model.learnedWeightsURL.deletingLastPathComponent().path
                        + "; without them, turning it on offers to download them."
                )
                .confirmationDialog(
                    Self.learnedDownloadTitle,
                    isPresented: Binding(
                        get: { model.offersLearnedDownload },
                        set: { if !$0, model.offersLearnedDownload { model.declineLearnedDownload() } }),
                    titleVisibility: .visible
                ) {
                    Button(Self.learnedDownloadButton) { model.downloadLearnedWeights() }
                    Button("Cancel", role: .cancel) { model.declineLearnedDownload() }
                } message: {
                    Text(LearnedField.Release.offer)
                }
                if model.learnedDownloadInFlight {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("Cancel Download") { model.cancelLearnedDownload() }
                    }
                }
                if !model.learnedDownloadStatus.isEmpty {
                    Text(model.learnedDownloadStatus).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Field model 1's file alone: the update is offered, and fetched only on a click.
                if !model.learnedDownloadInFlight, model.learnedUpdateAvailable() {
                    Text(LearnedField.Release.updateOffer).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Self.learnedUpdateButton) { model.downloadLearnedWeights() }
                        .controlSize(.small)
                }
                if model.quickEstimateLearnedPeaks {
                    if !model.learnedPeaksStatus.isEmpty {
                        Text(model.learnedPeaksStatus).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.learnedStanding, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Check on this Mac") { model.checkLearnedFieldOnThisMac() }
                            .controlSize(.small)
                            .disabled(model.learnedCheckInFlight)
                            .help(
                                "Runs the learned field model's networks twice on a built-in 5 km district, in a "
                                    + "process of its own, and says how long they take, how much memory they need "
                                    + "and whether they fit this Mac's GPU.")
                        if model.learnedCheckInFlight { ProgressView().controlSize(.small) }
                    }
                    ForEach(model.learnedCheckReport, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                if !model.envelopeVentingStatus.isEmpty {
                    Text(model.envelopeVentingStatus).font(.caption).foregroundStyle(.orange)
                }
                if !model.envelopeStructureChances.isEmpty {
                    ForEach(FacadeLoadSurrogate.structureStanding, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                if model.envelopeDamageIsEstimate {
                    // An estimate must never pass for a run, nor a preview for the estimate.
                    Text(model.envelopeDamageStatus).font(.caption).foregroundStyle(.orange)
                    if model.envelopeEstimateIsPreview {
                        Text(FacadeLoadSurrogate.Prepared.previewStanding).font(.caption).foregroundStyle(
                            .orange
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("With Place Charge on, drag the charge in the view: the estimate follows it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(FacadeLoadSurrogate.standing, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.envelopeDamage.isEmpty {
                    Text(
                        model.envelopeDamageStatus.isEmpty
                            ? "Damage appears as the run records each wall, roof and pane's load."
                            : model.envelopeDamageStatus
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                // A preview's buildings are listed once the full estimate is in.
                ForEach(model.envelopeEstimateIsPreview ? [] : model.envelopeDamage) { building in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expanded.contains(building.id) },
                            set: {
                                if $0 { expanded.insert(building.id) } else { expanded.remove(building.id) }
                            })
                    ) {
                        ForEach(building.components) { component in
                            LabeledContent(Self.name(component)) {
                                Text(Self.describe(component)).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        // Set to the leading edge: a short line in a disclosure is otherwise centred.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(building.construction.detail)
                            let sides = model.envelopeGlassChances.filter { $0.owner == building.id }
                            if !sides.isEmpty {
                                Text(
                                    "Chances (glass breaks, blown out, thrown past 3 m; openings blown out, fitted to Beirut): "
                                        + Self.chances(sides))
                            }
                            if let structure = model.envelopeStructureChances.first(where: {
                                $0.owner == building.id
                            }) {
                                Text(Self.structureLine(structure))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Circle().fill(Self.colour(Self.code(building)))
                                    .overlay(Circle().stroke(.secondary.opacity(0.5)))
                                    .frame(width: 9, height: 9)
                                Text(model.settings.scenario.object(id: building.id)?.name ?? "Building")
                                if model.refinedBuildings.contains(building.id) {
                                    Text("refined").font(.caption).foregroundStyle(.green)
                                        .help(
                                            "The solver's result, run on this building's close call, in place of the estimate's."
                                        )
                                }
                                Spacer()
                                Text(Self.levels(building.structuralLevels))
                            }
                            if building.panes > 0 {
                                Text(
                                    "\(building.panesBroken) of \(building.panes) pane\(building.panes == 1 ? "" : "s") broken"
                                        + (building.firstPaneBrokenAtS.map {
                                            String(format: ", first at %.1f ms", $0 * 1000)
                                        }
                                            ?? "")
                                        + (building.insidePeakPa > 0
                                            ? String(
                                                format: building.vented == true
                                                    ? "; inside %.1f kPa, the air's (illustrative)"
                                                    : "; inside %.1f kPa (illustrative)",
                                                building.insidePeakPa / 1000)
                                            : "")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if let glass = Self.glassLine(building) {
                                Text(glass.prefix(1).uppercased() + glass.dropFirst())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if building.beyondOneWay {
                                Text("Frame damage beyond the one-way model: a panel turned past 2°.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if !model.envelopeDamage.isEmpty {
                    Button("Export damage…") {
                        do { export = EnvelopeResultsDocument(data: try model.envelopeDamageData()) } catch {
                            exportError = error.localizedDescription
                        }
                    }
                    .help("Each building's and component's one-way damage, with its construction, as JSON.")
                }
                Text(
                    model.envelopeDamage.contains { $0.vented == true }
                        ? "One way, but for the glazing: broken panes open in the air and the blast fills the rooms. Concrete is a range between fixed and simply supported edges, judged by ASCE/SEI 59-11's limits; brick and the inside are illustrative."
                        : "One way: the air sees each building whole. Concrete is a range between fixed and simply supported edges, judged by ASCE/SEI 59-11's limits; brick and the inside are illustrative."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .monospacedDigit()
            .fileExporter(
                isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                document: export, contentType: .json, defaultFilename: "BombCAD envelope damage"
            ) { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert(
                "Damage export failed",
                isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
            ) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    /// The learned field model's first-use download dialog: its title and its button.
    static let learnedDownloadTitle = "Download the learned field model?"
    static var learnedDownloadButton: String {
        "Download " + LearnedField.Release.megabytes(LearnedField.Release.bytes)
    }
    /// The update's button, for an install with field model 1's file alone.
    static var learnedUpdateButton: String {
        "Download Update, " + LearnedField.Release.megabytes(LearnedField.Release.levels.bytes)
    }

    /// Its façades' glass, by the construction's mix: the share of panes broken, and how many of
    /// its sides likely have some broken (each counted by its chance). Nil without a mix.
    static func glassLine(_ building: EnvelopeBuildingDamage) -> String? {
        guard let glass = building.glass, glass.panes > 0, let sides = building.facadeGlass else {
            return nil
        }
        let likely = sides.reduce(0.0) { $0 + $1.glass.anyBroken }
        return String(
            format: "glass %.0f%% of %.0f panes broken; %.1f of %d sides with some broken (%@)",
            100 * glass.fraction, glass.panes, likely, sides.count,
            building.construction.glazing?.name ?? "mix")
    }

    /// One line for a building, as headless runs print it.
    static func summary(_ building: EnvelopeBuildingDamage) -> String {
        var line =
            "\(levels(building.structuralLevels).lowercased()) (\(building.construction.walls.label.lowercased()), "
            + "\(building.construction.source.rawValue))"
        if building.panes > 0 {
            line +=
                "; \(building.panesBroken) of \(building.panes) pane\(building.panes == 1 ? "" : "s") broken"
            if let first = building.firstPaneBrokenAtS {
                line += String(format: ", first at %.1f ms", first * 1000)
            }
            if building.insidePeakPa > 0 {
                line += String(
                    format: building.vented == true ? ", inside %.1f kPa (vented)" : ", inside %.1f kPa",
                    building.insidePeakPa / 1000)
            }
            if let glazing = building.worstGlazing, glazing.condition > .two {
                line +=
                    "; glazing hazard: GSA \(glazing.condition.rawValue), ASTM \(glazing.rating.rawValue.lowercased())"
                line += String(format: " (glass at %.0f m/s)", glazing.speedMS)
            }
            if let overhead = building.worstOverhead, overhead.fall != .none {
                line += "; " + overheadLine(overhead)
            }
        }
        if let glass = glassLine(building) { line += "; " + glass }
        if let broken = building.panesBrokenByFragments, broken > 0 {
            line +=
                "; fragments broke \(broken) pane\(broken == 1 ? "" : "s")"
                + ((building.panesBrokenBeforeBlast ?? 0) > 0
                    ? " (\(building.panesBrokenBeforeBlast!) before the blast)" : "")
        }
        if let struck = building.wallStrikes, struck > 0 {
            line += String(
                format: "; walls struck by %.0f fragments, %.0f spalling and %.0f through", struck,
                building.wallsSpalled ?? 0, building.wallsPerforated ?? 0)
        }
        if building.beyondOneWay { line += "; beyond the one-way model (a panel past 2°)" }
        return line
    }

    /// What a building's roof glazing drops on the floor below.
    static func overheadLine(_ hazard: OverheadGlassHazard) -> String {
        switch hazard.fall {
        case .none: return "roof glass whole"
        case .held: return "roof glass cracked, held by its interlayer"
        case .whole:
            return String(
                format: "roof glass falls whole %.1f m at %.0f m/s, %.0f kg striking with %.0f J (%@)",
                hazard.dropM,
                hazard.impactSpeedMS, hazard.massKg, hazard.pieceEnergyJ ?? 0,
                hazard.hazardous ? "hazardous" : "under 79 J")
        case .shards:
            return String(
                format:
                    "roof glass falls in shards %.1f m at %.0f m/s, %.0f J/m²; shards over %.0f mm strike "
                    + "with 79 J, over %.0f mm with 14.9 J", hazard.dropM, hazard.impactSpeedMS,
                hazard.energyPerAreaJM2, (hazard.hazardousShardM ?? 0) * 1000,
                (hazard.injuriousShardM ?? 0) * 1000)
        }
    }

    static func code(_ building: EnvelopeBuildingDamage) -> Int { EnvelopeDamageColour.code(building) }

    static func colour(_ code: Int) -> Color {
        guard (1...6).contains(code) else { return .gray }
        let c = EnvelopeDamageColour.palette[code - 1]
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// Whether finer cells could change each building's outcome: the colours, the counts and what
    /// the band rests on.
    struct DoubtSummary: View {
        let model: SimulationModel

        var body: some View {
            HStack(spacing: 10) {
                ForEach(EnvelopeDoubtColour.palette.indices, id: \.self) { n in
                    let c = EnvelopeDoubtColour.palette[n]
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                            .frame(width: 14, height: 12)
                        Text(EnvelopeDoubtColour.labels[n]).font(.caption)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let doubt = model.envelopeDoubt {
                Text(
                    "\(doubt.count(.inDoubt)) in doubt and \(doubt.count(.likelyDifferent)) likely different on cells "
                        + "twice as fine, of \(doubt.buildings.count): the buildings to refine toward."
                )
                .font(.caption)
                Text(
                    String(
                        format:
                            "Each building's loads judged again at ×%.2f and ×%.2f, the band within which cells half as "
                            + "large read district façades' peaks at %.2f m/kg^(1/3) (Beirut and a 150 m block). On those, "
                            + "it caught 95–100%% of what finer cells changed, flagging a fifth to a third of the buildings; "
                            + "changes from the façades' own outline on finer cells, it cannot foresee.",
                        doubt.factors.lowerBound, doubt.factors.upperBound, doubt.scaledCell)
                )
                .font(.caption).foregroundStyle(.secondary)
            } else if model.judgingEnvelopeDoubt {
                Text("Judging each building at the ends of the band…").font(.caption).foregroundStyle(
                    .secondary)
            } else if model.isRunning {
                Text("Judged once the run stops.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The six colours with their meanings, three to a row.
    /// The glass chance's eighths, light to dark.
    struct ChanceLegend: View {
        var body: some View {
            HStack(spacing: 2) {
                Text("0").font(.caption)
                ForEach(EnvelopeChanceColour.ramp.indices, id: \.self) { n in
                    let c = EnvelopeChanceColour.ramp[n]
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                        .frame(width: 14, height: 12)
                }
                Text("1").font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Chance from none, light yellow, to certain, dark purple, in eighths")
        }
    }

    struct Legend: View {
        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(1...3, id: \.self) { column in
                            let code = row * 3 + column
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(EnvelopeDamageSection.colour(code))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5))
                                    )
                                    .frame(width: 12, height: 12)
                                Text(EnvelopeDamageColour.labels[code - 1]).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Colours: none, glass broken, moderate, heavy, hazardous, failed")
        }
    }

    /// A building's walls' and roof's chances, from the quick estimate's draws.
    static func structureLine(_ c: FacadeLoadSurrogate.StructureChance) -> String {
        String(
            format:
                "Chances of the structure: walls damaged (moderate or worse) %.2f, heavy or worse %.2f (illustrative for concrete); roof damaged %.2f",
            c.wallsModerate, c.wallsHeavy, c.roofModerate)
    }

    /// Each side's chances, by the way it faces (a map's x east, y north).
    static func chances(_ sides: [FacadeLoadSurrogate.SideGlass]) -> String {
        sides.sorted { ($0.axis, $0.outward) < ($1.axis, $1.outward) }.map { side in
            let face =
                side.axis == 0 ? (side.outward > 0 ? "east" : "west") : (side.outward > 0 ? "north" : "south")
            return String(
                format: "%@ %.2f, %.2f, %.2f, %.2f", face, side.someBroken, side.blownOut, side.thrownPast3b,
                side.openingsBlownOut)
        }.joined(separator: "; ")
    }

    static func levels(_ range: ClosedRange<EnvelopeDamageLevel>) -> String {
        range.lowerBound == range.upperBound
            ? range.lowerBound.label : "\(range.lowerBound.label) to \(range.upperBound.label.lowercased())"
    }

    /// A component's row: "Façade 3", its glass "Façade 3 glass", "Roof 0", "Pane 2", numbered as
    /// in the exported JSON's ids.
    static func name(_ component: EnvelopeComponentDamage) -> String {
        let parts = component.id.split(separator: "/")
        guard parts.count >= 3 else { return component.id }
        let kind = parts[1] == "facade" ? "Façade" : parts[1].capitalized
        let number = parts[2].hasSuffix(".0") ? parts[2].dropLast(2) : parts[2]
        let glass =
            switch component.material {
            case .annealedGlass, .toughenedGlass, .laminatedGlass, .filmedGlass: parts[1] != "pane"
            default: false
            }
        return "\(kind) \(number)" + (glass ? " glass" : "")
    }

    /// A rotation in degrees to two places; one that rounds to nought reads "0.00°", not "-0.00°".
    static func degrees(_ value: some BinaryFloatingPoint) -> String {
        let value = Double(value)
        return String(format: "%.2f°", abs(value) < 0.005 ? 0 : value)
    }

    /// A component's rotation, or its range between fixed and simply supported edges.
    static func rotation(_ component: EnvelopeComponentDamage) -> String {
        let range = component.rotationDeg
        return range.lowerBound == range.upperBound
            ? degrees(range.upperBound)
            : String(degrees(range.lowerBound).dropLast()) + "–" + degrees(range.upperBound)
    }

    static func describe(_ component: EnvelopeComponentDamage) -> String {
        switch component.material {
        case .annealedGlass, .toughenedGlass:
            return component.failedAtS.map { String(format: "broken at %.1f ms", $0 * 1000) } ?? "whole"
        case .laminatedGlass, .filmedGlass:
            if let gone = component.failedAtS {
                return String(format: "cracked, out of its frame at %.1f ms", gone * 1000)
            }
            return component.crackedAtS.map { String(format: "cracked at %.1f ms, held", $0 * 1000) }
                ?? "whole"
        case .reinforcedConcrete, .reinforcedBlockwork:
            return rotation(component) + ", " + levels(component.levels).lowercased()
                + (component.cantilever == true ? " (standing free)" : "")
                + (component.closeIn.map { ", \($0) (UFC 3-340-02)" } ?? "")
                + (component.holesOpened.map { ", \($0) hole\($0 == 1 ? "" : "s") open" } ?? "")
        case .profiledSteel:
            if let failed = component.failedAtS {
                return String(format: "blown off its fixings at %.1f ms", failed * 1000)
            }
            return rotation(component) + ", " + levels(component.levels).lowercased()
        case .crossLaminatedTimber:
            if let failed = component.failedAtS {
                return String(format: "blown out at %.1f ms", failed * 1000)
            }
            return degrees(component.rotationDeg.upperBound) + ", "
                + levels(component.levels).lowercased()
                + (component.cantilever == true ? " (standing free)" : "")
        case .unreinforcedMasonry:
            return component.failedAtS.map { String(format: "fallen at %.1f ms", $0 * 1000) }
                ?? (component.levels.upperBound == .none ? "uncracked" : "cracked")
                + ", \(degrees(component.rotationDeg.upperBound)) (illustrative)"
        }
    }
}

/// A district's far buildings (`FarFieldSet`): how many lie beyond the hand-over, and once a run has
/// finished, their damage judged on the far field carried from it, with the mode's standing beside
/// it (docs/hybrid-far-field.md).
struct FarFieldSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if let set = model.farFieldSet {
            Section("Far field (estimate)") {
                Text(
                    String(
                        format:
                            "%d buildings beyond the air, kept beside the scene: judged after each run on the far field carried from it past %.0f m.",
                        set.buildings.count, Double(set.handoverM))
                )
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                Toggle("Carry the run's match flat", isOn: $model.farFieldMatchFlat)
                    .help(
                        "The far field meets the run at the hand-over and carries that match on with no trend "
                            + "with distance (docs/hybrid-far-field.md), as New District's districts do since 25 "
                            + "October 2026. Off, the trend the run's strips inside the hand-over give, as districts "
                            + "made before then do. Saved with the project.")
                if model.judgingFarField { ProgressView().controlSize(.small) }
                if !model.farFieldStatus.isEmpty {
                    // An estimate must never pass for a run.
                    Text(model.farFieldStatus).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.farFieldDamage.isEmpty {
                    let counts = Dictionary(grouping: model.farFieldDamage, by: EnvelopeDamageSection.code)
                        .mapValues(\.count)
                    ForEach(counts.keys.sorted(), id: \.self) { code in
                        HStack {
                            Circle().fill(EnvelopeDamageSection.colour(code))
                                .overlay(Circle().stroke(.secondary.opacity(0.5)))
                                .frame(width: 9, height: 9)
                            Text(
                                code > 0 && code <= EnvelopeDamageColour.labels.count
                                    ? EnvelopeDamageColour.labels[code - 1] : "Not judged")
                            Spacer()
                            Text("\(counts[code] ?? 0)").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                if !model.farFieldGlass.isEmpty {
                    Text(
                        String(
                            format:
                                "Glass chances on %d building sides beyond the hand-over, drawn over the far field's scatter and the glass's strength: colour the view by them under Envelope building damage.",
                            model.farFieldGlass.count)
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(HybridFarField.standing, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The envelope building clicked in the view (`SimulationModel.inspectedEnvelope`): its judgement and
/// its sides' glass chances, the run's for a building in the air, the far field's estimate for one
/// beyond it.
struct InspectedEnvelopeSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if let building = model.inspectedEnvelopeBuilding, let id = model.inspectedEnvelope {
            Section("Selected building") {
                HStack {
                    Text(building.name).font(.headline)
                    Spacer()
                    Button("Clear") { model.inspectedEnvelope = nil }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear the selected building")
                }
                let damage = (building.far ? model.farFieldDamage : model.envelopeDamage).first {
                    $0.id == id
                }
                let sides = (building.far ? model.farFieldGlass : model.envelopeGlassChances).filter {
                    $0.owner == id
                }
                Text(
                    building.far
                        ? "Beyond the air: judged after the run on the far field carried from it, an estimate."
                        : model.envelopeDamageIsEstimate
                            ? "In the scene: the quick estimate's judgement, not a run's."
                            : "In the air: the run's judgement."
                )
                .font(.caption).foregroundStyle(
                    building.far || model.envelopeDamageIsEstimate ? .orange : .secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                if let damage {
                    HStack {
                        Circle().fill(EnvelopeDamageSection.colour(EnvelopeDamageSection.code(damage)))
                            .overlay(Circle().stroke(.secondary.opacity(0.5)))
                            .frame(width: 9, height: 9)
                        Text(
                            EnvelopeDamageSection.summary(damage).prefix(1).uppercased()
                                + EnvelopeDamageSection.summary(damage).dropFirst()
                        )
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(damage.construction.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Not judged: no face of it meets the air.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if !sides.isEmpty {
                    Text(
                        "Glass chances (breaks, blown out, thrown past 3 m, openings blown out): "
                            + EnvelopeDamageSection.chances(sides)
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !building.far,
                    let structure = model.envelopeStructureChances.first(where: { $0.owner == id })
                {
                    Text(EnvelopeDamageSection.structureLine(structure))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                }
            }
            .monospacedDigit()
        }
    }
}

/// The quick estimate's close calls refined by the solver: whether, within what budget, and how far
/// it has got, with a way to stop it (emmettl/bombcad-work#34).
private struct CloseCallsRow: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Toggle("Refine close calls with the solver", isOn: $model.refinesCloseCalls)
            .help(
                "Once the full estimate is in, run the air on the buildings whose chances lie between 0.2 and 0.8, "
                    + "nearest the charge first, on a scene cut down round them with finer air along the way to each; "
                    + "their results replace the estimate's as they come, outlined in the view.")
        if model.refinesCloseCalls {
            Picker("Up to", selection: $model.closeCallBudgetS) {
                ForEach(SimulationModel.closeCallBudgets, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min").tag(seconds)
                }
            }
            .help("The wall-clock time the refinement may take; what it has refined by then stays.")
        }
        if model.isRefiningCloseCalls {
            HStack {
                ProgressView(value: model.closeCallProgress)
                Button("Cancel") { model.cancelCloseCalls(status: nil) }
            }
        }
        if !model.closeCallStatus.isEmpty {
            Text(model.closeCallStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
