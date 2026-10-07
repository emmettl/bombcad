import AcousticCore
import SwiftUI

/// A view of the room along one axis.
enum RoomProjection: String, CaseIterable, Identifiable {
    /// Looking down: x to the right, y up the page.
    case plan
    /// Looking north from the south wall: x to the right, z up the page.
    case elevation

    var id: Self { self }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .elevation: "Section, looking north"
        }
    }

    /// The horizontal and vertical room axes shown.
    var axes: (Int, Int) {
        switch self {
        case .plan: (0, 1)
        case .elevation: (0, 2)
        }
    }

    var axisNames: (String, String) {
        switch self {
        case .plan: ("x", "y")
        case .elevation: ("x", "z")
        }
    }
}

/// Maps room coordinates in metres to view points for one projection.
struct RoomLayout {
    let projection: RoomProjection
    let size: SIMD3<Double>
    let bounds: CGSize
    static let padding: CGFloat = 30

    var scale: CGFloat {
        let (h, v) = projection.axes
        return max(
            0.001,
            min(
                (bounds.width - 2 * Self.padding) / CGFloat(size[h]),
                (bounds.height - 2 * Self.padding) / CGFloat(size[v])))
    }

    /// Bottom-left corner of the room in view coordinates.
    var origin: CGPoint {
        let (h, v) = projection.axes
        let width = CGFloat(size[h]) * scale
        let height = CGFloat(size[v]) * scale
        return CGPoint(x: (bounds.width - width) / 2, y: (bounds.height + height) / 2)
    }

    var roomRect: CGRect {
        let (h, v) = projection.axes
        let o = origin
        return CGRect(
            x: o.x, y: o.y - CGFloat(size[v]) * scale, width: CGFloat(size[h]) * scale,
            height: CGFloat(size[v]) * scale)
    }

    func point(_ position: SIMD3<Double>) -> CGPoint {
        let (h, v) = projection.axes
        let o = origin
        return CGPoint(x: o.x + CGFloat(position[h]) * scale, y: o.y - CGFloat(position[v]) * scale)
    }

    /// Moves `position` so it appears at `point`, keeping it at least `margin` inside the room.
    func moved(_ position: SIMD3<Double>, to point: CGPoint, margin: Double = 0.05) -> SIMD3<Double> {
        let (h, v) = projection.axes
        let o = origin
        var result = position
        let along = Double((point.x - o.x) / scale)
        let up = Double((o.y - point.y) / scale)
        result[h] = min(max(along, margin), size[h] - margin)
        result[v] = min(max(up, margin), size[v] - margin)
        // Snap to centimetres so typed and dragged values look alike.
        result[h] = (result[h] * 100).rounded() / 100
        result[v] = (result[v] * 100).rounded() / 100
        return result
    }
}

/// The room, source and receivers in one projection. Points can be dragged when `settings` is
/// editable.
struct RoomDrawing: View {
    @Binding var settings: RoomResponseSettings
    let projection: RoomProjection
    var editable = true
    /// Index of the dragged point: 0 for the source, 1... for receivers.
    @State private var dragging: Int?

    static let sourceColor = Color.orange
    static let receiverColor = Color.blue

    var body: some View {
        GeometryReader { geometry in
            let layout = RoomLayout(projection: projection, size: settings.room.size, bounds: geometry.size)
            Canvas { context, _ in
                draw(in: &context, layout: layout)
            }
            .contentShape(Rectangle())
            .gesture(editable ? drag(layout) : nil)
            .accessibilityElement()
            .accessibilityLabel("\(projection.title) of the room")
        }
    }

    private var points: [RoomPoint] { [settings.source] + settings.receivers }

    private func drag(_ layout: RoomLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    let nearest = points.indices.min {
                        distance(layout.point(points[$0].position), value.startLocation)
                            < distance(layout.point(points[$1].position), value.startLocation)
                    }
                    guard let nearest,
                        distance(layout.point(points[nearest].position), value.startLocation) < 20
                    else { return }
                    dragging = nearest
                }
                guard let index = dragging else { return }
                if index == 0 {
                    settings.source.position = layout.moved(settings.source.position, to: value.location)
                } else {
                    settings.receivers[index - 1].position = layout.moved(
                        settings.receivers[index - 1].position, to: value.location)
                }
            }
            .onEnded { _ in dragging = nil }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func draw(in context: inout GraphicsContext, layout: RoomLayout) {
        // Typing in the inspector can pass through values the room cannot have; draw nothing then.
        let size = settings.room.size
        guard [size.x, size.y, size.z].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1_000 }) else {
            context.draw(
                Text("Room dimensions must be between 0.5 and 500 m").foregroundStyle(.secondary),
                at: CGPoint(x: layout.bounds.width / 2, y: layout.bounds.height / 2))
            return
        }
        let rect = layout.roomRect
        context.fill(Path(rect), with: .color(.secondary.opacity(0.08)))
        // One-metre grid.
        let (h, v) = projection.axes
        var grid = Path()
        for metre in stride(from: 1.0, to: settings.room.size[h], by: 1) {
            let x = rect.minX + CGFloat(metre) * layout.scale
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for metre in stride(from: 1.0, to: settings.room.size[v], by: 1) {
            let y = rect.maxY - CGFloat(metre) * layout.scale
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        context.stroke(Path(rect), with: .color(.primary.opacity(0.8)), lineWidth: 2)

        let (hName, vName) = projection.axisNames
        let width = String(format: "%.2f m", settings.room.size[h])
        let height = String(format: "%.2f m", settings.room.size[v])
        context.draw(
            Text("\(hName) \(width)").font(.caption).foregroundStyle(.secondary),
            at: CGPoint(x: rect.midX, y: rect.maxY + 14))
        var rotated = context
        rotated.translateBy(x: rect.minX - 14, y: rect.midY)
        rotated.rotate(by: .degrees(-90))
        rotated.draw(Text("\(vName) \(height)").font(.caption).foregroundStyle(.secondary), at: .zero)

        let source = layout.point(settings.source.position)
        var paths = Path()
        for receiver in settings.receivers {
            paths.move(to: source)
            paths.addLine(to: layout.point(receiver.position))
        }
        context.stroke(
            paths, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // Labels move up until they clear those already placed, so coincident points stay readable.
        var placed: [CGPoint] = [CGPoint(x: source.x, y: source.y + 16)]
        func labelPosition(near point: CGPoint) -> CGPoint {
            var label = CGPoint(x: point.x, y: point.y - 14)
            while placed.contains(where: { abs($0.x - label.x) < 44 && abs($0.y - label.y) < 13 }) {
                label.y -= 13
            }
            placed.append(label)
            return label
        }
        for receiver in settings.receivers {
            let point = layout.point(receiver.position)
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                with: .color(Self.receiverColor))
            context.draw(
                Text(receiver.name).font(.caption).foregroundStyle(Self.receiverColor),
                at: labelPosition(near: point))
        }
        context.fill(
            Path(ellipseIn: CGRect(x: source.x - 8, y: source.y - 8, width: 16, height: 16)),
            with: .color(Self.sourceColor))
        context.draw(
            Text(settings.source.name).font(.caption.bold()).foregroundStyle(Self.sourceColor),
            at: CGPoint(x: source.x, y: source.y + 16))
    }
}
