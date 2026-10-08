import AcousticCore
import SceneRender
import simd

/// A room as a 3D scene: its surfaces coloured by material, open faces and openings in translucent
/// green, fitted zones as translucent brown boxes, the source and receivers as spheres, and each
/// directional microphone's aim as a line.
///
/// Every room is drawn as a mesh: a box or a floor plan is turned into one first. Its faces point into
/// the room, so from outside the near walls are cut away.
struct RoomScene {
    /// What a click can select.
    enum Item: Hashable {
        /// A material of the room's mesh, by index.
        case surface(Int)
        case source
        case receiver(Int)
        case zone(Int)
        case opening(Int)

        var pick: Int32 {
            switch self {
            case .surface(let index): Int32(index)
            case .source: 10_000
            case .receiver(let index): 10_001 + Int32(index)
            case .zone(let index): 20_000 + Int32(index)
            case .opening(let index): 30_000 + Int32(index)
            }
        }

        init?(pick: Int32) {
            switch pick {
            case 0..<10_000: self = .surface(Int(pick))
            case 10_000: self = .source
            case 10_001..<20_000: self = .receiver(Int(pick) - 10_001)
            case 20_000..<30_000: self = .zone(Int(pick) - 20_000)
            case 30_000...: self = .opening(Int(pick) - 30_000)
            default: return nil
            }
        }
    }

    let mesh: RoomMesh
    /// A name for each of the mesh's materials, such as "North wall" or "Audience".
    let names: [String]
    let geometry: SceneGeometry

    static let sourceColour = SIMD4<Float>(0.95, 0.5, 0.1, 1)
    static let receiverColour = SIMD4<Float>(0.15, 0.45, 0.95, 1)
    static let openingColour = SIMD4<Float>(0.2, 0.75, 0.3, 0.35)
    static let zoneColour = SIMD4<Float>(0.6, 0.4, 0.2, 0.22)
    static let edgeColour = SIMD4<Float>(0.15, 0.15, 0.15, 0.7)

    /// Gentle, distinct colours for the room's materials, in turn.
    static let palette: [SIMD4<Float>] = [
        [0.80, 0.74, 0.62, 1], [0.70, 0.78, 0.84, 1], [0.84, 0.80, 0.70, 1], [0.74, 0.82, 0.72, 1],
        [0.86, 0.72, 0.70, 1], [0.76, 0.72, 0.84, 1], [0.88, 0.84, 0.62, 1], [0.66, 0.80, 0.78, 1],
    ]

    /// The room as a mesh, with a name for each material: a mesh as it is, a floor plan's walls
    /// extruded, or a box's six surfaces.
    static func surfaces(of room: ShoeboxRoom) -> (mesh: RoomMesh, names: [String]) {
        if let mesh = room.mesh {
            let labels = mesh.labels ?? []
            return (
                mesh, mesh.materials.indices.map { $0 < labels.count ? labels[$0] : mesh.materials[$0].name }
            )
        }
        if let plan = room.plan {
            let mesh = RoomMesh.extruding(plan, height: room.size.z, floor: room.floor, ceiling: room.ceiling)
            return (mesh, plan.corners.indices.map { "Wall \($0 + 1)" } + ["Floor", "Ceiling"])
        }
        let mesh = RoomMesh.box(
            room.size, materials: Dictionary(uniqueKeysWithValues: Surface.allCases.map { ($0, room[$0]) }))
        return (
            mesh,
            Surface.allCases.map {
                [.floor, .ceiling].contains($0) ? $0.rawValue.capitalized : "\($0.rawValue.capitalized) wall"
            }
        )
    }

