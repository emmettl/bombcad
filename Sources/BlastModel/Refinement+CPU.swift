import Foundation
import simd

/// Matches `TerrainUniforms` in Refine.metal.
package struct TerrainUniforms {
    package var origin: SIMD2<Float> = .zero
    package var spacing: Float = 1
    package var columns: UInt32 = 0
    package var rows: UInt32 = 0
    package var enabled: UInt32 = 0
    /// With cut cells, the coarse grid's quadrature points to an edge (`TerrainCutGeometry.samples`).
    package var cutSamples: UInt32 = 8

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        origin: SIMD2<Float> = .zero,
        spacing: Float = 1,
        columns: UInt32 = 0,
        rows: UInt32 = 0,
        enabled: UInt32 = 0,
        cutSamples: UInt32 = 8
    ) {
        self.origin = origin
        self.spacing = spacing
        self.columns = columns
        self.rows = rows
        self.enabled = enabled
        self.cutSamples = cutSamples
    }
}

/// `PaneLookup` in Refine.metal: 32 bytes, as the kernels read its (cell, pane) entries from the
/// byte after it. Its padding is three floats, not a `SIMD3<Float>`, whose 16-byte alignment made
/// it 48 in Swift: the kernels then took two zeros for entries and missed the last two, so the two
/// highest pane cells never opened on the fine grid and pane 0 breaking opened coarse cell
/// (0, 0, 0)'s fine cells.
package struct PaneLookup {
    package var count: UInt32 = 0
    package var nx: UInt32 = 0
    package var ny: UInt32 = 0
    package var nz: UInt32 = 0
    package var coarseDx: Float = 0
    var pad0: Float = 0
    package var pad1: Float = 0
    var pad2: Float = 0

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        count: UInt32 = 0,
        nx: UInt32 = 0,
        ny: UInt32 = 0,
        nz: UInt32 = 0,
        coarseDx: Float = 0,
        pad0: Float = 0,
        pad1: Float = 0,
        pad2: Float = 0
    ) {
        self.count = count
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.coarseDx = coarseDx
        self.pad0 = pad0
        self.pad1 = pad1
        self.pad2 = pad2
    }
}

/// Refine.metal's `FacadeBand`: the coarse grid's size, the ratio from a level's cells to coarse
/// ones, the overpressure (Pa) above which the band holds refinement, the ambient pressure, on.
package struct FacadeBandParameters {
    package var nx: UInt32 = 0
    package var ny: UInt32 = 0
    package var nz: UInt32 = 0
    package var ratio: UInt32 = 1
    package var threshold: Float = 0
    package var ambient: Float = 0
    package var on: UInt32 = 0
    /// 1 where the band's bit 2 marks the coarse cells above the refinement's ceiling
    /// (`SolverConfiguration.refinementCeiling`), never refined; 0 for none.
    package var ceiling: UInt32 = 0

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        nx: UInt32 = 0,
        ny: UInt32 = 0,
        nz: UInt32 = 0,
        ratio: UInt32 = 1,
        threshold: Float = 0,
        ambient: Float = 0,
        on: UInt32 = 0,
        ceiling: UInt32 = 0
    ) {
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.ratio = ratio
        self.threshold = threshold
        self.ambient = ambient
        self.on = on
        self.ceiling = ceiling
    }
}
