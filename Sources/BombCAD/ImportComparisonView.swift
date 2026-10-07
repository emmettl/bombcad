import BlastCore
import SceneKit
import SwiftUI
import simd

/// The canvas stays fixed; diagnostics and grid comparisons scroll beneath it.
struct ImportComparisonView: View {
    let mesh: ImportedMesh
    let preview: ImportedMesh.Preview
    var placement: ImportPlacementReport? = nil
    var selectedPartID: Int? = nil
    var selectedPartIDs: Set<Int> = []
    var isolate = false
    var colourByMaterial = false
    var defaultMaterial = StructureMaterial.reinforcedConcrete
    var partMaterials: [Int: StructureMaterial] = [:]
    var comparisons: [ImportResolutionStudy.Row] = []
    var comparing = false
    var domain = SIMD3<Float>(64, 64, 32)
    var detailed = false
    var refined = false
    var memoryBudget = 8_000_000_000.0
    var chooseGrid: (Float) -> Void = { _ in }
    let canRefine: Bool
    let refine: () -> Void
    @State private var showSource = true
    @State private var showSimulation = true
    @State private var showIssues = true
    @State private var showContext = true
    @State private var showReference = true
    @State private var warningsForSelected = false
    @State private var selected: ImportFocus?
    @State private var resetRequest = 0
    private var diagnostics: [ImportedMesh.Diagnostic] {
        guard warningsForSelected, !selectedPartIDs.isEmpty else { return preview.diagnostics }
        return preview.diagnostics.filter { !selectedPartIDs.isDisjoint(with: $0.partIDs ?? []) }
    }
    private var placementIssues: [ImportPlacementReport.Issue] {
        let issues = placement?.issues ?? []
        guard warningsForSelected, !selectedPartIDs.isEmpty, let ids = preview.boxPartIDs else {
            return issues
        }
        let boxes = preview.boxes.enumerated().compactMap { n, box in
            ids.indices.contains(n) && selectedPartIDs.contains(ids[n]) ? box : nil
        }
        return issues.filter { issue in
            boxes.contains { all($0.min .<= issue.bounds.max) && all(issue.bounds.min .<= $0.max) }
        }
    }
    private var palette: ImportMaterialPalette {
        ImportMaterialPalette(parts: mesh.parts, defaultMaterial: defaultMaterial, assignments: partMaterials)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Source", isOn: $showSource)
                Toggle("Simulation", isOn: $showSimulation)
                Toggle("Warnings", isOn: $showIssues)
                if placement != nil { Toggle("Context", isOn: $showContext) }
                Toggle("Scale grid", isOn: $showReference)
                Spacer()
                Button("Reset view") {
                    selected = nil
                    resetRequest += 1
                }.controlSize(.small)
            }.toggleStyle(.checkbox).font(.caption)
            ImportSceneView(
                mesh: mesh, preview: preview, placement: placement, showSource: showSource,
                showSimulation: showSimulation, showIssues: showIssues, showContext: showContext,
                selected: selected, selectedPartID: selectedPartID,
                selectedPartIDs: selectedPartIDs, isolate: isolate, colourByMaterial: colourByMaterial,
                defaultMaterial: defaultMaterial, partMaterials: partMaterials, showReference: showReference,
                diagnostics: diagnostics, placementIssues: placementIssues, resetRequest: resetRequest
            )
            .frame(height: 310).clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(
                "3D source and simulation comparison. Selected parts are green; orange resolution risks and overlaps, red missing geometry or blocked charges, purple connectivity issues."
            )
            Text(
                "Drag to orbit · scroll to zoom. Scale grid: \(ImportReferenceGrid.step(for: preview.bounds), format: .number.precision(.fractionLength(0...3))) m spacing. Green: selected · orange: risks · red: geometry loss/charge · purple: contact."
            ).font(.caption).foregroundStyle(.secondary)
            if isolate {
                Text("Isolated preview · all parts will import.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if colourByMaterial {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading) {
                            ForEach(Array(palette.materials.enumerated()), id: \.offset) { n, material in
                                HStack {
                                    Circle().fill(Color(nsColor: ImportMaterialPalette.color(n))).frame(
                                        width: 10, height: 10)
                                    Text(material.name).font(.caption)
                                }
                            }
                        }
                    }
                    if comparing { ProgressView("Comparing all three grids…") }
                    if !comparisons.isEmpty { comparisonRows }
                    HStack {
                        Text("Warnings to review").font(.headline)
                        Spacer()
                        Picker("Warning scope", selection: $warningsForSelected) {
                            Text("All parts").tag(false)
                            Text("Selected parts").tag(true)
                        }.labelsHidden().frame(width: 140).disabled(selectedPartIDs.isEmpty)
                    }
                    if warningsForSelected {
                        Text(
                            "Geometry warnings use source part IDs; placement filtering uses overlapping sampled regions."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    if let selected {
                        Text("Selected: \(selected.title). \(selected.detail)").font(.caption)
                            .foregroundStyle(selected.color)
                    }
                    if !diagnostics.isEmpty {
                        HStack {
                            Text("Affected geometry (approximate)").font(.subheadline.bold())
                            Spacer()
                            Button("Preview finer grid", action: refine).disabled(!canRefine)
                        }
                        recommendation
                        warningGroup(
                            "Potential geometry loss", issues: diagnostics.filter { $0.kind == .missing })
                        warningGroup("Resolution risks", issues: diagnostics.filter { $0.kind != .missing })
                    } else {
                        Text("No localized geometry warnings in this scope.").font(.caption)
                    }
                    if let placement {
                        Text("Placement · \(placement.componentCount) sampled components").font(
                            .subheadline.bold())
                        if placementIssues.isEmpty {
                            Text("No placement issues in the checked scope.").font(.caption)
                        }
                        ForEach(placementIssues) { focusButton(.placement($0)) }
                        if placement.checksIncomplete {
                            Text("Placement checks reached a limit; highlighting is incomplete.").font(
                                .caption
                            ).foregroundStyle(.orange)
                        }
                    }
                    Text("Whole-model notes").font(.caption.bold())
                    ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    ForEach(placement?.warnings ?? [], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }.onChange(of: preview) { focusPart() }.onChange(of: placement) { focusPart() }
            .onChange(of: selectedPartID) { focusPart() }.onChange(of: selectedPartIDs) {
                if selectedPartIDs.isEmpty { warningsForSelected = false }
                focusPart()
            }
            .onChange(of: warningsForSelected) { selected = nil }
            .onChange(of: isolate) {
                if isolate { warningsForSelected = true }
                focusPart()
            }
            .onAppear { focusPart() }
    }
    @ViewBuilder private var recommendation: some View {
        if let minimum = diagnostics.compactMap(\.minimumSize).min() {
            let candidates: [Float] = [0.5, 0.25, 0.125]
            if let h = candidates.first(where: { 2 * $0 <= minimum }) {
                Text(
                    "Smallest measured feature/gap: \(minimum, format: .number.precision(.fractionLength(0...4))) m. A \(h) m grid provides at least two cells across that measured dimension."
                ).font(.caption)
                Button("Preview suggested \(h) m grid") { chooseGrid(h) }
            } else {
                Text(
                    "The smallest measured dimension is \(minimum, format: .number.precision(.fractionLength(0...4))) m; even the finest grid cannot give it two cells. Simplify/enlarge the feature or review the source before relying on it."
                ).font(.caption).foregroundStyle(.orange)
            }
        }
        Text(
            "These sampled measurements do not guarantee resolution of every feature. Compare grids; costs are shown before Apply."
        ).font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var comparisonRows: some View {
        Text("Grid comparison · sampled volume").font(.subheadline.bold())
        let reference = Float(preview.occupiedCells) * pow(preview.cellSize, 3)
        let finest = comparisons.filter { $0.preview != nil }.min { $0.cellSize < $1.cellSize }
        let finestCounts = finest?.counts() ?? [:]
        ForEach(comparisons) { row in
            let rowCounts = row.counts()
            let memory = ImportMemoryEstimate(
                domain: domain, cellSize: row.cellSize, detailed: detailed, refined: refined,
                budget: memoryBudget)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(row.cellSize, format: .number.precision(.fractionLength(0...3))) m").bold()
                    if let volume = row.volume {
                        Text(
                            "\(row.preview?.occupiedCells ?? 0) cells · \(volume, format: .number.precision(.fractionLength(0...4))) m³"
                        )
                        if reference > 0 {
                            Text(String(format: "%+.1f%%", 100 * (volume - reference) / reference))
                        }
                    }
                    Spacer()
                    Button("Use grid") { chooseGrid(row.cellSize) }.disabled(row.preview == nil)
                        .accessibilityLabel("Use \(row.cellSize) m grid")
                }.font(.caption)
                Text(memory.description + (memory.fits ? "" : " · exceeds budget")).font(.caption)
                    .foregroundStyle(memory.fits ? Color.secondary : .red)
                if let error = row.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let finest, row.preview != nil {
                    let restored = finestCounts.keys.filter {
                        finestCounts[$0, default: 0] > 0 && rowCounts[$0, default: 0] == 0
                    }
                    if !restored.isEmpty {
                        Text(
                            "Absent here, present at \(finest.cellSize) m: "
                                + mesh.parts.filter { restored.contains($0.id) }.prefix(12).map(\.name)
                                .joined(separator: ", ")
                                + (restored.count > 12 ? " (plus \(restored.count - 12) more)" : "")
                        ).font(.caption).foregroundStyle(.orange)
                    }
                }
            }.padding(6).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
        }
        Text(
            "Percent changes are relative to the currently chosen grid. A stable volume does not prove the geometry is accurate."
        ).font(.caption).foregroundStyle(.secondary)
    }
    private func focusPart() {
        let parts = mesh.parts.filter {
            selectedPartIDs.contains($0.id) || (selectedPartIDs.isEmpty && $0.id == selectedPartID)
        }
        guard let first = parts.first else {
            selected = nil
            return
        }
        let bounds = parts.dropFirst().reduce(mesh.bounds(of: first)) { b, part in
            let other = mesh.bounds(of: part)
            return Box(min: simd_min(b.min, other.min), max: simd_max(b.max, other.max))
        }
        selected = .part(
            id: selectedPartID ?? first.id, bounds: bounds,
            name: parts.count == 1 ? first.name : "\(parts.count) selected parts")
    }
    @ViewBuilder private func warningGroup(_ title: String, issues: [ImportedMesh.Diagnostic]) -> some View {
        if !issues.isEmpty {
            Text("\(title) (\(issues.count))").font(.subheadline.bold()).padding(.top, 4)
            ForEach(issues) { focusButton(.geometry($0)) }
        }
    }
    private func focusButton(_ focus: ImportFocus) -> some View {
        Button {
            selected = selected == focus ? nil : focus
            showIssues = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(focus.title, systemImage: selected == focus ? "scope" : "exclamationmark.triangle")
                    .foregroundStyle(focus.color)
                Text(focus.detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                .background(
                    selected == focus ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}

struct ImportMaterialPalette {
    var materials: [StructureMaterial]
    var indices: [Int: Int]
    init(
        parts: [ImportedMesh.Part], defaultMaterial: StructureMaterial, assignments: [Int: StructureMaterial]
    ) {
        materials = [defaultMaterial]
        indices = [:]
        for part in parts {
            let material = assignments[part.id] ?? defaultMaterial
            if let index = materials.firstIndex(of: material) {
                indices[part.id] = index
            } else {
                indices[part.id] = materials.count
                materials.append(material)
            }
        }
    }
    static func color(_ n: Int) -> NSColor {
        let colors: [NSColor] = [
            .systemBlue, .systemOrange, .systemPurple, .systemPink, .systemYellow, .systemTeal, .systemIndigo,
            .systemBrown,
        ]
        return colors[n % colors.count]
    }
}

enum ImportReferenceGrid {
    static func step(for bounds: Box) -> Float {
        let size = max(bounds.size.x, bounds.size.y)
        guard size.isFinite, size > 24 else { return 1 }
        let raw = size / 16
        let power = pow(Float(10), floor(log10(raw)))
        return [Float(1), 2, 5, 10].map { $0 * power }.first { $0 >= raw } ?? power * 10
    }
}

private enum ImportFocus: Equatable {
    case geometry(ImportedMesh.Diagnostic)
    case placement(ImportPlacementReport.Issue)
    case part(id: Int, bounds: Box, name: String)
    var bounds: Box {
        switch self {
        case .geometry(let d): d.bounds
        case .placement(let d): d.bounds
        case .part(_, let bounds, _): bounds
        }
    }
    var title: String {
        switch self {
        case .geometry(let d): d.title
        case .placement(let d): d.title
        case .part(_, _, let name): name
        }
    }
    var detail: String {
        switch self {
        case .geometry(let d): d.detail
        case .placement(let d): d.detail
        case .part: "Selected source part, highlighted in green."
        }
    }
    var color: Color {
        switch self {
        case .geometry(let d): d.kind == .missing ? .red : .orange
        case .placement(let d): d.isCritical ? .red : d.kind == .overlap ? .orange : .purple
        case .part: .green
        }
    }
}

private struct ImportSceneView: NSViewRepresentable {
    let mesh: ImportedMesh
    let preview: ImportedMesh.Preview
    let placement: ImportPlacementReport?
    let showSource: Bool
    let showSimulation: Bool
    let showIssues: Bool
    let showContext: Bool
    let selected: ImportFocus?
    let selectedPartID: Int?
    let selectedPartIDs: Set<Int>
    let isolate: Bool
    let colourByMaterial: Bool
    let defaultMaterial: StructureMaterial
    let partMaterials: [Int: StructureMaterial]
    let showReference: Bool
    let diagnostics: [ImportedMesh.Diagnostic]
    let placementIssues: [ImportPlacementReport.Issue]
    let resetRequest: Int
    final class Coordinator {
        var mesh: ImportedMesh?
        var preview: ImportedMesh.Preview?
        var placement: ImportPlacementReport?
        var selected: ImportFocus?
        var partID: Int?
        var selectedIDs: Set<Int> = []
        var isolate = false
        var colourByMaterial = false
        var defaultMaterial: StructureMaterial?
        var partMaterials: [Int: StructureMaterial] = [:]
        var diagnostics: [ImportedMesh.Diagnostic] = []
        var placementIssues: [ImportPlacementReport.Issue] = []
        var resetRequest = -1
        let camera = SCNNode()
        let source = SCNNode()
        let simulation = SCNNode()
        let issues = SCNNode()
        let surroundings = SCNNode()
        let ground = SCNNode()
        let reference = SCNNode()
        let part = SCNNode()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        context.coordinator.camera.camera = SCNCamera()
        view.scene?.rootNode.addChildNode(context.coordinator.camera)
        view.scene?.rootNode.addChildNode(context.coordinator.source)
        view.scene?.rootNode.addChildNode(context.coordinator.simulation)
        view.scene?.rootNode.addChildNode(context.coordinator.issues)
        view.scene?.rootNode.addChildNode(context.coordinator.surroundings)
        view.scene?.rootNode.addChildNode(context.coordinator.ground)
        view.scene?.rootNode.addChildNode(context.coordinator.reference)
        view.scene?.rootNode.addChildNode(context.coordinator.part)
        view.pointOfView = context.coordinator.camera
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        let geometryChanged = c.mesh != mesh || c.preview?.bounds != preview.bounds
        let changed =
            c.mesh != mesh || c.preview != preview || c.placement != placement
            || c.selectedIDs != selectedPartIDs || c.isolate != isolate
            || c.colourByMaterial != colourByMaterial
            || c.defaultMaterial != defaultMaterial || c.partMaterials != partMaterials
            || c.diagnostics != diagnostics || c.placementIssues != placementIssues
        if changed {
            c.mesh = mesh
            c.preview = preview
            c.placement = placement
            c.selectedIDs = selectedPartIDs
            c.isolate = isolate
            c.colourByMaterial = colourByMaterial
            c.defaultMaterial = defaultMaterial
            c.partMaterials = partMaterials
            c.diagnostics = diagnostics
            c.placementIssues = placementIssues
            c.surroundings.geometry = boxGeometry(placement?.contextVolumes ?? [])
            c.surroundings.geometry?.materials = [material(.lightGray, alpha: 0.35, wire: true)]
            c.surroundings.renderingOrder = 19
            let b = preview.bounds
            let padding = max(max(b.size.x, b.size.y) * 0.2, 1)
            c.ground.geometry = SCNPlane(
                width: CGFloat(b.size.x + 2 * padding), height: CGFloat(b.size.y + 2 * padding))
            let floor = material(.lightGray, alpha: 0.12)
            floor.writesToDepthBuffer = false
            c.ground.geometry?.materials = [floor]
            c.ground.position = SCNVector3((b.min.x + b.max.x) * 0.5, (b.min.y + b.max.y) * 0.5, 0)
            c.ground.renderingOrder = -10
            c.reference.geometry = referenceGeometry()
            let gridMaterial = material(.lightGray, alpha: 0.35)
            gridMaterial.writesToDepthBuffer = false
            c.reference.geometry?.materials = [gridMaterial]
            c.reference.renderingOrder = 10
            let visibleParts = mesh.parts.filter {
                !isolate || selectedPartIDs.isEmpty || selectedPartIDs.contains($0.id)
            }
            c.source.geometry = sourceGeometry(indices: visibleParts.flatMap(\.triangleIndices))
            for node in c.simulation.childNodes { node.removeFromParentNode() }
            c.simulation.geometry = nil
            let owners = preview.boxPartIDs ?? Array(repeating: 0, count: preview.boxes.count)
            let palette = ImportMaterialPalette(
                parts: mesh.parts, defaultMaterial: defaultMaterial, assignments: partMaterials)
            var groups: [Int: [Box]] = [:]
            for (n, box) in preview.boxes.enumerated() where owners.indices.contains(n) {
                if isolate && !selectedPartIDs.isEmpty && !selectedPartIDs.contains(owners[n]) { continue }
                groups[colourByMaterial ? palette.indices[owners[n], default: 0] : 0, default: []].append(box)
            }
            for index in groups.keys.sorted() {
                let node = SCNNode(geometry: boxGeometry(groups[index]!))
                node.geometry?.materials = [material(ImportMaterialPalette.color(index), alpha: 0.45)]
                c.simulation.addChildNode(node)
            }
            for node in c.issues.childNodes { node.removeFromParentNode() }
            for issue in diagnostics {
                let node = SCNNode(
                    geometry: boxGeometry([issue.bounds], minimumExtent: preview.cellSize * 0.15))
                node.geometry?.materials = [
                    material(issue.kind == .missing ? .systemRed : .systemOrange, alpha: 0.9, wire: true)
                ]
                node.renderingOrder = 20
                c.issues.addChildNode(node)
            }
            for issue in placementIssues {
                let node = SCNNode(
                    geometry: boxGeometry([issue.bounds], minimumExtent: preview.cellSize * 0.15))
                node.geometry?.materials = [
                    material(
                        issue.isCritical
                            ? .systemRed : issue.kind == .overlap ? .systemOrange : .systemPurple, alpha: 0.9,
                        wire: true)
                ]
                node.renderingOrder = 21
                c.issues.addChildNode(node)
            }
        }
        c.source.isHidden = !showSource
        c.simulation.isHidden = !showSimulation
        c.issues.isHidden = !showIssues
        c.surroundings.isHidden = !showContext || placement == nil
        c.ground.isHidden = !showContext || placement == nil
        c.reference.isHidden = !showReference
        if changed || c.partID != selectedPartID {
            c.partID = selectedPartID
            c.part.geometry = nil
            let selectedParts = mesh.parts.filter {
                selectedPartIDs.contains($0.id) || (selectedPartIDs.isEmpty && $0.id == selectedPartID)
            }
            if !selectedParts.isEmpty {
                c.part.geometry = sourceGeometry(indices: selectedParts.flatMap(\.triangleIndices))
                c.part.geometry?.materials = [material(.systemGreen, alpha: 1, wire: true)]
                c.part.renderingOrder = 30
            }
        }
        if geometryChanged || c.selected != selected || c.resetRequest != resetRequest {
            c.selected = selected
            c.resetRequest = resetRequest
            var b = selected?.bounds ?? preview.bounds
            if let selected, case .placement(let issue) = selected {
                if issue.kind == .blockedCharge || issue.kind == .overlap {
                    let center = (b.min + b.max) * 0.5
                    if let surrounding = preview.boxes.first(where: { $0.contains(center) }) {
                        b = Box(min: simd_min(b.min, surrounding.min), max: simd_max(b.max, surrounding.max))
                    }
                }
                if issue.kind == .floating || issue.kind == .disconnected { b.min.z = min(b.min.z, 0) }
            }
            let center = (b.min + b.max) * 0.5
            let half = simd_max(b.size, SIMD3(repeating: preview.cellSize * 0.3)) * 0.5
            let direction = simd_normalize(SIMD3<Float>(1.5, -2, 1.4))
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), direction))
            let up = simd_cross(direction, right)
            let aspect = view.bounds.height > 0 ? Float(view.bounds.width / view.bounds.height) : 2
            let tangent = tan(Float(c.camera.camera?.fieldOfView ?? 60) * .pi / 360)
            let distance =
                (max(
                    simd_dot(abs(right), half) / (tangent * max(aspect, 0.5)),
                    simd_dot(abs(up), half) / tangent) + simd_dot(abs(direction), half)) * 1.25
            let position = center + direction * distance
            c.camera.position = SCNVector3(position)
            c.camera.look(at: SCNVector3(center), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
            c.camera.camera?.zNear = Double(max(distance * 0.001, 0.0001))
            c.camera.camera?.zFar = Double(max(simd_length(preview.bounds.size) * 20, 100))
            view.pointOfView = c.camera
            view.defaultCameraController.target = SCNVector3(center)
        }
    }
    private func material(_ color: NSColor, alpha: CGFloat, wire: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color.withAlphaComponent(alpha)
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.fillMode = wire ? .lines : .fill
        m.readsFromDepthBuffer = !wire
        m.writesToDepthBuffer = !wire
        return m
    }
    private func sourceGeometry(indices triangleIndices: [Int]? = nil) -> SCNGeometry {
        let vertices = (triangleIndices ?? Array(mesh.triangles.indices)).flatMap { n in
            let t = mesh.triangles[n]
            return [SCNVector3(t.a), SCNVector3(t.b), SCNVector3(t.c)]
        }
        let indices = (0..<vertices.count).map { UInt32($0) }
        let g = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.materials = [material(.cyan, alpha: 0.8, wire: true)]
        return g
    }
    private func referenceGeometry() -> SCNGeometry {
        let b = preview.bounds
        let step = ImportReferenceGrid.step(for: b)
        let low = SIMD2(floor(b.min.x / step) - 1, floor(b.min.y / step) - 1) * step
        let high = SIMD2(ceil(b.max.x / step) + 1, ceil(b.max.y / step) + 1) * step
        var vertices: [SCNVector3] = []
        let xCount = min(64, Int(((high.x - low.x) / step).rounded()))
        let yCount = min(64, Int(((high.y - low.y) / step).rounded()))
        for i in 0...max(xCount, 0) {
            let x = low.x + Float(i) * step
            vertices += [SCNVector3(x, low.y, 0.001), SCNVector3(x, high.y, 0.001)]
        }
        for j in 0...max(yCount, 0) {
            let y = low.y + Float(j) * step
            vertices += [SCNVector3(low.x, y, 0.001), SCNVector3(high.x, y, 0.001)]
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [
                SCNGeometryElement(indices: (0..<vertices.count).map(UInt32.init), primitiveType: .line)
            ])
    }
    private func boxGeometry(_ boxes: [Box], minimumExtent: Float = 0) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        let faces: [UInt32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4,
            3, 4, 7,
        ]
        for box in boxes {
            let center = (box.min + box.max) * 0.5
            let half = simd_max(box.size, SIMD3(repeating: minimumExtent)) * 0.5
            let a = center - half
            let b = center + half
            let base = UInt32(vertices.count)
            vertices += [
                SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, a.y, a.z), SCNVector3(b.x, b.y, a.z),
                SCNVector3(a.x, b.y, a.z), SCNVector3(a.x, a.y, b.z), SCNVector3(b.x, a.y, b.z),
                SCNVector3(b.x, b.y, b.z), SCNVector3(a.x, b.y, b.z),
            ]
            indices += faces.map { base + $0 }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
