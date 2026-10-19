import Foundation
import simd

/// The visible surface of a body at one moment, as the renderer draws it (`structureVertex`,
/// `shellVertex` and `beamVertex` in Render.metal): the outer faces of intact solid elements, a
/// box for each shell and beam, and a small cube of rubble for each failed element. It is read
/// from the solvers' buffers, so take it only while no batch is in flight.
public struct StructureSurface: Sendable, Equatable {
    public struct Material: Sendable, Equatable {
        public var name: String
        public var isTransparent: Bool
    }

    public var points: [SIMD3<Float>] = []
    /// Four indices into `points` per face, counter-clockwise seen from outside.
    public var quads: [Int32] = []
    /// Per face: its element's damage index, 0 when sound and 1 at the point of failure. It goes on
    /// rising past 1 until the element is removed, as the app's colours do not show; 1 for rubble.
    public var damage: [Float] = []
    /// Per face: an index into `materials`.
    public var material: [Int32] = []
    /// Per face: whether it belongs to a lump of rubble standing for a failed element.
    public var rubble: [Bool] = []
    public var materials: [Material] = []
    /// Per-face owner index, with a stable ID/name table for multi-body exports.
    public var object: [Int32] = []
    public var objectIDs: [UUID] = []
    public var objectNames: [String] = []
    public var faceCount: Int { quads.count / 4 }

    public init() {}

    /// The faces of a cube whose corners are numbered by bits: bit 0 along x, 1 along y, 2 along z.
    package static let bitCubeFaces = [
        [0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6], [0, 1, 3, 2], [4, 5, 7, 6],
    ]
    /// The faces of a shell's box: its four nodes on the lower face, then on the upper.
    package static let shellFaces = [
        [0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7],
    ]

    package mutating func index(of material: StructureMaterial) -> Int32 {
        let entry = Material(name: material.name, isTransparent: material.isTransparent)
        if let index = materials.firstIndex(of: entry) { return Int32(index) }
        materials.append(entry)
        return Int32(materials.count - 1)
    }

    package mutating func appendFace(_ indices: [Int32], damage: Float, material: Int32, rubble: Bool = false)
    {
        quads.append(contentsOf: indices)
        self.damage.append(damage)
        self.material.append(material)
        self.rubble.append(rubble)
    }

    /// Appends a box of eight corners, each face turned away from the box's middle.
    package mutating func appendBox(
        _ corners: [SIMD3<Float>], faces: [[Int]], damage: Float, material: Int32, rubble: Bool = false
    ) {
        let base = Int32(points.count)
        points.append(contentsOf: corners)
        let middle = corners.reduce(SIMD3<Float>.zero, +) / 8
        for face in faces {
            let p = face.map { corners[$0] }
            let normal = cross(p[1] - p[0], p[2] - p[0]) + cross(p[2] - p[0], p[3] - p[0])
            let outward = dot(normal, (p[0] + p[1] + p[2] + p[3]) / 4 - middle) >= 0
            appendFace(
                (outward ? face : face.reversed()).map { base + Int32($0) }, damage: damage,
                material: material, rubble: rubble)
        }
    }
}
