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
