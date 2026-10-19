import Foundation
import simd

/// How closely a refined level's patches fit what its threshold asks for, at one moment: a
/// diagnostic for profiling, read on the CPU (see `BlastSolver.refinementCoverage()`).
public struct RefinementCoverage: Sendable {
    public struct Level: Sendable {
        /// Blocks refined, of 4 x 4 x 4 cells of the grid the level refines.
        public var refined = 0
        /// Of those, blocks holding a pair of neighbouring cells whose pressures differ by more
        /// than the threshold: the shock itself. The rest are the margin around it (`refinementMargin`)
        /// and, for the first level of two, the nesting around the second.
        public var core = 0
        /// Blocks holding such a pair that are not refined (the pool used up).
        public var missed = 0
        /// Cells of the grid refined that lie in such a pair, and all the cells refined.
        public var sharpCells = 0
        public var refinedCells = 0

        /// The share of the refined cells the threshold itself asks for.
        public var efficiency: Double { refinedCells == 0 ? 0 : Double(sharpCells) / Double(refinedCells) }

        public init() {}
    }

    public var levels: [Level] = []

    public init() {}
}
