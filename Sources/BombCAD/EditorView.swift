import BlastCore
import SwiftUI
import UniformTypeIdentifiers

/// The layout editor: rigid blocks, the deformable structure's walls and openings, and the
/// charge. Every change rebuilds the simulation from the start.
struct EditorView: View {
    @Bindable var model: SimulationModel

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
                ForEach(solids.indices, id: \.self) { index in
                    BoxRow(
                        title: name(of: solids[index], index: index), box: solidBinding(index), step: 0.125,
                        isSelected: model.selection == .solid(index),
                        select: { toggle(.solid(index)) }, remove: { model.removeSolid(at: index) })
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
                    Picker("Material", selection: $model.settings.material) {
                        ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                    }
                }
            } header: {
                Text("Deformable structure")
            } footer: {
                Text(
                    "Walls and slabs deform and break. Thin pieces are reinforced with a mat of bars in "
                        + "each face, stocky ones as columns; openings are cut out of them.")
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
    }

    private var solids: [Box] { model.settings.scenario.structure?.solids ?? [] }
    private var openings: [Box] { model.settings.scenario.structure?.openings ?? [] }

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
        Binding(
            get: { model.settings.scenario.boxes[index] },
            set: { model.settings.scenario.boxes[index] = $0 })
    }

    private func solidBinding(_ index: Int) -> Binding<Box> {
        Binding(
            get: { solids[index] },
            set: { box in model.editStructure { $0.solids[index] = box } })
    }

    private func openingBinding(_ index: Int) -> Binding<Box> {
        Binding(
            get: { openings[index] },
            set: { box in model.editStructure { $0.openings[index] = box } })
    }

    private func gaugeBinding(_ index: Int) -> Binding<BlastCore.Gauge> {
        Binding(
            get: { model.settings.scenario.gauges[index] },
            set: { model.settings.scenario.gauges[index] = $0 })
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
        return String(format: "%.2f × %.2f × %.2f m", size.x, size.y, size.z)
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
