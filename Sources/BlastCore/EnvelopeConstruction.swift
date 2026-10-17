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
        /// Concrete blockwork with bars in its cells, grouted or not: judged as reinforced
        /// concrete of the masonry's strength (walls only).
        case reinforcedBlockwork
        /// Profiled steel sheeting on rails or purlins, spanning one way between them
        /// (`EnvelopePanel.profiledSheetOneWay`): a portal-frame shed's cladding and roof.
        case profiledSteelSheeting

        public var label: String {
            switch self {
            case .reinforcedConcrete: "Reinforced concrete"
            case .unreinforcedMasonry: "Unreinforced masonry"
            case .reinforcedBlockwork: "Reinforced blockwork"
            case .profiledSteelSheeting: "Profiled steel sheeting"
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
    /// The pane a façade strip is taken to hold (a block's storey strip, as map buildings have),
    /// width and height, m: nil for `assumedFacadePane`, zero for none.
    public var facadePaneM: SIMD2<Float>?
    /// A window in each storey of a façade, where nothing says otherwise.
    public static let assumedFacadePane = SIMD2<Float>(1.2, 1.5)
    public var source: Source
    /// The tag, the materials read, or what was assumed, in words.
    public var detail: String
    /// The walls' bars (concrete or blockwork): a mat in each face, `barCoverM` from it to the
    /// bars' centres, the ratio shared between the two; nil or false for one central mat.
    public var barsInBothFaces: Bool?
    public var barCoverM: Float?
    /// The walls' concrete strength, MPa; nil for the default 30.
    public var concreteStrengthMPa: Float?
    /// The walls' bars' yield strength, MPa; nil for the default 500.
    public var barYieldMPa: Float?
    /// Reinforced blockwork: fully grouted (nil or true) or hollow, its cells holding only the
    /// bars; and its compressive strength on the gross area, MPa, nil for 10 grouted or 3 hollow
    /// (the model's concrete block).
    public var blockworkGrouted: Bool?
    public var masonryStrengthMPa: Float?
    /// A cap or canopy carried on a freestanding wall's top, kg per metre of wall: mass that moves
    /// with the top without holding it, as a slab on other walls would; nil for none.
    public var capMassKgPerM: Float?
    /// Profiled steel sheeting: the walls' and the roof's profiles, by name from
    /// `SheetProfile.library` (nil for the 32 mm wall and 45 mm roof profiles); the rails' and
    /// purlins' spacing it spans, m (nil for 1.8); whether it is continuous over them (nil or
    /// true) or a single span; and its screws per metre at each rail or purlin (nil for 3) into
    /// steel this thick, m (nil for 2 mm).
    public var wallSheet: String?
    public var roofSheet: String?
    public var sheetSpanM: Float?
    public var sheetContinuous: Bool?
    public var screwsPerM: Float?
    public var railThicknessM: Float?

    public init(
        objectID: UUID, walls: Kind = .reinforcedConcrete, wallThicknessM: Float? = nil,
        roof: Kind = .reinforcedConcrete, roofThicknessM: Float = 0.2, reinforcementRatio: Float = 0.003,
        glassThicknessM: Float = 0.006, source: Source, detail: String, barsInBothFaces: Bool? = nil,
        barCoverM: Float? = nil, concreteStrengthMPa: Float? = nil, barYieldMPa: Float? = nil,
        blockworkGrouted: Bool? = nil, masonryStrengthMPa: Float? = nil, capMassKgPerM: Float? = nil
    ) {
        self.barsInBothFaces = barsInBothFaces
        self.barCoverM = barCoverM
        self.concreteStrengthMPa = concreteStrengthMPa
        self.barYieldMPa = barYieldMPa
        self.blockworkGrouted = blockworkGrouted
        self.masonryStrengthMPa = masonryStrengthMPa
        self.capMassKgPerM = capMassKgPerM
        self.objectID = objectID
        self.walls = walls
        self.wallThicknessM = wallThicknessM ?? Self.defaultThickness(walls)
        self.roof = roof
        self.roofThicknessM = roofThicknessM
        self.reinforcementRatio = reinforcementRatio
        self.glassThicknessM = glassThicknessM
        self.source = source
        self.detail = detail
    }

    /// The thickness a wall of `kind` takes unless said: 215 mm of masonry, a sheet's profile
    /// depth, otherwise 200 mm.
    public static func defaultThickness(_ kind: Kind) -> Float {
        switch kind {
        case .unreinforcedMasonry: 0.215
        case .profiledSteelSheeting: SheetProfile.swedsteelSTW35.depth
        case .reinforcedConcrete, .reinforcedBlockwork: 0.2
        }
    }

    /// The sheeting's profile on the roof or the walls.
    public func sheet(roof: Bool) -> SheetProfile {
        let name = roof ? roofSheet : wallSheet
        return SheetProfile.library.first { $0.name == name }
            ?? (roof ? SheetProfile.swedsteelSTR45 : SheetProfile.swedsteelSTW35)
    }

    /// The walls' material for the concrete-like systems (reinforced concrete or blockwork): the
    /// app's reinforced concrete at the strengths given, or blockwork as a concrete of the
    /// masonry's strength, its modulus 1,000 times it (Eurocode 6, as the concrete block preset),
    /// 2,100 kg/m³ grouted or 1,400 hollow.
    public var wallMaterial: StructureMaterial {
        var steel = SteelProperties.grade500
        if let yield = barYieldMPa {
            steel.ultimateStress *= yield * 1e6 / steel.yieldStress
            steel.yieldStress = yield * 1e6
        }
        if walls == .reinforcedBlockwork {
            let grouted = blockworkGrouted ?? true
            let strength = (masonryStrengthMPa ?? (grouted ? 10 : 3)) * 1e6
            var material = StructureMaterial.concrete(
                name: "Reinforced blockwork", compressiveStrength: strength, density: grouted ? 2100 : 1400,
                steel: steel)
            material.youngsModulus = 1000 * strength
            return material
        }
        var material = StructureMaterial.reinforcedConcrete
        if let strength = concreteStrengthMPa {
            material = .concrete(name: material.name, compressiveStrength: strength * 1e6, steel: steel)
            material.rateDependent = true
        } else {
            material.steel = steel
        }
        return material
    }

    /// The walls' tension bars for a section `thickness` thick: their depth from the compression
    /// face and area per metre (one face's share when in both faces).
    public func wallBars(thickness: Double) -> (depth: Double, steelArea: Double) {
        let steel = Double(reinforcementRatio) * thickness
        if barsInBothFaces == true {
            return (thickness - Double(barCoverM ?? 0.03), steel / 2)
        }
        return (thickness / 2, steel)
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
