import BlastCore
import SwiftUI

/// Each envelope building's one-way damage: its concrete panels' levels between fixed and
/// simply supported edges, the panes broken and when, and the inside through them.
struct EnvelopeDamageSection: View {
    @Bindable var model: SimulationModel
    @State private var expanded: Set<UUID> = []
    @State private var export: EnvelopeResultsDocument?
    @State private var exportError: String?

    var body: some View {
        if !model.settings.scenario.envelopeObjects.isEmpty {
            Section("Envelope building damage") {
                StandingRow(model: model, kinds: [.envelopeDamage])
                Toggle("Show damage in the view", isOn: $model.showsEnvelopeDamage)
                    .help("Colour each envelope by its damage instead of the air's pressure.")
                Legend()
                if !model.envelopeVentingStatus.isEmpty {
                    Text(model.envelopeVentingStatus).font(.caption).foregroundStyle(.orange)
                }
                if model.envelopeDamage.isEmpty {
                    Text(
                        model.envelopeDamageStatus.isEmpty
                            ? "Damage appears as the run records each wall, roof and pane's load."
                            : model.envelopeDamageStatus
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.envelopeDamage) { building in
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
                        Text(building.construction.detail).font(.caption).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Circle().fill(Self.colour(Self.code(building)))
                                    .overlay(Circle().stroke(.secondary.opacity(0.5)))
                                    .frame(width: 9, height: 9)
                                Text(model.settings.scenario.object(id: building.id)?.name ?? "Building")
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

    static func code(_ building: EnvelopeBuildingDamage) -> Int { EnvelopeDamageColour.code(building) }

    static func colour(_ code: Int) -> Color {
        guard (1...6).contains(code) else { return .gray }
        let c = EnvelopeDamageColour.palette[code - 1]
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// The six colours with their meanings, three to a row.
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

    static func levels(_ range: ClosedRange<EnvelopeDamageLevel>) -> String {
        range.lowerBound == range.upperBound
            ? range.lowerBound.label : "\(range.lowerBound.label) to \(range.upperBound.label.lowercased())"
    }

    static func name(_ component: EnvelopeComponentDamage) -> String {
        let parts = component.id.split(separator: "/")
        return parts.count >= 3 ? "\(parts[1].capitalized) \(parts[2])" : component.id
    }

    static func describe(_ component: EnvelopeComponentDamage) -> String {
        switch component.material {
        case .annealedGlass:
            return component.failedAtS.map { String(format: "broken at %.1f ms", $0 * 1000) } ?? "whole"
        case .reinforcedConcrete, .reinforcedBlockwork:
            let rotation =
                component.rotationDeg.lowerBound == component.rotationDeg.upperBound
                ? String(format: "%.2f°", component.rotationDeg.upperBound)
                : String(
                    format: "%.2f–%.2f°", component.rotationDeg.lowerBound, component.rotationDeg.upperBound)
            return rotation + ", " + levels(component.levels).lowercased()
                + (component.cantilever == true ? " (standing free)" : "")
                + (component.closeIn.map { ", \($0) (UFC 3-340-02)" } ?? "")
                + (component.holesOpened.map { ", \($0) hole\($0 == 1 ? "" : "s") open" } ?? "")
        case .profiledSteel:
            if let failed = component.failedAtS {
                return String(format: "blown off its fixings at %.1f ms", failed * 1000)
            }
            let rotation =
                component.rotationDeg.lowerBound == component.rotationDeg.upperBound
                ? String(format: "%.2f°", component.rotationDeg.upperBound)
                : String(
                    format: "%.2f–%.2f°", component.rotationDeg.lowerBound, component.rotationDeg.upperBound)
            return rotation + ", " + levels(component.levels).lowercased()
        case .crossLaminatedTimber:
            if let failed = component.failedAtS {
                return String(format: "blown out at %.1f ms", failed * 1000)
            }
            return String(format: "%.2f°", component.rotationDeg.upperBound) + ", "
                + levels(component.levels).lowercased()
                + (component.cantilever == true ? " (standing free)" : "")
        case .unreinforcedMasonry:
            return component.failedAtS.map { String(format: "fallen at %.1f ms", $0 * 1000) }
                ?? (component.levels.upperBound == .none ? "uncracked" : "cracked")
                + String(format: ", %.2f° (illustrative)", component.rotationDeg.upperBound)
        }
    }
}
