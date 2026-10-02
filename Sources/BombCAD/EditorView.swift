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
