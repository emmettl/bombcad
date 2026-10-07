import simd

/// Uniform Cartesian grid. Cell `(i, j, k)` spans `[i, i + 1] * cellSize` along x and so on; z is up.
public struct Grid: Sendable, Hashable {
    public var nx: Int
    public var ny: Int
    public var nz: Int
    /// Edge length of a cell in metres.
    public var cellSize: Float

    public init(nx: Int, ny: Int, nz: Int, cellSize: Float) {
        precondition(nx > 0 && ny > 0 && nz > 0 && cellSize > 0, "Grid must be non-empty")
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.cellSize = cellSize
    }

    public var cellCount: Int { nx * ny * nz }

    public var size: SIMD3<Float> { SIMD3(Float(nx), Float(ny), Float(nz)) * cellSize }

    @inlinable
    public func index(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }

    public func contains(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        i >= 0 && i < nx && j >= 0 && j < ny && k >= 0 && k < nz
    }

    public func cellCentre(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * cellSize
    }

    /// Indices of the cell containing `point`, clamped to the grid.
    public func cell(containing point: SIMD3<Float>) -> (i: Int, j: Int, k: Int) {
        let scaled = point / cellSize
        return (
            min(max(Int(scaled.x.rounded(.down)), 0), nx - 1),
            min(max(Int(scaled.y.rounded(.down)), 0), ny - 1),
            min(max(Int(scaled.z.rounded(.down)), 0), nz - 1)
        )
    }
}
