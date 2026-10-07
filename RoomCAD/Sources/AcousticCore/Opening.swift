import Foundation

/// An open area in one of the room's surfaces, such as an open door or window, through which sound
/// leaves the room.
public struct Opening: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var surface: Surface
    /// In a room with a floor plan, the plan's wall the opening is in; then `surface` is ignored and the
    /// coordinates are the distance along the wall from its first corner and the height.
    public var wall: Int?
    /// Centre on the surface, in metres from its lower corner along the surface's two axes (see
    /// `Surface.planeAxes`).
    public var centre: SIMD2<Double>
    /// Width and height along the same axes, in metres.
    public var size: SIMD2<Double>

    public init(
        id: UUID = UUID(), name: String, surface: Surface, wall: Int? = nil, centre: SIMD2<Double>,
        size: SIMD2<Double>
    ) {
        self.id = id
        self.name = name
        self.surface = surface
        self.wall = wall
        self.centre = centre
        self.size = size
    }

    public var area: Double { size.x * size.y }

    /// Whether a point on the surface, in the surface's axes, lies in the opening.
    func contains(_ point: SIMD2<Double>) -> Bool {
        abs(point.x - centre.x) <= size.x / 2 && abs(point.y - centre.y) <= size.y / 2
    }

    func validate(in room: ShoeboxRoom) throws {
        let extent: SIMD2<Double>
        if let wall {
            guard let plan = room.plan, plan.corners.indices.contains(wall) else {
                throw AcousticError.invalid("\(name) is in a wall the floor plan does not have.")
            }
            extent = [plan.length(wall), room.size.z]
        } else {
            if room.plan != nil, ![.floor, .ceiling].contains(surface) {
                throw AcousticError.invalid(
                    "\(name) must name a wall of the floor plan, or the floor or ceiling.")
            }
            extent = room.extent(of: surface)
        }
        guard size.x > 0, size.y > 0, centre.x - size.x / 2 >= -1e-9, centre.y - size.y / 2 >= -1e-9,
            centre.x + size.x / 2 <= extent.x + 1e-9, centre.y + size.y / 2 <= extent.y + 1e-9
        else { throw AcousticError.invalid("\(name) must lie within the \(surface.rawValue) surface.") }
    }
}

extension Surface {
    /// The room axes spanning this surface, in the order an opening's coordinates use: horizontal first.
    public var planeAxes: (Int, Int) {
        switch self {
        case .west, .east: (1, 2)
        case .south, .north: (0, 2)
        case .floor, .ceiling: (0, 1)
        }
    }

    /// The room axis this surface is perpendicular to.
    public var normalAxis: Int {
        switch self {
        case .west, .east: 0
        case .south, .north: 1
        case .floor, .ceiling: 2
        }
    }
}

extension ShoeboxRoom {
    /// The surface's size along its two plane axes.
    public func extent(of surface: Surface) -> SIMD2<Double> {
        let (a, b) = surface.planeAxes
        return [size[a], size[b]]
    }

    /// This room with each surface's absorption raised by the share of it that is open:
    /// `α' = α (1 - f) + f`. The statistical models and the image sources use this; the ray tracer and the
    /// wave solver place the openings exactly.
    public func withOpenings(_ openings: [Opening]) -> ShoeboxRoom {
        var room = self
        if var plan = room.plan {
            for wall in plan.corners.indices {
                let open = openings.filter { $0.wall == wall }.reduce(0) { $0 + $1.area }
                guard open > 0 else { continue }
                let fraction = min(1, open / (plan.length(wall) * size.z))
                plan.walls[wall].absorption = plan.walls[wall].absorption.map {
                    $0 * (1 - fraction) + fraction
                }
            }
            room.plan = plan
        }
        for surface in Surface.allCases {
            let open = openings.filter { $0.surface == surface && $0.wall == nil }.reduce(0) { $0 + $1.area }
            guard open > 0 else { continue }
            let fraction = min(1, open / area(surface))
            room[surface].absorption = room[surface].absorption.map { $0 * (1 - fraction) + fraction }
        }
        return room
    }
}
