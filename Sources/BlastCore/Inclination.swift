import Foundation
import simd

/// A solid laid as a plane at a pitch: a roof's slope. The solid's box holds the plane, which runs
/// from the box's bottom along its low side to its top along its high side, rising along x or y; it
/// is meshed as shells in its own plane (`ShellMesh`), each element square to it, and keeps the
/// solid's material. With `trimsWalls`, the walls under it within its plan lose their elements
/// above it, so that a wall running up to a ridge is a gable.
public struct Inclination: Sendable, Hashable, Codable {
    /// The horizontal axis the plane rises along: 0 for x, 1 for y.
    public var rise: Int
    /// Whether it rises towards the box's high side along `rise`, or towards its low side.
    public var upwards: Bool
    /// The plane's thickness, square to it, in metres.
    public var thickness: Float
    /// Whether the walls under it lose their elements above it (gables under a pitched roof).
    public var trimsWalls: Bool

    public init(rise: Int, upwards: Bool, thickness: Float, trimsWalls: Bool = false) {
        self.rise = rise
        self.upwards = upwards
        self.thickness = thickness
        self.trimsWalls = trimsWalls
    }

    func validate() throws {
        guard rise == 0 || rise == 1, thickness.isFinite, thickness > 0 else {
            throw ImportedMesh.ImportError.invalid(
                "An inclined plane rises along x or y and has a positive thickness.")
        }
    }

    /// The plane in `box`: where its midsurface starts (its low edge's first corner), the unit
    /// vector along that edge (`along`, horizontal), the unit vector up the slope (`up`), the
    /// lengths of each, and its unit normal (up out of the plane, `along` × `up`).
    func plane(in box: Box) -> (
        origin: SIMD3<Float>, along: SIMD3<Float>, up: SIMD3<Float>, lengths: SIMD2<Float>,
        normal: SIMD3<Float>
    ) {
        let r = rise
        let a = 1 - rise
        let run = box.max[r] - box.min[r]
        let height = box.max.z - box.min.z
        var origin = box.min
        var up = SIMD3<Float>.zero
        up[r] = upwards ? run : -run
        up.z = height
        if !upwards { origin[r] = box.max[r] }
        let slope = simd_length(up)
        up /= slope
        var along = SIMD3<Float>.zero
        along[a] = 1
        // Along and up the slope, the normal up out of the plane; along turned the other way if not.
        if simd_cross(along, up).z < 0 {
            along[a] = -1
            origin[a] = box.max[a]
        }
        let length = box.max[a] - box.min[a]
        return (origin, along, up, SIMD2(length, slope), simd_normalize(simd_cross(along, up)))
    }

    /// The pitch, in degrees from the horizontal.
    public func pitch(in box: Box) -> Float {
        atan2(box.max.z - box.min.z, box.max[rise] - box.min[rise]) * 180 / .pi
    }

    /// The midsurface's height above (x, y), if the point lies in the box's plan.
    func height(at point: SIMD2<Float>, in box: Box, tolerance: Float = 1e-4) -> Float? {
        guard point.x >= box.min.x - tolerance, point.x <= box.max.x + tolerance,
            point.y >= box.min.y - tolerance, point.y <= box.max.y + tolerance
        else { return nil }
        let run = box.max[rise] - box.min[rise]
        let s = (point[rise] - box.min[rise]) / max(run, 1e-6)
        let share = upwards ? s : 1 - s
        return box.min.z + min(max(share, 0), 1) * (box.max.z - box.min.z)
    }
}

extension StructureModel {
    /// The inclination solid `index` is laid at, if it is a plane at a pitch.
    public func inclination(of index: Int) -> Inclination? {
        solidInclinations.indices.contains(index) ? solidInclinations[index] : nil
    }

    /// Lays solid `index` as a plane at a pitch, or (nil) as a plain solid again.
    public mutating func setInclination(_ inclination: Inclination?, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidInclinations.count <= index { solidInclinations.append(nil) }
        solidInclinations[index] = inclination
        while solidInclinations.last.map({ $0 == nil }) == true { solidInclinations.removeLast() }
    }

    /// Whether any solid is laid at a pitch.
    public var hasInclinedSolids: Bool { solidInclinations.contains { $0 != nil } }
}
