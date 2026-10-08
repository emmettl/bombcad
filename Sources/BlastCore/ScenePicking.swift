import Foundation
import simd

/// Picking follows the sampled solids, including openings, rather than the source AABB.
public enum ScenePicking {
    public static func distance(to box: Box, origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        guard
            (0..<3).allSatisfy({
                origin[$0].isFinite && direction[$0].isFinite && box.min[$0].isFinite && box.max[$0].isFinite
                    && box.min[$0] < box.max[$0]
            }), simd_length_squared(direction) > 0
        else { return nil }
        var near: Float = 0
        var far = Float.infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-8 {
                if origin[axis] < box.min[axis] || origin[axis] > box.max[axis] { return nil }
            } else {
                let a = (box.min[axis] - origin[axis]) / direction[axis]
                let b = (box.max[axis] - origin[axis]) / direction[axis]
                near = max(near, min(a, b))
                far = min(far, max(a, b))
                if far < near { return nil }
            }
        }
        return far >= 0 ? near : nil
    }
    public static func importedModel(in scenario: Scenario, origin: SIMD3<Float>, direction: SIMD3<Float>)
        -> UUID?
    {
        var closest = Float.infinity
        var selected: UUID?
        func visit(_ boxes: [Box], id: UUID?) {
            for box in boxes {
                if let hit = distance(to: box, origin: origin, direction: direction), hit < closest {
                    closest = hit
                    selected = id
                }
            }
        }
        visit(scenario.boxes, id: nil)
        let legacySources = (scenario.importedModels ?? []).filter {
            $0.isAttached && $0.behavior == .deformable
        }
        for object in scenario.structuralObjects {
            let body = object.structure!
            let owner = scenario.importedModels?.first { model in
                model.isAttached && model.behavior == .deformable
                    && (model.id == object.sourceModelID
                        || (object.sourceModelID == nil && scenario.structuralObjects.count == 1
                            && legacySources.count == 1))
            }
            for solid in body.solids {
                // Subtract openings before intersecting the ray. Work is bounded per member.
                let fragments = ImportPlacementReport.subtracting(body.openings, from: solid, limit: 4096)
                // In ambiguous over-budget cases, occlude rather than select through unknown geometry.
                visit(
                    fragments.complete ? fragments.boxes : [solid], id: fragments.complete ? owner?.id : nil)
            }
        }
        for model in scenario.importedModels ?? [] where model.isAttached && model.behavior == .rigid {
            visit(model.preview.boxes, id: model.id)
        }
        if direction.z < -1e-8 && origin.z >= 0 {
            let ground = -origin.z / direction.z
            if ground < closest { return nil }
        }
        return selected
    }
}
