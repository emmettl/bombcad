import Foundation

/// What the learned response's networks read of a building's construction and glazing
/// (emmettl/bombcad-work#113): not which of a few signatures it is, as the first networks did, but
/// what it is built of, so that one network covers the envelope model's walls, roofs and glass, and
/// the what-ifs that change them.
extension LiveResponse {
    /// The construction's kinds, in their one-hots' order.
    static let constructionKinds: [EnvelopeConstruction.Kind] = [
        .reinforcedConcrete, .reinforcedBlockwork, .unreinforcedMasonry, .profiledSteelSheeting,
        .crossLaminatedTimber,
    ]

    /// The glazing mixes the networks know, by name: the map buildings' four (`GlazingMix`).
    static let standardMixes: [GlazingMix] = [.olderLowRise, .apartments, .commercial, .industrial]

    /// The width of `glassFeatures`, and one more: each of the construction's and the glazing's
    /// vectors ends in a zero, kept for the inputs as the version 2 networks were trained on them.
    static let glassWidth = 14

    /// A pane's glass as the networks read it: toughened; laminated (its interlayer ionoplast, its
    /// glass plies and interlayer, mm, and what its edge holds, kN/m, or held without limit); filmed
    /// (its thickness, mil, and its anchorage); and its condition's strength factor.
    static func glassFeatures(
        toughened: Bool, laminate: LaminatedGlass?, film: SecurityFilm?, condition: GlassCondition?
    ) -> [Float] {
        var values: [Float] = [toughened && laminate == nil ? 1 : 0]
        if let laminate {
            values += [
                1, laminate.interlayer == .sgp ? 1 : 0, Float(laminate.plies.reduce(0, +) * 1000),
                Float(laminate.interlayerThickness * 1000), Float((laminate.edgeCapacity ?? 0) / 1000),
                laminate.edgeCapacity == nil ? 1 : 0,
            ]
        } else {
            values += [0, 0, 0, 0, 0, 0]
        }
        if let film, laminate == nil {
            values += [1, Float(film.thickness / 25.4e-6)]
            values += SecurityFilm.Anchorage.allCases.map { $0 == film.anchorage ? 1 : 0 }
        } else {
            values += [0, 0, 0, 0, 0]
        }
        values.append(Float((condition ?? .asDesigned).strengthFactor))
        return values
    }

    /// The width of `constructionFeatures`.
    public static let constructionWidth = 5 + 1 + 5 + 1 + 1 + 2 + glassWidth + 3

    /// A building's construction as the component and walls networks read it: its walls' kind and
    /// thickness, its roof's kind and thickness, its bars (% each way), its façade panes' glass
    /// (thickness, mm, and `glassFeatures`) and their size, m, and whether it is plain annealed
    /// glass. Nil for a construction with more than these, which the networks were not trained on: a
    /// liner, arching, bars in both faces, strengths, a cap, sheets or rails other than the
    /// defaults, or glazing set side by side.
    public static func constructionFeatures(_ c: EnvelopeConstruction) -> [Float]? {
        guard c.wallLiner == nil, c.masonryArching == nil, c.barsInBothFaces == nil, c.barCoverM == nil,
            c.concreteStrengthMPa == nil, c.barYieldMPa == nil, c.blockworkGrouted == nil,
            c.masonryStrengthMPa == nil, c.capMassKgPerM == nil, c.wallSheet == nil, c.roofSheet == nil,
            c.sheetSpanM == nil, c.sheetContinuous == nil, c.screwsPerM == nil, c.railThicknessM == nil,
            c.sideGlazing == nil, c.glazing.map({ glazingFeatures($0) != nil }) ?? true
        else { return nil }
        let pane = c.facadePaneM ?? EnvelopeConstruction.assumedFacadePane
        return constructionKinds.map { $0 == c.walls ? 1 : 0 } + [c.wallThicknessM]
            + constructionKinds.map { $0 == c.roof ? 1 : 0 } + [c.roofThicknessM, c.reinforcementRatio * 100]
            + [Float(c.glassAloneM * 1000), c.hasPlainGlass ? 1 : 0]
            + glassFeatures(
                toughened: c.glassToughened == true, laminate: c.laminate, film: c.film,
                condition: c.glassCondition)
            + [pane.x, pane.y, pane.x > 0 && pane.y > 0 ? 1 : 0] + [0]
    }

    /// The width of `glazingFeatures`.
    public static let glazingWidth = 4 + glassWidth

