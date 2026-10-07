import simd

/// Placement shortcuts preserve physical scale and never shrink the existing domain.
public enum ImportPlacement {
    public static func size(sourceBounds: Box, scale: Float, yUp: Bool) throws -> SIMD3<Float> {
        let raw = sourceBounds.size
        let size = (yUp ? SIMD3(raw.x, raw.z, raw.y) : raw) * scale
        guard scale.isFinite, scale > 0, (0..<3).allSatisfy({ size[$0].isFinite && size[$0] > 0 }) else {
            throw ImportedMesh.ImportError.invalid(
                "Check source units: the model must have finite, positive dimensions.")
        }
        return size
    }
    public static func centeredFootprint(size: SIMD3<Float>, corner: SIMD3<Float>, domain: SIMD3<Float>)
        throws -> SIMD3<Float>
    {
        guard size.x <= domain.x, size.y <= domain.y else {
            throw ImportedMesh.ImportError.invalid(
                "The model is wider than the domain. Expand the domain first or check source units.")
        }
        return SIMD3((domain.x - size.x) * 0.5, (domain.y - size.y) * 0.5, corner.z)
    }
    public static func onGround(corner: SIMD3<Float>) -> SIMD3<Float> { SIMD3(corner.x, corner.y, 0) }
    public static func expandedDomain(
        size: SIMD3<Float>, corner: SIMD3<Float>, current: SIMD3<Float>, cellSize: Float, maxCells: Double
    ) throws -> SIMD3<Float> {
        guard cellSize.isFinite, cellSize > 0,
            (0..<3).allSatisfy({
                corner[$0].isFinite && corner[$0] >= 0 && size[$0].isFinite && size[$0] > 0
                    && current[$0].isFinite && current[$0] > 0
            })
        else {
            throw ImportedMesh.ImportError.invalid(
                "Move the corner inside the domain and check the source dimensions before expanding.")
        }
        let padding = max(2 * cellSize, 1)
        let proposed = simd_max(current, corner + size + SIMD3(repeating: padding))
        let cells = (0..<3).reduce(1.0) { $0 * max(1, Double((proposed[$1] / cellSize).rounded())) }
        guard cells.isFinite, cells <= min(maxCells, Double(Int.max) / 128) else {
            throw ImportedMesh.ImportError.invalid(
                "Expanding would make the air grid too large for the available memory. Use a coarser grid, move the model closer to the origin, or check source units."
            )
        }
        return proposed
    }
}
