import AcousticCore
import simd

/// Edits made in the 3D view, as changes to the settings.
extension RoomResponseSettings {
    /// The material of one of the room's surfaces, numbered as in `RoomScene.surfaces(of:)`: a mesh's
    /// materials; a plan's walls, then floor and ceiling; or a box's six surfaces.
    func surfaceMaterial(_ index: Int) -> SurfaceMaterial? {
        if let mesh = room.mesh { return index < mesh.materials.count ? mesh.materials[index] : nil }
        if let plan = room.plan {
            switch index {
            case 0..<plan.corners.count: return plan.walls[index]
            case plan.corners.count: return room.floor
            case plan.corners.count + 1: return room.ceiling
            default: return nil
            }
        }
        return index < Surface.allCases.count ? room[Surface.allCases[index]] : nil
    }

    /// These settings with surface `index`'s material replaced.
    func settingSurfaceMaterial(_ index: Int, to material: SurfaceMaterial) -> RoomResponseSettings {
        var result = self
        if var mesh = room.mesh {
            guard index < mesh.materials.count else { return self }
            mesh.materials[index] = material
            result.room.mesh = mesh
        } else if var plan = room.plan {
            switch index {
            case 0..<plan.corners.count:
                plan.walls[index] = material
                result.room.plan = plan
            case plan.corners.count: result.room.floor = material
            case plan.corners.count + 1: result.room.ceiling = material
            default: return self
            }
        } else if index < Surface.allCases.count {
            result.room[Surface.allCases[index]] = material
        }
        return result
    }

    /// The position of the source or a receiver.
    func position(of item: RoomScene.Item) -> SIMD3<Double>? {
        switch item {
        case .source: source.position
        case .receiver(let index): index < receivers.count ? receivers[index].position : nil
        case .surface, .zone, .opening, .corner: nil
        }
    }

    /// These settings with the source or a receiver moved to `position`, snapped to centimetres, if it
    /// lies inside the room and at least `margin` from its boundary; otherwise unchanged.
    func moving(_ item: RoomScene.Item, to position: SIMD3<Double>, margin: Double = 0.05)
        -> RoomResponseSettings
    {
        let snapped = (position * 100).rounded(.toNearestOrEven) / 100
        guard room.contains(snapped), room.clearance(snapped) >= margin else { return self }
        var result = self
        switch item {
        case .source: result.source.position = snapped
        case .receiver(let index) where index < receivers.count: result.receivers[index].position = snapped
        default: return self
        }
        return result
    }
}

