import simd

public enum BodyCouplingLayout: String, Sendable, CaseIterable {
    case automatic, dense, tiled
}

/// Coarse boundary pages. The air solution and its refinement pool are separate allocations.
package struct TiledCoupling {
    static let side = 4
    static let cells = side * side * side
    let tileDims: SIMD3<Int>
    package let mapCount: Int
    package let capacity: Int
    package var capacityCells: Int { capacity * Self.cells }
    package var wallHeaderWords: Int { mapCount + 2 }
    package var bytes: Int { capacityCells * 80 + wallHeaderWords * 4 + capacity * 4 }

    /// A body as the pages cover it: its model's bounds, and how far its coupling reaches beyond
    /// them besides the air's own margin, the larger of its element size and its shells' envelope
    /// margin (`StructuralBody`'s).
    package struct Footprint {
        var bounds: Box
        var reach: Float

        package init(bounds: Box, reach: Float) {
            self.bounds = bounds
            self.reach = reach
        }
    }

    package init(grid: Grid, footprints: [Footprint], requestedCapacity: Int) throws {
        guard requestedCapacity >= 0 else {
            throw BlastError.allocationFailed("nonnegative coupling capacity")
        }
        tileDims = (SIMD3(grid.nx, grid.ny, grid.nz) &+ (Self.side - 1)) / Self.side
        mapCount = tileDims.x * tileDims.y * tileDims.z
        var initial: Set<Int> = []
        for body in footprints {
            let padding = SIMD3<Float>(4, 4, 3) + body.reach
            let low = grid.cell(containing: body.bounds.min - padding)
            let high = grid.cell(containing: body.bounds.max + padding)
            for z in (low.k / Self.side)...(high.k / Self.side) {
                for y in (low.j / Self.side)...(high.j / Self.side) {
                    for x in (low.i / Self.side)...(high.i / Self.side) {
                        initial.insert(x + tileDims.x * (y + tileDims.y * z))
                    }
                }
            }
        }
        capacity = min(mapCount, requestedCapacity > 0 ? requestedCapacity : max(64, initial.count * 2))
    }
}
