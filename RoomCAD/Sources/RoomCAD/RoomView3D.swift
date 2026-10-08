import AcousticCore
import MetalKit
import Observation
import SceneModel
import SceneRender
import SceneView
import SwiftUI

/// The 3D view's state: its camera, what is drawn, and what was clicked.
@MainActor
@Observable
final class RoomViewport: OrbitControlling {
    var camera = OrbitCamera(target: .zero, distance: 10, azimuth: -2.45, elevation: 0.5)
    /// What the last click selected, if anything.
    private(set) var selected: RoomScene.Item?
    private(set) var scene: RoomScene?
    @ObservationIgnored let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored private(set) lazy var renderer: MeshRenderer? = device.flatMap {
        try? MeshRenderer(device: $0)
    }
    @ObservationIgnored private(set) lazy var commandQueue = device?.makeCommandQueue()
    @ObservationIgnored private var shown: RoomResponseSettings?
    /// The room size the camera was last framed for.
    @ObservationIgnored private var framedSize: SIMD3<Double>?
    /// Receives settings edited in the view: a point dragged, or a surface's material chosen.
    @ObservationIgnored var onEdit: (RoomResponseSettings) -> Void = { _ in }
    /// The point being dragged, and where on it it was grabbed.
    @ObservationIgnored private var dragging: (item: RoomScene.Item, grab: SIMD3<Double>)?
    /// A surface being pushed or pulled: the settings when it was grabbed, where, and its normal into
    /// the room.
    @ObservationIgnored private var pushing:
        (index: Int, face: Int, start: RoomResponseSettings, point: SIMD3<Double>, normal: SIMD3<Double>)?

    /// Shows `settings`' room, framing the camera on it the first time and whenever its size changes.
    func show(_ settings: RoomResponseSettings) {
        guard settings != shown else { return }
        shown = settings
        let scene = RoomScene(settings: settings)
        self.scene = scene
        renderer?.setGeometry(scene.geometry)
        if framedSize != settings.room.size {
            framedSize = settings.room.size
            frame()
        }
        if let selected, !scene.contains(selected, settings: settings) { select(nil) }
    }

    /// Frames the camera on the room from a three-quarter view above it.
    func frame() {
        guard let size = framedSize else { return }
        camera = Self.framing(SIMD3<Float>(size), aspectRatio: 1.6)
    }

    /// The shared three-quarter view, as close as it can be with every corner of the room within the
    /// middle 85% of a view of the given aspect ratio.
    static func framing(_ size: SIMD3<Float>, aspectRatio: Float) -> OrbitCamera {
        var camera = OrbitCamera.framing(Box(min: .zero, max: size))
        let corners = (0..<8).map { i in
            SIMD3<Float>(i & 1 == 0 ? 0 : size.x, i & 2 == 0 ? 0 : size.y, i & 4 == 0 ? 0 : size.z)
        }
        camera.distance = 0.5 * simd_length(size)
        while camera.distance < 600 {
            let projection = MeshRenderer.viewProjection(camera, aspectRatio: aspectRatio)
            let fits = corners.allSatisfy { corner in
                let clip = projection * SIMD4(corner, 1)
                return clip.w > 0 && abs(clip.x / clip.w) <= 0.85 && abs(clip.y / clip.w) <= 0.85
            }
            if fits { break }
            camera.distance *= 1.05
        }
        camera.distance = max(camera.distance, 3)
        return camera
    }

    func select(_ item: RoomScene.Item?) {
        selected = item
        renderer?.highlighted = item?.pick
    }

    func click(ndc: SIMD2<Float>, aspectRatio: Float) {
        let ray = camera.ray(ndc: ndc, aspectRatio: aspectRatio)
        select(
            scene?.geometry.pick(origin: ray.origin, direction: ray.direction).flatMap(RoomScene.Item.init))
    }

    /// Applies an edit: shown at once, and handed on. The camera stays where it is, even if the room
    /// changed size.
    func edit(_ settings: RoomResponseSettings) {
        guard settings != shown else { return }
        framedSize = settings.room.size
        show(settings)
        onEdit(settings)
    }

