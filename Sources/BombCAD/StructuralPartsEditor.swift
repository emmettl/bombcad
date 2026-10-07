import BlastCore
import SwiftUI

/// Edit named source parts without exposing every coalesced voxel as a separate object.
struct StructuralPartsEditor: View {
    @Bindable var model: SimulationModel

    private var selected: StructureEditing.Part? {
        guard case .part(let reference) = model.selection else { return nil }
        return model.structuralParts.first { $0.id == reference }
    }

    var body: some View {
        ForEach(model.structuralParts) { part in
            Button {
                model.selection = model.selection == .part(part.id) ? nil : .part(part.id)
            } label: {
                HStack {
                    Image(systemName: model.selection == .part(part.id) ? "chevron.down" : "chevron.right")
                    VStack(alignment: .leading) {
                        Text(part.name)
                        Text(
                            "\(part.regions.count) sampled \(part.regions.count == 1 ? "region" : "regions") · \(part.attached ? "Linked to source" : "Detached")"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.contentShape(.rect)
            }.buttonStyle(.plain)
        }
        if let selected, let body = model.settings.scenario.structure {
            let materials = selected.regions.map { body.material(of: $0) }
            Toggle(
                "Use structure’s default material",
                isOn: Binding(
                    get: { usesDefault(selected, body: body) },
                    set: { model.setPartMaterial($0 ? nil : body.material, for: selected.id) })
            )
            .disabled(!selected.attached && selected.regions.isEmpty)
            if Set(materials).count > 1 {
                Text("Mixed region materials. Choosing a preset applies it to this whole part.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let material = Binding<StructureMaterial>(
                get: {
                    assignment(selected, body: model.settings.scenario.structure ?? body) ?? body.material
                },
                set: { model.setPartMaterial($0, for: selected.id) })
            Picker("Part material", selection: material) {
                ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                if !StructureMaterial.presets.contains(material.wrappedValue) {
                    Text("Custom: \(material.wrappedValue.name)").tag(material.wrappedValue)
                }
            }
            .disabled(!selected.attached && selected.regions.isEmpty)
            DisclosureGroup("Part material properties") { MaterialEditor(material: material) }
                .disabled(!selected.attached && selected.regions.isEmpty)
            if selected.regions.isEmpty {
                Text(
                    selected.attached
                        ? "This part has no sampled solid regions at this grid. Its source material assignment is retained for finer grids."
                        : "No editable regions remain for this detached part. The original source is retained for inspection."
                )
                .font(.caption).foregroundStyle(.orange)
            } else {
                Button("Frame selected part") {
                    if let bounds = model.highlightedBox { model.camera = .framing(bounds) }
                }
                let specs = selected.regions.map { body.reinforcement(of: $0) }
                if Set(specs).count > 1 {
                    Text("Mixed reinforcement. A new choice applies to every region of this part.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ReinforcementEditor(
                    spec: Binding(
                        get: { specs.first ?? .none },
                        set: { model.setPartReinforcement($0, for: selected.id) }))
                Text(
                    "Reinforcement follows the sampled regions’ shapes, not the original mesh surfaces. Review the regions before choosing mats or columns."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cut opening") { model.addOpening() }
                    Button("Add base support") { model.addSupport() }
                }
            }
        }
    }

    private func usesDefault(_ part: StructureEditing.Part, body: StructureModel) -> Bool {
        if part.attached {
            return model.settings.scenario.importedModels?.first { $0.id == part.id.modelID }?
                .partMaterials?[part.id.partID] == nil
        }
        return part.regions.allSatisfy {
            !body.solidMaterial.indices.contains($0) || body.solidMaterial[$0] == nil
        }
    }

    private func assignment(_ part: StructureEditing.Part, body: StructureModel) -> StructureMaterial? {
        if part.attached {
            return model.settings.scenario.importedModels?.first { $0.id == part.id.modelID }?
                .partMaterials?[part.id.partID]
        }
        let values = part.regions.map { body.material(of: $0) }
        return Set(values).count == 1 ? values.first : nil
    }
}
