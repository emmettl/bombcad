import Foundation
import simd

/// The terrain as the kernels read it (`ThermalTerrain` in Thermal.metal).
package struct TerrainSightUniforms {
    package var originX: Float
    package var originY: Float
    package var spacing: Float
    package var reach: Float
    package var columns: UInt32
    package var rows: UInt32
    /// The first cell's primitive in the acceleration structure; all of them are boxes with no
    /// terrain.
    package var firstCell: UInt32
    package var present: UInt32

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        originX: Float,
        originY: Float,
        spacing: Float,
        reach: Float,
        columns: UInt32,
        rows: UInt32,
        firstCell: UInt32,
        present: UInt32
    ) {
        self.originX = originX
        self.originY = originY
        self.spacing = spacing
        self.reach = reach
        self.columns = columns
        self.rows = rows
        self.firstCell = firstCell
        self.present = present
    }
}
