import Foundation
import simd

/// Authored ownership, independent of GPU indices and renderer picking numbers.
/// Each deformable object owns its model and independently compiled structural state.
public struct SceneObject: Sendable, Hashable, Identifiable {
    public enum Representation: Sendable, Hashable {
        case fixed(Box)
        case deformable(StructureModel)
    }

    public enum ComponentKind: String, Codable, Sendable { case solid, opening, support }

    public struct ComponentReference: Sendable, Hashable, Codable {
        public var objectID: UUID
        public var componentID: UUID
        public var kind: ComponentKind
    }

    public let id: UUID
    public var name: String
    public private(set) var representation: Representation
    /// Retained import provenance, including after detachment.
    public internal(set) var sourceModelID: UUID?
    public internal(set) var preferredSolidElementSize: Float?
    public private(set) var solidIDs: [UUID] = []
    public private(set) var openingIDs: [UUID] = []
    public private(set) var supportIDs: [UUID] = []

    public init(id: UUID = UUID(), name: String, representation: Representation) {
        self.id = id
        self.name = name
        self.representation = representation
        if case .deformable(let body) = representation {
            preferredSolidElementSize = body.elementKind == .solid ? body.elementSize : nil
            solidIDs = body.solids.map { _ in UUID() }
            openingIDs = body.openings.map { _ in UUID() }
            supportIDs = body.supports.map { _ in UUID() }
        }
    }

    public var fixedBox: Box? {
        if case .fixed(let box) = representation { return box }
        return nil
    }
    public var structure: StructureModel? {
        if case .deformable(let body) = representation { return body }
        return nil
    }

    public func references(_ kind: ComponentKind) -> [ComponentReference] {
        ids(kind).map { ComponentReference(objectID: id, componentID: $0, kind: kind) }
    }

    public func index(of reference: ComponentReference) -> Int? {
        guard reference.objectID == id else { return nil }
        return ids(reference.kind).firstIndex(of: reference.componentID)
    }

    private func ids(_ kind: ComponentKind) -> [UUID] {
        switch kind {
        case .solid: solidIDs
        case .opening: openingIDs
        case .support: supportIDs
        }
    }

    internal mutating func setBox(_ box: Box) { representation = .fixed(box) }

    internal mutating func setStructure(_ body: StructureModel) {
        guard let old = structure else { return }
        solidIDs = Self.reconcile(old.solids, ids: solidIDs, new: body.solids)
        openingIDs = Self.reconcile(old.openings, ids: openingIDs, new: body.openings)
        supportIDs = Self.reconcile(old.supports, ids: supportIDs, new: body.supports)
        representation = .deformable(body)
    }

    internal mutating func retainComponentIDs(from old: Self, removing reference: ComponentReference?) throws
    {
        var solids = old.solidIDs
        var openings = old.openingIDs
        var supports = old.supportIDs
        if let reference {
            guard let index = old.index(of: reference) else { throw SceneObjectError.missingObject }
            switch reference.kind {
            case .solid: solids.remove(at: index)
            case .opening: openings.remove(at: index)
            case .support: supports.remove(at: index)
            }
        }
        guard let body = structure, solids.count == body.solids.count,
            openings.count == body.openings.count, supports.count == body.supports.count
        else { throw SceneObjectError.invalidOwnership }
        solidIDs = solids
        openingIDs = openings
        supportIDs = supports
    }

    /// Exact surviving geometry wins before positional edits. New geometry gets new identity.
    /// Duplicate equal regions require explicit identity-based operations to disambiguate.
    internal static func reconcile<T: Equatable>(_ old: [T], ids: [UUID], new: [T]) -> [UUID] {
        if old == new { return ids }
        var used = Set<Int>()
        var result: [UUID?] = new.map { value in
            guard let index = old.indices.first(where: { !used.contains($0) && old[$0] == value })
            else { return nil }
            used.insert(index)
            return ids[index]
        }
        if old.count == new.count {
            for index in new.indices where result[index] == nil && !used.contains(index) {
                result[index] = ids[index]
                used.insert(index)
            }
        }
        return result.map { $0 ?? UUID() }
    }

    /// Deterministic IDs for legacy inputs and presets, scoped to their owning scene.
    /// New authored additions and duplicates use fresh UUIDs.
    internal static func legacyID(_ category: UInt8, _ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-80%02x-%012llx", category, index))!
    }

    internal static func validateSeparation(_ bodies: [SceneObject]) throws {
        for a in bodies.indices {
            guard let first = bodies[a].structure, !first.solids.isEmpty,
                first.elementSize.isFinite, first.elementSize > 0,
                (first.solids + first.openings + first.supports).allSatisfy({ box in
                    [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z].allSatisfy(\.isFinite)
                        && (0..<3).allSatisfy({ box.size[$0] > 0 })
                })
            else { throw SceneObjectError.invalidOwnership }
            for b in bodies.indices where b > a {
                guard let second = bodies[b].structure else { throw SceneObjectError.invalidOwnership }
                let overlap =
                    simd_min(first.bounds.max, second.bounds.max)
                    - simd_max(first.bounds.min, second.bounds.min)
                if (0..<3).allSatisfy({ overlap[$0] >= -1e-5 }) { throw SceneObjectError.interObjectContact }
            }
        }
    }

