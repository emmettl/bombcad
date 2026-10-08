import Foundation
import simd

/// Rooms of the shapes performance spaces take, built from `Solid` pieces of air.
///
/// Each returns a mesh whose materials are, in order: the audience seating, other floors, walls,
/// ceiling, the stage's floor and the stage's walls; `labels` names them.
public enum HallShapes {
    public static let labels = ["Audience", "Floors", "Walls", "Ceiling", "Stage floor", "Stage walls"]
    static let (audience, floors, walls, ceiling, stageFloor, stageWalls) = (0, 1, 2, 3, 4, 5)

    /// A shoebox concert hall: a flat floor with seating, a balcony along both sides and the back, and a
    /// stage house behind a proscenium at x < 0, its floor `stageRise` above the hall's.
    public static func shoebox(
        length: Double, width: Double, height: Double, stageDepth: Double, stageWidth: Double,
        stageHeight: Double, stageRise: Double, balconyHeight: Double, balconyDepth: Double,
        materials: [SurfaceMaterial]
    ) -> RoomMesh {
        let half = width / 2
        let front = half - balconyDepth
        var air = Solid.box(
            [-stageDepth, -stageWidth / 2, stageRise], [0, stageWidth / 2, stageRise + stageHeight],
            materials: [stageWalls, walls, stageWalls, stageWalls, stageFloor, ceiling])
        air = air.union(
            .box(
                [0, -half, 0], [length, half, height],
                materials: [walls, walls, walls, walls, floors, ceiling]))
        // The balcony: a 0.4 m slab with its front edge along the hall, cut out of the air.
        let slab = [balconyHeight - 0.4, balconyHeight]
        let pieces: [(SIMD3<Double>, SIMD3<Double>)] = [
            ([0, front, slab[0]], [length, half, slab[1]]),
            ([0, -half, slab[0]], [length, -front, slab[1]]),
            ([length - balconyDepth * 1.5, -half, slab[0]], [length, half, slab[1]]),
        ]
        for (low, high) in pieces { air = air.subtracting(.box(low, high, material: walls)) }
        // Seating: a 1 cm layer on the stalls and on the balcony.
        let seats: [(SIMD3<Double>, SIMD3<Double>)] = [
            ([length * 0.12, -front + 0.6, 0], [length - balconyDepth * 1.5 - 1, front - 0.6, 0.01]),
            (
                [length - balconyDepth * 1.5 + 0.3, -front, balconyHeight],
                [length - 0.3, front, balconyHeight + 0.01]
            ),
        ]
        for (low, high) in seats {
            air = air.subtracting(
                .box(low, high, materials: [floors, floors, floors, floors, audience, audience]))
        }
        return air.room(materials: materials).labelled(labels)
    }

    /// A raked lecture hall or auditorium: a fan-shaped plan widening from `frontWidth` at the stage to
    /// `backWidth`, its seating rising by `rake` over `depth`, under a ceiling sloping from `frontHeight`
    /// to `backHeight` above the stage floor; the stage, `stageDepth` deep, lies at x < 0, and a rear
    /// tier `tierDepth` deep sits `tierHeight` above the stalls' back row.
    public static func raked(
        depth: Double, frontWidth: Double, backWidth: Double, frontHeight: Double, backHeight: Double,
        rake: Double, stageDepth: Double, tierDepth: Double, tierHeight: Double, materials: [SurfaceMaterial]
    ) -> RoomMesh {
        // The long section, from the back of the stage to the back wall: stage floor at 0, stalls from
        // 0.6 m below it rising to `rake` above, ceiling sloping.
        let section: [SIMD2<Double>] = [
            [-stageDepth, 0], [0, 0], [0, -0.6], [depth, rake - 0.6], [depth, backHeight],
            [-stageDepth, frontHeight],
        ]
        let long = Solid.extrusion(
            section, along: 1, from: -backWidth, to: backWidth,
            sides: [stageFloor, walls, audience, walls, ceiling, stageWalls], ends: (walls, walls))
        let plan: [SIMD2<Double>] = [
            [-stageDepth, -frontWidth / 2], [0, -frontWidth / 2], [depth, -backWidth / 2],
            [depth, backWidth / 2],
            [0, frontWidth / 2], [-stageDepth, frontWidth / 2],
        ]
        let fan = Solid.extrusion(
            plan, along: 2, from: -1, to: max(frontHeight, backHeight) + 1,
            sides: [stageWalls, walls, walls, walls, stageWalls, stageWalls], ends: (floors, ceiling))
        var air = long.intersection(fan)
        // The rear tier: its underside slopes up towards the back, cut out of the air.
        let tierFront = depth - tierDepth
        let tierFloor = rake - 0.6 + tierHeight
        let tier: [SIMD2<Double>] = [
            [tierFront, tierFloor - 0.5], [depth + 1, tierFloor - 0.5], [depth + 1, tierFloor + 1.5],
            [tierFront, tierFloor],
        ]
        air = air.subtracting(
            .extrusion(
                tier, along: 1, from: -backWidth, to: backWidth, sides: [walls, walls, audience, walls],
                ends: (walls, walls)))
        return air.room(materials: materials).labelled(labels)
    }
}

extension RoomMesh {
    func labelled(_ labels: [String]) -> RoomMesh {
        var mesh = self
        mesh.labels = labels
        return mesh
    }
}
