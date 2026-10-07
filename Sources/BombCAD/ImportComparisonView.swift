import BlastCore
import SceneKit
import SwiftUI
import simd

/// Interactive 3D inspection of source surfaces, sampled solids and spatial diagnostics.
struct ImportComparisonView: View {
    let mesh: ImportedMesh
    let preview: ImportedMesh.Preview
    let canRefine: Bool
    let refine: () -> Void
    @State private var showSource = true
    @State private var showSimulation = true
    @State private var showIssues = true
    @State private var selected: ImportedMesh.Diagnostic?
    @State private var resetRequest = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Source", isOn: $showSource)
                Toggle("Simulation", isOn: $showSimulation)
                Toggle("Affected regions", isOn: $showIssues)
                Spacer()
                Button("Reset view") {
                    selected = nil
                    resetRequest += 1
                }.controlSize(.small)
            }.toggleStyle(.checkbox)
            ImportSceneView(
                mesh: mesh, preview: preview, showSource: showSource, showSimulation: showSimulation,
                showIssues: showIssues, selected: selected, resetRequest: resetRequest
            )
            .frame(height: 300).clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(
                "3D geometry comparison. Cyan source surface, blue simulation volumes, orange thin features and gaps, red potentially missing surfaces."
            )
            Text(
                "Drag to orbit · scroll to zoom. Cyan: source wireframe · blue: simulation · orange: thin features and gaps · red: potentially missing surfaces."
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
                        selected.kind == .missing ? .red : .orange)
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
        }.onChange(of: preview) { selected = nil }
    }
    @ViewBuilder private func warningGroup(_ title: String, issues: [ImportedMesh.Diagnostic]) -> some View {
        if !issues.isEmpty {
            Text("\(title) (\(issues.count))").font(.subheadline.bold()).padding(.top, 4)
            ForEach(issues) { issue in
                Button {
                    selected = selected == issue ? nil : issue
                    showIssues = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            issue.title, systemImage: selected == issue ? "scope" : "exclamationmark.triangle"
                        )
                        .foregroundStyle(issue.kind == .missing ? .red : .orange)
                        Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(
                            selected == issue ? Color.accentColor.opacity(0.2) : .clear,
                            in: .rect(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
        }
    }

}

private struct ImportSceneView: NSViewRepresentable {
    let mesh: ImportedMesh
    let preview: ImportedMesh.Preview
    let showSource: Bool
    let showSimulation: Bool
    let showIssues: Bool
    let selected: ImportedMesh.Diagnostic?
    let resetRequest: Int
    final class Coordinator {
        var mesh: ImportedMesh?
        var preview: ImportedMesh.Preview?
        var selected: ImportedMesh.Diagnostic?
        var resetRequest = -1
        let camera = SCNNode()
        let source = SCNNode()
        let simulation = SCNNode()
        let issues = SCNNode()
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
        view.pointOfView = context.coordinator.camera
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        let changed = c.mesh != mesh || c.preview != preview
        if changed {
            c.mesh = mesh
            c.preview = preview
            c.source.geometry = sourceGeometry()
            c.simulation.geometry = boxGeometry(preview.boxes)
            c.simulation.geometry?.materials = [material(.systemBlue, alpha: 0.45)]
            c.issues.childNodes.forEach { $0.removeFromParentNode() }
            for issue in preview.diagnostics {
                let node = SCNNode(
                    geometry: boxGeometry([issue.bounds], minimumExtent: preview.cellSize * 0.15))
                node.geometry?.materials = [
                    material(issue.kind == .missing ? .systemRed : .systemOrange, alpha: 0.9, wire: true)
                ]
                node.renderingOrder = 20
                c.issues.addChildNode(node)
            }
        }
        c.source.isHidden = !showSource
        c.simulation.isHidden = !showSimulation
        c.issues.isHidden = !showIssues
        if changed || c.selected != selected || c.resetRequest != resetRequest {
            c.selected = selected
            c.resetRequest = resetRequest
            let b = selected?.bounds ?? preview.bounds
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
    private func sourceGeometry() -> SCNGeometry {
        let vertices = mesh.triangles.flatMap { [SCNVector3($0.a), SCNVector3($0.b), SCNVector3($0.c)] }
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
