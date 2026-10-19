import Foundation
import simd

/// Stationary opaque geometry for exposure studies. No mass, deformation or failure law.
/// Solids describe walls/roofs; openings remove material from every solid they cross, but not from
/// one they hold whole (a door or a window's glass set in its opening). Panes are glazing, solid in
/// the air as the solids are: a one-way damage model takes a pane as closed until it fails
/// (docs/building-envelopes.md, "Envelope components").
public struct BuildingEnvelope: Hashable, Sendable, Codable {
    public let solids: [Box]
    public let openings: [Box]
    public let panes: [Box]
    /// Disjoint fragments within each solid, using Box's half-open boundary convention, then the
    /// panes.
    public let blocks: [Box]
    /// Where each block came from.
    public let blockSources: [BlockSource]
    private enum CodingKeys: String, CodingKey { case solids, openings, panes }

    /// A block's source: a solid or a pane, by index.
    public enum BlockSource: Hashable, Sendable {
        case solid(Int)
        case pane(Int)
    }

    public init(solids: [Box], openings: [Box] = [], panes: [Box] = []) throws {
        guard !(solids + panes).isEmpty, solids.count <= 2048, openings.count <= 256, panes.count <= 256,
            (solids + openings + panes).allSatisfy({ box in
                (0..<3).allSatisfy { box.min[$0].isFinite && box.max[$0].isFinite && box.size[$0] > 0 }
            })
        else { throw SceneObjectError.invalidOwnership }
        self.solids = solids
        self.openings = openings
        self.panes = panes
        var compiled: [Box] = []
        var sources: [BlockSource] = []
        for (index, solid) in solids.enumerated() {
            var pieces = [solid]
            for opening in openings where !opening.holds(solid) {
                pieces = pieces.flatMap { Self.subtract(opening, from: $0) }
                guard pieces.count + compiled.count <= 2048 else { throw SceneObjectError.invalidOwnership }
            }
            compiled.append(contentsOf: pieces)
            sources.append(contentsOf: Array(repeating: .solid(index), count: pieces.count))
            guard compiled.count <= 2048 else { throw SceneObjectError.invalidOwnership }
        }
        compiled.append(contentsOf: panes)
        sources.append(contentsOf: panes.indices.map { .pane($0) })
        guard !compiled.isEmpty, compiled.count <= 2048 + 256 else { throw SceneObjectError.invalidOwnership }
        blocks = compiled
        blockSources = sources
    }

    /// A detailed structure's envelope: its solids and openings, with its glass solids (annealed or
    /// toughened) as panes.
    public init(structure: StructureModel) throws {
        let glass = structure.solids.indices.map { index in
            index < structure.solidMaterial.count && structure.solidMaterial[index]?.isTransparent == true
        }
        try self.init(
            solids: structure.solids.indices.filter { !glass[$0] }.map { structure.solids[$0] },
            openings: structure.openings,
            panes: structure.solids.indices.filter { glass[$0] }.map { structure.solids[$0] })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            solids: c.decode([Box].self, forKey: .solids),
            openings: c.decode([Box].self, forKey: .openings),
            panes: c.decodeIfPresent([Box].self, forKey: .panes) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(solids, forKey: .solids)
        try c.encode(openings, forKey: .openings)
        // Written only when there are some, so that envelopes without glass encode as before.
        if !panes.isEmpty { try c.encode(panes, forKey: .panes) }
    }

    public func occupies(_ point: SIMD3<Float>) -> Bool {
        solids.contains { solid in
            solid.contains(point) && !openings.contains { $0.contains(point) && !$0.holds(solid) }
        } || panes.contains { $0.contains(point) }
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
    /// Whether any envelope has glazing (`BuildingEnvelope.panes`), which older readers would drop.
    public var hasEnvelopePanes: Bool { envelopeObjects.contains { !($0.envelope?.panes.isEmpty ?? true) } }

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
            representation: .envelope(try BuildingEnvelope(structure: body)))
    }
}

extension BuildingEnvelope {
    /// The cells of the grid that stand for pane `index` in the air: across its face, those whose
    /// centres lie within it (as a block's cells are found); through it, those whose centres lie in
    /// a solid of the building holding it whole (its wall, where the glass is set in the wall
    /// without an opening), or else the one its middle plane passes through, so that glass thinner
    /// than a cell still closes its window. They are solid from the start, carry the pane's load,
    /// and open when it breaks.
    public func paneCells(_ index: Int, grid: Grid) -> [Int] {
        let pane = panes[index]
        let size = pane.size
        let thin = size.x <= size.y && size.x <= size.z ? 0 : (size.y <= size.z ? 1 : 2)
        let dx = grid.cellSize
        let counts = [grid.nx, grid.ny, grid.nz]
        func range(_ low: Float, _ high: Float, _ axis: Int) -> Range<Int> {
            // As the mask's rasteriser: a cell whose centre lies in [low, high).
            let lower = min(max(Int((low / dx - 0.5).rounded(.up)), 0), counts[axis])
            let upper = min(max(Int((high / dx - 0.5).rounded(.up)), lower), counts[axis])
            return lower..<upper
        }
        var ranges = (0..<3).map { range(pane.min[$0], pane.max[$0], $0) }
        let holders = solids.filter { solid in
            (0..<3).allSatisfy { solid.min[$0] <= pane.min[$0] && solid.max[$0] >= pane.max[$0] }
        }
        var through = Set(ranges[thin])
        for solid in holders { through.formUnion(range(solid.min[thin], solid.max[thin], thin)) }
        if through.isEmpty {
            let middle = Int(floor((pane.min[thin] + pane.max[thin]) / 2 / dx))
            through.insert(min(max(middle, 0), counts[thin] - 1))
        }
        ranges[thin] = 0..<0
        var cells: [Int] = []
        let along = through.sorted()
        for k in (thin == 2 ? along : Array(ranges[2])) {
            for j in (thin == 1 ? along : Array(ranges[1])) {
                for i in (thin == 0 ? along : Array(ranges[0])) { cells.append(grid.index(i, j, k)) }
            }
        }
        return cells
    }
}

extension BuildingEnvelope {
    /// The same envelope moved by `offset`, metres.
    public func translated(by offset: SIMD3<Float>) throws -> BuildingEnvelope {
        func move(_ box: Box) -> Box { Box(min: box.min + offset, max: box.max + offset) }
        return try BuildingEnvelope(
            solids: solids.map(move), openings: openings.map(move), panes: panes.map(move))
    }
}
