import AppKit
import MetalKit
import SceneView

/// What an `OrbitControlView` steers: a camera, and what a click on the scene does.
@MainActor
public protocol OrbitControlling: AnyObject {
    var camera: OrbitCamera { get set }
    /// A press and release without movement, at a point in normalised device coordinates (x right and
    /// y up, both from -1 to 1).
    func click(ndc: SIMD2<Float>, aspectRatio: Float)
}

/// A Metal view with camera controls: drag or two-finger scroll to orbit, shift-drag or right-drag
/// to pan, pinch or mouse wheel to zoom, and click to pick. A view that does not redraw continuously
/// asks for a redraw after each change.
public final class OrbitControlView: MTKView {
    public weak var controller: (any OrbitControlling)?

    public override var acceptsFirstResponder: Bool { true }

    private var dragged = false

    public override func mouseDown(with event: NSEvent) {
        dragged = false
    }

    public override func mouseUp(with event: NSEvent) {
        // A press and release without movement is a click on the scene.
        guard !dragged, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ndc = SIMD2(Float(2 * point.x / bounds.width - 1), Float(2 * point.y / bounds.height - 1))
        controller?.click(ndc: ndc, aspectRatio: Float(bounds.width / bounds.height))
        changed()
    }

    public override func mouseDragged(with event: NSEvent) {
        dragged = true
        if event.modifierFlags.contains(.shift) {
            pan(event)
        } else {
            controller?.camera.orbit(
                deltaAzimuth: -Float(event.deltaX) * 0.008, deltaElevation: Float(event.deltaY) * 0.008)
        }
        changed()
    }

    public override func rightMouseDragged(with event: NSEvent) {
        pan(event)
        changed()
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            controller?.camera.orbit(
                deltaAzimuth: -Float(event.scrollingDeltaX) * 0.006,
                deltaElevation: Float(event.scrollingDeltaY) * 0.006)
        } else {
            controller?.camera.zoom(by: exp(-Float(event.scrollingDeltaY) * 0.05))
        }
        changed()
    }

    public override func magnify(with event: NSEvent) {
        controller?.camera.zoom(by: 1 / (1 + Float(event.magnification)))
        changed()
    }

    private func pan(_ event: NSEvent) {
        let scale = 1 / Float(max(bounds.height, 1))
        controller?.camera.pan(right: Float(event.deltaX) * scale, forward: Float(event.deltaY) * scale)
    }

    private func changed() {
        if isPaused { needsDisplay = true }
    }
}
