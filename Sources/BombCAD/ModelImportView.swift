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
    @State private var partMaterials: [Int: StructureMaterial] = [:]
    @State private var selectedPartID: Int?
    @State private var error: String?
    @State private var acknowledged = false
    @State private var resolution = Resolution.medium
    @State private var domainSize = SIMD3<Float>(64, 64, 32)
    @State private var sourceBounds: Box?
    @State private var initialized = false
    @State private var previewModel: ImportPreviewModel
    init(mesh: ImportedMesh, filename: String, existing: ImportedModel? = nil, model: SimulationModel) {
        self.mesh = mesh
        self.filename = filename
        self.existing = existing
        self._model = Bindable(wrappedValue: model)
        self._previewModel = State(initialValue: ImportPreviewModel(source: mesh))
    }
    private var preview: ImportedMesh.Preview? { previewModel.preview }
    private var busy: Bool { previewModel.isPreparing }
    private var currentRequest: ImportPreviewRequest {
        ImportPreviewRequest(
            scale: scale, yUp: yUp, corner: SIMD3<Float>(corner), cellSize: h, domain: domainSize,
            scene: model.settings.scenario, editingID: existing?.id, fixedBase: deformable ? fixedBase : nil)
    }
    private var isPreviewCurrent: Bool { previewModel.isCurrent && previewModel.request == currentRequest }
    private var h: Float { resolution.cellSize }
    private var applyTitle: String { existing == nil ? "Import" : "Apply" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(existing == nil ? "Import" : "Update") \(filename)").font(.title2)
            ScrollView {
                Form {
                    Section("Geometry") {
                        Text(
                            "OBJ polygons must be triangulated or convex. Texture and visual material files are ignored."
                        ).font(.caption)
                        Text(
                            "Nested shells are treated as cavities. Boolean-union contained solid parts before export if they should fill material."
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
                                format: .number.precision(.fractionLength(0...4)))
                        }
                        Text("The model’s lowest corner is placed here. Simulation Z points upward.").font(
                            .caption)
                        HStack {
                            Button("Centre horizontally") { place(.center) }
                            Button("Place on ground") { place(.ground) }
                            Button("Expand domain to fit") { place(.expand) }
                        }.controlSize(.small)
                        Text(
                            "Domain: \(domainSize.x, format:.number.precision(.fractionLength(0...4))) × \(domainSize.y, format:.number.precision(.fractionLength(0...4))) × \(domainSize.z, format:.number.precision(.fractionLength(0...4))) m"
                        ).font(.caption)
                        if domainSize != model.settings.scenario.domainSize {
                            Text(
                                "Domain expansion is pending until \(applyTitle); existing geometry stays inside the domain."
                            ).font(.caption).foregroundStyle(.orange)
                            Button("Undo domain expansion") {
                                domainSize = model.settings.scenario.domainSize
                            }
                        }
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
                    Section("Parts (\(mesh.parts.count))") {
                        ImportPartsView(
                            parts: mesh.parts, preview: preview, previewIsCurrent: isPreviewCurrent,
                            deformable: deformable, defaultMaterial: material, editable: canApply,
                            selectedID: $selectedPartID, assignments: $partMaterials)
                    }
                    Section("Simulation preview") {
                        Picker("Grid", selection: $resolution) {
                            ForEach(Resolution.allCases) { Text($0.title).tag($0) }
                        }
                        Text(
                            "Applying uses this air grid for the layout. Source meshes are retained and regenerated on grid changes. Finer grids cost more memory and simulation time."
                        ).font(.caption)
                        Text(
                            "Air cells: \(h, format:.number.precision(.fractionLength(0...4))) m · \(mesh.triangles.count) triangles"
                        )
                        if busy {
                            ProgressView("Updating preview…")
                        } else if isPreviewCurrent {
                            Label("Preview up to date", systemImage: "checkmark.circle").foregroundStyle(
                                .secondary)
                        }
                        Text(
                            "Preview updates automatically after a brief pause. \(applyTitle) changes the simulation."
                        ).font(.caption).foregroundStyle(.secondary)
                        if !canApply {
                            Text(
                                "This source is detached or the structure has local edits. The preview samples the retained source; local geometry edits are not shown or overwritten. Applying is disabled."
                            ).foregroundStyle(.orange)
                        }
                        if let message = error ?? previewModel.error {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            if previewModel.error != nil {
                                Button("Retry preview") { schedulePreview(immediately: true) }
                            }
                        }
                        if let preview {
                            Text("\(preview.occupiedCells) occupied cells · \(preview.boxes.count) regions")
                            Text(
                                "Dimensions: \(preview.bounds.size.x, format:.number.precision(.fractionLength(0...4))) × \(preview.bounds.size.y, format:.number.precision(.fractionLength(0...4))) × \(preview.bounds.size.z, format:.number.precision(.fractionLength(0...4))) m"
                            )
                            if !isPreviewCurrent {
                                Text(
                                    "Showing the previous preview; it does not represent your latest settings."
                                ).font(.caption).foregroundStyle(.orange)
                            }
                            if let transformedMesh = previewModel.transformedMesh {
                                ImportComparisonView(
                                    mesh: transformedMesh, preview: preview,
                                    placement: previewModel.placementReport, selectedPartID: selectedPartID,
                                    canRefine: resolution != .fine,
                                    refine: { previewFiner() }
                                )
                                .opacity(isPreviewCurrent ? 1 : 0.4).allowsHitTesting(isPreviewCurrent)
                            }
                            ForEach(preview.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(
                                    .orange)
                            }
                            if let placement = previewModel.placementReport {
                                ForEach(placement.warnings, id: \.self) {
                                    Text($0).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Toggle("I have reviewed the geometry and placement warnings", isOn: $acknowledged)
                                .disabled(
                                    !isPreviewCurrent)
                        }
                    }
                }.formStyle(.grouped)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(applyTitle) { commit() }.disabled(
                    !isPreviewCurrent || preview?.occupiedCells == 0 || !acknowledged || busy || !canApply
                )
                .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 760, height: 820)
            .onChange(of: scale) { schedulePreview() }
            .onChange(of: yUp) { schedulePreview() }
            .onChange(of: corner) { schedulePreview() }
            .onAppear {
                sourceBounds = mesh.bounds
                domainSize = model.settings.scenario.domainSize
                resolution = model.settings.resolution
                if let existing {
                    scale = existing.scale
                    yUp = existing.yUp
                    corner = SIMD3<Double>(existing.corner)
                    deformable = existing.behavior == .deformable
                    partMaterials = existing.partMaterials ?? [:]
                    if deformable, let body = model.settings.scenario.structure {
                        material = body.material
                        fixedBase = body.fixedBase
                    }
                }
                initialized = true
                schedulePreview()
            }
            .onChange(of: resolution) { schedulePreview() }
            .onChange(of: domainSize) { schedulePreview() }
            .onChange(of: deformable) { schedulePreview() }
            .onChange(of: fixedBase) { schedulePreview() }
            .onChange(of: model.settings.scenario) { schedulePreview() }
            .onDisappear { previewModel.cancel() }
    }
    private func schedulePreview(immediately: Bool = false) {
        guard initialized else { return }
        acknowledged = false
        error = nil
        previewModel.update(currentRequest, delay: immediately ? .zero : .milliseconds(350))
    }
    private func previewFiner() {
        switch resolution {
        case .coarse: resolution = .medium
        case .medium: resolution = .fine
        case .fine: break
        }
    }
    private enum Placement { case center, ground, expand }
    private func place(_ action: Placement) {
        do {
            let size = try ImportPlacement.size(
                sourceBounds: sourceBounds ?? mesh.bounds, scale: scale, yUp: yUp)
            let point = SIMD3<Float>(corner)
            switch action {
            case .center:
                corner = SIMD3<Double>(
                    try ImportPlacement.centeredFootprint(size: size, corner: point, domain: domainSize))
            case .ground: corner = SIMD3<Double>(ImportPlacement.onGround(corner: point))
            case .expand:
                let bytesPerCell = model.settings.detailedCharge ? 73.0 : 57.0
                let refinement =
                    model.settings.sharpShocks ? Double(SolverConfiguration().refinementMemory) : 0
                let budget = Double(model.device?.recommendedMaxWorkingSetSize ?? 8_000_000_000) * 0.7
                domainSize = try ImportPlacement.expandedDomain(
                    size: size, corner: point, current: domainSize, cellSize: h,
                    maxCells: max(0, (budget - refinement) / bytesPerCell))
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private var canApply: Bool { existing?.canRegenerate(model.settings.scenario.structure) ?? true }
    private func commit() {
        guard let preview, canApply, isPreviewCurrent, acknowledged, !busy else { return }
        do {
            let imported = ImportedModel(
                id: existing?.id ?? UUID(), name: filename, source: mesh, scale: Float(scale), yUp: yUp,
                corner: SIMD3<Float>(corner), behavior: deformable ? .deformable : .rigid, preview: preview,
                partMaterials: partMaterials.isEmpty ? nil : partMaterials)
            var candidate = model.settings.scenario
            candidate.domainSize = domainSize
            try candidate.installImport(imported, material: material, fixedBase: fixedBase)
            // Validate every retained source before applying a layout-wide resolution change.
            candidate = try candidate.resamplingImports(cellSize: h)
            let domainExpanded = candidate.domainSize != model.settings.scenario.domainSize
            model.settings.resolution = resolution
            model.settings.scenario = candidate
            model.selection = .imported(imported.id)
            if domainExpanded { model.camera = .framing(candidate) }
            if deformable { model.settings.solidElementSize = h }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
