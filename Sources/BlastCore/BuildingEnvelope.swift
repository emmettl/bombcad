import Foundation
import simd

/// Stationary opaque geometry for exposure studies. No mass, deformation or failure law.
/// Solids describe walls/roofs; openings remove material from every intersecting solid.
public struct BuildingEnvelope: Hashable, Sendable, Codable {
    public let solids: [Box]
    public let openings: [Box]
    /// Disjoint fragments within each solid, using Box's half-open boundary convention.
    public let blocks: [Box]
    private enum CodingKeys: String, CodingKey { case solids, openings }

    public init(solids: [Box], openings: [Box] = []) throws {
        guard !solids.isEmpty, solids.count <= 2048, openings.count <= 256,
            (solids + openings).allSatisfy({ box in
                (0..<3).allSatisfy { box.min[$0].isFinite && box.max[$0].isFinite && box.size[$0] > 0 }
            })
        else { throw SceneObjectError.invalidOwnership }
        self.solids = solids
        self.openings = openings
        var compiled: [Box] = []
        for solid in solids {
            var pieces = [solid]
            for opening in openings {
                pieces = pieces.flatMap { Self.subtract(opening, from: $0) }
                guard pieces.count + compiled.count <= 2048 else { throw SceneObjectError.invalidOwnership }
            }
            compiled.append(contentsOf: pieces)
            guard compiled.count <= 2048 else { throw SceneObjectError.invalidOwnership }
        }
        guard !compiled.isEmpty else { throw SceneObjectError.invalidOwnership }
        blocks = compiled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            solids: c.decode([Box].self, forKey: .solids),
            openings: c.decode([Box].self, forKey: .openings))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(solids, forKey: .solids)
        try c.encode(openings, forKey: .openings)
    }

    public func occupies(_ point: SIMD3<Float>) -> Bool {
        solids.contains { $0.contains(point) } && !openings.contains { $0.contains(point) }
    }

    private static func subtract(_ hole: Box, from solid: Box) -> [Box] {
        let low = simd_max(hole.min, solid.min)
        let high = simd_min(hole.max, solid.max)
        guard (0..<3).allSatisfy({ low[$0] < high[$0] }) else { return [solid] }
        var middle = solid
        var result: [Box] = []
        for axis in 0..<3 {
            if middle.min[axis] < low[axis] {
                var piece = middle
                piece.max[axis] = low[axis]
                if piece.size[axis] > 0 { result.append(piece) }
            }
            if middle.max[axis] > high[axis] {
                var piece = middle
                piece.min[axis] = high[axis]
                if piece.size[axis] > 0 { result.append(piece) }
            }
            middle.min[axis] = low[axis]
            middle.max[axis] = high[axis]
        }
        return result
    }
}

extension Scenario {
    public var envelopeObjects: [SceneObject] { objects.filter { $0.envelope != nil } }

    @discardableResult
    public mutating func addEnvelopeObject(
        _ envelope: BuildingEnvelope, name: String = "Building", id: UUID = UUID()
    ) throws -> UUID {
        guard object(id: id) == nil else { throw SceneObjectError.invalidOwnership }
        let object = SceneObject(id: id, name: name, representation: .envelope(envelope))
        objects.append(object)
        return object.id
    }

    /// Explicit approximation of a local authored structure, retaining its object identity.
    /// Source-owned imports remain on their import workflow.
    public mutating func useEnvelope(id: UUID) throws {
        guard let index = objects.firstIndex(where: { $0.id == id }),
            let body = objects[index].structure, objects[index].sourceModelID == nil
        else { throw SceneObjectError.unsupportedRepresentation }
        objects[index] = SceneObject(
            id: id, name: objects[index].name,
            representation: .envelope(try BuildingEnvelope(solids: body.solids, openings: body.openings)))
    }
}
