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
    /// A press that may start dragging something in the scene instead of the camera, with the keys held;
    /// true to take the drag. By default the camera orbits.
    func beginDrag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) -> Bool
    /// The pointer moved during a drag taken by `beginDrag`, with the keys held.
    func drag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers)
    func endDrag()
}

/// Keys held during a drag: Option for `vertical`, Command for `resize`.
public struct DragModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let vertical = DragModifiers(rawValue: 1)
    public static let resize = DragModifiers(rawValue: 2)

    public init(_ flags: NSEvent.ModifierFlags) {
        self.init()
        if flags.contains(.option) { insert(.vertical) }
        if flags.contains(.command) { insert(.resize) }
    }
}

extension OrbitControlling {
    public func beginDrag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) -> Bool { false }
    public func drag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) {}
    public func endDrag() {}
}

/// A Metal view with camera controls: drag or two-finger scroll to orbit, shift-drag or right-drag
/// to pan, pinch or mouse wheel to zoom, and click to pick. A press on something the controller takes
/// drags that instead of the camera. A view that does not redraw continuously
/// asks for a redraw after each change.
public final class OrbitControlView: MTKView {
    public weak var controller: (any OrbitControlling)?

    public override var acceptsFirstResponder: Bool { true }

    private var dragged = false
    /// Whether the controller took the current drag.
    private var draggingObject = false

    private func ndc(_ event: NSEvent) -> SIMD2<Float> {
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(2 * point.x / bounds.width - 1), Float(2 * point.y / bounds.height - 1))
    }

    private var aspectRatio: Float { Float(bounds.width / max(bounds.height, 1)) }

    public override func mouseDown(with event: NSEvent) {
        dragged = false
        draggingObject =
            bounds.width > 0 && bounds.height > 0
            && controller?.beginDrag(
                ndc: ndc(event), aspectRatio: aspectRatio, modifiers: DragModifiers(event.modifierFlags))
                == true
    }

    public override func mouseUp(with event: NSEvent) {
        if draggingObject {
            draggingObject = false
            controller?.endDrag()
            // A press on an object without movement still selects it.
            if dragged {
                changed()
                return
            }
        }
        // A press and release without movement is a click on the scene.
        guard !dragged, bounds.width > 0, bounds.height > 0 else { return }
        controller?.click(ndc: ndc(event), aspectRatio: aspectRatio)
        changed()
    }

    public override func mouseDragged(with event: NSEvent) {
        dragged = true
        if draggingObject {
            controller?.drag(
                ndc: ndc(event), aspectRatio: aspectRatio, modifiers: DragModifiers(event.modifierFlags))
        } else if event.modifierFlags.contains(.shift) {
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
