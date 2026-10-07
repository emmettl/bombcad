import BlastCore
import SwiftUI

/// Only known selected source IDs can be edited. Resetting removes overrides rather than copying
/// today's default, so subsequent default-material changes still propagate.
enum PartMaterialEditing {
    static func applying(
        _ material: StructureMaterial?, to selection: Set<Int>,
        parts: [ImportedMesh.Part], assignments: [Int: StructureMaterial]
    ) -> [Int: StructureMaterial] {
        var result = assignments
        let known = Set(parts.map(\.id))
        for id in selection.intersection(known) {
            if let material { result[id] = material } else { result.removeValue(forKey: id) }
        }
        return result
    }
}

struct ImportPartsView: View {
    let parts: [ImportedMesh.Part]
    let preview: ImportedMesh.Preview?
    let previewIsCurrent: Bool
    let deformable: Bool
    let defaultMaterial: StructureMaterial
    let editable: Bool
    @Binding var focusedID: Int?
    @Binding var selectedIDs: Set<Int>
    @Binding var assignments: [Int: StructureMaterial]
    @Binding var isolate: Bool
    @Binding var colourByMaterial: Bool
    @State private var search = ""
    @State private var bulkMaterial = StructureMaterial.structuralSteel
    @State private var copiedMaterial: StructureMaterial?
    private var filtered: [ImportedMesh.Part] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? parts
            : parts.filter {
                [$0.name, $0.ifcGlobalID ?? "", $0.ifcClass ?? "", $0.storey ?? ""].contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
            }
    }
    private var selected: ImportedMesh.Part? {
        selectedIDs.count == 1 ? parts.first { selectedIDs.contains($0.id) } : nil
    }
    var body: some View {
        Text(
            parts.contains { $0.ifcGlobalID != nil }
                ? "IFC products retain their names, types, storeys and GlobalIds. Touching elements remain separate source parts."
                : "Parts are closed shells. Face groups within a shell do not define separate material volumes."
        )
        .font(.caption)
        TextField("Find a part", text: $search)
        HStack {
            Button("Select matching") {
                selectedIDs.formUnion(filtered.map(\.id))
                focusedID = selectedIDs.sorted().first
            }.disabled(filtered.isEmpty)
            Button("Clear") {
                selectedIDs = []
                focusedID = nil
                isolate = false
            }.disabled(selectedIDs.isEmpty)
            Spacer()
            Text("\(selectedIDs.count) selected").font(.caption)
        }.controlSize(.small)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filtered) { part in
                    HStack {
                        Toggle(
                            "Select \(part.name)",
                            isOn: Binding(
                                get: { selectedIDs.contains(part.id) },
                                set: { chosen in
                                    if chosen {
                                        selectedIDs.insert(part.id)
                                        focusedID = part.id
                                    } else {
                                        selectedIDs.remove(part.id)
                                        if focusedID == part.id { focusedID = selectedIDs.sorted().first }
                                        if selectedIDs.isEmpty { isolate = false }
                                    }
                                })
                        ).labelsHidden().toggleStyle(.checkbox)
                        Button {
                            if !selectedIDs.contains(part.id) { selectedIDs = [part.id] }
                            focusedID = part.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.name)
                                if let type = part.ifcClass {
                                    Text([type, part.storey].compactMap { $0 }.joined(separator: " · ")).font(
                                        .caption
                                    ).foregroundStyle(.secondary)
                                }
                                Text(
                                    "\(part.triangleIndices.count) triangles · \(deformable ? (assignments[part.id]?.name ?? "Model default") : "Rigid obstacle")"
                                ).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }.padding(6).background(
                        selectedIDs.contains(part.id) ? Color.accentColor.opacity(0.15) : .clear,
                        in: .rect(cornerRadius: 6))
                }
                if filtered.isEmpty { Text("No matching parts.").foregroundStyle(.secondary) }
            }
        }.frame(height: min(200, CGFloat(max(filtered.count, 1)) * 52))
        Toggle("Isolate selected parts", isOn: $isolate).disabled(selectedIDs.isEmpty)
        if deformable { Toggle("Colour simulation by material", isOn: $colourByMaterial) }
        Text("Isolation only changes the preview. All parts will import.").font(.caption).foregroundStyle(
            .secondary)
        if let selected {
            Text("Selected: \(selected.name)").font(.subheadline.bold())
            if let id = selected.ifcGlobalID {
                Text("IFC GlobalId: \(id)").font(.caption).textSelection(.enabled)
            }
            if previewIsCurrent, let preview, let ids = preview.boxPartIDs {
                let cells = preview.boxes.enumerated().reduce(0) { count, entry in
                    guard ids.indices.contains(entry.offset), ids[entry.offset] == selected.id else {
                        return count
                    }
                    let s = entry.element.size / preview.cellSize
                    return count + Int((s.x * s.y * s.z).rounded())
                }
                Text("\(cells) sampled solid cells").font(.caption)
                if cells == 0 {
                    Text(
                        selected.ifcGlobalID == nil
                            ? "No solid cells for this shell: it may describe a cavity or an unresolved feature. Compare grids and review its warnings."
                            : "No assigned cells for this IFC element: it may be unresolved or covered by another element. Compare Source and Simulation."
                    ).font(.caption).foregroundStyle(.orange)
                }
            }
            if deformable {
                Toggle(
                    "Use model’s default material",
                    isOn: Binding(
                        get: { assignments[selected.id] == nil },
                        set: { useDefault in assign(useDefault ? nil : defaultMaterial) })
                ).disabled(!editable)
                if assignments[selected.id] != nil {
                    let material = Binding<StructureMaterial>(
                        get: { assignments[selected.id] ?? defaultMaterial },
                        set: { assignments[selected.id] = $0 })
                    materialPicker("Part material preset", material: material).disabled(!editable)
                    DisclosureGroup("Advanced part properties") { MaterialEditor(material: material) }
                        .disabled(!editable)
                } else {
                    Text("Uses \(defaultMaterial.name).").font(.caption)
                }
                HStack {
                    Button("Copy material") { copiedMaterial = assignments[selected.id] ?? defaultMaterial }
                    Button("Use default") { assign(nil) }.disabled(!editable)
                }.controlSize(.small)
            }
        } else if selectedIDs.count > 1 && deformable {
            materialPicker("Bulk material", material: $bulkMaterial)
            DisclosureGroup("Advanced bulk properties") { MaterialEditor(material: $bulkMaterial) }
            Button("Assign to \(selectedIDs.count) parts") { assign(bulkMaterial) }.disabled(!editable)
            Button("Use default for selected parts") { assign(nil) }.disabled(!editable)
        }
        if deformable, let copiedMaterial, !selectedIDs.isEmpty {
            Button("Paste \(copiedMaterial.name) to \(selectedIDs.count) parts") { assign(copiedMaterial) }
                .disabled(!editable)
        }
        if deformable {
            Text(
                "Up to \(StructureModel.maxMaterials) distinct active materials, including the model default."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func assign(_ material: StructureMaterial?) {
        assignments = PartMaterialEditing.applying(
            material, to: selectedIDs, parts: parts, assignments: assignments)
    }
    private func materialPicker(_ title: String, material: Binding<StructureMaterial>) -> some View {
        Picker(title, selection: material) {
            ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
            if !StructureMaterial.presets.contains(material.wrappedValue) {
                Text("Custom: \(material.wrappedValue.name)").tag(material.wrappedValue)
            }
        }
    }
}
