import BlastCore
import SceneKit
import SwiftUI
import UniformTypeIdentifiers
import simd

struct ImportRecoveryView: View {
    let filename: String
    let inspection: ImportedMesh.Inspection
    let retry: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var exporting = false
    @State private var selected = 0
    @State private var focus = true
    @State private var exportError: String?
    private var report: String {
        "BombCAD mesh repair report\nFile: \(filename)\nCoordinates: source units\nTriangles: \(inspection.triangles.count)\nUndisplayable triangles: \(inspection.omittedTriangles)\n\n"
            + inspection.issues.map { issue in
                let faces = issue.triangleIndices.prefix(100).map { String($0 + 1) }.joined(separator: ", ")
                let suffix =
                    issue.triangleIndices.count > 100
                    ? " (first 100; \(issue.triangleIndices.count) affected)" : ""
                return issue.message + "\nAffected source triangles: "
                    + (faces.isEmpty ? "not localized" : faces + suffix)
            }.joined(separator: "\n\n")
            + "\n\nRepair in your CAD or mesh editor, re-export, then choose the repaired file. Separate nested shells describe cavities; do not fill them unless that is intended. Geometry is not imported until validation succeeds.\n"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair needed: \(filename)").font(.title2)
            Text(
                "This file has not been imported. Red surfaces mark affected geometry near defects; coordinates are in source units."
            ).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(inspection.issues.enumerated()), id: \.offset) { n, issue in
                            Button {
                                selected = n
                                focus = true
                            } label: {
                                Label(issue.message, systemImage: "exclamationmark.triangle").frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).foregroundStyle(.red)
                                .padding(8).background(
                                    selected == n ? Color.red.opacity(0.1) : .clear,
                                    in: .rect(cornerRadius: 8))
                            if !issue.triangleIndices.isEmpty {
                                Text(
                                    "\(issue.triangleIndices.count) affected triangle\(issue.triangleIndices.count == 1 ? "" : "s"). Export the report for source triangle numbers."
                                ).font(.caption)
                            }
                        }
                        if inspection.omittedTriangles > 0 {
                            Text(
                                "\(inspection.omittedTriangles) collapsed or non-finite triangles cannot be displayed. Their presence still blocks importing."
                            ).font(.caption)
                        }
                        Text(
                            "Stitch open edges, remove duplicate faces, or Boolean-union intersecting solids in your CAD tool. Preserve intentional cavities. Re-export as a watertight triangulated OBJ or STL."
                        ).font(.callout)
                        Button("Choose repaired file…") { choosing = true }
                        Button("Export repair report…") { exporting = true }
                        if let exportError { Text(exportError).foregroundStyle(.red) }
                    }
                }.frame(width: 320)
                VStack(alignment: .leading) {
                    HStack {
                        Button("Show whole model") { focus = false }
                        Button("Focus defect") { focus = true }
                    }.controlSize(.small)
                    RecoverySceneView(
                        triangles: inspection.triangles,
                        issue: inspection.issues.indices.contains(selected)
                            ? inspection.issues[selected] : nil, focus: focus
                    )
                    .background(.black.opacity(0.8)).clipShape(.rect(cornerRadius: 8))
                    Text(
                        "Drag to orbit · scroll to zoom. Inspection only; repairing does not change the simulation."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
            }
        }.padding(20).frame(width: 1000, height: 700)
            .fileImporter(
                isPresented: $choosing,
                allowedContentTypes: [
                    UTType(filenameExtension: "obj") ?? .data, UTType(filenameExtension: "stl") ?? .data,
                ]
            ) { result in
                if case .success(let url) = result { retry(url) }
            }
            .fileExporter(
                isPresented: $exporting, document: ImportReportDocument(text: report),
                contentType: .plainText,
                defaultFilename: "\(filename)-repair.txt"
            ) { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
    }
}

