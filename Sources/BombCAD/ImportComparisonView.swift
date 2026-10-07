import BlastCore
import SceneKit
import SwiftUI
import simd

/// Interactive 3D inspection of source surfaces, sampled solids and spatial diagnostics.
struct ImportComparisonView: View {
    let mesh: ImportedMesh
    let preview: ImportedMesh.Preview
    var placement: ImportPlacementReport? = nil
    var selectedPartID: Int? = nil
    let canRefine: Bool
    let refine: () -> Void
    @State private var showSource = true
    @State private var showSimulation = true
    @State private var showIssues = true
    @State private var showContext = true
    @State private var selected: ImportFocus?
    @State private var resetRequest = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Source", isOn: $showSource)
                Toggle("Simulation", isOn: $showSimulation)
                Toggle("Affected regions", isOn: $showIssues)
                if placement != nil {
                    Toggle("Context", isOn: $showContext).help(
                        "Show surrounding geometry and a ground reference.")
                }
                Spacer()
                Button("Reset view") {
                    selected = nil
                    resetRequest += 1
                }.controlSize(.small)
            }.toggleStyle(.checkbox)
            ImportSceneView(
                mesh: mesh, preview: preview, placement: placement, showSource: showSource,
                showSimulation: showSimulation,
                showIssues: showIssues, showContext: showContext, selected: selected,
                selectedPartID: selectedPartID,
                resetRequest: resetRequest
            )
            .frame(height: 300).clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(
                "3D geometry comparison. Cyan source surface, blue simulation volumes, orange thin features and gaps, red potentially missing surfaces."
            )
            Text(
                "Drag to orbit · scroll to zoom. Cyan: source · blue: simulation · orange: resolution/overlap risks · purple: contact/connectivity · red: missing surfaces or blocked charges."
            ).font(.caption).foregroundStyle(.secondary)
            if !preview.diagnostics.isEmpty || preview.diagnosticsTruncated {
                HStack {
                    Text("Affected regions (approximate)").font(.headline)
                    Spacer()
                    Button("Preview finer grid", action: refine).disabled(!canRefine)
                }
                if !canRefine {
                    Text(
                        "Fine is the smallest available grid (0.125 m); highlighted features may still be unresolved."
                    ).font(.caption).foregroundStyle(.orange)
                }
                if let selected {
                    Text("Selected: \(selected.title). \(selected.detail)").font(.caption).foregroundStyle(
                        selected.color)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        warningGroup(
                            "Potential geometry loss",
                            issues: preview.diagnostics.filter { $0.kind == .missing })
                        warningGroup(
                            "Resolution risks", issues: preview.diagnostics.filter { $0.kind != .missing })
                    }
                }.frame(maxHeight: 190)
                Text(
                    "Select a region to focus it. Highlights are approximate; compare finer grids before trusting results."
                ).font(.caption).foregroundStyle(.secondary)
            }
            if let placement {
                Text(
                    "Placement checks · \(placement.componentCount) sampled component\(placement.componentCount == 1 ? "" : "s")"
                ).font(.headline)
                if placement.issues.isEmpty {
                    Text("No placement issues found in the checked volumes.").font(.caption).foregroundStyle(
                        .secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(placement.issues) { issue in
                                focusButton(.placement(issue))
                            }
                        }
                    }.frame(maxHeight: 190)
                }
                if placement.checksIncomplete {
                    Text("Placement highlighting is incomplete; some checks reached their limit.").font(
                        .caption
                    ).foregroundStyle(.orange)
                }
            }
            if let selected, case .placement = selected {
                Text("Selected: \(selected.title). \(selected.detail)").font(.caption).foregroundStyle(
                    selected.color)
            }
        }.onChange(of: preview) { focusPart() }.onChange(of: placement) {
            selected = nil
            focusPart()
        }
        .onChange(of: selectedPartID) { focusPart() }.onAppear { focusPart() }
    }
    private func focusPart() {
        if let part = mesh.parts.first(where: { $0.id == selectedPartID }) {
            selected = .part(id: part.id, bounds: mesh.bounds(of: part), name: part.name)
        } else {
            selected = nil
        }
    }
    @ViewBuilder private func warningGroup(_ title: String, issues: [ImportedMesh.Diagnostic]) -> some View {
        if !issues.isEmpty {
            Text("\(title) (\(issues.count))").font(.subheadline.bold()).padding(.top, 4)
            ForEach(issues) { issue in focusButton(.geometry(issue)) }
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
    let resetRequest: Int
    final class Coordinator {
        var mesh: ImportedMesh?
        var preview: ImportedMesh.Preview?
        var placement: ImportPlacementReport?
        var selected: ImportFocus?
        var partID: Int?
        var resetRequest = -1
        let camera = SCNNode()
        let source = SCNNode()
        let simulation = SCNNode()
        let issues = SCNNode()
        let surroundings = SCNNode()
        let ground = SCNNode()
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
        view.scene?.rootNode.addChildNode(context.coordinator.part)
        view.pointOfView = context.coordinator.camera
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        let changed = c.mesh != mesh || c.preview != preview || c.placement != placement
        if changed {
            c.mesh = mesh
            c.preview = preview
            c.placement = placement
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
            c.source.geometry = sourceGeometry()
            c.simulation.geometry = boxGeometry(preview.boxes)
            c.simulation.geometry?.materials = [material(.systemBlue, alpha: 0.45)]
            for node in c.issues.childNodes { node.removeFromParentNode() }
            for issue in preview.diagnostics {
                let node = SCNNode(
                    geometry: boxGeometry([issue.bounds], minimumExtent: preview.cellSize * 0.15))
                node.geometry?.materials = [
                    material(issue.kind == .missing ? .systemRed : .systemOrange, alpha: 0.9, wire: true)
                ]
                node.renderingOrder = 20
                c.issues.addChildNode(node)
            }
            for issue in placement?.issues ?? [] {
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
        if changed || c.partID != selectedPartID {
            c.partID = selectedPartID
            c.part.geometry = nil
            if let part = mesh.parts.first(where: { $0.id == selectedPartID }) {
                c.part.geometry = sourceGeometry(indices: part.triangleIndices)
                c.part.geometry?.materials = [material(.systemGreen, alpha: 1, wire: true)]
                c.part.renderingOrder = 30
            }
        }
        if changed || c.selected != selected || c.resetRequest != resetRequest {
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
