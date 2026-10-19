import Foundation
import simd

extension SceneObject {
    /// The object's extent: its block, its structure's solids, or its envelope's blocks; nil for an
    /// envelope with none.
    public var bounds: Box? {
        if let box = fixedBox { return box }
        if let structure { return structure.bounds }
        guard let blocks = envelope?.blocks, let first = blocks.first else { return nil }
        return blocks.dropFirst().reduce(first) {
            Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
        }
    }
}

extension RefinementRegion {
    /// The half-width a corridor takes either side of its line by default, in m/kg^(1/3) of the
    /// largest charge: 1.5, the wider of the two that gave each of Beirut's four buildings full
    /// refinement's answer (docs/refinement-steering.md, 120 m for 500 t).
    public static let corridorScaledHalfWidth: Float = 1.5

    /// Corridors along which air may be refined, from each of `charges` to each of `targets`, for
    /// refinement toward chosen buildings: each the line from the charge over the ground to the
    /// target's middle and on beyond its far side, `halfWidth` m either side of it, as `pieces`
    /// boxes along it, each its piece's extent widened by `halfWidth`; and the target itself
    /// widened by as much. The shock must be fine along its way, not only where it arrives.
    /// Boxes reach from far below the ground to far above it.
    public static func corridors(
        from charges: [SIMD3<Float>], to targets: [Box], halfWidth: Float, pieces: Int = 32
    ) -> [RefinementRegion] {
        let depth: Float = 1e4
        var regions: [RefinementRegion] = []
        for target in targets {
            let middle = 0.5 * SIMD2(target.min.x + target.max.x, target.min.y + target.max.y)
            let reach = 0.5 * simd_length(SIMD2(target.max.x - target.min.x, target.max.y - target.min.y))
            regions.append(
                RefinementRegion(
                    low: SIMD3(target.min.x - halfWidth, target.min.y - halfWidth, -depth),
                    high: SIMD3(target.max.x + halfWidth, target.max.y + halfWidth, depth)))
            for charge in charges {
                let start = SIMD2(charge.x, charge.y)
                let toward = middle - start
                let length = simd_length(toward)
                guard length > 0 else { continue }
                let end = middle + toward / length * (reach + halfWidth)
                for n in 0..<pieces {
                    let a = start + (end - start) * Float(n) / Float(pieces)
                    let b = start + (end - start) * Float(n + 1) / Float(pieces)
                    let low = simd_min(a, b) - halfWidth
                    let high = simd_max(a, b) + halfWidth
                    regions.append(
                        RefinementRegion(low: SIMD3(low.x, low.y, -depth), high: SIMD3(high.x, high.y, depth))
                    )
                }
            }
        }
        return regions
    }
}

extension Scenario {
    /// Corridors toward the scene's objects with `ids` (`RefinementRegion.corridors`), from each
    /// charge with any mass, `scaledHalfWidth` m/kg^(1/3) of the largest either side; nil if none
    /// of the ids is an object with an extent, so that refinement is not confined to nothing.
    public func refinementCorridors(
        toward ids: [UUID], scaledHalfWidth: Float = RefinementRegion.corridorScaledHalfWidth
    ) -> [RefinementRegion]? {
        let targets = ids.compactMap { object(id: $0)?.bounds }
        let charges = ([charge] + (additionalCharges ?? [])).filter { $0.mass > 0 }
        guard !targets.isEmpty, let largest = charges.map(\.mass).max() else { return nil }
        let halfWidth = scaledHalfWidth * cbrt(largest)
        return RefinementRegion.corridors(from: charges.map(\.position), to: targets, halfWidth: halfWidth)
    }
}