    /// Where an item is held while dragged: a point's centre, the middle of a zone's top, or an
    /// opening's centre. Surfaces are not dragged.
    func anchor(of item: RoomScene.Item, in settings: RoomResponseSettings) -> SIMD3<Double>? {
        switch item {
        case .source, .receiver: return settings.position(of: item)
        case .zone(let index):
            guard let zone = settings.room.fittings?[safe: index] else { return nil }
            return SIMD3((zone.low.x + zone.high.x) / 2, (zone.low.y + zone.high.y) / 2, zone.high.z)
        case .opening(let index):
            guard let opening = settings.openings[safe: index], let frame = settings.frame(of: opening) else {
                return nil
            }
            return frame.origin + frame.u * opening.centre.x + frame.v * opening.centre.y
        case .corner(let index):
            guard let corner = settings.room.plan?.corners[safe: index] else { return nil }
            return SIMD3(corner.x, corner.y, settings.room.size.z)
        case .surface: return nil
        }
    }

    /// The plane an item moves in: horizontal through its anchor, an opening's own surface, or, with
    /// `vertical`, upright through the anchor and facing the camera.
    private func plane(
        for item: RoomScene.Item, anchor: SIMD3<Double>, vertical: Bool,
        ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)
    ) -> SIMD3<Double>? {
        if case .opening(let index) = item {
            return shown.flatMap { $0.openings[safe: index] }.flatMap { shown?.frame(of: $0)?.normal }
        }
        guard vertical else { return [0, 0, 1] }
        let forward = SIMD3<Double>(SIMD3<Float>(ray.direction.x, ray.direction.y, 0))
        return simd_length(forward) > 1e-6 ? simd_normalize(forward) : nil
    }

    /// A press on the source, a receiver, a zone or an opening selects it and drags it. With Command, a
    /// press on a box's or a floor plan's wall, floor or ceiling selects it to push or pull.
    func beginDrag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) -> Bool {
        let ray = camera.ray(ndc: ndc, aspectRatio: aspectRatio)
        guard let shown,
            let item = scene?.geometry.pick(origin: ray.origin, direction: ray.direction).flatMap(
                RoomScene.Item.init)
        else { return false }
        if case .surface(let index) = item {
            guard modifiers.contains(.resize), let scene,
                let face = Self.face(of: index, in: scene.mesh, under: ray)
            else { return false }
            let normal = scene.mesh.normalAndArea(face).normal
            guard
                let point = Self.intersect(
                    ray, withPlaneThrough: scene.mesh.vertices[scene.mesh.faces[face].corners[0]],
                    normal: normal)
            else { return false }
            select(item)
            pushing = (index, face, shown, point, normal)
            return true
        }
        guard let anchor = anchor(of: item, in: shown),
            let normal = plane(for: item, anchor: anchor, vertical: false, ray: ray)
        else { return false }
        select(item)
        let hit = Self.intersect(ray, withPlaneThrough: anchor, normal: normal) ?? anchor
        dragging = (item, anchor - hit)
        return true
    }

    /// Moves or, with `resize`, reshapes what is being dragged, following the pointer across the plane
    /// it moves in. Points and zones move across the room at their height, or with `vertical` up and
    /// down; a zone's footprint corner or, with `vertical`, its top follows a resize. An opening moves
    /// over its surface, and a resize moves its nearest corner. Changes that would leave the room, or
    /// make a zone overlap another, are ignored.
    func drag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) {
        let ray = camera.ray(ndc: ndc, aspectRatio: aspectRatio)
        if let pushing {
            // How far along the surface's normal the pointer's ray passes closest: the push, out of
            // the room, is the opposite of that.
            let direction = SIMD3<Double>(ray.direction)
            let along = simd_dot(pushing.normal, direction)
            guard abs(along) < 0.999 else { return }
            let w = pushing.point - SIMD3<Double>(ray.origin)
            let t = (along * simd_dot(direction, w) - simd_dot(pushing.normal, w)) / (1 - along * along)
            // A mesh's face keeps its number as its plane moves; a box or plan is numbered by surface.
            let face = pushing.start.room.mesh == nil ? nil : pushing.face
            if let pushed = pushing.start.pushingSurface(pushing.index, face: face, by: -t) { edit(pushed) }
            return
        }
        guard let dragging, let shown, let anchor = anchor(of: dragging.item, in: shown) else { return }
        let vertical = modifiers.contains(.vertical)
        guard let normal = plane(for: dragging.item, anchor: anchor, vertical: vertical, ray: ray),
            let hit = Self.intersect(ray, withPlaneThrough: anchor, normal: normal)
        else { return }
        switch dragging.item {
        case .source, .receiver:
            var target = anchor
            if vertical {
                target.z = hit.z
            } else {
                target.x = hit.x + dragging.grab.x
                target.y = hit.y + dragging.grab.y
            }
            edit(shown.moving(dragging.item, to: target))
        case .zone(let index):
            if modifiers.contains(.resize) {
                edit(shown.resizingZone(index, toward: hit, vertical: vertical))
            } else if vertical {
                edit(shown.movingZone(index, by: [0, 0, hit.z - anchor.z]))
            } else {
                let target = hit + dragging.grab
                edit(shown.movingZone(index, by: [target.x - anchor.x, target.y - anchor.y, 0]))
            }
        case .opening(let index):
            guard let opening = shown.openings[safe: index], let frame = shown.frame(of: opening) else {
                return
            }
            let point = frame.coordinates(hit)
            if modifiers.contains(.resize) {
                edit(shown.resizingOpening(index, toward: point))
            } else {
                edit(
                    shown.movingOpening(
                        index,
                        to: point + frame.coordinates(anchor + dragging.grab) - frame.coordinates(anchor)))
            }
        case .corner(let index):
            let target = hit + dragging.grab
            if let moved = shown.movingCorner(index, to: SIMD2(target.x, target.y)) { edit(moved) }
        case .surface:
            break
        }
    }

    func endDrag() {
        dragging = nil
        pushing = nil
    }

    /// The face of material `index` that a ray meets first from its inside, if any.
    static func face(
        of index: Int, in mesh: RoomMesh, under ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)
    ) -> Int? {
        let origin = SIMD3<Double>(ray.origin)
        let direction = SIMD3<Double>(ray.direction)
        var nearest = Double.infinity
        var found: Int?
        for (corners, face) in mesh.triangles() where mesh.faces[face].material == index {
            let (a, b, c) = (mesh.vertices[corners.x], mesh.vertices[corners.y], mesh.vertices[corners.z])
            let e1 = b - a
            let e2 = c - a
            let h = simd_cross(direction, e2)
            let det = simd_dot(e1, h)
            guard abs(det) > 1e-12, simd_dot(simd_cross(e1, e2), direction) < 0 else { continue }
            let s = origin - a
            let u = simd_dot(s, h) / det
            let q = simd_cross(s, e1)
            let v = simd_dot(direction, q) / det
            let t = simd_dot(e2, q) / det
            if u >= 0, v >= 0, u + v <= 1, t > 0, t < nearest {
                nearest = t
                found = face
            }
        }
        return found
    }

    /// Where a ray meets a plane in front of it, if it does.
    static func intersect(
        _ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), withPlaneThrough point: SIMD3<Double>,
        normal: SIMD3<Double>
    ) -> SIMD3<Double>? {
        let origin = SIMD3<Double>(ray.origin)
        let direction = SIMD3<Double>(ray.direction)
        let denominator = simd_dot(direction, normal)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = simd_dot(point - origin, normal) / denominator
        return t > 0 ? origin + direction * t : nil
    }

    /// The material of the selected surface, if a surface is selected.
    var selectedMaterial: SurfaceMaterial? {
        guard case .surface(let index) = selected else { return nil }
        return shown?.surfaceMaterial(index)
    }

    /// Gives the selected surface a published material's absorption, keeping its scattering.
    func applyToSelected(_ preset: MaterialPreset) {
        guard case .surface(let index) = selected, let shown, let material = shown.surfaceMaterial(index)
        else {
            return
        }
        edit(shown.settingSurfaceMaterial(index, to: material.applying(absorption: preset)))
    }

    /// What is selected, in words.
    var caption: String? {
        guard let selected, let scene, let shown else { return nil }
        return scene.describe(selected, settings: shown)
    }
}

