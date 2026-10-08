import BlastCore
import SwiftUI
import UniformTypeIdentifiers

/// The layout editor: rigid blocks, the deformable structure's walls and openings, and the
/// charge. Every change rebuilds the simulation from the start.
struct EditorView: View {
    @Bindable var model: SimulationModel
    @State private var showAllImportedRegions = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                        .disabled(!model.canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                        .disabled(!model.canRedo)
                }
            }

            if let imports = model.settings.scenario.importedModels, !imports.isEmpty {
                Section("Imported models") {
                    if model.isPreparingImports { ProgressView("Resampling source geometry…") }
                    ForEach(imports) { imported in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                imported.name,
                                systemImage: model.selection == .imported(imported.id) ? "scope" : "cube.box"
                            ).font(.headline)
                            Text(
                                "\(imported.isAttached ? imported.behavior.rawValue.capitalized : "Detached") · \(imported.preview.cellSize, format:.number) m sampling"
                            ).font(.caption)
                            HStack {
                                Button("Inspect / edit source…") { model.inspectImport(id: imported.id) }
                                if imported.isAttached {
                                    Button("Detach geometry") { model.detachImport(id: imported.id) }
                                }
                            }
                            if imported.behavior == .deformable,
                                let part = model.structuralParts.first(where: { $0.id.modelID == imported.id }
                                )
                            {
                                Button("Edit structural parts") { model.selection = .part(part.id) }
                            }
                            Button(
                                imported.isAttached ? "Remove model" : "Remove saved source",
                                role: .destructive
                            ) { model.removeImport(id: imported.id) }
                            ForEach(imported.preview.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Text(
                        "Retained sources regenerate when the grid changes. Detaching keeps the current geometry and local edits, and stops source regeneration."
                    ).font(.caption)
                }
            }
            Section("Resolution warnings") {
                ForEach(model.settings.scenario.importNotes ?? [], id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
                        .orange)
                }
                let h = model.settings.resolution.cellSize
                let thin = (model.settings.scenario.boxes + solids).filter { box in
                    (0..<3).contains { box.size[$0] < 2 * h }
                }.count
                if thin > 0 {
                    Label(
                        "\(thin) regions have a dimension below two air cells (\(2 * h, format: .number) m). Thin walls or small gaps may be under-resolved. Imported voxel regions can also reflect the sampling grid rather than individual features.",
                        systemImage: "exclamationmark.triangle"
                    ).font(.caption).foregroundStyle(.orange)
                }
                if thin == 0 && (model.settings.scenario.importNotes ?? []).isEmpty {
                    Text(
                        "Air cells: \(h, format: .number) m. Features and gaps smaller than a cell can disappear; compare finer grids before trusting results."
                    ).font(.caption)
                }
            }

            Section {
                ForEach(model.settings.scenario.boxes.indices, id: \.self) { index in
                    BoxRow(
                        title: "Block \(index + 1)", box: blockBinding(index), step: 0.25,
                        isSelected: model.selection == .block(index),
                        select: { toggle(.block(index)) }, remove: { model.removeBlock(at: index) })
                }
                Button("Add Block", systemImage: "plus") { model.addBlock() }
            } header: {
                Text("Rigid blocks")
            } footer: {
                Text("Blocks reflect the blast but never move or break.")
            }

            Section {
                if !model.structuralParts.isEmpty {
                    StructuralPartsEditor(model: model)
                    Toggle("Show all sampled regions", isOn: $showAllImportedRegions)
                    Text(
                        "Region edits, reinforcement and custom supports detach the structure. Undo restores its source link."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visibleSolidIndices, id: \.self) { index in
                    BoxRow(
                        title: name(of: solids[index], index: index), box: solidBinding(index), step: 0.125,
                        isSelected: model.selection == .solid(index),
                        select: { toggle(.solid(index)) }, remove: { model.removeSolid(at: index) })
                    if model.selection == .solid(index) {
                        Picker("Material", selection: materialBinding(index)) {
                            ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                            if !StructureMaterial.presets.contains(materialBinding(index).wrappedValue) {
                                Text("Custom").tag(materialBinding(index).wrappedValue)
                            }
                        }
                        .font(.callout)
                        .padding(.leading, 18)
                        Picker("Elements", selection: elementKindBinding(index)) {
                            Text("Solid").tag(ElementKind.solid)
                            Text("Shell").tag(ElementKind.shell)
                        }
                        .pickerStyle(.segmented)
                        .font(.callout)
                        .padding(.leading, 18)
                        .help(
                            "Mesh this piece with solid elements (where stress through the thickness matters, "
                                + "near a charge) or shells; the two kinds are tied where they meet.")
                        DisclosureGroup("Material properties") {
                            MaterialEditor(material: materialBinding(index))
                        }
                        ReinforcementEditor(spec: reinforcementBinding(index))
                    }
                }
                Button("Add Wall", systemImage: "plus") { model.addWall() }
                if !solids.isEmpty {
                    ForEach(openings.indices, id: \.self) { index in
                        BoxRow(
                            title: "Opening \(index + 1)", box: openingBinding(index), step: 0.125,
                            isSelected: model.selection == .opening(index),
                            select: { toggle(.opening(index)) }, remove: { model.removeOpening(at: index) })
                    }
                    Button("Add Opening", systemImage: "plus") { model.addOpening() }
                    Picker("Main material", selection: mainMaterialBinding) {
                        ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                        if !StructureMaterial.presets.contains(model.settings.material) {
                            Text("Custom: \(model.settings.material.name)").tag(model.settings.material)
                        }
                    }
                    DisclosureGroup("Main material properties") {
                        MaterialEditor(material: mainMaterialBinding)
                    }
                    Picker("Elements", selection: mainElementKindBinding) {
                        Text("Solid").tag(ElementKind.solid)
                        Text("Shell").tag(ElementKind.shell)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Joints between materials can open", isOn: bondBinding)
                        .help(
                            "Where two materials meet, as masonry against its concrete frame, hold them "
                                + "together only by the bond of mortar to concrete (0.2 MPa), so infill can come away."
                        )
                    Toggle("Masonry as units and mortar joints", isOn: unitJointsBinding)
                        .help(
                            "Where solid elements are no more than half a course high, mesh brickwork and "
                                + "blockwork as units with mortar joints that open at the mortar's bond and "
                                + "slide by friction. Otherwise the wall has one strength throughout."
                        )
                }
            } header: {
                Text("Deformable structure")
            } footer: {
                Text(
                    "Walls and slabs deform and break. Each piece can have its own material; thin pieces "
                        + "are reinforced with a mat of bars in each face and stocky ones as columns unless "
                        + "set otherwise. Openings are cut out of them. Shell elements (with beams for "
                        + "columns) run many times faster, but every piece must then be a wall, slab or column."
                )
            }

            if !solids.isEmpty {
                Section {
                    Toggle(
                        "Restrain the base on the ground",
                        isOn: Binding(
                            get: { model.settings.scenario.structure?.fixedBase ?? false },
                            set: { model.setFixedBase($0) }))
                    if model.settings.scenario.structure?.fixedBase == true {
                        AnchorageEditor(
                            title: "Base connection",
                            law: Binding(
                                get: { model.settings.scenario.structure?.baseAnchorage },
                                set: { model.setBaseAnchorage($0) }))
                    }
                    ForEach(supports.indices, id: \.self) { index in
                        BoxRow(
                            title: "Support \(index + 1)", box: supportBinding(index), step: 0.125,
                            isSelected: model.selection == .support(index),
                            select: { toggle(.support(index)) }, remove: { model.removeSupport(at: index) })
                        if model.selection == .support(index) {
                            AnchorageEditor(
                                title: "Support connection",
                                law: Binding(
                                    get: { model.settings.scenario.structure?.anchorage(ofSupport: index) },
                                    set: { model.setSupportAnchorage($0, at: index) }))
                            if model.settings.scenario.structure?.anchorage(ofSupport: index) != nil,
                                let area = model.supportBearingArea(at: index)
                            {
                                if area > 0 {
                                    Text(
                                        "Connected bearing area: \(area, format: .number.precision(.fractionLength(0...4))) m²"
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        "No active bearing points in this region. Move or resize the strip, check overlapping clamps, or choose Clamped."
                                    )
                                    .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text(
                                "Finite connections act on exposed lower faces of solids and lower edges of walls or vertical columns within this region. Keep the region a thin horizontal strip. It selects initial bearing points; the bearing plane extends horizontally after separation. A region on a vertical face or a horizontal shell slab needs an ideal clamp."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Add Support", systemImage: "plus") { model.addSupport() }
                } header: {
                    Text("Structural supports")
                } footer: {
                    Text(
                        "Clamped support regions hold their nodes still and override finite connections where they overlap. The last finite region wins over earlier finite regions. Finite connections can open, slide and fail, retaining bearing and friction after separation. Add Support places a strip at the selected part’s base; select it to choose a connection. Ground restraint and support regions are independent."
                    )
                }
            }

            Section {
                ForEach(model.settings.scenario.gauges.indices, id: \.self) { index in
                    GaugeRow(
                        gauge: gaugeBinding(index), isSelected: model.selection == .gauge(index),
                        select: { toggle(.gauge(index)) }, remove: { model.removeGauge(at: index) })
                }
                Button("Add Gauge", systemImage: "plus") { model.addGauge() }
                    .disabled(!model.canAddGauge)
            } header: {
                Text("Gauges")
            } footer: {
                Text(
                    "Gauges record the air pressure where they stand. With one selected, clicking the "
                        + "ground in placing mode moves it instead of the charge.")
            }

            Section("Charge") {
                Toggle("Click the ground to move it", isOn: $model.isPlacingCharge)
                LabeledContent("Position") {
                    Text(
                        String(
                            format: "%.2f, %.2f, %.2f m", model.settings.chargePosition.x,
                            model.settings.chargePosition.y, model.settings.chargePosition.z)
                    )
                    .monospacedDigit()
                }
                if model.chargeIsBlocked {
                    Label(
                        "The charge is inside a block or wall and will release no energy.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isPreparingImports)

    }

    private var solids: [Box] { model.settings.scenario.structure?.solids ?? [] }
    private var openings: [Box] { model.settings.scenario.structure?.openings ?? [] }

    private var supports: [Box] { model.settings.scenario.structure?.supports ?? [] }

    private var visibleSolidIndices: [Int] {
        guard !showAllImportedRegions else { return Array(solids.indices) }
        if case .part(let id) = model.selection {
            return model.structuralParts.first(where: { $0.id == id })?.regions ?? []
        }
        let owned = Set(model.structuralParts.flatMap(\.regions))
        return solids.indices.filter { !owned.contains($0) || model.selection == .solid($0) }
    }

    private var mainMaterialBinding: Binding<StructureMaterial> {
        Binding(get: { model.settings.material }, set: { model.setStructureMaterial($0) })
    }

    private var mainElementKindBinding: Binding<ElementKind> {
        Binding(
            get: { model.settings.elementKind },
            set: { kind in
                // Preserve the existing mixed-mesh sizing rules, then make it a local edit.
                let size = kind == .shell ? SimulationSettings.shellSize : model.settings.solidElementSize
                if kind == .shell {
                    model.settings.solidElementSize = model.settings.scenario.structure?.elementSize ?? size
                }
                model.editStructure {
                    $0.elementKind = kind
                    $0.elementSize = size
                }
            })
    }

    private func supportBinding(_ index: Int) -> Binding<Box> {
        regionBinding(index, keyPath: \.supports)
    }

    /// SwiftUI can read an old row's binding while undo/deletion removes it from the form.
    private func regionBinding(_ index: Int, keyPath: WritableKeyPath<StructureModel, [Box]>) -> Binding<Box>
    {
        let original =
            (model.settings.scenario.structure?[keyPath: keyPath] ?? []).safeElement(at: index)
            ?? Box(min: .zero, max: SIMD3(repeating: 1))
        return Binding(
            get: {
                (model.settings.scenario.structure?[keyPath: keyPath] ?? []).safeElement(at: index)
                    ?? original
            },
            set: { box in
                model.editStructure { body in
                    guard body[keyPath: keyPath].indices.contains(index) else { return }
                    body[keyPath: keyPath][index] = box
                }
            })
    }

    private func toggle(_ selection: EditSelection) {
        model.selection = model.selection == selection ? nil : selection
    }

    /// Calls a piece a wall, slab or column according to its proportions.
    private func name(of box: Box, index: Int) -> String {
        let size = box.size
        let thin = (0..<3).min { size[$0] < size[$1] } ?? 0
        let isSlab =
            size[thin] <= 0.6 && (0..<3).filter { $0 != thin }.allSatisfy { size[$0] >= 3 * size[thin] }
        let kind = !isSlab ? "Column" : (thin == 2 ? "Slab" : "Wall")
        return "\(kind) \(index + 1)"
    }

    private func blockBinding(_ index: Int) -> Binding<Box> {
        let original =
            model.settings.scenario.boxes.safeElement(at: index)
            ?? Box(min: .zero, max: SIMD3(repeating: 1))
        return Binding(
            get: { model.settings.scenario.boxes.safeElement(at: index) ?? original },
            set: {
                guard model.settings.scenario.boxes.indices.contains(index) else { return }
                model.settings.scenario.boxes[index] = $0
            })
    }

    private func solidBinding(_ index: Int) -> Binding<Box> {
        regionBinding(index, keyPath: \.solids)
    }

    private func openingBinding(_ index: Int) -> Binding<Box> {
        regionBinding(index, keyPath: \.openings)
    }

    private var bondBinding: Binding<Bool> {
        Binding(
            get: { model.settings.scenario.structure?.interfaceBond != nil },
            set: { on in model.editStructure { $0.interfaceBond = on ? StructureModel.masonryBond : nil } })
    }

    private var unitJointsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.scenario.structure?.unitJoints ?? true },
            set: { on in model.editStructure { $0.unitJoints = on } })
    }

    private func elementKindBinding(_ index: Int) -> Binding<ElementKind> {
        Binding(
            get: { model.settings.scenario.structure?.elementKind(of: index) ?? .solid },
            set: { model.setElementKind($0, ofSolid: index) })
    }

    private func materialBinding(_ index: Int) -> Binding<StructureMaterial> {
        Binding(
            get: { model.settings.scenario.structure?.material(of: index) ?? .reinforcedConcrete },
            set: { model.setMaterial($0, ofSolid: index) })
    }

    private func reinforcementBinding(_ index: Int) -> Binding<Reinforcement> {
        Binding(
            get: { model.settings.scenario.structure?.reinforcement(of: index) ?? .automatic },
            set: { model.setReinforcement($0, ofSolid: index) })
    }

    private func gaugeBinding(_ index: Int) -> Binding<BlastCore.Gauge> {
        let original = model.settings.scenario.gauges.safeElement(at: index) ?? Gauge("Removed", at: .zero)
        return Binding(
            get: { model.settings.scenario.gauges.safeElement(at: index) ?? original },
            set: {
                guard model.settings.scenario.gauges.indices.contains(index) else { return }
                model.settings.scenario.gauges[index] = $0
            })
    }

}

/// How the selected piece of the structure is reinforced, with the quantities for a custom
/// arrangement in the units engineers use.
struct ReinforcementEditor: View {
    @Binding var spec: Reinforcement

    private enum Kind: String, CaseIterable {
        case automatic = "Automatic"
        case none = "None"
        case mats = "Mats"
        case column = "Column"
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch spec {
                case .automatic: .automatic
                case .none: .none
                case .mats: .mats
                case .column: .column
                }
            },
            set: { kind in
                switch kind {
                case .automatic: spec = .automatic
                case .none: spec = .none
                case .mats: spec = .mats(areaPerMetre: 565e-6, depth: 0.04, bothFaces: true)
                case .column: spec = .column(longitudinal: 0.02, ties: 0.004)
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Reinforcement", selection: kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            switch spec {
            case .mats(let area, let depth, let bothFaces):
                number("Bar area each way", "mm²/m", Double(area * 1e6)) {
                    spec = .mats(areaPerMetre: Float(max($0, 0)) * 1e-6, depth: depth, bothFaces: bothFaces)
                }
                number("Depth to bars", "mm", Double(depth * 1000)) {
                    spec = .mats(areaPerMetre: area, depth: Float(max($0, 1)) / 1000, bothFaces: bothFaces)
                }
                Toggle(
                    "Both faces",
                    isOn: Binding(
                        get: { bothFaces },
                        set: { spec = .mats(areaPerMetre: area, depth: depth, bothFaces: $0) }))
            case .column(let longitudinal, let ties):
                number("Along its length", "%", Double(longitudinal * 100)) {
                    spec = .column(longitudinal: Float(max($0, 0)) / 100, ties: ties)
                }
                number("Ties", "%", Double(ties * 100)) {
                    spec = .column(longitudinal: longitudinal, ties: Float(max($0, 0)) / 100)
                }
            case .automatic, .none:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.leading, 18)
    }

    private func number(
        _ title: String, _ unit: String, _ value: Double, set: @escaping @MainActor (Double) -> Void
    )
        -> some View
    {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(
                    "", value: Binding(get: { value }, set: set),
                    format: .number.precision(.fractionLength(0...2))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// One gauge in the editor: a title row that selects it, and its name and position when selected.
private struct GaugeRow: View {
    @Binding var gauge: BlastCore.Gauge
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: select) {
                    HStack {
                        Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                        Text(gauge.name)
                        Spacer()
                        Text(
                            String(
                                format: "%.2f, %.2f, %.2f m", gauge.position.x, gauge.position.y,
                                gauge.position.z)
                        )
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if isSelected {
                TextField("Name", text: $gauge.name)
                    .textFieldStyle(.roundedBorder)
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        Text("X").foregroundStyle(.secondary)
                        Text("Y").foregroundStyle(.secondary)
                        Text("Z").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Position")
                        field(axis: 0)
                        field(axis: 1)
                        field(axis: 2)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func field(axis: Int) -> some View {
        TextField(
            "",
            value: Binding(
                get: { Double(gauge.position[axis]) },
                set: { gauge.position[axis] = max((Float($0) / 0.05).rounded() * 0.05, 0) }),
            format: .number.precision(.fractionLength(0...2))
        )
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 62)
        .labelsHidden()
    }
}

/// One box in the editor: a title row that selects it, and its position and size when selected.
private struct BoxRow: View {
    let title: String
    @Binding var box: Box
    let step: Float
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: select) {
                    HStack {
                        Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                        Text(title)
                        Spacer()
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if isSelected {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        Text("X").foregroundStyle(.secondary)
                        Text("Y").foregroundStyle(.secondary)
                        Text("Z").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Corner")
                        field(position(0))
                        field(position(1))
                        field(position(2))
                    }
                    GridRow {
                        Text("Size")
                        field(size(0))
                        field(size(1))
                        field(size(2))
                    }
                }
                .font(.callout)
            }
        }
    }

    private var summary: String {
        let size = box.size
        return String(format: "%.3g × %.3g × %.3g m", size.x, size.y, size.z)
    }

    private func field(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 62)
            .labelsHidden()
    }

    private func snap(_ value: Double) -> Float { (Float(value) / step).rounded() * step }

    /// Moves the box, keeping its size.
    private func position(_ axis: Int) -> Binding<Double> {
        Binding(
            get: { Double(box.min[axis]) },
            set: {
                let size = box.size[axis]
                box.min[axis] = max(snap($0), 0)
                box.max[axis] = box.min[axis] + size
            })
    }

    /// Resizes the box, keeping its low corner.
    private func size(_ axis: Int) -> Binding<Double> {
        Binding(
            get: { Double(box.size[axis]) },
            set: { box.max[axis] = box.min[axis] + max(snap($0), step) })
    }
}

/// A run's histories saved as comma-separated values.
struct ResultsDocument: FileDocument {
    static let readableContentTypes = [UTType.commaSeparatedText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// A layout saved as JSON.
struct ScenarioDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    var scenario: Scenario

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        scenario = try JSONDecoder().decode(Scenario.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Self.encode(scenario))
    }

    static func encode(_ scenario: Scenario) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(scenario)
    }
}

extension Array {
    fileprivate func safeElement(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
