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
        }
    }
}

/// The room in 3D, with a caption naming what was clicked. Drag to orbit, shift-drag to pan, pinch or
/// scroll to zoom, click a surface, zone or point to select it.
struct RoomView3D: View {
    let settings: RoomResponseSettings
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
                Text(viewport.caption ?? "Drag to orbit, shift-drag to pan, pinch to zoom; click to select")
                    .font(.caption)
                    .foregroundStyle(viewport.caption == nil ? .secondary : .primary)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Button("Reset View", systemImage: "arrow.counterclockwise") { viewport.frame() }
                    .labelStyle(.iconOnly)
                    .help("Frame the whole room again")
            }
            .padding(8)
        }
        .onAppear { viewport.show(settings) }
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