extension RoomScene {
    /// Whether the scene still has the item, after the settings changed.
    func contains(_ item: Item, settings: RoomResponseSettings) -> Bool {
        switch item {
        case .surface(let index): index < mesh.materials.count
        case .source: true
        case .receiver(let index): index < settings.receivers.count
        case .zone(let index): index < (settings.room.fittings?.count ?? 0)
        case .opening(let index): index < settings.openings.count
        case .corner(let index): index < (settings.room.plan?.corners.count ?? 0)
        }
    }
}

/// The room in 3D, with a caption naming what was clicked. Drag to orbit, shift-drag to pan, pinch or
/// scroll to zoom, click a surface, zone or point to select it.
struct RoomView3D: View {
    @Binding var settings: RoomResponseSettings
    @State private var viewport = RoomViewport()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if viewport.renderer != nil {
                RoomMetalView(viewport: viewport, settings: settings)
            } else {
                Text("3D view needs a Metal device").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(alignment: .bottom) {
                HStack(spacing: 8) {
                    Text(
                        viewport.caption
                            ?? "Drag to orbit, shift-drag to pan, pinch to zoom; click to select. Drag a point, zone or "
                            + "opening to move it, with Option to raise or lower it, or with Command to resize it; "
                            + "Command-drag a wall, floor or ceiling to push or pull it"
                    )
                    .font(.caption)
                    .foregroundStyle(viewport.caption == nil ? .secondary : .primary)
                    if viewport.selectedMaterial != nil {
                        Menu("Material") {
                            ForEach(MaterialPresets.categories(of: MaterialPresets.absorption), id: \.self) {
                                category in
                                Menu(category) {
                                    ForEach(MaterialPresets.absorption.filter { $0.category == category }) {
                                        preset in
                                        Button(preset.name) { viewport.applyToSelected(preset) }
                                    }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(
                            "Give this surface a material with published absorption, keeping its scattering")
                    }
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Button("Reset View", systemImage: "arrow.counterclockwise") { viewport.frame() }
                    .labelStyle(.iconOnly)
                    .help("Frame the whole room again")
            }
            .padding(8)
        }
        .onAppear {
            viewport.show(settings)
            viewport.onEdit = { settings = $0 }
        }
        .onChange(of: settings) { viewport.show(settings) }
    }
}

/// The Metal view itself, redrawn only when something changes.
private struct RoomMetalView: NSViewRepresentable {
    let viewport: RoomViewport
    let settings: RoomResponseSettings

    func makeCoordinator() -> Coordinator { Coordinator(viewport: viewport) }

    func makeNSView(context: Context) -> OrbitControlView {
        let view = OrbitControlView(frame: .zero, device: viewport.device)
        view.controller = viewport
        view.delegate = context.coordinator
        view.colorPixelFormat = MeshRenderer.pixelFormat
        view.depthStencilPixelFormat = MeshRenderer.depthFormat
        view.sampleCount = MeshRenderer.sampleCount
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        return view
    }

    func updateNSView(_ view: OrbitControlView, context: Context) {
        // Settings, selection or a reset camera may have changed.
        _ = (viewport.camera, viewport.selected, settings)
        view.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let viewport: RoomViewport

        init(viewport: RoomViewport) { self.viewport = viewport }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let renderer = viewport.renderer, let queue = viewport.commandQueue,
                let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor,
                let commandBuffer = queue.makeCommandBuffer(), view.drawableSize.height > 0
            else { return }
            renderer.encode(
                into: commandBuffer, descriptor: descriptor, camera: viewport.camera,
                aspectRatio: Float(view.drawableSize.width / view.drawableSize.height))
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
