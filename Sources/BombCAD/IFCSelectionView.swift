import BlastCore
import SwiftUI

/// Chooses exact GUIDs before tessellation. Existing projects can revisit the retained IFC source.
struct IFCImportFlow: View {
    let filename: String
    var existing: ImportedModel?
    @Bindable var model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @State private var prepared: IFCImporter.Prepared?
    @State private var mesh: ImportedMesh?
    @State private var previousMesh: ImportedMesh?
    @State private var preparing = false
    @State private var retryID = UUID()
    @State private var revision = UUID()
    @State private var draft: ModelImportView.Draft?
    @State private var error: String?
    init(
        prepared: IFCImporter.Prepared? = nil, mesh: ImportedMesh? = nil, filename: String,
        existing: ImportedModel? = nil, model: SimulationModel
    ) {
        self.filename = filename
        self.existing = existing
        self._model = Bindable(wrappedValue: model)
        self._prepared = State(initialValue: prepared)
        self._mesh = State(initialValue: mesh)
        self._previousMesh = State(initialValue: mesh)
    }
    var body: some View {
        Group {
            if let mesh {
                ModelImportView(
                    mesh: mesh, filename: filename, existing: existing, model: model, draft: draft,
                    chooseBuildingElements: {
                        draft = $0
                        previousMesh = mesh
                        self.mesh = nil
                    }
                )
                .id(revision)
            } else if let prepared {
                IFCSelectionView(
                    prepared: prepared, filename: filename,
                    initialIDs: previousMesh?.buildingSelection.map { Set($0.includedIDs) },
                    cancel: { if let previousMesh { mesh = previousMesh } else { dismiss() } },
                    converted: {
                        mesh = $0
                        previousMesh = $0
                        revision = UUID()
                    })
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose IFC elements").font(.title2)
                    if preparing { ProgressView("Reading retained IFC inventory…") }
                    if let error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Button("Back to preview") { mesh = previousMesh }
                        if !preparing { Button("Retry") { retryID = UUID() } }
                    }
                }.padding(24).frame(width: 900, height: 500)
                    .task(id: retryID) {
                        guard prepared == nil, let data = previousMesh?.buildingSourceData else { return }
                        preparing = true
                        error = nil
                        do {
                            let work = Task.detached { try await IFCImporter.prepare(data) }
                            let inventory = try await withTaskCancellationHandler(
                                operation: { try await work.value }, onCancel: { work.cancel() })
                            try Task.checkCancellation()
                            prepared = inventory
                        } catch is CancellationError {} catch { self.error = error.localizedDescription }
                        preparing = false
                    }
            }
        }
    }
}

