import BlastCore
import BlastRender
import SwiftUI
import UniformTypeIdentifiers

struct ModelImportView: View {
    let mesh: ImportedMesh
    let filename: String
    var existing: ImportedModel? = nil
    struct Draft {
        var scale: Float
        var yUp: Bool
        var corner: SIMD3<Double>
        var resolution: Resolution
        var domain: SIMD3<Float>
        var deformable: Bool
        var fixedBase: Bool
        var material: StructureMaterial
        var partMaterials: [Int: StructureMaterial]
    }
    var draft: Draft?
    var chooseBuildingElements: ((Draft) -> Void)?
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
    @State private var selectedPartIDs: Set<Int> = []
    @State private var isolate = false
    @State private var colourByMaterial = false
    @State private var error: String?
    @State private var acknowledged = false
    @State private var resolution = Resolution.medium
    @State private var domainSize = SIMD3<Float>(64, 64, 32)
    @State private var sourceBounds: Box?
    @State private var initialized = false
    @State private var previewModel: ImportPreviewModel
    @State private var study = ImportResolutionStudy()
    @State private var profiles = ImportProfileStore()
    @State private var selectedProfile: UUID?
    @State private var profileName = ""
    @State private var profileMessage: String?
    @State private var exporting = false
    @State private var geometryExpanded = true
    @State private var behaviorExpanded = true
    @State private var partsExpanded = true
    init(
        mesh: ImportedMesh, filename: String, existing: ImportedModel? = nil, model: SimulationModel,
        draft: Draft? = nil, chooseBuildingElements: ((Draft) -> Void)? = nil
    ) {
        self.mesh = mesh
        self.filename = filename
        self.existing = existing
        self.draft = draft
        self.chooseBuildingElements = chooseBuildingElements
        self._model = Bindable(wrappedValue: model)
        self._previewModel = State(initialValue: ImportPreviewModel(source: mesh))
    }
    private var isBuilding: Bool { mesh.buildingElements != nil }
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
    private var size: SIMD3<Float>? {
        try? ImportPlacement.size(sourceBounds: sourceBounds ?? mesh.bounds, scale: scale, yUp: yUp)
    }
    private var memory: ImportMemoryEstimate {
        ImportMemoryEstimate(
            domain: domainSize, cellSize: h, detailed: model.settings.detailedCharge,
            refined: model.settings.sharpShocks,
            budget: Double(model.device?.recommendedMaxWorkingSetSize ?? 8_000_000_000) * 0.7)
    }
    private var materialCount: Int {
        let active = Set(preview?.boxPartIDs ?? [])
        return Set([material] + active.compactMap { partMaterials[$0] }).count
    }
    private var blocker: String? {
        if !canApply {
            return
                "This source is detached or has local geometry/support edits. Detach from the sidebar to keep independent edits, or undo them before applying."
        }
        if let placementError = previewModel.placementError {
            return "Placement checks unavailable for the staged layout: \(placementError)"
        }
        if !memory.fits {
            return
                "This grid exceeds the available air-memory budget. Choose a coarser grid or a smaller domain."
        }
        if deformable && materialCount > StructureModel.maxMaterials {
            return
                "\(materialCount) materials exceed the solver limit of \(StructureModel.maxMaterials). Reuse a material or reset selected parts to the default."
        }
        if isPreviewCurrent && preview?.occupiedCells == 0 {
            return "No occupied cells remain. Preview a finer grid or correct the source units."
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(existing == nil ? "Import" : "Update") \(filename)").font(.title2)
                Spacer()
                if let chooseBuildingElements {
                    Button("Choose IFC elements…") {
                        chooseBuildingElements(
                            Draft(
                                scale: scale, yUp: yUp, corner: corner,
                                resolution: resolution, domain: domainSize, deformable: deformable,
                                fixedBase: fixedBase, material: material, partMaterials: partMaterials))
                    }.disabled(!canApply)
                }
                Button("Export import report…") { exporting = true }.disabled(!isPreviewCurrent)
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    Form {
                        Section {
                            DisclosureGroup("Units & placement", isExpanded: $geometryExpanded) {
                                geometryControls
                            }
                        }
                        Section {
                            DisclosureGroup("Behavior & default material", isExpanded: $behaviorExpanded) {
                                behaviorControls
                            }
                        }
                        Section {
                            DisclosureGroup("Parts (\(mesh.parts.count))", isExpanded: $partsExpanded) {
                                ImportPartsView(
                                    parts: mesh.parts, preview: preview, previewIsCurrent: isPreviewCurrent,
                                    deformable: deformable, defaultMaterial: material, editable: canApply,
                                    focusedID: $selectedPartID, selectedIDs: $selectedPartIDs,
                                    assignments: $partMaterials,
                                    isolate: $isolate, colourByMaterial: $colourByMaterial)
                            }
                        }
                        if isBuilding {
                            Section {
                                IFCCompletenessView(mesh: mesh, preview: isPreviewCurrent ? preview : nil)
                            }
                        }
                        Section { DisclosureGroup("Reusable import profiles") { profileControls } }
                    }.formStyle(.grouped)
                }.frame(width: 365)
                VStack(alignment: .leading, spacing: 8) {
                    if let size {
                        Text(
                            "Model size: \(size.x, format: .number.precision(.fractionLength(0...4))) × \(size.y, format: .number.precision(.fractionLength(0...4))) × \(size.z, format: .number.precision(.fractionLength(0...4))) m"
                        ).font(.headline)
                    }
                    HStack {
                        Picker("Grid", selection: $resolution) {
                            ForEach(Resolution.allCases) { Text($0.title).tag($0) }
                        }.frame(maxWidth: 240)
                        Button(study.isRunning ? "Stop comparison" : "Compare grids") {
                            if study.isRunning {
                                study.cancel()
                            } else if let mesh = previewModel.transformedMesh, let preview, isPreviewCurrent {
                                study.compare(mesh: mesh, baseline: preview, domain: domainSize)
                            }
                        }.disabled(!isPreviewCurrent)
                    }
                    Text(memory.description + (memory.fits ? "" : " · exceeds budget")).font(.caption)
                        .foregroundStyle(memory.fits ? Color.secondary : .red)
                    Text(
                        "Apply uses this air grid for the whole layout and regenerates other attached imports."
                    ).font(.caption).foregroundStyle(.secondary)
                    if busy {
                        ProgressView("Updating preview…")
                    } else if isPreviewCurrent, let preview {
                        Text(
                            "Preview up to date · \(preview.occupiedCells) occupied cells · \(preview.boxes.count) regions"
                        ).font(.caption)
                    }
                    if let message = error ?? previewModel.error {
                        Label(message, systemImage: "exclamationmark.triangle").font(.caption)
                            .foregroundStyle(.red)
                        if previewModel.error != nil {
                            Button("Retry preview") { schedulePreview(immediately: true) }
                        }
                    }
                    if let preview, let transformedMesh = previewModel.transformedMesh {
                        if !isPreviewCurrent {
                            Text("Previous preview; latest settings are not shown yet.").font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ImportComparisonView(
                            mesh: transformedMesh, preview: preview, placement: previewModel.placementReport,
                            selectedPartID: selectedPartID, selectedPartIDs: selectedPartIDs,
                            isolate: isolate,
                            colourByMaterial: colourByMaterial && deformable, defaultMaterial: material,
                            partMaterials: partMaterials,
                            comparisons: study.rows, comparing: study.isRunning, domain: domainSize,
                            detailed: model.settings.detailedCharge, refined: model.settings.sharpShocks,
                            memoryBudget: memory.budget,
                            chooseGrid: { value in
                                if let r = Resolution.allCases.first(where: { $0.cellSize == value }) {
                                    resolution = r
                                }
                            },
                            canRefine: resolution != .fine, refine: { previewFiner() }
                        )
                        .opacity(isPreviewCurrent ? 1 : 0.4).allowsHitTesting(isPreviewCurrent)
                    } else {
                        ContentUnavailableView(
                            "Preview unavailable", systemImage: "cube.transparent",
                            description: Text(
                                "Check source units and placement. Use Expand domain to fit if the model lies outside the domain."
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            if let blocker { Text(blocker).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Toggle("I reviewed the geometry and placement warnings", isOn: $acknowledged).disabled(
                    !isPreviewCurrent
                ).font(.caption)
                Spacer()
                Button(applyTitle) { commit() }.disabled(
                    !isPreviewCurrent || (preview?.occupiedCells ?? 0) == 0 || !acknowledged || busy
                        || blocker != nil
                )
                .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 1120, height: 780)
            .onChange(of: scale) { schedulePreview() }.onChange(of: yUp) { schedulePreview() }
            .onChange(of: corner) { schedulePreview() }.onChange(of: resolution) { schedulePreview() }
            .onChange(of: domainSize) { schedulePreview() }.onChange(of: deformable) { schedulePreview() }
            .onChange(of: fixedBase) { schedulePreview() }.onChange(of: model.settings.scenario) {
                schedulePreview()
            }
            .onAppear {
                sourceBounds = mesh.bounds
                domainSize = model.settings.scenario.domainSize
                resolution = model.settings.resolution
                profileName = String(
                    URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.prefix(80))
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
                if let draft {
                    scale = draft.scale
                    yUp = draft.yUp
                    corner = draft.corner
                    resolution = draft.resolution
                    domainSize = draft.domain
                    deformable = draft.deformable
                    fixedBase = draft.fixedBase
                    material = draft.material
                    partMaterials = draft.partMaterials.filter { key, _ in
                        mesh.parts.contains { $0.id == key }
                    }
                }
                initialized = true
                schedulePreview()
            }
            .onDisappear {
                previewModel.cancel()
                study.cancel()
            }
            .fileExporter(
                isPresented: $exporting, document: ImportReportDocument(text: report),
                contentType: .plainText,
                defaultFilename: "\(filename)-import.txt"
            ) { result in
                if case .failure(let error) = result { self.error = error.localizedDescription }
            }
    }
    @ViewBuilder private var geometryControls: some View {
        Text(
            isBuilding
                ? "IFC elements remain separate products. Openings are retained in each element’s geometry; overlaps form rigid occupancy."
                : "Nested shells describe cavities. OBJ polygons must be triangulated or convex; visual material files are ignored."
        ).font(.caption)
        Picker("Source units", selection: $scale) {
            Text("Metres").tag(Float(1))
            Text("Centimetres").tag(Float(0.01))
            Text("Millimetres").tag(Float(0.001))
            Text("Feet").tag(Float(0.3048))
            Text("Inches").tag(Float(0.0254))
            if ![Float(1), 0.01, 0.001, 0.3048, 0.0254].contains(scale) {
                Text("Custom scale \(scale)").tag(scale)
            }
        }
        .disabled(isBuilding)
        Toggle("Y is the source up axis", isOn: $yUp).disabled(isBuilding)
        if isBuilding {
            Text(
                "IFC units and placements have been converted to metres, Z up. Physical building elements import as rigid obstacles."
            ).font(.caption)
        }
        if let size, !isBuilding {
            let longest = max(size.x, max(size.y, size.z))
            if longest < h * 2 {
                Text(
                    "The entire model is smaller than two air cells. Check source units; a small intended model may need a finer grid."
                ).font(.caption).foregroundStyle(.orange)
            } else if longest > max(domainSize.x, max(domainSize.y, domainSize.z)) * 4 {
                Text(
                    "This export is much larger than the domain. Check its units before expanding the domain."
                ).font(.caption).foregroundStyle(.orange)
            }
            if longest < h * 2 || longest > max(domainSize.x, max(domainSize.y, domainSize.z)) * 4 {
                HStack {
                    Button("Try metres") { scale = 1 }
                    Button("Try millimetres") { scale = 0.001 }
                }.controlSize(.small)
                Text("Unit corrections are your choice; they are never applied automatically.").font(.caption)
            }
        }
        ForEach(0..<3, id: \.self) { axis in
            TextField(
                "Corner \(["X","Y","Z"][axis]) (m)",
                value: Binding(get: { corner[axis] }, set: { corner[axis] = $0 }),
                format: .number.precision(.fractionLength(0...4)))
        }
        Text("The lowest corner is placed here; simulation Z points upward.").font(.caption)
        HStack {
            Button("Centre") { place(.center) }
            Button("On ground") { place(.ground) }
        }.controlSize(.small)
        Button("Expand domain to fit") { place(.expand) }.controlSize(.small)
        Text(
            "Domain: \(domainSize.x, format: .number.precision(.fractionLength(0...3))) × \(domainSize.y, format: .number.precision(.fractionLength(0...3))) × \(domainSize.z, format: .number.precision(.fractionLength(0...3))) m"
        ).font(.caption)
        if domainSize != model.settings.scenario.domainSize {
            Text("Expansion is staged until \(applyTitle).").font(.caption).foregroundStyle(.orange)
            Button("Undo expansion") { domainSize = model.settings.scenario.domainSize }
        }
    }
    @ViewBuilder private var behaviorControls: some View {
        Toggle("Deformable solid", isOn: $deformable).disabled(
            isBuilding || existing != nil
                || model.settings.scenario.structure != nil && existing?.behavior != .deformable)
        if !isBuilding && model.settings.scenario.structure != nil && existing?.behavior != .deformable {
            Text("A structure already exists. Use an empty layout for a new deformable body.").font(.caption)
        }
        if deformable {
            Picker("Default material", selection: $material) {
                ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                if !StructureMaterial.presets.contains(material) {
                    Text("Custom: \(material.name)").tag(material)
                }
            }
            DisclosureGroup("Advanced default properties") { MaterialEditor(material: $material) }
            Toggle("Fix nodes at the model’s base", isOn: $fixedBase)
            Text(
                "Solid elements use the air grid. Imports start without reinforcement. Review support and connection assumptions."
            ).font(.caption)
        } else {
            Text("Rigid obstacles reflect the blast and do not deform. Structural materials have no effect.")
                .font(.caption)
        }
    }
    @ViewBuilder private var profileControls: some View {
        Picker("Saved profile", selection: $selectedProfile) {
            Text("Select a profile").tag(Optional<UUID>.none)
            ForEach(profiles.profiles) { Text($0.name).tag(Optional($0.id)) }
        }
        HStack {
            Button("Load profile") { loadProfile() }.disabled(selectedProfile == nil)
            Button("Delete") {
                if let selectedProfile {
                    profiles.remove(id: selectedProfile)
                    self.selectedProfile = nil
                }
            }.disabled(selectedProfile == nil)
        }.controlSize(.small)
        TextField("Profile name", text: $profileName)
        Button("Save / update profile") { saveProfile() }.disabled(
            profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Text(
            "Saves units, up axis, behavior, support choice, default material and overrides matched by part name. Placement and grid stay specific to this session."
        ).font(.caption)
        if let profileMessage { Text(profileMessage).font(.caption) }
    }
    private func saveProfile() {
        do {
            let named = Dictionary(
                uniqueKeysWithValues: mesh.parts.compactMap { part in
                    partMaterials[part.id].map { (part.name, $0) }
                })
            try profiles.save(
                ImportProfile(
                    name: profileName, scale: scale, yUp: yUp, deformable: deformable,
                    fixedBase: fixedBase, material: material, namedMaterials: named))
            selectedProfile =
                profiles.profiles.first {
                    $0.name.caseInsensitiveCompare(
                        profileName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }?.id
            error = nil
            profileMessage = "Profile saved."
        } catch { self.error = error.localizedDescription }
    }
    private func loadProfile() {
        guard let profile = profiles.profiles.first(where: { $0.id == selectedProfile }) else { return }
        scale = isBuilding ? 1 : profile.scale
        yUp = isBuilding ? false : profile.yUp
        fixedBase = profile.fixedBase
        material = profile.material
        if !isBuilding && existing == nil && (model.settings.scenario.structure == nil || !profile.deformable)
        {
            deformable = profile.deformable
        }
        partMaterials = profile.assignments(for: mesh.parts)
        profileName = profile.name
        profileMessage =
            "Loaded profile; matched \(partMaterials.count) of \(profile.namedMaterials.count) named overrides. Settings are staged until \(applyTitle)."
        schedulePreview()
    }
    private var report: String {
        var text =
            "BombCAD import report\nFile: \(filename)\nScale: \(scale), Y-up: \(yUp)\nCorner (m): \(corner)\nGrid: \(h) m\n\(memory.description)\n\n"
        if let origin = mesh.buildingOrigin { text += "IFC original geometry origin (m): \(origin)\n" }
        text += IFCCompleteness.report(mesh: mesh, preview: isPreviewCurrent ? preview : nil)
        for note in mesh.buildingNotes ?? [] { text += note + "\n" }
        for part in mesh.parts {
            if let guid = part.ifcGlobalID {
                text += "IFC element: \(guid) · \(part.ifcClass ?? "") · \(part.storey ?? "No storey")\n"
            }
            text +=
                "Part: \(part.name) · \(deformable ? (partMaterials[part.id]?.name ?? "Model default: " + material.name) : "Rigid obstacle")\n"
        }
        for issue in preview?.diagnostics ?? [] {
            let names = mesh.parts.filter { (issue.partIDs ?? []).contains($0.id) }.map(\.name).joined(
                separator: ", ")
            text += "\n\(issue.title): \(issue.detail)\nAffected parts: \(names)\n"
        }
        for warning in preview?.warnings ?? [] { text += warning + "\n" }
        for issue in previewModel.placementReport?.issues ?? [] {
            text += "\n\(issue.title): \(issue.detail)\n"
        }
        if let placementError = previewModel.placementError {
            text += "\nPlacement checks unavailable: \(placementError)\n"
        }
        for row in study.rows {
            text +=
                "\nGrid \(row.cellSize) m: \(row.preview?.occupiedCells.description ?? row.error ?? "unavailable") cells\n"
        }
        return text
    }
    private func schedulePreview(immediately: Bool = false) {
        guard initialized else { return }
        acknowledged = false
        error = nil
        study.cancel(clear: true)
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
        guard let preview, canApply, isPreviewCurrent, acknowledged, !busy, blocker == nil else { return }
        do {
            guard !isBuilding || (!deformable && scale == 1 && !yUp) else {
                throw ImportedMesh.ImportError.invalid("IFC imports require metres, Z up and rigid behavior.")
            }
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
