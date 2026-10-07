import BlastCore
import SwiftUI

/// Selection and assignments refer to source shells, never to transient voxel region indices.
struct ImportPartsView: View {
    let parts: [ImportedMesh.Part]
    let preview: ImportedMesh.Preview?
    let previewIsCurrent: Bool
    let deformable: Bool
    let defaultMaterial: StructureMaterial
    let editable: Bool
    @Binding var selectedID: Int?
    @Binding var assignments: [Int: StructureMaterial]
    @State private var search = ""
    private var filtered: [ImportedMesh.Part] {
        search.isEmpty ? parts : parts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var selected: ImportedMesh.Part? { parts.first { $0.id == selectedID } }
    var body: some View {
        Text(
            "Parts follow closed connected shells. OBJ object/group names label complete shells; face groups within a shell do not define separate material volumes."
        ).font(.caption)
        TextField("Find a part", text: $search)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filtered) { part in
                    Button {
                        selectedID = selectedID == part.id ? nil : part.id
                    } label: {
                        HStack {
                            Image(systemName: selectedID == part.id ? "scope" : "cube")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.name)
                                Text(
                                    "\(part.triangleIndices.count) triangles · \(deformable ? (assignments[part.id]?.name ?? "Model default") : "Rigid obstacle")"
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(
                                selectedID == part.id ? Color.accentColor.opacity(0.2) : .clear,
                                in: .rect(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                if filtered.isEmpty { Text("No matching parts.").foregroundStyle(.secondary) }
            }
        }.frame(maxHeight: 150)
        if deformable {
            Text(
                "The solver supports up to \(StructureModel.maxMaterials) distinct materials, including the model default."
            ).font(.caption)
        }
        if let selected {
            Text("Selected: \(selected.name)").font(.subheadline.bold())
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
                        "This shell has no sampled solid cells. It may describe a cavity or an unresolved feature; review the source overlay and resolution warnings."
                    ).font(.caption).foregroundStyle(.orange)
                }
            }
            if deformable {
                Toggle(
                    "Use model’s default material",
                    isOn: Binding(
                        get: { assignments[selected.id] == nil },
                        set: { useDefault in
                            if useDefault {
                                assignments.removeValue(forKey: selected.id)
                            } else {
                                assignments[selected.id] = defaultMaterial
                            }
                        })
                )
                .disabled(!editable)
                if assignments[selected.id] != nil {
                    let material = Binding<StructureMaterial>(
                        get: { assignments[selected.id] ?? defaultMaterial },
                        set: { assignments[selected.id] = $0 })
                    Picker("Part material preset", selection: material) {
                        ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                        if !StructureMaterial.presets.contains(material.wrappedValue) {
                            Text("Custom: \(material.wrappedValue.name)").tag(material.wrappedValue)
                        }
                    }.disabled(!editable)
                    MaterialEditor(material: material).disabled(!editable)
                    Button("Reset part to model default") { assignments.removeValue(forKey: selected.id) }
                        .disabled(!editable)
                } else {
                    Text("Uses \(defaultMaterial.name). Changes to the model default apply to this part.")
                        .font(.caption)
                }
            }
        }
        Text(
            "Select a part to highlight and focus it in the preview. Source assignments persist through grid and placement changes."
        ).font(.caption).foregroundStyle(.secondary)
    }
}
