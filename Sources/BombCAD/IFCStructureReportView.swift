import BlastCore
import SwiftUI

/// What converting an IFC building to shells and beams did (`IFCStructure.Report`): how many
/// elements became what, every assumption, the supports and connections it inferred, and each
/// element's material and notes.
struct IFCStructureReportView: View {
    let report: IFCStructure.Report
    /// The pairs left untied, where the report's connections can be changed (the import sheet).
    var untied: Binding<Set<String>>? = nil

    private func count(_ role: IFCStructure.Role) -> Int { report.members.filter { $0.role == role }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "\(count(.shell)) shells · \(count(.beam)) beams · \(count(.pane)) panes · \(count(.footing)) footings · "
                    + "\(count(.opening)) openings · \(count(.rigid)) kept rigid"
            ).font(.caption.weight(.semibold))
            if !report.assumedMaterials.isEmpty {
                Label(
                    "\(report.assumedMaterials.count) elements use the default material: choose theirs under Parts.",
                    systemImage: "exclamationmark.triangle"
                ).font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Assumptions (\(report.assumptions.count))") {
                ForEach(report.assumptions, id: \.self) { Text("• " + $0).font(.caption) }
            }
            DisclosureGroup("Supports (\(report.supports.count))") {
                ForEach(report.supports, id: \.self) { Text("• " + $0).font(.caption) }
                Text(
                    "Change them under Restraints once imported; edits detach the structure from its source."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Connections (\(report.connections.count))") {
                let names = Dictionary(
                    report.members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                ForEach(Array(report.connections.enumerated()), id: \.offset) { _, connection in
                    let text = Text(
                        "\(names[connection.first] ?? connection.first) with \(names[connection.second] ?? connection.second): \(connection.kind)"
                    ).font(.caption)
                    if let untied {
                        Toggle(
                            isOn: Binding(
                                get: { !untied.wrappedValue.contains(connection.key) },
                                set: { tie in
                                    if tie {
                                        untied.wrappedValue.remove(connection.key)
                                    } else {
                                        untied.wrappedValue.insert(connection.key)
                                    }
                                })
                        ) { text }
                        .toggleStyle(.checkbox)
                    } else {
                        Text("• ") + text
                    }
                }
                if untied != nil {
                    Text(
                        "Untick a connection to leave the pair untied: the second member is drawn back 10 mm from the first."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Elements (\(report.members.count))") {
                ForEach(report.members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(member.name) · \(member.ifcClass) · \(title(member.role))").font(
                            .caption.weight(.medium))
                        if let material = member.material {
                            Text("\(material): \(member.materialSource)").font(.caption)
                                .foregroundStyle(member.assumed ? .orange : .secondary)
                        }
                        ForEach(member.notes, id: \.self) {
                            Text($0).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func title(_ role: IFCStructure.Role) -> String {
        switch role {
        case .shell: "shells"
        case .beam: "beams"
        case .pane: "glass pane"
        case .footing: "footing"
        case .opening: "opening"
        case .rigid: "rigid obstacle"
        }
    }
}