/// Invalid triangles never enter ImportedMesh or the solver. This renderer normalizes coordinates
/// in Double, so even an outsize export can be inspected without overflowing SceneKit's Float positions.
private struct RecoverySceneView: NSViewRepresentable {
    let triangles: [ImportedMesh.Triangle]
    let issue: ImportedMesh.InspectionIssue?
    let focus: Bool
    final class Coordinator {
        let camera = SCNNode()
        let defect = SCNNode()
        var built = false
        var lastIssue: ImportedMesh.InspectionIssue?
        var lastFocus: Bool?
        var center = SIMD3<Double>.zero
        var scale = 1.0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = .init(white: 0.09, alpha: 1)
        view.allowsCameraControl = true
        let c = context.coordinator
        c.camera.camera = SCNCamera()
        c.camera.camera?.zNear = 0.001
        c.camera.camera?.zFar = 1000
        view.scene?.rootNode.addChildNode(c.camera)
        view.scene?.rootNode.addChildNode(c.defect)
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        let visible = triangles.indices.filter { n in
            let t = triangles[n]
            return [t.a, t.b, t.c].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                && simd_length_squared(
                    simd_cross(
                        SIMD3<Double>(t.b) - SIMD3<Double>(t.a), SIMD3<Double>(t.c) - SIMD3<Double>(t.a))) > 0
        }
        if !c.built {
            c.built = true
            var low = SIMD3<Double>(repeating: .infinity)
            var high = SIMD3<Double>(repeating: -.infinity)
            for t in triangles {
                for p in [t.a, t.b, t.c] where p.x.isFinite && p.y.isFinite && p.z.isFinite {
                    low = simd_min(low, SIMD3<Double>(p))
                    high = simd_max(high, SIMD3<Double>(p))
                }
            }
            if low.x.isFinite {
                c.center = (low + high) * 0.5
                c.scale = 10 / max((high - low).x, max((high - low).y, (high - low).z), 1e-30)
            }
            let node = SCNNode(geometry: geometry(visible, c))
            node.geometry?.materials = [material(.lightGray, alpha: 0.6)]
            view.scene?.rootNode.addChildNode(node)
        }
        if c.lastIssue != issue || c.lastFocus != focus {
            c.lastIssue = issue
            c.lastFocus = focus
            let selected = Set(issue?.triangleIndices ?? [])
            let localized = visible.filter { selected.contains($0) }
            c.defect.geometry = geometry(localized, c)
            if localized.isEmpty, let bounds = issue?.bounds {
                let low = (SIMD3<Double>(bounds.min) - c.center) * c.scale
                let high = (SIMD3<Double>(bounds.max) - c.center) * c.scale
                let size = simd_max(high - low, SIMD3(repeating: 0.03))
                c.defect.geometry = SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0)
                c.defect.position = SCNVector3(SIMD3<Float>((low + high) * 0.5))
            } else {
                c.defect.position = SCNVector3(0, 0, 0)
            }
            c.defect.geometry?.materials = [material(.systemRed, alpha: 1)]
            c.defect.renderingOrder = 20
            var center = SIMD3<Float>.zero
            var size = SIMD3<Float>(repeating: 10)
            if focus, let bounds = issue?.bounds,
                (0..<3).allSatisfy({ bounds.min[$0].isFinite && bounds.max[$0].isFinite })
            {
                let low = (SIMD3<Double>(bounds.min) - c.center) * c.scale
                let high = (SIMD3<Double>(bounds.max) - c.center) * c.scale
                center = SIMD3<Float>((low + high) * 0.5)
                size = SIMD3<Float>(high - low)
            }
            let distance = max(3, simd_length(size) * 1.4)
            let direction = simd_normalize(SIMD3<Float>(1.5, -2, 1.4))
            c.camera.position = SCNVector3(center + direction * distance)
            c.camera.look(at: SCNVector3(center), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
            view.pointOfView = c.camera
            view.defaultCameraController.target = SCNVector3(center)
        }
    }
    private func geometry(_ indices: [Int], _ c: Coordinator) -> SCNGeometry {
        let vertices = indices.flatMap { n in
            [triangles[n].a, triangles[n].b, triangles[n].c].map {
                SCNVector3(SIMD3<Float>((SIMD3<Double>($0) - c.center) * c.scale))
            }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [
                SCNGeometryElement(indices: (0..<vertices.count).map(UInt32.init), primitiveType: .triangles)
            ])
    }
    private func material(_ color: NSColor, alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(alpha)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.fillMode = .lines
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }
}
