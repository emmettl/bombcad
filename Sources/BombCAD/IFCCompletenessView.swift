import BlastCore
import SwiftUI

enum IFCCompleteness {
    struct Row: Identifiable {
        var id: String
        var name: String
        var type: String
        var location: String
        var status: String
        var issue: Bool
        var sampling: ImportedMesh.BuildingSampling?
    }
    static func rows(mesh: ImportedMesh, preview: ImportedMesh.Preview?) -> [Row] {
        let converted = Set((mesh.buildingElements ?? []).map(\.globalID))
        let chosen = Set(mesh.buildingSelection?.includedIDs ?? Array(converted))
        let samples = Dictionary(uniqueKeysWithValues: (preview?.buildingSampling ?? []).map { ($0.id, $0) })
        let inventory =
            mesh.buildingSelection?.inventory
            ?? (mesh.buildingElements ?? []).map {
                ImportedMesh.BuildingSourceElement(
                    id: $0.globalID, name: $0.name, ifcClass: $0.ifcClass, storey: $0.storey)
            }
        return inventory.map { e in
            let status: String
            var issue = false
            if !e.supported {
                status = "Unsupported type, excluded"
            } else if !chosen.contains(e.id) {
                status = "Excluded by your choices"
            } else if !converted.contains(e.id) {
                status =
                    e.hasChildren
                    ? "No converted geometry; has child elements"
                    : "No converted geometry; possible conversion failure"
                issue = true
            } else if let sample = samples[e.id] {
                status = sample.status
                issue = sample.sampledCells == 0 || sample.assignedCells == 0
            } else {
                status = "Converted; grid check pending"
            }
            return Row(
                id: e.id, name: e.name, type: e.ifcClass,
                location: [e.building, e.storey].compactMap { $0 }.joined(separator: " · "),
                status: status, issue: issue, sampling: samples[e.id])
        }
    }
    static func summary(mesh: ImportedMesh, preview: ImportedMesh.Preview?) -> String {
        let inventory = mesh.buildingSelection?.inventory ?? []
        let chosen = Set(mesh.buildingSelection?.includedIDs ?? (mesh.buildingElements ?? []).map(\.globalID))
        let missing = chosen.subtracting((mesh.buildingElements ?? []).map(\.globalID)).count
        let excluded = inventory.filter { $0.supported && !chosen.contains($0.id) }.count
        let unsupported = inventory.filter { !$0.supported }.count
        var text =
            "\(chosen.count) chosen · \(mesh.parts.count) converted · \(missing) without geometry\n\(excluded) excluded by choice · \(unsupported) unsupported"
        if let samples = preview?.buildingSampling {
            text +=
                "\n\(samples.filter { $0.sampledCells == 0 }.count) with no grid cells · \(samples.filter { $0.sampledCells > 0 && $0.assignedCells == 0 }.count) fully covered"
        }
        return text
    }
    static func report(mesh: ImportedMesh, preview: ImportedMesh.Preview?) -> String {
        guard mesh.buildingElements != nil else { return "" }
        var text = "\nIFC completeness\n" + summary(mesh: mesh, preview: preview) + "\n"
        text +=
            "Inventory follows the IFC decomposition tree; uncontained products may be absent. Missing geometry can indicate a container or conversion failure. Review against the source CAD model.\n"
        for row in rows(mesh: mesh, preview: preview) {
            text += "\(row.id) · \(row.name) · \(row.type) · \(row.location): \(row.status)"
            if let s = row.sampling {
                text += " · \(s.sampledCells) sampled / \(s.assignedCells) assigned cells"
            }
            text += "\n"
        }
        return text + "\n"
    }
}

struct IFCCompletenessView: View {
    let mesh: ImportedMesh
    let preview: ImportedMesh.Preview?
    @State private var onlyIssues = true
    @State private var search = ""
    private var rows: [IFCCompleteness.Row] {
        IFCCompleteness.rows(mesh: mesh, preview: preview).filter { row in
            (!onlyIssues || row.issue)
                && (search.isEmpty
                    || [row.name, row.id, row.type, row.location, row.status].contains {
                        $0.localizedCaseInsensitiveContains(search)
                    })
        }
    }
    var body: some View {
        DisclosureGroup("IFC completeness") {
            Text(IFCCompleteness.summary(mesh: mesh, preview: preview)).font(.caption)
            if mesh.buildingSelection == nil {
                Text(
                    "This earlier import has no saved inclusion choices. Choose IFC elements to record them."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show omissions and grid losses only", isOn: $onlyIssues)
            TextField("Find a completeness entry", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).font(.caption.bold())
                            Text(row.status).font(.caption).foregroundStyle(
                                row.issue ? Color.orange : .secondary)
                            Text([row.type, row.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                            Text(row.id).font(.caption).textSelection(.enabled)
                            if let s = row.sampling {
                                Text("\(s.sampledCells) sampled / \(s.assignedCells) assigned cells").font(
                                    .caption)
                            }
                        }
                    }
                    if rows.isEmpty {
                        Text("No matching entries.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(height: 180)
            Text(
                "Inventory follows the source decomposition tree; uncontained products may be absent. An element with children can be a container, but missing geometry still needs review. Grid losses are separate from converter omissions. Partial surface and gap warnings remain in Warnings."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
}
