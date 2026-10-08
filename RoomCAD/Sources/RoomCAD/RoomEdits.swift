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
        case .surface, .zone: nil
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
