import Foundation

/// Authored ownership, independent of GPU indices and renderer picking numbers.
/// The initial adapter supports fixed blocks and at most one deformable object.
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
    public private(set) var solidIDs: [UUID] = []
    public private(set) var openingIDs: [UUID] = []
    public private(set) var supportIDs: [UUID] = []

    public init(id: UUID = UUID(), name: String, representation: Representation) {
        self.id = id
        self.name = name
        self.representation = representation
        if case .deformable(let body) = representation {
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

    internal static func legacyBlock(_ box: Box, index: Int) -> Self {
        Self(id: legacyID(1, index), name: "Block \(index + 1)", representation: .fixed(box))
    }

    internal static func legacyStructure(_ body: StructureModel) -> Self {
        var object = Self(id: legacyID(2, 0), name: "Structure", representation: .deformable(body))
        object.solidIDs = body.solids.indices.map { legacyID(3, $0) }
        object.openingIDs = body.openings.indices.map { legacyID(4, $0) }
        object.supportIDs = body.supports.indices.map { legacyID(5, $0) }
        return object
    }

    /// Ownership is encoded beside the legacy geometry, without duplicating numerical inputs.
    internal struct Ownership: Codable {
        var id: UUID
        var name: String
        var sourceModelID: UUID?
        var solidIDs: [UUID]
        var openingIDs: [UUID]
        var supportIDs: [UUID]

        init(_ object: SceneObject) {
            id = object.id
            name = object.name
            sourceModelID = object.sourceModelID
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
            result.solidIDs = solidIDs
            result.openingIDs = openingIDs
            result.supportIDs = supportIDs
            return result
        }
    }
}

public enum SceneObjectError: Error, LocalizedError {
    case invalidOwnership, missingObject, unsupportedRepresentation

    public var errorDescription: String? {
        switch self {
        case .invalidOwnership: "Scene object ownership is invalid or contains duplicate identities."
        case .missingObject: "The scene object or component no longer exists."
        case .unsupportedRepresentation: "This scene adapter supports fixed blocks and one deformable object."
        }
    }
}

extension Scenario {
    public var fixedObjects: [SceneObject] { objects.filter { $0.fixedBox != nil } }
    public var structuralObject: SceneObject? { objects.first { $0.structure != nil } }

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
        guard structuralObject?.id == old.id, old.structure != nil else {
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
        candidate.structure = body
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
            objects.filter({ $0.structure != nil }).count <= 1,
            objects.filter({ $0.fixedBox != nil }).allSatisfy({ $0.sourceModelID == nil }),
            objects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SceneObjectError.invalidOwnership }
    }

    internal mutating func bindStructuralSource(_ id: UUID) {
        if let index = objects.firstIndex(where: { $0.structure != nil }) {
            objects[index].sourceModelID = id
        }
    }

    public mutating func resolveLegacyStructuralSource() {
        guard structuralObject?.sourceModelID == nil else { return }
        if let model = importedModels?.first(where: { model in
            model.behavior == .deformable
                && (model.canRegenerate(structure)
                    || structure?.solidSourceParts.contains(where: { $0?.modelID == model.id }) == true)
        }) {
            bindStructuralSource(model.id)
        }
    }

    public mutating func clearSourceOwnership(id: UUID) {
        for index in objects.indices where objects[index].sourceModelID == id {
            objects[index].sourceModelID = nil
        }
    }
}