    init(settings: RoomResponseSettings) {
        let room = settings.room
        (mesh, names) = Self.surfaces(of: room)
        var scene = SceneGeometry()
        // Surfaces of the same material share a colour.
        var distinct: [SurfaceMaterial] = []
        let colours = mesh.materials.map { material -> SIMD4<Float> in
            let index = distinct.firstIndex(of: material) ?? distinct.count
            if index == distinct.count { distinct.append(material) }
            return Self.palette[index % Self.palette.count]
        }
        func point(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(p) }
        for (corners, face) in mesh.triangles() {
            let (a, b, c) = (
                point(mesh.vertices[corners.x]), point(mesh.vertices[corners.y]),
                point(mesh.vertices[corners.z])
            )
            if mesh.faces[face].open {
                scene.addTriangle(a, b, c, colour: Self.openingColour, translucent: true)
            } else {
                let material = mesh.faces[face].material
                scene.addTriangle(a, b, c, colour: colours[material], pick: Item.surface(material).pick)
            }
        }
        for (a, b) in mesh.outlineEdges() { scene.addLine(point(a), point(b), colour: Self.edgeColour) }
        for (index, opening) in settings.openings.enumerated() {
            if let corners = Self.corners(of: opening, in: room) {
                scene.addPolygon(
                    corners.map(point), colour: Self.openingColour, pick: Item.opening(index).pick,
                    translucent: true)
                for i in corners.indices {
                    scene.addLine(
                        point(corners[i]), point(corners[(i + 1) % corners.count]),
                        colour: SIMD4(0.1, 0.55, 0.2, 0.9))
                }
            }
        }
        for (index, zone) in (room.fittings ?? []).enumerated() {
            scene.addBox(
                point(zone.low), point(zone.high), colour: Self.zoneColour, pick: Item.zone(index).pick,
                translucent: true)
            scene.addBoxEdges(point(zone.low), point(zone.high), colour: SIMD4(0.5, 0.32, 0.15, 0.9))
        }
        // Points sized with the room, so they show in a hall and do not fill a booth.
        let radius = Float(min(max(0.012 * simd_length(room.size), 0.06), 0.35))
        scene.addSphere(
            centre: point(settings.source.position), radius: radius, colour: Self.sourceColour,
            pick: Item.source.pick)
        for (index, receiver) in settings.receivers.enumerated() {
            let centre = point(receiver.position)
            scene.addSphere(
                centre: centre, radius: radius, colour: Self.receiverColour, pick: Item.receiver(index).pick)
            if let microphone = receiver.microphone, microphone.pattern != .omni {
                scene.addLine(
                    centre, centre + 4 * radius * point(microphone.axis), colour: Self.receiverColour)
            }
        }
        geometry = scene
    }

    /// An opening's four corners in the room, a centimetre in from its surface so it shows in front of
    /// it; nil if it is in a wall the room does not have.
    static func corners(of opening: Opening, in room: ShoeboxRoom) -> [SIMD3<Double>]? {
        let half = opening.size / 2
        if let wall = opening.wall {
            guard let plan = room.plan, wall < plan.corners.count else { return nil }
            let start = plan.start(wall)
            let along = simd_normalize(plan.end(wall) - start)
            let inward = plan.inwardNormal(wall) * 0.01
            func corner(_ u: Double, _ v: Double) -> SIMD3<Double> {
                let flat = start + along * (opening.centre.x + u) + inward
                return SIMD3(flat.x, flat.y, opening.centre.y + v)
            }
            return [
                corner(-half.x, -half.y), corner(half.x, -half.y), corner(half.x, half.y),
                corner(-half.x, half.y),
            ]
        }
        let (a, b) = opening.surface.planeAxes
        let normal = opening.surface.normalAxis
        let low = [Surface.west, .south, .floor].contains(opening.surface)
        func corner(_ u: Double, _ v: Double) -> SIMD3<Double> {
            var p = SIMD3<Double>(repeating: 0)
            p[a] = opening.centre.x + u
            p[b] = opening.centre.y + v
            p[normal] = low ? 0.01 : room.size[normal] - 0.01
            return p
        }
        return [
            corner(-half.x, -half.y), corner(half.x, -half.y), corner(half.x, half.y),
            corner(-half.x, half.y),
        ]
    }

    /// What an item is, for the view's caption.
    func describe(_ item: Item, settings: RoomResponseSettings) -> String {
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        switch item {
        case .surface(let index):
            guard index < mesh.materials.count else { return "" }
            let material = mesh.materials[index]
            let area = mesh.materialAreas[index]
            return
                "\(names[index]): \(material.name), \(area.formatted(.number.precision(.fractionLength(1)))) m²; "
                + "absorbs \(percent(material.absorption[4])) and scatters \(percent(material.scattering[4])) at 1 kHz"
        case .source:
            return "Source \(settings.source.name)"
        case .receiver(let index):
            guard index < settings.receivers.count else { return "" }
            let receiver = settings.receivers[index]
            return "Receiver \(receiver.name), \(receiver.microphone?.summary ?? "omnidirectional")"
        case .opening(let index):
            guard index < settings.openings.count else { return "" }
            let opening = settings.openings[index]
            func metres(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
            return
                "\(opening.name): \(metres(opening.size.x)) × \(metres(opening.size.y)) m, open to the outside"
        case .zone(let index):
            guard let zone = settings.room.fittings?[index] else { return "" }
            return
                "\(zone.name): objects met \(zone.density.formatted(.number.precision(.fractionLength(2)))) "
                + "per metre, absorbing \(percent(zone.absorption[4])) at 1 kHz"
        }
    }
}