    /// A glazing mix as the glass network reads it: which of the map buildings' four it is, and its
    /// glass (`glassFeatures`). Nil for any other mix.
    public static func glazingFeatures(_ mix: GlazingMix) -> [Float]? {
        guard
            let base = standardMixes.firstIndex(where: {
                $0.panes == mix.panes && $0.glazedFraction == mix.glazedFraction
            })
        else { return nil }
        return (0..<standardMixes.count).map { $0 == base ? 1 : 0 }
            + glassFeatures(
                toughened: mix.glass?.toughened == true, laminate: mix.glass?.laminate, film: mix.glass?.film,
                condition: mix.condition) + [0]
    }

    /// Glass for every pane of a building, as a what-if or the training data sets it.
    public enum Glass: Hashable, Sendable {
        case annealed
        case toughened
        case filmed(SecurityFilm)
        case laminated(LaminatedGlass)

        /// The names the app's what-if offers, with the glass each is.
        public static let offered: [(name: String, glass: Glass)] = [
            ("Annealed (as built)", .annealed),
            ("Toughened", .toughened),
            ("Film, not anchored", .filmed(.mils(8, anchorage: .daylight))),
            ("Film, wet glazed", .filmed(.mils(8, anchorage: .wetGlazed))),
            ("Film, mechanically attached", .filmed(.mils(8, anchorage: .mechanical))),
            ("Laminated", .laminated(.facade)),
        ]

        /// `construction` with this glass in its façade panes and its glazing mix.
        public func applied(to construction: EnvelopeConstruction) -> EnvelopeConstruction {
            var c = construction
            c.glassToughened = nil
            c.film = nil
            c.laminate = nil
            var glass: GlazingMix.Glass?
            switch self {
            case .annealed:
                c.glassThicknessM = 0.006
            case .toughened:
                c.glassThicknessM = 0.006
                c.glassToughened = true
                glass = GlazingMix.Glass(toughened: true)
            case .filmed(let film):
                c.glassThicknessM = 0.006
                c.film = film
                glass = GlazingMix.Glass(film: film)
            case .laminated(let laminate):
                c.laminate = laminate
                c.glassThicknessM = Float(laminate.thickness)
                glass = GlazingMix.Glass(laminate: laminate)
            }
            c.glazing = c.glazing?.with(glass)
            return c
        }
    }

    /// `construction` with its walls (and roof, if given) of `kind`, at that kind's usual thickness.
    public static func building(
        _ construction: EnvelopeConstruction, walls: EnvelopeConstruction.Kind,
        roof: EnvelopeConstruction.Kind? = nil
    ) -> EnvelopeConstruction {
        var c = construction
        c.walls = walls
        c.wallThicknessM = EnvelopeConstruction.defaultThickness(walls)
        if let roof {
            c.roof = roof
            c.roofThicknessM = roof == .crossLaminatedTimber ? 0.14 : 0.2
        }
        return c
    }

    /// A way of building drawn for the training data (`recipe`): its walls' and roof's kinds and
    /// their thicknesses over the usual, its bars, a mix of panes for every building (nil, each its
    /// own), its glass and its condition.
    package struct Recipe: Sendable {
        var walls: EnvelopeConstruction.Kind
        var wallFactor: Float
        var roof: EnvelopeConstruction.Kind
        var roofFactor: Float
        var reinforcementRatio: Float
        var mix: GlazingMix?
        var glass: Glass
        var newGlass: Bool

        /// `base` (a building's own) built this way.
        package func applied(to base: EnvelopeConstruction) -> EnvelopeConstruction {
            var c = base
            c.walls = walls
            c.wallThicknessM =
                EnvelopeConstruction.defaultThickness(walls)
                * (walls == .profiledSteelSheeting ? 1 : wallFactor)
            c.roof = roof
            c.roofThicknessM = (roof == .crossLaminatedTimber ? 0.14 : 0.2) * roofFactor
            c.reinforcementRatio = reinforcementRatio
            if let mix { c.glazing = mix }
            c = glass.applied(to: c)
            c.setGlassCondition(newGlass ? .newOrTested : .asDesigned)
            return c
        }
    }

