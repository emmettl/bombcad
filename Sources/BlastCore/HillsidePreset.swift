import Foundation
import simd

/// "Two-storey frame on a hillside": the concrete frame of "Two-storey frame" built across a slope
/// rising 1 in 4 (14°) along x, as a frame is built on a hillside: its slabs level, its columns
/// standing at three heights, the uphill ones 3 m shorter, each on a pad footing 1.6 m square and
/// 0.5 m thick cast flush with the ground there, its sides in the slope (`FootingGround`): buried
/// deeper on the uphill side than the downhill, the bearing capacity cut by the slope to
/// (1 − tan β)² = 0.56 of level ground's. 500 kg of TNT stands on the slope 7 m in front.
extension ScenarioPreset {
    /// The slope's rise along x, and where it starts: the ground stands 4, 5.5 and 7 m up under the
    /// three lines of columns, on the frame's lattice, and the slope runs on below them.
    static let hillsideRise: Float = 0.25
    static let hillsideFoot: Float = 14.1875 - 4 / hillsideRise

    static func hillsideFrameScenario(title: String) -> Scenario {
        let domain = SIMD3<Float>(40, 32, 20)
        let terrain = Terrain.sampled(domain: domain, spacing: 0.5, source: "slope of 1 in 4 along x") {
            max(0, ($0.x - hillsideFoot) * hillsideRise)
        }
        let columnSize: Float = 0.375
        let ground = { (x: Float) in terrain.height(at: SIMD2(x + columnSize / 2, 16)) }
        // Level slabs at the frame's storey heights above the uphill columns' ground.
        let uphill = ground(26)
        let levels = [3.25, 6.75].map { uphill + $0 }
        let top = uphill + 7
        var columns: [Box] = []
        for x in [14, 20, 26] as [Float] {
            for y in [13, 19] as [Float] {
                columns.append(
                    Box(min: SIMD3(x, y, ground(x)), max: SIMD3(x + columnSize, y + columnSize, top)))
            }
        }
        let slabs = levels.map { level in
            Box(min: SIMD3(14, 13, level), max: SIMD3(26 + columnSize, 19 + columnSize, level + 0.25))
        }
        var structure = StructureModel(solids: columns + slabs, elementSize: 0.125, fixedBase: false)
        for column in columns {
            structure.reinforcement.append(
                ReinforcementLayer(region: column, ratio: SIMD3(0.004, 0.004, 0.02)))
        }
        for slab in slabs {
            structure.addMat(to: slab, thicknessAxis: 2, areaPerMetre: 754e-6, depth: Self.barDepth)
        }
        // Each column cast onto its own pad with starter bars, the pad's top at the ground there.
        var joint = Anchorage.dowelled(ratio: BaseConnection.dowelRatio)
        joint.footing = Footing(
            overhang: SIMD2(0.6125, 0.6125), thickness: 0.5, soil: Soil(), embedment: Embedment(depth: 0.5))
        for column in columns {
            structure.supports.append(
                Box(
                    min: SIMD3(column.min.x - 0.01, column.min.y - 0.01, column.min.z - 0.01),
                    max: SIMD3(column.max.x + 0.01, column.max.y + 0.01, column.min.z + 0.01)))
            structure.setAnchorage(joint, ofSupport: structure.supports.count - 1)
        }
        var scenario = Scenario(
            name: title, domainSize: domain, boxes: [],
            charge: Charge(mass: 500, position: SIMD3(20.2, 6, terrain.height(at: SIMD2(20.2, 6)) + 1)),
            gauges: [
                Gauge("Front column, downhill", at: SIMD3(14.2, 12.9, ground(14) + 1.5)),
                Gauge("Front column, middle", at: SIMD3(20.2, 12.9, ground(20) + 1.5)),
                Gauge("Front column, uphill", at: SIMD3(26.2, 12.9, ground(26) + 1.5)),
                Gauge("Behind", at: SIMD3(20, 22, ground(20) + 1.5)),
            ],
            structure: structure)
        scenario.terrain = terrain
        return scenario
    }
}

extension Scenario {
    /// Whether any structure stands on the terrain: a solid's base within half a metre, an element
    /// or an air cell of `cellSize` (a fine cut cell's top can lie a fine cell over the ground, and
    /// a structure's base half an element over its cells) of the highest ground under its
    /// footprint, or below it, where that ground is above the floor (on the floor there are no cut
    /// cells to shut in).
    public func structureStandsOnTerrain(cellSize: Float = 0) -> Bool {
        guard let terrain, !terrain.isFlat else { return false }
        return structuralObjects.contains { object in
            guard let model = object.structure else { return false }
            let margin = max(0.5, model.elementSize, cellSize)
            return model.solids.contains { box in
                let corners = [
                    SIMD2(box.min.x, box.min.y), SIMD2(box.max.x, box.min.y), SIMD2(box.min.x, box.max.y),
                    SIMD2(box.max.x, box.max.y),
                    0.5 * (SIMD2(box.min.x, box.min.y) + SIMD2(box.max.x, box.max.y)),
                ]
                let highest = corners.map { terrain.height(at: $0) }.max() ?? 0
                return highest > 0 && box.min.z <= highest + margin
            }
        }
    }
}
