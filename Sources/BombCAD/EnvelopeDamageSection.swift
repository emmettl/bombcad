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
                                Circle().fill(Self.colour(Self.code(building))).frame(width: 9, height: 9)
                                Text(model.settings.scenario.object(id: building.id)?.name ?? "Building")
                                Spacer()
                                Text(Self.levels(building.structuralLevels))
                            }
                            if building.panes > 0 {
                                Text(
                                    "\(building.panesBroken) of \(building.panes) panes broken"
                                        + (building.firstPaneBrokenAtS.map {
                                            String(format: ", first at %.1f ms", $0 * 1000)
                                        }
                                            ?? "")
                                        + (building.insidePeakPa > 0
                                            ? String(
                                                format: "; inside %.1f kPa (illustrative)",
                                                building.insidePeakPa / 1000)
                                            : "")
                                )
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
                    "One way: the air sees each building whole. Concrete is a range between fixed and simply supported edges, judged by ASCE/SEI 59-11's limits; brick and the inside are illustrative."
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

    /// The viewport's colour code for a building (`SceneRenderer.setEnvelopeDamage`): the worse end
    /// of its concrete range, or glass broken alone.
    static func code(_ building: EnvelopeBuildingDamage) -> Int {
        let worst = building.structuralLevels.upperBound
        if worst == .none { return building.panesBroken > 0 ? 2 : 1 }
        return worst.rawValue + 2
    }

    static func colour(_ code: Int) -> Color {
        let colours: [Color] = [
            Color(red: 0.62, green: 0.78, blue: 0.60), Color(red: 0.55, green: 0.75, blue: 0.92),
            Color(red: 0.95, green: 0.85, blue: 0.35), Color(red: 0.96, green: 0.60, blue: 0.25),
            Color(red: 0.88, green: 0.28, blue: 0.22), Color(red: 0.55, green: 0.12, blue: 0.35),
        ]
        return (1...6).contains(code) ? colours[code - 1] : .gray
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
        case .reinforcedConcrete:
            return String(
                format: "%.2f–%.2f°, %@", component.rotationDeg.lowerBound, component.rotationDeg.upperBound,
                levels(component.levels).lowercased())
        case .unreinforcedMasonry:
            return component.failedAtS.map { String(format: "fallen at %.1f ms", $0 * 1000) }
                ?? (component.levels.upperBound == .none ? "uncracked" : "cracked")
                + String(format: ", %.2f° (illustrative)", component.rotationDeg.upperBound)
        }
    }
}
