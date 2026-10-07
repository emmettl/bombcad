import Foundation
import simd

/// Source geometry and its derived simulation volumes travel together in saved layouts.
public struct ImportedModel: Sendable, Hashable, Codable, Identifiable {
    public enum Behavior: String, Sendable, Codable { case rigid, deformable }
    public var id: UUID
    public var name: String
    public var source: ImportedMesh
    public var scale: Float
    public var yUp: Bool
    public var corner: SIMD3<Float>
    public var behavior: Behavior
    public var preview: ImportedMesh.Preview
    public var regenerationEnabled: Bool?
    public var isAttached: Bool { regenerationEnabled ?? true }
    public init(
        id: UUID = UUID(), name: String, source: ImportedMesh, scale: Float, yUp: Bool, corner: SIMD3<Float>,
        behavior: Behavior, preview: ImportedMesh.Preview
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.scale = scale
        self.yUp = yUp
        self.corner = corner
        self.behavior = behavior
        self.preview = preview
    }
    public func transformedSource() throws -> ImportedMesh {
        try source.transformed(scale: scale, yUp: yUp, corner: corner)
    }
    public func sampled(cellSize: Float, domain: SIMD3<Float>) throws -> Self {
        var copy = self
        copy.preview = try transformedSource().preview(cellSize: cellSize, domain: domain)
        return copy
    }
    public func supports(fixedBase: Bool) -> [Box] {
        guard fixedBase, !preview.boxes.isEmpty else { return [] }
        let h = preview.cellSize
        let b = preview.boxes.reduce(preview.boxes[0]) {
            Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
        }
        return [
            Box(
                min: b.min - SIMD3(repeating: h * 0.01),
                max: SIMD3(b.max.x + h * 0.01, b.max.y + h * 0.01, b.min.z + h * 0.01))
        ]
    }
    /// Regeneration must never discard local region edits, reinforcement or custom supports.
    public func canRegenerate(_ body: StructureModel?) -> Bool {
        guard isAttached else { return false }
        guard behavior == .deformable, let body, !preview.boxes.isEmpty else { return behavior == .rigid }
        return body.solids == preview.boxes && body.openings.isEmpty && body.elementKind == .solid
            && body.solidElementKind.allSatisfy { $0 == nil || $0 == .solid }
            && body.solidMaterial.allSatisfy { $0 == nil } && body.reinforcement.isEmpty
            && body.inclinedBars.isEmpty && body.solidReinforcement.count == body.solids.count
            && body.solidReinforcement.allSatisfy { $0 == .none }
            && body.supports == supports(fixedBase: body.fixedBase)
    }
}

extension Scenario {
    public var rigidBoxes: [Box] {
        boxes
            + (importedModels ?? []).filter { $0.isAttached && $0.behavior == .rigid }.flatMap {
                $0.preview.boxes
            }
    }
    public func resamplingImports(cellSize: Float) throws -> Self {
        var copy = self
        for original in importedModels ?? []
        where original.isAttached && original.preview.cellSize != cellSize {
            guard original.canRegenerate(copy.structure) else {
                throw ImportedMesh.ImportError.invalid(
                    "\(original.name) has edited regions, reinforcement or supports. Detach its geometry from the source before changing the grid, or undo those edits."
                )
            }
            let updated = try original.sampled(cellSize: cellSize, domain: domainSize)
            if original.behavior == .deformable, var body = copy.structure {
                body.solids = updated.preview.boxes
                body.elementSize = cellSize
                body.solidReinforcement = Array(repeating: .none, count: body.solids.count)
                body.supports = updated.supports(fixedBase: body.fixedBase)
                copy.structure = body
            }
            if let index = copy.importedModels?.firstIndex(where: { $0.id == original.id }) {
                copy.importedModels?[index] = updated
            }
        }
        guard copy.rigidBoxes.count <= 2048 else {
            throw ImportedMesh.ImportError.invalid(
                "The combined layout exceeds the 2,048 rigid region limit at this resolution.")
        }
        return copy
    }
    public mutating func installImport(
        _ imported: ImportedModel, material: StructureMaterial, fixedBase: Bool
    ) throws {
        guard imported.preview.occupiedCells > 0 else {
            throw ImportedMesh.ImportError.invalid(
                "No occupied cells remain. Choose a finer grid before importing.")
        }
        let old = importedModels?.first { $0.id == imported.id }
        guard old?.isAttached != false else {
            throw ImportedMesh.ImportError.invalid(
                "Detached sources can be inspected, but cannot replace independently edited geometry.")
        }
        guard old == nil || old?.behavior == imported.behavior else {
            throw ImportedMesh.ImportError.invalid(
                "An existing import cannot change its rigid or deformable behavior.")
        }
        var models = importedModels ?? []
        if let n = models.firstIndex(where: { $0.id == imported.id }) {
            models[n] = imported
        } else {
            models.append(imported)
        }
        guard
            boxes.count
                + models.filter({ $0.isAttached && $0.behavior == .rigid }).reduce(
                    0, { $0 + $1.preview.boxes.count })
                <= 2048
        else {
            throw ImportedMesh.ImportError.invalid(
                "The combined layout exceeds the 2,048 rigid region limit.")
        }
        if imported.behavior == .deformable {
            guard structure == nil || old?.canRegenerate(structure) == true else {
                throw ImportedMesh.ImportError.invalid(
                    "The structure contains local edits. Detach its geometry before replacing it from the source."
                )
            }
            var body =
                structure
                ?? StructureModel(solids: [], material: material, elementSize: imported.preview.cellSize)
            body.solids = imported.preview.boxes
            body.material = material
            body.fixedBase = fixedBase
            body.elementSize = imported.preview.cellSize
            body.solidReinforcement = Array(repeating: .none, count: body.solids.count)
            body.supports = imported.supports(fixedBase: fixedBase)
            structure = body
        }
        importedModels = models
    }
    /// Keep derived volumes and material edits, but stop automatic source regeneration.
    public mutating func detachImport(id: UUID) {
        guard let index = importedModels?.firstIndex(where: { $0.id == id }),
            let model = importedModels?[index], model.isAttached
        else { return }
        if model.behavior == .rigid { boxes.append(contentsOf: model.preview.boxes) }
        importedModels?[index].regenerationEnabled = false
        importNotes =
            (importNotes ?? []) + [
                "\(model.name): geometry detached at \(model.preview.cellSize) m; the source remains available for inspection. Grid changes do not regenerate detached geometry."
            ]
    }
}
