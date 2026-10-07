import BlastCore
import BlastRender
import SwiftUI

struct ModelImportView: View {
    let mesh: ImportedMesh
    let filename: String
    @Bindable var model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var yUp = false
    @State private var corner = SIMD3<Double>(1, 1, 0)
    @State private var deformable = false
    @State private var fixedBase = true
    @State private var material = StructureMaterial.reinforcedConcrete
    @State private var preview: ImportedMesh.Preview?
    @State private var error: String?
    @State private var busy = false
    @State private var acknowledged = false
    @State private var generation = 0
    @State private var resolution = Resolution.medium
    private var h: Float { resolution.cellSize }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(filename)").font(.title2)
            ScrollView {
                Form {
                    Section("Geometry") {
                        Text(
                            "OBJ polygons must be triangulated or convex. Texture and visual material files are ignored."
                        ).font(.caption)
                        Picker("Source units", selection: $scale) {
                            Text("Metres").tag(1.0)
                            Text("Centimetres").tag(0.01)
                            Text("Millimetres").tag(0.001)
                            Text("Feet").tag(0.3048)
                            Text("Inches").tag(0.0254)
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
                            model.settings.scenario.structure != nil)
                        if model.settings.scenario.structure != nil {
                            Text(
                                "A deformable structure already exists. Import into an empty layout to create a new deformable body."
                            ).font(.caption)
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
                            "Importing applies this air grid to the layout. A finer grid costs more memory and simulation time."
                        ).font(.caption)
                        Text("Air cells: \(h, format:.number) m · \(mesh.triangles.count) triangles")
                        Button(busy ? "Preparing…" : "Prepare preview", action: prepare).disabled(busy)
                        if let error { Text(error).foregroundStyle(.red) }
                        if let preview {
                            Text("\(preview.occupiedCells) occupied cells · \(preview.boxes.count) regions")
                            Text(
                                "Dimensions: \(preview.bounds.size.x, format:.number) × \(preview.bounds.size.y, format:.number) × \(preview.bounds.size.z, format:.number) m"
                            )
                            Canvas { context, size in
                                let bounds = preview.bounds
                                let width = max(bounds.size.x, h)
                                let depth = max(bounds.size.y, h)
                                let factor = min(Float(size.width) / width, Float(size.height) / depth)
                                for box in preview.boxes {
                                    let rect = CGRect(
                                        x: CGFloat((box.min.x - bounds.min.x) * factor),
                                        y: CGFloat((box.min.y - bounds.min.y) * factor),
                                        width: CGFloat(box.size.x * factor),
                                        height: CGFloat(box.size.y * factor))
                                    context.fill(Path(rect), with: .color(.blue.opacity(0.35)))
                                    context.stroke(Path(rect), with: .color(.blue), lineWidth: 0.5)
                                }
                            }.frame(height: 180).background(.black.opacity(0.06))
                            Text("Top view of occupied simulation volumes (X–Y), not the source mesh.").font(
                                .caption)
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
                Button("Import") { commit() }.disabled(preview == nil || !acknowledged || busy)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: 740)
            .onChange(of: scale) { invalidate() }
            .onChange(of: yUp) { invalidate() }
            .onChange(of: corner) { invalidate() }
            .onAppear { resolution = model.settings.resolution }
            .onChange(of: resolution) { invalidate() }
    }
    private func invalidate() {
        generation += 1
        preview = nil
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
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<ImportedMesh.Preview, Error> in
                Result {
                    try mesh.transformed(scale: scale, yUp: yUp, corner: corner).preview(
                        cellSize: h, domain: domain)
                }
            }.value
            busy = false
            guard generation == token else { return }
            switch result {
            case .success(let value): preview = value
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    private func commit() {
        guard let preview else { return }
        if !deformable && model.settings.scenario.boxes.count + preview.boxes.count > SceneRenderer.maxBoxes {
            error = "The combined layout exceeds the 2,048 rigid region limit."
            return
        }
        if deformable {
            guard model.settings.scenario.structure == nil else {
                error = "A structure already exists."
                return
            }
            var body = StructureModel(
                solids: preview.boxes, material: material, elementSize: h, fixedBase: fixedBase)
            body.solidReinforcement = Array(repeating: .none, count: preview.boxes.count)
            if fixedBase {
                let bounds = body.bounds
                body.supports = [
                    Box(
                        min: bounds.min - SIMD3(repeating: h * 0.01),
                        max: SIMD3(bounds.max.x + h * 0.01, bounds.max.y + h * 0.01, bounds.min.z + h * 0.01))
                ]
            }
            model.settings.resolution = resolution
            model.settings.scenario.structure = body
            model.settings.solidElementSize = h
        } else {
            model.settings.resolution = resolution
            model.settings.scenario.boxes.append(contentsOf: preview.boxes)
        }
        let note =
            "\(filename): sampled at \(preview.cellSize) m. \(preview.warnings.joined(separator: " ")) Re-import the source at a finer resolution to recover discarded geometry; changing the air grid alone cannot restore it."
        model.settings.scenario.importNotes = (model.settings.scenario.importNotes ?? []) + [note]
        dismiss()
    }
}
