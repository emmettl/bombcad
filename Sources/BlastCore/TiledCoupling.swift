import simd

public enum BodyCouplingLayout: String, Sendable, CaseIterable {
    case automatic, dense, tiled
}

/// Coarse boundary pages. The air solution and its refinement pool are separate allocations.
struct TiledCoupling {
    static let side = 4
    static let cells = side * side * side
    let tileDims: SIMD3<Int>
    let mapCount: Int
    let capacity: Int
    var capacityCells: Int { capacity * Self.cells }
    var wallHeaderWords: Int { mapCount + 2 }
    var bytes: Int { capacityCells * 80 + wallHeaderWords * 4 + capacity * 4 }

    init(grid: Grid, bodies: [StructuralBody], requestedCapacity: Int) throws {
        guard requestedCapacity >= 0 else {
            throw BlastError.allocationFailed("nonnegative coupling capacity")
        }
        tileDims = (SIMD3(grid.nx, grid.ny, grid.nz) &+ (Self.side - 1)) / Self.side
        mapCount = tileDims.x * tileDims.y * tileDims.z
        var initial: Set<Int> = []
        for body in bodies {
            let padding = SIMD3<Float>(4, 4, 3) + max(body.model.elementSize, body.shellEnvelopeMargin)
            let low = grid.cell(containing: body.model.bounds.min - padding)
            let high = grid.cell(containing: body.model.bounds.max + padding)
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
