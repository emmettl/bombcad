import BlastCore
import BlastRender
import SwiftUI

struct ModelImportView: View {
    let mesh: ImportedMesh
    let filename: String
    var existing: ImportedModel? = nil
    @Bindable var model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @State private var scale: Float = 1
    @State private var yUp = false
    @State private var corner = SIMD3<Double>(1, 1, 0)
    @State private var deformable = false
    @State private var fixedBase = true
    @State private var material = StructureMaterial.reinforcedConcrete
    @State private var preview: ImportedMesh.Preview?
    @State private var transformedMesh: ImportedMesh?
    @State private var error: String?
    @State private var busy = false
    @State private var acknowledged = false
    @State private var generation = 0
    @State private var resolution = Resolution.medium
    @State private var previewTask: Task<Void, Never>?
    private var h: Float { resolution.cellSize }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(existing == nil ? "Import" : "Update") \(filename)").font(.title2)
            ScrollView {
                Form {
                    Section("Geometry") {
                        Text(
                            "OBJ polygons must be triangulated or convex. Texture and visual material files are ignored."
                        ).font(.caption)
                        Picker("Source units", selection: $scale) {
                            Text("Metres").tag(Float(1.0))
                            Text("Centimetres").tag(Float(0.01))
                            Text("Millimetres").tag(Float(0.001))
                            Text("Feet").tag(Float(0.3048))
                            Text("Inches").tag(Float(0.0254))
                        }
                        Toggle("Y is the source up axis", isOn: $yUp)
                        ForEach(0..<3, id: \.self) { axis in
                            TextField(
                                "Corner \(["X", "Y", "Z"][axis]) (m)",
                                value: Binding(get: { corner[axis] }, set: { corner[axis] = $0 }),
                                format: .number)
                        }
                        Text("The model’s lowest corner is placed here. Simulation Z points upward.").font(
                            .caption)
                    }
                    Section("Behavior") {
                        Toggle("Deformable solid", isOn: $deformable).disabled(
                            existing != nil
                                || model.settings.scenario.structure != nil
                                    && existing?.behavior != .deformable
                        )
                        if model.settings.scenario.structure != nil && existing?.behavior != .deformable {
                            Text(
                                "A deformable structure already exists. Import into an empty layout to create a new deformable body."
                            ).font(.caption)
                        }
                        if existing != nil {
                            Text("The retained model keeps its rigid or deformable behavior.").font(.caption)
                        }
                        if deformable {
                            Picker("Material preset", selection: $material) {
                                ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                                if !StructureMaterial.presets.contains(material) {
                                    Text("Custom: \(material.name)").tag(material)
                                }
                            }
                            MaterialEditor(material: $material)
                            Toggle("Fix nodes at the model’s base", isOn: $fixedBase)
                            Text(
                                "Uses solid elements at the selected air cell size, with no reinforcement. Support and connection assumptions need review before running."
                            ).font(.caption)
                        } else {
                            Text(
                                "Rigid geometry reflects the blast and does not deform. Structural material properties have no effect on rigid obstacles."
                            ).font(.caption)
                        }
                    }
                    Section("Simulation preview") {
                        Picker("Grid", selection: $resolution) {
                            ForEach(Resolution.allCases) { Text($0.title).tag($0) }
                        }
                        Text(
                            "Applying uses this air grid for the layout. Source meshes are retained and regenerated on grid changes. Finer grids cost more memory and simulation time."
                        ).font(.caption)
                        Text("Air cells: \(h, format:.number) m · \(mesh.triangles.count) triangles")
                        Button(busy ? "Preparing…" : "Prepare preview", action: prepare).disabled(busy)
                        if !canApply {
                            Text(
                                "This source is detached or the structure has local edits. The preview samples the retained source; local geometry edits are not shown or overwritten. Applying is disabled."
                            ).foregroundStyle(.orange)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        if let preview {
                            Text("\(preview.occupiedCells) occupied cells · \(preview.boxes.count) regions")
                            Text(
                                "Dimensions: \(preview.bounds.size.x, format:.number) × \(preview.bounds.size.y, format:.number) × \(preview.bounds.size.z, format:.number) m"
                            )
                            if let transformedMesh {
                                ImportComparisonView(mesh: transformedMesh, preview: preview)
                            }
                            ForEach(preview.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(
                                    .orange)
                            }
                            Toggle("I have reviewed the resolution warnings", isOn: $acknowledged)
                        }
                    }
                }.formStyle(.grouped)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(existing == nil ? "Import" : "Apply") { commit() }.disabled(
                    preview == nil || preview?.occupiedCells == 0 || !acknowledged || busy || !canApply
                )
                .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 760, height: 820)
            .onChange(of: scale) { invalidate() }
            .onChange(of: yUp) { invalidate() }
            .onChange(of: corner) { invalidate() }
            .onAppear {
                resolution = model.settings.resolution
                if let existing {
                    scale = existing.scale
                    yUp = existing.yUp
                    corner = SIMD3<Double>(existing.corner)
                    deformable = existing.behavior == .deformable
                    if deformable, let body = model.settings.scenario.structure {
                        material = body.material
                        fixedBase = body.fixedBase
                    }
                }
            }
            .onChange(of: resolution) { invalidate() }
            .onDisappear { previewTask?.cancel() }
    }
    private func invalidate() {
        generation += 1
        previewTask?.cancel()
        busy = false
        preview = nil
        transformedMesh = nil
        acknowledged = false
        error = nil
    }
    private func prepare() {
        invalidate()
        busy = true
        let token = generation
        let mesh = mesh
        let scale = Float(scale)
        let yUp = yUp
        let corner = SIMD3<Float>(corner)
        let h = h
        let domain = model.settings.scenario.domainSize
        previewTask = Task {
            let sampling = Task.detached(priority: .userInitiated) {
                () -> Result<(ImportedMesh, ImportedMesh.Preview), Error> in
                Result {
                    let transformed = try mesh.transformed(scale: scale, yUp: yUp, corner: corner)
                    return (
                        transformed, try transformed.preview(cellSize: h, domain: domain, allowEmpty: true)
                    )
                }
            }
            let result = await withTaskCancellationHandler(
                operation: { await sampling.value }, onCancel: { sampling.cancel() })
            guard generation == token, !Task.isCancelled else { return }
            busy = false
            switch result {
            case .success(let value):
                transformedMesh = value.0
                preview = value.1
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    private var canApply: Bool { existing?.canRegenerate(model.settings.scenario.structure) ?? true }
    private func commit() {
        guard let preview, canApply else { return }
        do {
            let imported = ImportedModel(
                id: existing?.id ?? UUID(), name: filename, source: mesh, scale: Float(scale), yUp: yUp,
                corner: SIMD3<Float>(corner), behavior: deformable ? .deformable : .rigid, preview: preview)
            var candidate = model.settings.scenario
            try candidate.installImport(imported, material: material, fixedBase: fixedBase)
            // Validate every retained source before applying a layout-wide resolution change.
            candidate = try candidate.resamplingImports(cellSize: h)
            model.settings.resolution = resolution
            model.settings.scenario = candidate
            if deformable { model.settings.solidElementSize = h }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
