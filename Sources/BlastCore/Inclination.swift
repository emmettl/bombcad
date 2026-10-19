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
    /// The plane given outright, in place of `rise` and `upwards`: a wall turned in plan, a chord
    /// of a curved wall. Nil for a plane at a pitch through its box.
    public var frame: Frame?

    /// A rectangle in space: a corner, the unit vectors along its two edges from it (square to
    /// each other) and their lengths, m.
    public struct Frame: Sendable, Hashable, Codable {
        public var origin: SIMD3<Float>
        public var along: SIMD3<Float>
        public var up: SIMD3<Float>
        public var lengths: SIMD2<Float>

        public init(origin: SIMD3<Float>, along: SIMD3<Float>, up: SIMD3<Float>, lengths: SIMD2<Float>) {
            self.origin = origin
            self.along = along
            self.up = up
            self.lengths = lengths
        }

        /// A wall standing upright: its midsurface from `start` to `end` (at their height) up
        /// `height` m.
        public static func upright(from start: SIMD3<Float>, to end: SIMD3<Float>, height: Float) -> Frame {
            var run = end - start
            run.z = 0
            let length = simd_length(run)
            return Frame(
                origin: start, along: run / max(length, 1e-9), up: SIMD3(0, 0, 1),
                lengths: SIMD2(length, height))
        }

        /// The box it lies in.
        public var box: Box {
            let corners = [
                origin, origin + lengths.x * along, origin + lengths.y * up,
                origin + lengths.x * along + lengths.y * up,
            ]
            return Box(
                min: corners.reduce(SIMD3(repeating: .infinity), simd_min),
                max: corners.reduce(SIMD3(repeating: -.infinity), simd_max))
        }
    }

    public init(rise: Int, upwards: Bool, thickness: Float, trimsWalls: Bool = false) {
        self.rise = rise
        self.upwards = upwards
        self.thickness = thickness
        self.trimsWalls = trimsWalls
    }

    /// A plane given outright (`frame`), its own thickness, trimming nothing.
    public init(frame: Frame, thickness: Float) {
        self.rise = 0
        self.upwards = true
        self.thickness = thickness
        self.trimsWalls = false
        self.frame = frame
    }

    func validate() throws {
        guard rise == 0 || rise == 1, thickness.isFinite, thickness > 0 else {
            throw ImportedMesh.ImportError.invalid(
                "An inclined plane rises along x or y and has a positive thickness.")
        }
        if let frame {
            guard abs(simd_length(frame.along) - 1) < 1e-3, abs(simd_length(frame.up) - 1) < 1e-3,
                abs(simd_dot(frame.along, frame.up)) < 1e-3, frame.lengths.x > 0, frame.lengths.y > 0,
                !trimsWalls
            else {
                throw ImportedMesh.ImportError.invalid(
                    "A plane given outright has unit edges square to each other, lengths above 0, and trims nothing."
                )
            }
        }
    }

    /// The plane in `box`: where its midsurface starts (its low edge's first corner), the unit
    /// vector along that edge (`along`, horizontal), the unit vector up the slope (`up`), the
    /// lengths of each, and its unit normal (up out of the plane, `along` × `up`).
    func plane(in box: Box) -> (
        origin: SIMD3<Float>, along: SIMD3<Float>, up: SIMD3<Float>, lengths: SIMD2<Float>,
        normal: SIMD3<Float>
    ) {
        if let frame {
            return (
                frame.origin, frame.along, frame.up, frame.lengths,
                simd_normalize(simd_cross(frame.along, frame.up))
            )
        }
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

    /// The pitch, in degrees from the horizontal (90 for a wall standing upright).
    public func pitch(in box: Box) -> Float {
        if let frame {
            return acos(min(abs(simd_normalize(simd_cross(frame.along, frame.up)).z), 1)) * 180 / .pi
        }
        return atan2(box.max.z - box.min.z, box.max[rise] - box.min[rise]) * 180 / .pi
    }

    /// The midsurface's height above (x, y), if the point lies in the box's plan.
    func height(at point: SIMD2<Float>, in box: Box, tolerance: Float = 1e-4) -> Float? {
        guard frame == nil else { return nil }
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
