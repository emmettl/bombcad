import Foundation
import simd

/// A room's outline in plan, extruded from the floor to the ceiling: vertical walls between a flat floor
/// and a flat ceiling.
public struct FloorPlan: Codable, Equatable, Sendable {
    /// Corners in metres, anticlockwise seen from above. Wall `i` runs from corner `i` to corner `i + 1`.
    public var corners: [SIMD2<Double>]
    /// One material per wall.
    public var walls: [SurfaceMaterial]

    public init(corners: [SIMD2<Double>], walls: [SurfaceMaterial]) {
        self.corners = corners
        self.walls = walls
    }

    /// The same material on every wall.
    public init(corners: [SIMD2<Double>], material: SurfaceMaterial) {
        self.init(corners: corners, walls: Array(repeating: material, count: corners.count))
    }

    public var count: Int { corners.count }

    public func start(_ wall: Int) -> SIMD2<Double> { corners[wall] }
    public func end(_ wall: Int) -> SIMD2<Double> { corners[(wall + 1) % corners.count] }
    public func length(_ wall: Int) -> Double { simd_distance(start(wall), end(wall)) }

    /// Unit normal of a wall pointing into the room (to the left of an anticlockwise edge).
    public func inwardNormal(_ wall: Int) -> SIMD2<Double> {
        let d = simd_normalize(end(wall) - start(wall))
        return [-d.y, d.x]
    }

    /// Signed area by the shoelace formula; positive when the corners run anticlockwise.
    public var signedArea: Double {
        corners.indices.reduce(0) { total, i in
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            return total + (a.x * b.y - b.x * a.y) / 2
        }
    }

    public var area: Double { abs(signedArea) }

    public var bounds: (min: SIMD2<Double>, max: SIMD2<Double>) {
        (corners.reduce(corners[0]) { simd_min($0, $1) }, corners.reduce(corners[0]) { simd_max($0, $1) })
    }

    /// Whether a point lies strictly inside the outline, by counting crossings of a ray along +x.
    public func contains(_ point: SIMD2<Double>) -> Bool {
        var inside = false
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if point.x < x { inside.toggle() }
            }
        }
        return inside
    }

    /// Shortest distance from a point to any wall.
    public func distanceToWalls(_ point: SIMD2<Double>) -> Double {
        corners.indices.map { segmentDistance(point, start($0), end($0)) }.min() ?? 0
    }

    /// The wall nearest a point.
    public func nearestWall(_ point: SIMD2<Double>) -> Int {
        corners.indices.min {
            segmentDistance(point, start($0), end($0)) < segmentDistance(point, start($1), end($1))
        } ?? 0
    }

    func validate() throws {
        guard corners.count >= 3, walls.count == corners.count else {
            throw AcousticError.invalid(
                "A floor plan needs at least three corners and one material per wall.")
        }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), signedArea > 0.25 else {
            throw AcousticError.invalid(
                "The floor plan's corners must run anticlockwise and enclose at least 0.25 m².")
        }
        for i in corners.indices where length(i) < 0.1 {
            throw AcousticError.invalid("Wall \(i + 1) of the floor plan is shorter than 10 cm.")
        }
        for i in corners.indices {
            for j in corners.indices where j > i + 1 && !(i == 0 && j == corners.count - 1) {
                if segmentsCross(start(i), end(i), start(j), end(j)) {
                    throw AcousticError.invalid("Walls \(i + 1) and \(j + 1) of the floor plan cross.")
                }
            }
        }
        for material in walls { try material.validate() }
    }

    // MARK: - Shapes

    /// A rectangle with its south-west corner at the origin.
    public static func rectangle(_ size: SIMD2<Double>, material: SurfaceMaterial) -> FloorPlan {
        FloorPlan(corners: [[0, 0], [size.x, 0], [size.x, size.y], [0, size.y]], material: material)
    }

    /// An L: the rectangle `size` without its north-east `notch`.
    public static func lShape(_ size: SIMD2<Double>, notch: SIMD2<Double>, material: SurfaceMaterial)
        -> FloorPlan
    {
        FloorPlan(
            corners: [
                [0, 0], [size.x, 0], [size.x, size.y - notch.y], [size.x - notch.x, size.y - notch.y],
                [size.x - notch.x, size.y], [0, size.y],
            ], material: material)
    }

    /// A T: a bar across the north side `size.x` wide and `bar` deep, on a stem `stem` wide, centred.
    public static func tShape(_ size: SIMD2<Double>, stem: Double, bar: Double, material: SurfaceMaterial)
        -> FloorPlan
    {
        let left = (size.x - stem) / 2
        let right = (size.x + stem) / 2
        let shoulder = size.y - bar
        return FloorPlan(
            corners: [
                [left, 0], [right, 0], [right, shoulder], [size.x, shoulder], [size.x, size.y], [0, size.y],
                [0, shoulder], [left, shoulder],
            ], material: material)
    }

    /// A trapezoid narrowing towards the north, as a fan-shaped hall or a room with splayed walls.
    public static func trapezoid(
        width: Double, depth: Double, narrowTo top: Double, material: SurfaceMaterial
    )
        -> FloorPlan
    {
        let inset = (width - top) / 2
        return FloorPlan(
            corners: [[0, 0], [width, 0], [width - inset, depth], [inset, depth]], material: material)
    }
}

func segmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let ab = b - a
    let t = min(max(simd_dot(p - a, ab) / simd_length_squared(ab), 0), 1)
    return simd_distance(p, a + ab * t)
}

/// Whether two segments properly cross or touch.
func segmentsCross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
    func cross(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { u.x * v.y - u.y * v.x }
    let d1 = cross(b - a, c - a)
    let d2 = cross(b - a, d - a)
    let d3 = cross(d - c, a - c)
    let d4 = cross(d - c, b - c)
    return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0) && d1 != 0 && d2 != 0
}

/// Parameter t ≥ 0 along `origin + t direction` where it meets the segment a–b, if it does.
func raySegment(
    _ origin: SIMD2<Double>, _ direction: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
) -> Double? {
    let edge = b - a
    let denominator = direction.x * edge.y - direction.y * edge.x
    guard abs(denominator) > 1e-15 else { return nil }
    let offset = a - origin
    let t = (offset.x * edge.y - offset.y * edge.x) / denominator
    let u = (offset.x * direction.y - offset.y * direction.x) / denominator
    guard t > 1e-9, u >= 0, u <= 1 else { return nil }
    return t
}

extension ShoeboxRoom {
    /// Every boundary with its area and material: the six faces of a box, or a plan's walls with its
    /// floor and ceiling.
    public var boundaries: [(area: Double, material: SurfaceMaterial)] {
        if let mesh { return mesh.faces.indices.map { (mesh.normalAndArea($0).area, mesh.material(of: $0)) } }
        guard let plan else { return Surface.allCases.map { (area($0), self[$0]) } }
        return plan.corners.indices.map { (plan.length($0) * size.z, plan.walls[$0]) } + [
            (plan.area, floor), (plan.area, ceiling),
        ]
    }

    /// This room with its mesh's bounding box as its size, moved so its corners fill `[0, size]`.
    public func fittingMesh() -> ShoeboxRoom {
        guard var mesh else { return self }
        let (low, high) = mesh.bounds
        mesh.vertices = mesh.vertices.map { $0 - low }
        var room = self
        room.mesh = mesh
        room.size = high - low
        return room
    }

    /// This room with its plan's bounding box as its size, so a plan's corners fill `[0, size]`.
    public func fittingPlan() -> ShoeboxRoom {
        guard var plan else { return self }
        let (low, high) = plan.bounds
        plan.corners = plan.corners.map { $0 - low }
        var room = self
        room.plan = plan
        room.size.x = high.x - low.x
        room.size.y = high.y - low.y
        return room
    }
}
