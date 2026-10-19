import BlastCore
import SwiftUI
import simd

/// A DXF floor plan raised into a building: the plan's layers marked as walls (with their
/// construction), doors, windows or floor outlines, the storeys and heights given, and the walls
/// and openings found shown over the drawing; then the building is reviewed and placed as an IFC
/// building is (`ModelImportView`), as shells and panes or rigid obstacles.
struct FloorPlanImportFlow: View {
    let drawing: DXFDrawing
    let filename: String
    @Bindable var model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @State private var options: FloorPlan.Options
    @State private var mesh: ImportedMesh?
    @State private var draft: ModelImportView.Draft?
    @State private var revision = UUID()

    init(drawing: DXFDrawing, filename: String, model: SimulationModel) {
        self.drawing = drawing
        self.filename = filename
        self._model = Bindable(wrappedValue: model)
        var options = FloorPlan.Options()
        options.roles = FloorPlan.guessedRoles(drawing.layers)
        options.metresPerUnit = drawing.metresPerUnit ?? FloorPlanView.guessedUnit(drawing)
        self._options = State(initialValue: options)
    }

    var body: some View {
        if let mesh {
            ModelImportView(
                mesh: mesh, filename: filename, model: model, draft: draft,
                chooseBuildingElements: {
                    draft = $0
                    self.mesh = nil
                }, chooseBuildingElementsLabel: "Back to the plan…"
            )
            .id(revision)
        } else {
            FloorPlanView(
                drawing: drawing, filename: filename, options: $options, cancel: { dismiss() },
                raised: { building in
                    mesh = building
                    revision = UUID()
                })
        }
    }
}

struct FloorPlanView: View {
    let drawing: DXFDrawing
    let filename: String
    @Binding var options: FloorPlan.Options
    var cancel: () -> Void
    var raised: (ImportedMesh) -> Void
    @State private var error: String?

    /// Metres per unit where the header gives none: millimetres if the drawing spans over 200
    /// units, else metres (a house is 5–50 m across).
    static func guessedUnit(_ drawing: DXFDrawing) -> Double {
        let points = drawing.segments().flatMap { [$0.a, $0.b] }
        guard let first = points.first else { return 0.001 }
        let span = points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        return max(span.1.x - span.0.x, span.1.y - span.0.y) > 200 ? 0.001 : 1
    }

    private var analysis: FloorPlan.Analysis { FloorPlan.analyse(drawing, options: options) }
    private var counts: [String: Int] {
        Dictionary(grouping: drawing.segments(), by: \.layer).mapValues(\.count)
    }

