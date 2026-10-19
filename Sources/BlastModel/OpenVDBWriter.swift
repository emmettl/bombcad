import Foundation
import simd

/// Writes float grids in OpenVDB's file format, without the OpenVDB library: enough for Blender,
/// Houdini or USD to read a sampled volume. Only what that needs is written: a standard
/// `Tree_float_5_4_3` (a root over 4096³ and 128³ internal nodes over 8³ leaves), an affine
/// transform, and the leaves that hold an active voxel. File format version 224; values zipped
/// when that makes them smaller, as OpenVDB's own ZIP compression does.
///
/// The layout follows OpenVDB's `io::Archive`, `GridDescriptor`, `RootNode`, `InternalNode` and
/// `LeafNode` writers (OpenVDB 11).
public enum OpenVDBWriter {
    /// A dense block of samples on a regular grid, voxel (0, 0, 0) centred at `origin`.
    public struct Grid {
        public var name: String
        public var dimensions: SIMD3<Int>
        public var voxelSize: Double
        public var origin: SIMD3<Double>
        /// Samples with x varying fastest, then y, then z.
        public var values: [Float]
        /// Voxels whose magnitude reaches this are active; the rest are left out at zero.
        public var threshold: Float
        /// Written as the grid's class: "fog volume" for densities, "unknown" for anything else.
        public var gridClass: String

        public init(
            name: String, dimensions: SIMD3<Int>, voxelSize: Double, origin: SIMD3<Double>, values: [Float],
            threshold: Float, gridClass: String = "unknown"
        ) {
            precondition(values.count == dimensions.x * dimensions.y * dimensions.z)
            self.name = name
            self.dimensions = dimensions
            self.voxelSize = voxelSize
            self.origin = origin
            self.values = values
            self.threshold = threshold
            self.gridClass = gridClass
        }
    }

    package static let fileVersion: UInt32 = 224
    package static let compressNone: UInt32 = 0
    package static let compressZip: UInt32 = 1
}