    internal static func legacyBlock(_ box: Box, index: Int) -> Self {
        Self(id: legacyID(1, index), name: "Block \(index + 1)", representation: .fixed(box))
    }

    internal static func legacyStructure(_ body: StructureModel, index: Int = 0) -> Self {
        var object = Self(id: legacyID(2, index), name: "Structure", representation: .deformable(body))
        object.solidIDs = body.solids.indices.map { legacyID(3, index * 1_000_000 + $0) }
        object.openingIDs = body.openings.indices.map { legacyID(4, index * 1_000_000 + $0) }
        object.supportIDs = body.supports.indices.map { legacyID(5, index * 1_000_000 + $0) }
        return object
    }

    /// Ownership is encoded beside the legacy geometry, without duplicating numerical inputs.
    internal struct Ownership: Codable {
        var id: UUID
        var name: String
        var sourceModelID: UUID?
        var preferredSolidElementSize: Float?
        var solidIDs: [UUID]
        var openingIDs: [UUID]
        var supportIDs: [UUID]

        init(_ object: SceneObject) {
            id = object.id
            name = object.name
            sourceModelID = object.sourceModelID
            preferredSolidElementSize = object.preferredSolidElementSize
            solidIDs = object.solidIDs
            openingIDs = object.openingIDs
            supportIDs = object.supportIDs
        }

        func applying(to object: SceneObject) throws -> SceneObject {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                solidIDs.count == object.solidIDs.count,
                openingIDs.count == object.openingIDs.count,
                supportIDs.count == object.supportIDs.count
            else { throw SceneObjectError.invalidOwnership }
            var result = SceneObject(id: id, name: name, representation: object.representation)
            result.sourceModelID = sourceModelID
            result.preferredSolidElementSize = preferredSolidElementSize
            result.solidIDs = solidIDs
            result.openingIDs = openingIDs
            result.supportIDs = supportIDs
            return result
        }
    }
}

public enum SceneObjectError: Error, LocalizedError {
    case invalidOwnership, missingObject, unsupportedRepresentation, interObjectContact

    public var errorDescription: String? {
        switch self {
        case .invalidOwnership: "Scene object ownership is invalid or contains duplicate identities."
        case .missingObject: "The scene object or component no longer exists."
        case .unsupportedRepresentation:
            "This operation does not support the selected object's representation."
        case .interObjectContact:
            "Independent structures need separated bounds. Inter-object contact and connections are not supported."
        }
    }
}

extension Scenario {
    public static let maximumStructures = 16
    public var fixedObjects: [SceneObject] { objects.filter { $0.fixedBox != nil } }
    public var structuralObjects: [SceneObject] { objects.filter { $0.structure != nil } }
    /// Legacy single-body adapter. Multi-body code must select an owner explicitly.
    public var structuralObject: SceneObject? { structuralObjects.first }

    public func structuralObject(sourceID: UUID) -> SceneObject? {
        structuralObjects.first { $0.sourceModelID == sourceID }
    }

    @discardableResult
    public mutating func addStructureObject(_ body: StructureModel, name: String = "Structure") throws -> UUID
    {
        guard structuralObjects.count < Self.maximumStructures else {
            throw SceneObjectError.unsupportedRepresentation
        }
        let object = SceneObject(name: name, representation: .deformable(body))
        objects.append(object)
        return object.id
    }

    public mutating func updateStructureObject(id: UUID, model: StructureModel?) throws {
        guard let index = objects.firstIndex(where: { $0.id == id }), objects[index].structure != nil else {
            throw SceneObjectError.missingObject
        }
        if let model { objects[index].setStructure(model) } else { objects.remove(at: index) }
    }

    public mutating func setPreferredSolidElementSize(id: UUID, size: Float) throws {
        guard size.isFinite, size > 0,
            let index = objects.firstIndex(where: { $0.id == id && $0.structure != nil })
        else {
            throw SceneObjectError.invalidOwnership
        }
        objects[index].preferredSolidElementSize = size
    }

    /// Conservative initial exclusion: touching/intersecting envelopes require an unsupported
    /// inter-object interaction, even when detailed geometry might leave a gap inside them.
    public func validateStructuralSeparation() throws {
        try SceneObject.validateSeparation(structuralObjects)
    }

    public func object(id: UUID) -> SceneObject? { objects.first { $0.id == id } }

    public func componentReferences(_ kind: SceneObject.ComponentKind) -> [SceneObject.ComponentReference] {
        structuralObject?.references(kind) ?? []
    }

    public func componentIndex(_ reference: SceneObject.ComponentReference) -> Int? {
        object(id: reference.objectID)?.index(of: reference)
    }

    @discardableResult
    public mutating func addFixedObject(_ box: Box, name: String = "Block") -> UUID {
        let object = SceneObject(name: name, representation: .fixed(box))
        objects.append(object)
        return object.id
    }