    var body: some View {
        let plan = analysis
        VStack(alignment: .leading, spacing: 12) {
            Text("Raise \(filename) into a building").font(.title2)
            HStack(alignment: .top, spacing: 16) {
                Form {
                    Section("Drawing") {
                        Picker("Units", selection: $options.metresPerUnit) {
                            Text("Millimetres").tag(0.001)
                            Text("Centimetres").tag(0.01)
                            Text("Metres").tag(1.0)
                            Text("Inches").tag(0.0254)
                            Text("Feet").tag(0.3048)
                        }
                        if drawing.metresPerUnit == nil {
                            Text("The drawing does not say its units; check them against the plan's size.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("Storeys") {
                        Stepper(
                            "\(options.storeys) storey\(options.storeys == 1 ? "" : "s")",
                            value: $options.storeys, in: 1...12)
                        metres("Floor to floor", $options.storeyHeight)
                        metres("Floors and roof, thick", $options.slabThickness)
                        Toggle("Flat roof slab", isOn: $options.roof)
                        Toggle("Floors and roof inside the outer walls", isOn: $options.slabsInsideWalls)
                            .help(
                                "As a BIM model lays them: the outer walls run each storey's full height and the slabs sit between them. Off: the slabs lie over the whole outline, on the walls."
                            )
                        Toggle(
                            "Ground-bearing slab",
                            isOn: Binding(
                                get: { options.groundSlab > 0 }, set: { options.groundSlab = $0 ? 0.15 : 0 }))
                    }
                    Section("Openings") {
                        metres("Door head", $options.doorHead)
                        metres("Window sill", $options.windowSill)
                        metres("Window head", $options.windowHead)
                        Picker("Gaps with nothing drawn", selection: $options.gapKind) {
                            Text("Windows").tag(FloorPlan.OpeningKind.window)
                            Text("Doors").tag(FloorPlan.OpeningKind.door)
                        }
                    }
                    Section("Layers") {
                        ForEach(drawing.layers.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { layer in
                            layerRow(layer)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 430)
                VStack(alignment: .leading, spacing: 8) {
                    PlanPreview(drawing: drawing, plan: plan, metresPerUnit: options.metresPerUnit)
                        .frame(minWidth: 420, minHeight: 420)
                        .border(.separator)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.notes, id: \.self) { Text($0).font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 130)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("Walls must run square to the plan; angled and curved ones are left out.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button("Preview building") { raise(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.walls.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 1040, height: 760)
    }

    private func metres(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
            .help("\(title), in metres")
    }

    @ViewBuilder private func layerRow(_ layer: String) -> some View {
        let role = Binding<String>(
            get: {
                switch options.roles[layer] ?? .ignore {
                case .ignore: "ignore"
                case .wall: "wall"
                case .door: "door"
                case .window: "window"
                case .slab: "slab"
                }
            },
            set: { kind in
                switch kind {
                case "wall": options.roles[layer] = .wall(.cavityBrickBlock)
                case "door": options.roles[layer] = .door
                case "window": options.roles[layer] = .window
                case "slab": options.roles[layer] = .slab
                default: options.roles[layer] = .ignore
                }
            })
        VStack(alignment: .leading, spacing: 4) {
            Picker("\(layer) (\(counts[layer] ?? 0))", selection: role) {
                Text("Ignore").tag("ignore")
                Text("Walls").tag("wall")
                Text("Doors").tag("door")
                Text("Windows").tag("window")
                Text("Floor outline").tag("slab")
            }
            if case .wall(let construction) = options.roles[layer] {
                Picker(
                    "Construction",
                    selection: Binding(
                        get: { construction.name },
                        set: { name in
                            if let chosen = FloorPlan.Construction.presets.first(where: { $0.name == name }) {
                                options.roles[layer] = .wall(chosen)
                            }
                        })
                ) {
                    ForEach(FloorPlan.Construction.presets) { Text($0.name).tag($0.name) }
                }.font(.caption)
            }
            if options.roles[layer].map({ $0 != .ignore }) ?? false {
                Picker(
                    "On",
                    selection: Binding(
                        get: { options.layerStoreys[layer] ?? -1 },
                        set: { options.layerStoreys[layer] = $0 < 0 ? nil : $0 })
                ) {
                    Text("Every storey").tag(-1)
                    ForEach(0..<options.storeys, id: \.self) { Text(FloorPlan.storeyName($0)).tag($0) }
                }.font(.caption)
            }
        }
    }

    private func raise(_ plan: FloorPlan.Analysis) {
        do {
            let elements = try FloorPlan.buildingElements(plan, options: options)
            let corner = plan.bounds.min
            raised(
                try ImportedMesh(
                    buildingElements: elements,
                    notes: Array(plan.notes.prefix(100)).map { String($0.prefix(2000)) },
                    origin: SIMD3(corner.x, corner.y, 0)))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The drawing in grey with the walls found filled and the openings coloured: windows blue, doors
/// red, gaps taken as openings dashed.
struct PlanPreview: View {
    let drawing: DXFDrawing
    let plan: FloorPlan.Analysis
    let metresPerUnit: Double

    var body: some View {
        Canvas { context, size in
            let segments = drawing.segments().map { ($0.a * metresPerUnit, $0.b * metresPerUnit) }
            guard let first = segments.first else { return }
            var lo = first.0
            var hi = first.0
            for (a, b) in segments {
                lo = simd_min(lo, simd_min(a, b))
                hi = simd_max(hi, simd_max(a, b))
            }
            let span = max(hi.x - lo.x, hi.y - lo.y, 1e-6)
            let scale = 0.92 * min(size.width, size.height) / span
            func point(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(
                    x: 0.04 * size.width + (p.x - lo.x) * scale,
                    y: size.height - 0.04 * size.height - (p.y - lo.y) * scale)
            }
            var faint = Path()
            for (a, b) in segments {
                faint.move(to: point(a))
                faint.addLine(to: point(b))
            }
            context.stroke(faint, with: .color(.gray.opacity(0.5)), lineWidth: 0.5)
            for wall in plan.walls {
                let r = wall.rectangle
                let rect = CGRect(
                    x: point(r.min).x, y: point(SIMD2(r.min.x, r.max.y)).y,
                    width: (r.max.x - r.min.x) * scale, height: (r.max.y - r.min.y) * scale)
                context.fill(Path(rect), with: .color(.primary.opacity(0.55)))
            }
            for opening in plan.openings where opening.wall < plan.walls.count {
                var wall = plan.walls[opening.wall]
                wall.from = opening.from
                wall.to = opening.to
                let r = wall.rectangle
                let rect = CGRect(
                    x: point(r.min).x, y: point(SIMD2(r.min.x, r.max.y)).y,
                    width: (r.max.x - r.min.x) * scale, height: (r.max.y - r.min.y) * scale)
                let colour: Color = opening.kind == .window ? .blue : .red
                context.fill(Path(rect), with: .color(colour.opacity(opening.layer == nil ? 0.35 : 0.8)))
            }
        }
        .accessibilityLabel(
            "The plan, with \(plan.walls.count) walls and \(plan.openings.count) openings found")
    }
}