extension RoomResponseSettings {
    /// These settings with a new room of any shape: openings, which a mesh does not take, are dropped,
    /// as are fitted zones that no longer fit. The source and receivers stay where they are if they are
    /// still well inside; otherwise the source goes to a roomy spot near one end, and the receivers to
    /// the roomiest spot well away from it, side by side as they were.
    func replacingRoom(with room: ShoeboxRoom) -> RoomResponseSettings {
        var result = self
        result.room = room
        result.openings = []
        result.room.fittings = room.fittings?.filter { all($0.low .>= 0) && all($0.high .<= room.size) }
        if result.room.fittings?.isEmpty == true { result.room.fittings = nil }
        func fits(_ p: SIMD3<Double>) -> Bool { room.contains(p) && room.clearance(p) >= 0.3 }
        guard !(fits(source.position) && receivers.allSatisfy { fits($0.position) }) else { return result }
        // Candidates on a grid through the room, roomiest first.
        var candidates: [(point: SIMD3<Double>, clearance: Double)] = []
        let steps = 12
        for i in 1..<steps {
            for j in 1..<steps {
                for k in 1..<6 {
                    let p =
                        room.size * SIMD3(Double(i) / Double(steps), Double(j) / Double(steps), Double(k) / 6)
                    guard room.contains(p) else { continue }
                    let clearance = room.clearance(p)
                    if clearance >= 0.3 {
                        candidates.append(((p * 100).rounded(.toNearestOrEven) / 100, clearance))
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return result }
        candidates.sort { $0.clearance > $1.clearance }
        let roomy = candidates.prefix(max(1, candidates.count / 4))
        let source = roomy.min { $0.point.x < $1.point.x }!.point
        let far = roomy.max { a, b in
            simd_distance(a.point, source) * a.clearance < simd_distance(b.point, source) * b.clearance
        }!.point
        result.source.position = source
        let offsets = receivers.map(\.position.y)
        let middle = offsets.isEmpty ? 0 : (offsets.min()! + offsets.max()!) / 2
        for index in result.receivers.indices {
            var p = far
            p.y += min(max(receivers[index].position.y - middle, -1), 1)
            result.receivers[index].position = fits(p) ? p : far
        }
        return result
    }
}

/// The plane an opening lies in: a point on it, two axes along it matching the opening's coordinates,
/// and how far those run.
struct OpeningFrame {
    var origin: SIMD3<Double>
    var u: SIMD3<Double>
    var v: SIMD3<Double>
    var extent: SIMD2<Double>

    var normal: SIMD3<Double> { simd_normalize(simd_cross(u, v)) }

    /// A point's coordinates in the plane.
    func coordinates(_ point: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(simd_dot(point - origin, u), simd_dot(point - origin, v))
    }
}

extension RoomResponseSettings {
    /// The smallest a zone or opening may be made, in metres along each side.
    static let smallestSide = 0.1

    func frame(of opening: Opening) -> OpeningFrame? {
        if let wall = opening.wall {
            guard let plan = room.plan, wall < plan.corners.count else { return nil }
            let start = plan.start(wall)
            let along = simd_normalize(plan.end(wall) - start)
            return OpeningFrame(
                origin: SIMD3(start.x, start.y, 0), u: SIMD3(along.x, along.y, 0), v: [0, 0, 1],
                extent: [plan.length(wall), room.size.z])
        }
        let (a, b) = opening.surface.planeAxes
        let normal = opening.surface.normalAxis
        var origin = SIMD3<Double>(repeating: 0)
        if ![Surface.west, .south, .floor].contains(opening.surface) { origin[normal] = room.size[normal] }
        var u = SIMD3<Double>(repeating: 0)
        var v = SIMD3<Double>(repeating: 0)
        u[a] = 1
        v[b] = 1
        return OpeningFrame(origin: origin, u: u, v: v, extent: [room.size[a], room.size[b]])
    }

    /// These settings with opening `index` centred at `centre`, kept within its surface.
    func movingOpening(_ index: Int, to centre: SIMD2<Double>) -> RoomResponseSettings {
        guard index < openings.count, let frame = frame(of: openings[index]) else { return self }
        var result = self
        let half = openings[index].size / 2
        let low = half
        let high = simd_max(frame.extent - half, low)
        result.openings[index].centre = (simd_clamp(centre, low, high) * 100).rounded(.toNearestOrEven) / 100
        return result
    }

    /// These settings with the corner of opening `index` nearest `point` moved to it, within its
    /// surface and no smaller than `smallestSide`.
    func resizingOpening(_ index: Int, toward point: SIMD2<Double>) -> RoomResponseSettings {
        guard index < openings.count, let frame = frame(of: openings[index]) else { return self }
        let opening = openings[index]
        let p = (simd_clamp(point, .zero, frame.extent) * 100).rounded(.toNearestOrEven) / 100
        var low = opening.centre - opening.size / 2
        var high = opening.centre + opening.size / 2
        for axis in 0..<2 {
            if abs(p[axis] - low[axis]) < abs(p[axis] - high[axis]) {
                low[axis] = min(p[axis], high[axis] - Self.smallestSide)
            } else {
                high[axis] = max(p[axis], low[axis] + Self.smallestSide)
            }
        }
        var result = self
        result.openings[index].centre = (low + high) / 2
        result.openings[index].size = high - low
        return result
    }

    /// These settings with zone `zone` replaced, if the new one lies within the room and overlaps no
    /// other zone; otherwise unchanged.
    func replacingZone(_ index: Int, with zone: FittingZone) -> RoomResponseSettings {
        guard let zones = room.fittings, index < zones.count, all(zone.low .>= -1e-9),
            all(zone.high .<= room.size + 1e-9), all(zone.high - zone.low .>= Self.smallestSide - 1e-9)
        else { return self }
        for (other, existing) in zones.enumerated() where other != index {
            if all(zone.low .< existing.high - 1e-9) && all(existing.low .< zone.high - 1e-9) { return self }
        }
        var result = self
        result.room.fittings![index] = zone
        return result
    }

    /// These settings with zone `index` moved by `offset`, as far as it can go within the room.
    func movingZone(_ index: Int, by offset: SIMD3<Double>) -> RoomResponseSettings {
        guard let zone = room.fittings?[safe: index] else { return self }
        let shift = simd_clamp(offset, -zone.low, room.size - zone.high)
        var moved = zone
        moved.low = ((zone.low + shift) * 100).rounded(.toNearestOrEven) / 100
        moved.high = moved.low + (zone.high - zone.low)
        return replacingZone(index, with: moved)
    }

    /// These settings with the corner of zone `index`'s footprint nearest `point` moved to it, or with
    /// `vertical`, its top moved to `point`'s height; within the room and no smaller than
    /// `smallestSide`.
    func resizingZone(_ index: Int, toward point: SIMD3<Double>, vertical: Bool) -> RoomResponseSettings {
        guard let zone = room.fittings?[safe: index] else { return self }
        let p = (simd_clamp(point, .zero, room.size) * 100).rounded(.toNearestOrEven) / 100
        var resized = zone
        if vertical {
            resized.high.z = max(p.z, zone.low.z + Self.smallestSide)
        } else {
            for axis in 0..<2 {
                if abs(p[axis] - zone.low[axis]) < abs(p[axis] - zone.high[axis]) {
                    resized.low[axis] = min(p[axis], zone.high[axis] - Self.smallestSide)
                } else {
                    resized.high[axis] = max(p[axis], zone.low[axis] + Self.smallestSide)
                }
            }
        }
        return replacingZone(index, with: resized)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension RoomResponseSettings {
    /// These settings with everything in the room moved by `offset`: the source and receivers, the
    /// zones, a plan's corners or a mesh's vertices, and openings' positions on the surfaces they move
    /// along. The room's size is unchanged.
    func translating(by offset: SIMD3<Double>) -> RoomResponseSettings {
        var result = self
        result.source.position += offset
        for index in result.receivers.indices { result.receivers[index].position += offset }
        result.room.fittings = room.fittings?.map { zone in
            var zone = zone
            zone.low += offset
            zone.high += offset
            return zone
        }
        result.room.plan?.corners = room.plan?.corners.map { $0 + SIMD2(offset.x, offset.y) } ?? []
        result.room.mesh?.vertices = room.mesh?.vertices.map { $0 + offset } ?? []
        for index in result.openings.indices where result.openings[index].wall == nil {
            let (a, b) = result.openings[index].surface.planeAxes
            result.openings[index].centre += SIMD2(offset[a], offset[b])
        }
        return result
    }

    /// These settings with surface `index` (numbered as in `RoomScene.surfaces(of:)`) pushed out of the
    /// room by `distance` metres, or pulled in for a negative one: a box's wall, floor or ceiling, or a
    /// plan's wall, with its two corners, or its floor or ceiling. What is inside keeps its place
    /// relative to the surfaces that do not move. In a mesh, `face` says which face's plane moves (see
    /// `RoomMesh.pushingPlane`). Nil if the result would not be a valid room.
    func pushingSurface(_ index: Int, face: Int? = nil, by distance: Double) -> RoomResponseSettings? {
        let step = (distance * 100).rounded() / 100
        var result = self
        if let mesh = room.mesh {
            guard let face, mesh.faces.indices.contains(face), mesh.faces[face].material == index,
                let pushed = mesh.pushingPlane(of: face, by: step)
            else { return nil }
            result.room.mesh = pushed
            // Keep the mesh starting at the origin, shifting everything with it.
            let (low, high) = pushed.bounds
            result = result.translating(by: -low)
            result.room.size = high - low
            guard (try? result.validate()) != nil else { return nil }
            return result
        }
        // The floor and ceiling are the box's last two surfaces, and a plan's too.
        let floorIndex = room.plan.map { $0.corners.count } ?? 4
        if let plan = room.plan, index < plan.corners.count {
            let outward = -plan.inwardNormal(index) * step
            var corners = plan.corners
            corners[index] += outward
            corners[(index + 1) % corners.count] += outward
            result.room.plan?.corners = corners
            // Keep the plan's corners at or above zero, shifting everything if it grew past the origin.
            let low = corners.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
            let high = corners.reduce(-SIMD2(Double.infinity, .infinity)) { simd_max($0, $1) }
            result = result.translating(by: SIMD3(-low.x, -low.y, 0))
            result.room.size.x = high.x - low.x
            result.room.size.y = high.y - low.y
        } else {
            let surface: Surface
            switch index - floorIndex {
            case 0: surface = .floor
            case 1: surface = .ceiling
            default:
                guard room.plan == nil, index < 4 else { return nil }
                surface = Surface.allCases[index]
            }
            let axis = surface.normalAxis
            if [Surface.west, .south, .floor].contains(surface) {
                // The low wall moves; everything else shifts so the far wall stays put.
                result.room.size[axis] += step
                var offset = SIMD3<Double>(repeating: 0)
                offset[axis] = step
                result = result.translating(by: offset)
            } else {
                result.room.size[axis] += step
            }
        }
        guard (try? result.validate()) != nil else { return nil }
        return result
    }
}

extension RoomResponseSettings {
    /// These settings with the plan's corner `index` moved to `position`, snapped to centimetres. If the
    /// plan then reaches past the origin, everything shifts so its corners stay at or above zero; the
    /// room's length and width follow the plan. Nil if the walls would cross or anything would be left
    /// outside.
    func movingCorner(_ index: Int, to position: SIMD2<Double>) -> RoomResponseSettings? {
        guard var plan = room.plan, plan.corners.indices.contains(index) else { return nil }
        plan.corners[index] = (position * 100).rounded(.toNearestOrEven) / 100
        var result = self
        result.room.plan = plan
        let low = plan.corners.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let high = plan.corners.reduce(-SIMD2(Double.infinity, .infinity)) { simd_max($0, $1) }
        result = result.translating(by: SIMD3(-low.x, -low.y, 0))
        result.room.size.x = high.x - low.x
        result.room.size.y = high.y - low.y
        guard (try? result.validate()) != nil else { return nil }
        return result
    }
}