    /// A way of building drawn from `uniform(k)`, a draw in [0, 1) for each k: its walls of any of
    /// the five kinds (concrete and masonry the likelier), their thickness 0.6–1.6 times the usual,
    /// its roof concrete, sheeting or timber, its bars 0.15–0.9% each way, half the time one mix of
    /// panes for all, and its glass annealed, toughened, filmed (4 or 8 mil, any anchorage) or
    /// laminated (4 or 6 mm plies, PVB or ionoplast, 0.76 or 1.52 mm, a silicone edge or none), new a
    /// fifth of the time. The data's frames each draw a few, every building built as one of them or
    /// as it is: a few ways of building a frame, so that the SDOF's and the panes' tables serve many.
    package static func recipe(_ uniform: (UInt64) -> Double) -> Recipe {
        func pick<T>(_ list: [T], _ k: UInt64) -> T {
            list[min(Int(uniform(k) * Double(list.count)), list.count - 1)]
        }
        func range(_ low: Double, _ high: Double, _ k: UInt64) -> Double { low + (high - low) * uniform(k) }
        let glass: Glass =
            switch uniform(8) {
            case ..<0.35: .annealed
            case ..<0.5: .toughened
            case ..<0.75:
                .filmed(.mils(uniform(9) < 0.5 ? 4 : 8, anchorage: pick(SecurityFilm.Anchorage.allCases, 10)))
            default:
                .laminated(
                    LaminatedGlass(
                        plies: uniform(11) < 0.5 ? [0.004, 0.004] : [0.006, 0.006],
                        interlayer: uniform(12) < 0.7 ? .pvb : .sgp,
                        interlayerThickness: uniform(13) < 0.5 ? 0.00076 : 0.00152,
                        edgeCapacity: uniform(14) < 0.5 ? LaminatedGlass.siliconeCapacity(bite: 0.02) : nil))
            }
        return Recipe(
            walls: pick(
                [
                    .reinforcedConcrete, .reinforcedConcrete, .reinforcedBlockwork, .unreinforcedMasonry,
                    .unreinforcedMasonry, .profiledSteelSheeting, .crossLaminatedTimber,
                ], 1),
            wallFactor: Float(range(0.6, 1.6, 2)),
            roof: pick(
                [.reinforcedConcrete, .reinforcedConcrete, .profiledSteelSheeting, .crossLaminatedTimber], 3),
            roofFactor: Float(range(0.6, 1.6, 4)), reinforcementRatio: Float(0.003 * range(0.5, 3, 5)),
            mix: uniform(6) < 0.5 ? pick(standardMixes, 7) : nil, glass: glass, newGlass: uniform(15) < 0.2)
    }
}

extension LiveResponse {
    /// What if every building were built otherwise (emmettl/bombcad-work#113): its glass, its walls
    /// and its roof, each as built unless set. Applied to a copy of the scene for the quick
    /// estimate and its previews, never to the project itself.
    public struct WhatIf: Hashable, Sendable {
        public var glass: Glass?
        public var walls: EnvelopeConstruction.Kind?
        public var roof: EnvelopeConstruction.Kind?

        public init(
            glass: Glass? = nil, walls: EnvelopeConstruction.Kind? = nil,
            roof: EnvelopeConstruction.Kind? = nil
        ) {
            self.glass = glass
            self.walls = walls
            self.roof = roof
        }

        public var isEmpty: Bool { glass == nil && walls == nil && roof == nil }

        /// The walls' and roofs' kinds a what-if offers.
        public static let wallKinds: [EnvelopeConstruction.Kind] = constructionKinds
        public static let roofKinds: [EnvelopeConstruction.Kind] = [
            .reinforcedConcrete, .profiledSteelSheeting, .crossLaminatedTimber,
        ]

        /// `construction` as this what-if builds it.
        public func applied(to construction: EnvelopeConstruction) -> EnvelopeConstruction {
            var c = construction
            if let walls {
                c.walls = walls
                c.wallThicknessM = EnvelopeConstruction.defaultThickness(walls)
            }
            if let roof {
                c.roof = roof
                c.roofThicknessM = roof == .crossLaminatedTimber ? 0.14 : 0.2
            }
            if let glass { c = glass.applied(to: c) }
            return c
        }

        /// `scene` with every envelope building built as this what-if builds it.
        public func applied(to scene: Scenario) -> Scenario {
            guard !isEmpty else { return scene }
            var copy = scene
            let recorded = Dictionary(
                (scene.envelopeConstructions ?? []).map { ($0.objectID, $0) },
                uniquingKeysWith: { _, last in last })
            copy.envelopeConstructions = scene.envelopeObjects.map {
                applied(to: recorded[$0.id] ?? .assumed(objectID: $0.id))
            }
            return copy
        }

        /// In words, for the sidebar: "every building's glass toughened, walls of unreinforced masonry".
        public var label: String {
            var parts: [String] = []
            if let glass, let name = Glass.offered.first(where: { $0.glass == glass })?.name {
                parts.append("glass \(name.lowercased())")
            }
            if let walls { parts.append("walls of \(walls.label.lowercased())") }
            if let roof { parts.append("roofs of \(roof.label.lowercased())") }
            return parts.isEmpty ? "as built" : "every building's " + parts.joined(separator: ", ")
        }
    }
}
