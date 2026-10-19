import Foundation
import simd

/// A pitched roof to put over a structure (`StructureModel.addPitchedRoof`): two raftered slopes
/// (`ScenarioPreset.rafteredRoof`) meeting at a ridge, under their covering.
public struct PitchedRoof: Sendable, Hashable {
    /// The slopes' pitch, in degrees from the horizontal.
    public var pitch: Float
    /// The horizontal axis the ridge runs along: 0 for x, 1 for y.
    public var ridgeAlong: Int
    /// What the slopes are covered with, on battens; nil, bare rafters.
    public var covering: ScenarioPreset.RoofCovering?

    public init(
        pitch: Float = 40, ridgeAlong: Int = 1, covering: ScenarioPreset.RoofCovering? = .plainClayTiles
    ) {
        self.pitch = pitch
        self.ridgeAlong = ridgeAlong
        self.covering = covering
    }

    /// Pitches the model takes: a plane steeper than this has elements too long up the slope for
    /// the walls under it, flatter it is a flat roof's.
    public static let pitches: ClosedRange<Float> = 10...60
}

extension StructureModel {
    /// Puts `roof` over `plan` (its x and y; its heights are ignored) from eaves at `eaves` m:
    /// two slopes, each from an eave along the ridge's axis up to the ridge over the plan's
    /// middle, that cut the walls under them to their line (`Inclination.trimsWalls`). The walls
    /// across the ridge at the plan's two ends that reach the eaves are raised to the ridge, so as
    /// to become gables. Each slope bears on every wall under it that reaches the eaves, as the
    /// terraced row's rafters do (`ScenarioPreset.joistPocket`, level, notched over the wall
    /// plate), and its covering hangs on it on its nibs (`ScenarioPreset.pitchedCoveringSeat`).
    /// No purlins: a span of more than about 2.5 m up the slope wants a wall or a purlin under
    /// it, added as a piece of its own and seated as its own joint.
    ///
    /// - Returns: The solids added: the slopes, then their coverings.
    @discardableResult
    public mutating func addPitchedRoof(_ roof: PitchedRoof, over plan: Box, eaves: Float) -> Range<Int> {
        let along = roof.ridgeAlong == 0 ? 0 : 1
        let rise = 1 - along
        let angle =
            min(max(roof.pitch, PitchedRoof.pitches.lowerBound), PitchedRoof.pitches.upperBound) * .pi / 180
        let middle = (plan.min[rise] + plan.max[rise]) / 2
        let height = (middle - plan.min[rise]) * tan(angle)
        let ridge = eaves + height
        let h = shellElementSize ?? elementSize
        var slopes: [Box] = []
        var normals: [SIMD3<Float>] = []
        for side in 0..<2 {
            var low = SIMD3(plan.min.x, plan.min.y, eaves)
            var high = SIMD3(plan.max.x, plan.max.y, ridge)
            if side == 0 { high[rise] = middle } else { low[rise] = middle }
            slopes.append(Box(min: low, max: high))
            var normal = SIMD3<Float>(0, 0, cos(angle))
            normal[rise] = side == 0 ? -sin(angle) : sin(angle)
            normals.append(normal)
        }
        // The walls under it, as they stand before the gables are raised.
        let walls = solids.indices.filter { index in
            guard inclination(of: index) == nil else { return false }
            let box = solids[index]
            let size = box.size
            let thin = (0..<3).min { size[$0] < size[$1] } ?? 2
            return thin != 2 && box.max.z >= eaves - h / 2 && box.min.z < eaves
                && box.max.x > plan.min.x && box.min.x < plan.max.x && box.max.y > plan.min.y
                && box.min.y < plan.max.y
        }
        for index in walls {
            let box = solids[index]
            let thin = (0..<3).min { box.size[$0] < box.size[$1] } ?? 2
            let atEnd =
                box.min[along] <= plan.min[along] + 0.5 || box.max[along] >= plan.max[along] - 0.5
            if thin == along && atEnd { solids[index].max.z = ridge }
        }
        let first = solids.count
        let offset: Float = 0.0625
        for (side, box) in slopes.enumerated() {
            solids.append(box)
            setMaterial(ScenarioPreset.rafteredRoof, of: solids.count - 1)
            setInclination(
                Inclination(rise: rise, upwards: side == 0, thickness: 0.05, trimsWalls: true),
                of: solids.count - 1)
        }
        let coverings = solids.count
        if let covering = roof.covering {
            for (side, box) in slopes.enumerated() {
                solids.append(
                    Box(min: box.min + offset * normals[side], max: box.max + offset * normals[side]))
                setMaterial(covering.material, of: solids.count - 1)
                setInclination(
                    Inclination(
                        rise: rise, upwards: side == 0, thickness: ScenarioPreset.RoofCovering.thickness),
                    of: solids.count - 1)
            }
        }
        // Each slope on the walls under it, short of the ridge (whose nodes both slopes share).
        let pocket = ScenarioPreset.joistPocket(bearingArea: h / 2)
        for index in walls {
            let wall = solids[index]
            for side in 0..<2 {
                var low = SIMD3(wall.min.x - h / 2, wall.min.y - h / 2, eaves - h)
                var high = SIMD3(wall.max.x + h / 2, wall.max.y + h / 2, ridge + 0.1)
                if side == 0 {
                    high[rise] = min(high[rise], middle - 0.01)
                } else {
                    low[rise] = max(low[rise], middle + 0.01)
                }
                guard low[rise] < high[rise] else { continue }
                var law = pocket
                law.solids = [first + side]
                law.partners = [index]
                supports.append(Box(min: low, max: high))
                setAnchorage(law, ofSupport: supports.count - 1)
            }
        }
        // Each covering on its slope.
        for side in 0..<(solids.count - coverings) {
            var low = SIMD3(plan.min.x, plan.min.y, eaves - 0.2)
            var high = SIMD3(plan.max.x, plan.max.y, ridge + 0.3)
            if side == 0 {
                low[rise] -= 0.2
                high[rise] = middle
            } else {
                low[rise] = middle
                high[rise] += 0.2
            }
            supports.append(Box(min: low, max: high))
            setAnchorage(
                ScenarioPreset.pitchedCoveringSeat(
                    normal: normals[side], solids: [coverings + side], slope: first + side),
                ofSupport: supports.count - 1)
        }
        return first..<solids.count
    }
}