struct IFCSelectionView: View {
    let prepared: IFCImporter.Prepared
    let filename: String
    let cancel: () -> Void
    let converted: (ImportedMesh) -> Void
    @State private var included: Set<String>
    @State private var search = ""
    @State private var building = "*"
    @State private var storey = "*"
    @State private var type = "*"
    @State private var error: String?
    @State private var busy = false
    @State private var failedElement: String?
    @State private var conversion: Task<Void, Never>?
    init(
        prepared: IFCImporter.Prepared, filename: String, initialIDs: Set<String>? = nil,
        cancel: @escaping () -> Void, converted: @escaping (ImportedMesh) -> Void
    ) {
        self.prepared = prepared
        self.filename = filename
        self.cancel = cancel
        self.converted = converted
        self._included = State(initialValue: initialIDs ?? prepared.defaultIDs)
    }
    private var filtered: [IFCImporter.Element] {
        prepared.inventory.filter { e in
            (building == "*" || (e.buildingID ?? "") == building)
                && (storey == "*" || (e.storeyID ?? "") == storey)
                && (type == "*" || e.ifcClass == type)
                && (search.isEmpty
                    || [e.name, e.id, e.ifcClass, e.building ?? "", e.storey ?? ""].contains {
                        $0.localizedCaseInsensitiveContains(search)
                    })
        }
    }
    private func groups(
        _ id: KeyPath<IFCImporter.Element, String?>,
        name: KeyPath<IFCImporter.Element, String?>
    ) -> [(String, String)] {
        var values: [String: String] = [:]
        for e in prepared.inventory { values[e[keyPath: id] ?? ""] = e[keyPath: name] ?? "Unassigned" }
        let counts = Dictionary(grouping: values, by: { $0.value }).mapValues(\.count)
        return values.map { key, label in
            (key, (counts[label] ?? 0) > 1 && !key.isEmpty ? label + " · " + key : label)
        }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("Choose elements from \(filename)").font(.title2)
                Text(
                    "Choose what becomes a rigid obstacle. Only checked elements are converted. Openings remain subtracted from their hosts; materials and structural connections are not inferred."
                )
                HStack {
                    Picker("Building", selection: $building) {
                        Text("All buildings").tag("*")
                        ForEach(groups(\.buildingID, name: \.building), id: \.0) {
                            Text($0.1).tag($0.0)
                        }
                    }
                    Picker("Storey", selection: $storey) {
                        Text("All storeys").tag("*")
                        ForEach(groups(\.storeyID, name: \.storey), id: \.0) {
                            Text($0.1).tag($0.0)
                        }
                    }
                    Picker("Type", selection: $type) {
                        Text("All types").tag("*")
                        ForEach(Set(prepared.inventory.map(\.ifcClass)).sorted(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                TextField("Find an element, type, storey or GlobalId", text: $search)
                HStack {
                    Button("Include matching") { included.formUnion(filtered.filter(\.supported).map(\.id)) }
                        .disabled(!filtered.contains(where: \.supported))
                    Button("Exclude matching") { included.subtract(filtered.map(\.id)) }
                    Button("Include all supported") { included = prepared.defaultIDs }
                    Button("Clear all") { included = [] }
                    Spacer()
                    Text("\(included.count) chosen · \(filtered.count) shown").font(.caption)
                }.controlSize(.small)
                Text(
                    "Filters only change this list. Use Include matching or Exclude matching to change the import."
                ).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered) { e in
                            Toggle(
                                isOn: Binding(
                                    get: { included.contains(e.id) },
                                    set: { if $0 { included.insert(e.id) } else { included.remove(e.id) } })
                            ) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.name)
                                    Text(
                                        [e.ifcClass, e.building, e.storey].compactMap { $0 }.joined(
                                            separator: " · ")
                                    ).font(.caption).foregroundStyle(.secondary)
                                    Text(
                                        e.id
                                            + (e.supported
                                                ? (e.hasChildren
                                                    ? " · Has child elements; choose children separately"
                                                    : "") : " · Unsupported type, excluded")
                                    )
                                    .font(.caption).foregroundStyle(e.supported ? Color.secondary : .orange)
                                    .textSelection(.enabled)
                                }
                            }.toggleStyle(.checkbox).disabled(!e.supported)
                        }
                        if filtered.isEmpty { Text("No matching elements.").foregroundStyle(.secondary) }
                    }.padding(8)
                }.frame(maxHeight: .infinity)
                Text(
                    "Inventory follows the IFC decomposition tree. Uncontained products may be absent; compare with the source CAD model. Choose up to 1,024 supported elements. Choices and the original IFC file are saved with the project. Each subset starts at its own bounds; review placement after changing choices."
                ).font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let failedElement {
                    Button("Exclude invalid element and retry") {
                        included.remove(failedElement)
                        convert()
                    }.disabled(included.subtracting([failedElement]).isEmpty)
                    Text(
                        "This removes only the named failed element. The import remains staged until you review the preview and apply."
                    ).font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Converting chosen elements…") }
            }.disabled(busy)
            HStack {
                Button(busy ? "Cancel conversion" : "Cancel") {
                    if busy { conversion?.cancel() } else { cancel() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Preview chosen elements") { convert() }
                    .disabled(busy || included.isEmpty || included.count > 1024).keyboardShortcut(
                        .defaultAction)
            }
        }.padding(24).frame(width: 1040, height: 740)
            .onChange(of: building) { storey = "*" }
            .onDisappear { conversion?.cancel() }
    }
    private func convert() {
        busy = true
        error = nil
        failedElement = nil
        let choices = included
        conversion = Task {
            do {
                let work = Task.detached(priority: .userInitiated) {
                    try await IFCImporter.convert(prepared, includedIDs: choices)
                }
                let mesh = try await withTaskCancellationHandler(
                    operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation()
                busy = false
                converted(mesh)
            } catch is CancellationError { busy = false } catch let failure as IFCImporter.ElementFailure {
                busy = false
                error = failure.localizedDescription
                failedElement = failure.id
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
