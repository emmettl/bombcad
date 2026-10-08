import BlastCore
import Foundation
import simd

/// Named selections use persisted source ownership, never the current voxel ordering.
enum StructureEditing {
    struct Part: Identifiable {
        var id: StructureModel.SourcePart
        var objectID: UUID
        var name: String
        var regions: [Int]
        var attached: Bool
    }

    static func parts(in scenario: Scenario) -> [Part] {
        return (scenario.importedModels ?? []).filter { $0.behavior == .deformable }.flatMap {
            model -> [Part] in
            guard let object = scenario.structuralObject(sourceID: model.id), let body = object.structure
            else { return [] }
            let owners =
                body.solidSourceParts.isEmpty && model.canRegenerate(body)
                ? model.regionSourceParts : body.solidSourceParts
            var regionsByPart: [StructureModel.SourcePart: [Int]] = [:]
            for index in body.solids.indices where owners.indices.contains(index) {
                if let owner = owners[index] { regionsByPart[owner, default: []].append(index) }
            }
            return model.source.parts.map { part in
                let reference = StructureModel.SourcePart(modelID: model.id, partID: part.id)
                return Part(
                    id: reference, objectID: object.id, name: part.name,
                    regions: regionsByPart[reference] ?? [], attached: model.isAttached)
            }
        }
    }

    static func bounds(of indices: [Int], in body: StructureModel) -> Box? {
        let boxes = indices.filter { body.solids.indices.contains($0) }.map { body.solids[$0] }
        return boxes.first.map { first in
            boxes.dropFirst().reduce(first) {
                Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
            }
        }
    }

    /// Source material edits remain regenerable. Detached edits only update owned regions.
    static func settingMaterial(
        _ material: StructureMaterial?, for part: StructureModel.SourcePart, in scenario: Scenario
    ) throws -> Scenario {
        var candidate = scenario
        guard let index = candidate.importedModels?.firstIndex(where: { $0.id == part.modelID }),
            var imported = candidate.importedModels?[index], imported.behavior == .deformable,
            imported.source.parts.contains(where: { $0.id == part.partID }),
            let owner = candidate.structuralObject(sourceID: part.modelID), var body = owner.structure
        else { throw invalid("This structural part is no longer available.") }
        if imported.isAttached {
            guard imported.canRegenerate(body) else {
                throw invalid("Detach this structure before changing parts with local region edits.")
            }
            var assignments = imported.partMaterials ?? [:]
            assignments[part.partID] = material
            imported.partMaterials = assignments.isEmpty ? nil : assignments
            body.solidMaterial = try imported.regionMaterials()
            candidate.importedModels?[index] = imported
        } else {
            for n in body.solids.indices
            where body.solidSourceParts.indices.contains(n) && body.solidSourceParts[n] == part {
                body.setMaterial(material, of: n)
            }
        }
        try validateMaterials(body)
        try candidate.updateStructureObject(id: owner.id, model: body)
        return candidate
    }

    /// A local edit and any necessary detachment are one transaction and one undo step.
    static func changing(
        _ scenario: Scenario, objectID: UUID? = nil,
        removing reference: SceneObject.ComponentReference? = nil,
        retainingComponents: Bool = false, _ change: (inout StructureModel) -> Void
    ) throws -> Scenario {
        var candidate = scenario
        let targetID = reference?.objectID ?? objectID
        let target = targetID.flatMap { scenario.object(id: $0) } ?? scenario.structuralObject
        if targetID != nil, target?.id != targetID { throw invalid("This structure is no longer available.") }
        var body = target?.structure ?? StructureModel(solids: [], elementSize: 0.0625)
        if body.solidSourceParts.isEmpty,
            let imported = scenario.importedModels?.first(where: {
                $0.behavior == .deformable && $0.id == target?.sourceModelID && $0.canRegenerate(body)
            })
        {
            body.solidSourceParts = imported.regionSourceParts
        }
        let before = body
        change(&body)
        guard body != before else { return scenario }
        if !body.solidSourceParts.isEmpty {
            body.solidSourceParts = Array(body.solidSourceParts.prefix(body.solids.count))
            while body.solidSourceParts.count < body.solids.count { body.solidSourceParts.append(nil) }
        }
        // Preserve explicitly stored layers when rebuilding reinforcement from region specs.
        var generatedBefore = before
        generatedBefore.autoReinforce()
        var remainingGenerated = generatedBefore.reinforcement
        let custom = before.reinforcement.filter { layer in
            if let index = remainingGenerated.firstIndex(of: layer) {
                remainingGenerated.remove(at: index)
                return false
            }
            return true
        }
        body.autoReinforce()
        body.reinforcement.append(contentsOf: custom)
        try validateMaterials(body)
        try body.baseAnchorage?.validate()
        guard body.supportAnchorages.count <= body.supports.count else {
            throw invalid("A connection references a missing support region.")
        }
        for law in body.supportAnchorages.compactMap({ $0 }) { try law.validate() }
        guard
            (body.solids + body.openings + body.supports).allSatisfy({ box in
                [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z].allSatisfy(\.isFinite)
                    && box.size.x > 0 && box.size.y > 0 && box.size.z > 0
            })
        else { throw invalid("Structural regions must have finite coordinates and positive dimensions.") }
        for imported in scenario.importedModels ?? []
        where imported.behavior == .deformable && imported.id == target?.sourceModelID && imported.isAttached
            && !imported.canRegenerate(body)
        {
            candidate.detachImport(id: imported.id)
        }
        if retainingComponents || reference != nil, let old = target {
            try candidate.replaceStructure(
                body.solids.isEmpty ? nil : body, retainingComponentsFrom: old, removing: reference)
        } else if let target {
            try candidate.updateStructureObject(id: target.id, model: body.solids.isEmpty ? nil : body)
        } else if !body.solids.isEmpty {
            try candidate.addStructureObject(body)
        }
        return candidate
    }

    private static func validateMaterials(_ body: StructureModel) throws {
        guard body.materials.count <= StructureModel.maxMaterials else {
            throw invalid(
                "The structure can use at most \(StructureModel.maxMaterials) materials, including its default."
            )
        }
    }

    private static func invalid(_ message: String) -> ImportedMesh.ImportError { .invalid(message) }
}