    public mutating func updateFixedObject(id: UUID, box: Box) throws {
        guard let index = objects.firstIndex(where: { $0.id == id }) else {
            throw SceneObjectError.missingObject
        }
        guard objects[index].fixedBox != nil else { throw SceneObjectError.unsupportedRepresentation }
        objects[index].setBox(box)
    }

    public mutating func removeObject(id: UUID) throws {
        guard objects.contains(where: { $0.id == id }) else { throw SceneObjectError.missingObject }
        // Source removal/detachment must be handled transactionally by the import workflow.
        guard object(id: id)?.sourceModelID == nil else { throw SceneObjectError.unsupportedRepresentation }
        objects.removeAll { $0.id == id }
    }

    @discardableResult
    public mutating func duplicateFixedObject(id: UUID) throws -> UUID {
        guard let original = object(id: id) else { throw SceneObjectError.missingObject }
        guard let box = original.fixedBox else { throw SceneObjectError.unsupportedRepresentation }
        return addFixedObject(box, name: "\(original.name) copy")
    }

    public mutating func reorderObjects(_ ids: [UUID]) throws {
        guard ids.count == objects.count, Set(ids).count == ids.count,
            Set(ids) == Set(objects.map(\.id))
        else { throw SceneObjectError.invalidOwnership }
        let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        objects = ids.map { byID[$0]! }
    }

    /// An editor knows whether it edited a component or removed one, even for equal regions.
    /// Apply transactionally after the edited body has passed application validation.
    public mutating func replaceStructure(
        _ body: StructureModel?, retainingComponentsFrom old: SceneObject,
        removing reference: SceneObject.ComponentReference? = nil
    ) throws {
        guard object(id: old.id)?.structure != nil, old.structure != nil else {
            throw SceneObjectError.missingObject
        }
        if let reference, body == nil {
            guard reference.kind == .solid, old.index(of: reference) != nil,
                old.structure?.solids.count == 1
            else { throw SceneObjectError.invalidOwnership }
        }
        if let reference, let body {
            guard let index = old.index(of: reference), var expected = old.structure else {
                throw SceneObjectError.missingObject
            }
            switch reference.kind {
            case .solid: expected.removeSolid(at: index)
            case .opening: expected.openings.remove(at: index)
            case .support: expected.removeSupport(at: index)
            }
            guard expected.solids == body.solids, expected.openings == body.openings,
                expected.supports == body.supports
            else { throw SceneObjectError.invalidOwnership }
        }
        var candidate = self
        try candidate.updateStructureObject(id: old.id, model: body)
        if let index = candidate.objects.firstIndex(where: { $0.id == old.id }) {
            try candidate.objects[index].retainComponentIDs(from: old, removing: reference)
        } else if body != nil {
            throw SceneObjectError.invalidOwnership
        }
        try candidate.validateObjectOwnership()
        self = candidate
    }

    public func validateObjectOwnership() throws {
        let objectIDs = objects.map(\.id)
        let componentIDs = objects.flatMap { $0.solidIDs + $0.openingIDs + $0.supportIDs }
        guard Set(objectIDs).count == objectIDs.count,
            Set(componentIDs).count == componentIDs.count,
            Set(objectIDs).isDisjoint(with: componentIDs),
            structuralObjects.count <= Self.maximumStructures,
            Set(structuralObjects.compactMap(\.sourceModelID)).count
                == structuralObjects.compactMap(\.sourceModelID).count,
            objects.filter({ $0.fixedBox != nil }).allSatisfy({ $0.sourceModelID == nil }),
            objects.allSatisfy({ $0.preferredSolidElementSize.map { $0.isFinite && $0 > 0 } ?? true }),
            objects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SceneObjectError.invalidOwnership }
    }

    internal mutating func bindStructuralSource(_ id: UUID, objectID: UUID? = nil) {
        if let index = objects.firstIndex(where: {
            objectID.map { $0 == $0 } == nil ? $0.structure != nil : $0.id == objectID
        }) {
            objects[index].sourceModelID = id
        }
    }

    public mutating func resolveLegacyStructuralSource() {
        for object in structuralObjects where object.sourceModelID == nil {
            if let model = importedModels?.first(where: { model in
                model.behavior == .deformable && structuralObject(sourceID: model.id) == nil
                    && (model.canRegenerate(object.structure)
                        || object.structure?.solidSourceParts.contains(where: { $0?.modelID == model.id })
                            == true)
            }) {
                bindStructuralSource(model.id, objectID: object.id)
            }
        }
        // Legacy single-body layouts could retain edited geometry without sampled part IDs.
        if structuralObjects.count == 1, structuralObject?.sourceModelID == nil {
            let candidates = (importedModels ?? []).filter { $0.isAttached && $0.behavior == .deformable }
            if candidates.count == 1 { bindStructuralSource(candidates[0].id) }
        }
    }

    public mutating func clearSourceOwnership(id: UUID) {
        for index in objects.indices where objects[index].sourceModelID == id {
            objects[index].sourceModelID = nil
        }
    }
}
