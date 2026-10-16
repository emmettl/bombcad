import Foundation

/// What an envelope building is built of, for the one-way damage of its components
/// (`EnvelopePanel`). The air never sees it: an envelope's geometry stays rigid and whole.
///
/// Read from an IFC import's materials or a map building's `building:material` tag where they say;
/// otherwise assumed (and said so), or chosen by the user in the editor.
public struct EnvelopeConstruction: Codable, Hashable, Sendable {
    /// The walls' and roof's construction, as the damage model knows them.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Reinforced concrete with one central mat, as a two-way panel (`EnvelopePanel.reinforcedConcrete`).
        case reinforcedConcrete
        /// Brick, block or stone without reinforcement and without arching
        /// (`EnvelopePanel.unreinforcedMasonry`).
        case unreinforcedMasonry

        public var label: String {
            switch self {
            case .reinforcedConcrete: "Reinforced concrete"
            case .unreinforcedMasonry: "Unreinforced masonry"
            }
        }
    }

    /// Where it came from.
    public enum Source: String, Codable, Sendable {
        /// The IFC import's material layers.
        case ifc
        /// The map building's `building:material` tag.
        case map
        /// Chosen in the editor.
        case user
        /// Nothing said: the default, flagged as assumed.
        case assumed
    }

    public var objectID: UUID
    public var walls: Kind
    public var wallThicknessM: Float
    /// The roof (and floor slabs), reinforced concrete unless said otherwise.
    public var roof: Kind
    public var roofThicknessM: Float
    /// Reinforcement of each concrete member, a central mat, as a share of the gross section
    /// each way.
    public var reinforcementRatio: Float
    /// Annealed glass in every pane, this thick.
    public var glassThicknessM: Float
    public var source: Source
    /// The tag, the materials read, or what was assumed, in words.
    public var detail: String

    public init(
        objectID: UUID, walls: Kind = .reinforcedConcrete, wallThicknessM: Float? = nil,
        roof: Kind = .reinforcedConcrete, roofThicknessM: Float = 0.2, reinforcementRatio: Float = 0.003,
        glassThicknessM: Float = 0.006, source: Source, detail: String
    ) {
        self.objectID = objectID
        self.walls = walls
        self.wallThicknessM = wallThicknessM ?? (walls == .unreinforcedMasonry ? 0.215 : 0.2)
        self.roof = roof
        self.roofThicknessM = roofThicknessM
        self.reinforcementRatio = reinforcementRatio
        self.glassThicknessM = glassThicknessM
        self.source = source
        self.detail = detail
    }

    /// The default when nothing says otherwise: 0.2 m reinforced concrete at 0.3% each way under a
    /// 0.2 m concrete roof, 6 mm annealed glass (stage 3a's references).
    public static func assumed(objectID: UUID) -> Self {
        Self(
            objectID: objectID, source: .assumed,
            detail: "assumed: 0.2 m reinforced concrete, 0.3% each way, 6 mm annealed glass")
    }

    /// From a map building's `building:material` value, when it names something the model knows.
    public static func fromMap(objectID: UUID, material: String?) -> Self? {
        guard let material else { return nil }
        let value = material.lowercased()
        let masonry = [
            "brick", "stone", "masonry", "sandstone", "limestone", "granite", "cement_block", "block",
        ]
        if value == "concrete" || value == "reinforced_concrete" {
            return Self(
                objectID: objectID, walls: .reinforcedConcrete, source: .map,
                detail: "building:material=\(material); 0.2 m, 0.3% each way assumed")
        }
        if masonry.contains(value) {
            return Self(
                objectID: objectID, walls: .unreinforcedMasonry, source: .map,
                detail: "building:material=\(material); 0.215 m assumed")
        }
        return nil
    }

    /// From the material layers of an IFC import's elements: concrete or masonry by the larger
    /// count of elements, with their median structural thickness. Nil when neither is read.
    public static func fromIFC(objectID: UUID, elementLayers: [[IFCStructure.Layer]]) -> Self? {
        var concrete: [Float] = []
        var masonry: [Float] = []
        for layers in elementLayers where !layers.isEmpty {
            let reading = IFCStructure.material(of: layers, default: .reinforcedConcrete)
            guard !reading.assumed else { continue }
            let kinds = layers.map { IFCStructure.classify($0.name) }
            if kinds.contains(.concrete) {
                concrete.append(reading.thickness ?? 0)
            } else if kinds.contains(where: { $0 == .masonry || $0 == .block }) {
                masonry.append(reading.thickness ?? 0)
            }
        }
        guard !concrete.isEmpty || !masonry.isEmpty else { return nil }
        let isConcrete = concrete.count >= masonry.count
        let thicknesses = (isConcrete ? concrete : masonry).filter { $0 > 0.05 && $0 < 1 }.sorted()
        let median = thicknesses.isEmpty ? nil : thicknesses[thicknesses.count / 2]
        return Self(
            objectID: objectID, walls: isConcrete ? .reinforcedConcrete : .unreinforcedMasonry,
            wallThicknessM: median, source: .ifc,
            detail: "IFC: \(concrete.count) concrete and \(masonry.count) masonry elements"
                + (median.map { String(format: ", %.3f m thick", $0) } ?? "")
                + (isConcrete ? ", 0.3% each way assumed" : ""))
    }
}

extension Scenario {
    /// Each envelope's construction: the one recorded for it, or the assumed default.
    public func envelopeConstruction(for objectID: UUID) -> EnvelopeConstruction {
        envelopeConstructions?.last { $0.objectID == objectID } ?? .assumed(objectID: objectID)
    }

    /// Records `construction` for its envelope, replacing any before it.
    public mutating func setEnvelopeConstruction(_ construction: EnvelopeConstruction) {
        var list = (envelopeConstructions ?? []).filter { $0.objectID != construction.objectID }
        list.append(construction)
        let present = Set(envelopeObjects.map(\.id))
        list.removeAll { !present.contains($0.objectID) }
        envelopeConstructions = list.isEmpty ? nil : list
    }
}
