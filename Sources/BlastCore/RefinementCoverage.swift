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

extension BlastSolver {
    /// How the refined levels' patches fit the jumps their threshold flags, now. Slow; for
    /// diagnostics.
    public func refinementCoverage() -> RefinementCoverage? {
        guard let refinement else { return nil }
        var coverage = RefinementCoverage()
        let grid = self.grid
        let gamma = configuration.gamma
        let model = configuration.airModel
        // The first level, against the coarse cells.
        let coarseDims = SIMD3(grid.nx, grid.ny, grid.nz)
        let pressures: [Float?] = withState { cells in
            (0..<grid.cellCount).map { index in
                let i = index % grid.nx
                let j = (index / grid.nx) % grid.ny
                let k = index / (grid.nx * grid.ny)
                guard !isSolid(i, j, k) else { return nil }
                return Self.primitive(of: cells[index], gamma: gamma, airModel: model).pressure
            }
        }
        let firstMap = refinement.patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: refinement.tileDims.x * refinement.tileDims.y * refinement.tileDims.z)
        coverage.levels.append(
            Self.coverage(
                dims: coarseDims, threshold: configuration.refinementThreshold,
                pressure: { pressures[$0.x + coarseDims.x * ($0.y + coarseDims.y * $0.z)] },
                refined: { block in
                    let t = refinement.tileDims
                    return firstMap[block.x + t.x * (block.y + t.y * block.z)] >= 0
                }, blocks: refinement.tileDims))
        // The second, against the first level's cells where its patches hold them.
        if let deep = finerRefinement {
            let side = refinement.side
            let cells = side * side * side
            let state = refinement.fine[0].contents().bindMemory(
                to: CellState.self, capacity: refinement.maxPatches * cells)
            let mask = refinement.fineMask.contents().bindMemory(
                to: UInt8.self, capacity: refinement.maxPatches * cells)
            let dims = coarseDims &* refinement.ratio
            func pressure(_ p: SIMD3<Int>) -> Float? {
                let block = p / side
                let t = refinement.tileDims
                let patch = Int(firstMap[block.x + t.x * (block.y + t.y * block.z)])
                guard patch >= 0 else { return nil }
                let local = p &- block &* side
                let at = patch * cells + local.x + side * (local.y + side * local.z)
                guard mask[at] & 1 == 0 else { return nil }
                return Self.primitive(of: state[at], gamma: gamma, airModel: model).pressure
            }
            let deepMap = (deep.patchOfTile.contents() + deep.patchOffset * 4).bindMemory(
                to: Int32.self, capacity: deep.tileDims.x * deep.tileDims.y * deep.tileDims.z)
            coverage.levels.append(
                Self.coverage(
                    dims: dims,
                    threshold: configuration.refinementFinerThreshold ?? configuration.refinementThreshold,
                    pressure: pressure,
                    refined: { block in
                        let t = deep.tileDims
                        return deepMap[block.x + t.x * (block.y + t.y * block.z)] >= 0
                    }, blocks: deep.tileDims))
        }
        return coverage
    }

    /// Each refined level's blocks counted by their height, a row a block of the level's own grid
    /// (4 of its cells high: 4 coarse cells for the first level, 4 of the first's for the second),
    /// from the ground: where the refined air lies, for profiling. Read on the CPU.
    public func refinedBlocksByHeight() -> [[Int]] {
        var rows: [[Int]] = []
        for level in [refinement, finerRefinement].compactMap({ $0 }) {
            let t = level.tileDims
            let map = (level.patchOfTile.contents() + level.patchOffset * 4).bindMemory(
                to: Int32.self, capacity: t.x * t.y * t.z)
            var row = [Int](repeating: 0, count: t.z)
            for z in 0..<t.z {
                for y in 0..<t.y {
                    for x in 0..<t.x where map[x + t.x * (y + t.y * z)] >= 0 { row[z] += 1 }
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// One level's coverage, over a grid of `dims` cells whose pressures (nil where solid or not
    /// held) `pressure` gives, refined in blocks of 4 x 4 x 4 cells where `refined` says.
    private static func coverage(
        dims: SIMD3<Int>, threshold: Float, pressure: (SIMD3<Int>) -> Float?,
        refined: (SIMD3<Int>) -> Bool, blocks: SIMD3<Int>
    ) -> RefinementCoverage.Level {
        let block = AirRefinement.patchSize
        var sharp = Set<Int>()
        func key(_ p: SIMD3<Int>) -> Int { p.x + dims.x * (p.y + dims.y * p.z) }
        for k in 0..<dims.z {
            for j in 0..<dims.y {
                for i in 0..<dims.x {
                    let cell = SIMD3(i, j, k)
                    guard let p = pressure(cell) else { continue }
                    for axis in 0..<3 {
                        var next = cell
                        next[axis] += 1
                        guard next[axis] < dims[axis], let q = pressure(next) else { continue }
                        if abs(q - p) > threshold * min(p, q) {
                            sharp.insert(key(cell))
                            sharp.insert(key(next))
                        }
                    }
                }
            }
        }
        var level = RefinementCoverage.Level()
        var coreBlocks = Set<Int>()
        for index in sharp {
            let cell = SIMD3(index % dims.x, (index / dims.x) % dims.y, index / (dims.x * dims.y))
            let b = cell / block
            coreBlocks.insert(b.x + blocks.x * (b.y + blocks.y * b.z))
            if refined(b) { level.sharpCells += 1 }
        }
        for z in 0..<blocks.z {
            for y in 0..<blocks.y {
                for x in 0..<blocks.x {
                    let b = SIMD3(x, y, z)
                    let isCore = coreBlocks.contains(x + blocks.x * (y + blocks.y * z))
                    if refined(b) {
                        level.refined += 1
                        level.refinedCells += block * block * block
                        if isCore { level.core += 1 }
                    } else if isCore {
                        level.missed += 1
                    }
                }
            }
        }
        return level
    }
}
