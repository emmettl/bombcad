import Foundation
import simd

// The evidential standing of each result a scene produces: whether it rests on agreement with
// measurements, on agreement with theory, on stated assumptions, or on nothing but plausibility.
// The content is one reviewed table (`StandingTable`) that mirrors docs/validation.md and the
// roadmap's limitations table; `SceneStanding.init(_:)` picks from it by the scene's settings.
// See docs/standing.md.

/// How far a result has been established, strongest first.
public enum EvidenceLevel: String, Codable, CaseIterable, Sendable, Comparable {
    /// Compared with measurements, and the comparison says how close it came.
    case measured
    /// Shown to solve its equations correctly against exact or textbook solutions; not compared
    /// with measurements.
    case verified
    /// A recognised approximation whose assumptions are stated; nothing establishes how close
    /// it comes for this scene.
    case approximation
    /// Plausible-looking only, or compared too loosely to rely on.
    case illustrative

    public var title: String {
        switch self {
        case .measured: "Measured agreement"
        case .verified: "Verified against theory"
        case .approximation: "Approximation"
        case .illustrative: "Illustrative"
        }
    }

    /// One word for a badge.
    public var badge: String {
        switch self {
        case .measured: "Measured"
        case .verified: "Verified"
        case .approximation: "Approximate"
        case .illustrative: "Illustrative"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }

    /// Stronger evidence sorts first.
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// The results a scene can produce, each with a standing of its own.
public enum ResultKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case peakOverpressure
    case impulse
    case structuralResponse
    case structuralDamage
    case envelopeExposure
    case freestandingMotion
    case thermal
    case surfaceHeating
    case cloud
    case fragments
    case groundShock

    public var id: Self { self }

    public var title: String {
        switch self {
        case .peakOverpressure: "Peak overpressure"
        case .impulse: "Impulse"
        case .structuralResponse: "Structural deflection"
        case .structuralDamage: "Structural damage and failure"
        case .envelopeExposure: "Building surface exposure"
        case .freestandingMotion: "Freestanding objects' motion"
        case .thermal: "Thermal radiation"
        case .surfaceHeating: "Surface heating and ignition"
        case .cloud: "Rise and cloud"
        case .fragments: "Fragments"
        case .groundShock: "Ground shock"
        }
    }
}

/// One check behind a standing: what it was, how close it came, and where it is written up.
public struct StandingEvidence: Codable, Hashable, Sendable {
    public var check: String
    public var agreement: String
    /// A page under docs/, with an anchor: `validation.md#with-refinement`.
    public var document: String

    public init(_ check: String, _ agreement: String, _ document: String) {
        self.check = check
        self.agreement = agreement
        self.document = document
    }
}

/// The standing of one result in one scene.
public struct ResultStanding: Codable, Hashable, Sendable, Identifiable {
    public var kind: ResultKind
    public var level: EvidenceLevel
    /// One sentence: the strongest evidence that applies, and how close it came.
    public var summary: String
    public var evidence: [StandingEvidence]
    public var assumptions: [String]
    /// What the scene's resolution does to it.
    public var resolution: [String]
    /// The model options set in this scene that change it, as `ModelOption` titles.
    public var options: [String]
    /// Pages under docs/, with anchors.
    public var documents: [String]

    public var id: ResultKind { kind }
}

/// The standing of everything a scene produces, with what its resolution does to it and what
/// it leaves out. Saved with a kept run, so that the run keeps the standing it was made under
/// when the table is later revised.
public struct SceneStanding: Codable, Hashable, Sendable {
    /// Advance when the table's content changes, so that a kept run says which it was judged by.
    public static let currentTable = "standing-table-1"

    public var table = Self.currentTable
    public var results: [ResultStanding]
    /// Scene-wide notes on resolution.
    public var resolution: [String]
    /// Effects this scene could involve that no model here represents.
    public var unsupported: [String]

    public subscript(kind: ResultKind) -> ResultStanding? { results.first { $0.kind == kind } }

    /// The weakest of `kinds` that this scene produces.
    public func weakest(_ kinds: [ResultKind]) -> ResultStanding? {
        results.filter { kinds.contains($0.kind) }.max { $0.level < $1.level }
    }

    /// Where `other`'s standing differs from this one's, in words, for comparing runs.
    public func differences(from other: SceneStanding) -> [String] {
        var lines: [String] = []
        if table != other.table {
            lines.append("Judged by different standing tables (\(table), \(other.table))")
        }
        for kind in ResultKind.allCases {
            switch (self[kind], other[kind]) {
            case (nil, nil): continue
            case (let mine?, nil):
                lines.append("\(kind.title): \(mine.level.title.lowercased()) in one run only")
            case (nil, let theirs?):
                lines.append("\(kind.title): \(theirs.level.title.lowercased()) in one run only")
            case (let mine?, let theirs?):
                if mine.level != theirs.level {
                    lines.append(
                        "\(kind.title): \(mine.level.title.lowercased()) against \(theirs.level.title.lowercased())"
                    )
                } else if mine.summary != theirs.summary || mine.options != theirs.options {
                    lines.append(
                        "\(kind.title): \(mine.level.title.lowercased()) in both runs, on different evidence")
                }
            }
        }
        return lines
    }

    /// Plain text, a line or a few a result, for a terminal.
    public var lines: [String] {
        var text = ["Standing (\(table)):"]
        for result in results {
            text.append("  \(result.kind.title): \(result.level.title). \(result.summary)")
            for note in result.resolution { text.append("    Resolution: \(note)") }
        }
        for note in resolution { text.append("  Resolution: \(note)") }
        for effect in unsupported { text.append("  Not modelled: \(effect)") }
        return text
    }

    /// One line, for metadata: each result's level.
    public var compact: String {
        results.map { "\($0.kind.rawValue)=\($0.level.rawValue)" }.joined(separator: " ")
    }
}

/// What a scene's standing is derived from: its inputs, the air's resolution and solver
/// configuration, and the models run alongside it.
public struct StandingInputs: Sendable {
    public var scenario: Scenario
    /// The coarse air cell, in metres.
    public var cellSize: Float
    public var configuration: SolverConfiguration
    public var thermal: ThermalSpec?
    public var cloud: CloudSpec?
    public var fragments: FragmentSpec?
    public var groundShock: GroundShockSpec?

    public init(
        scenario: Scenario, cellSize: Float, configuration: SolverConfiguration = SolverConfiguration(),
        thermal: ThermalSpec? = nil, cloud: CloudSpec? = nil, fragments: FragmentSpec? = nil,
        groundShock: GroundShockSpec? = nil
    ) {
        self.scenario = scenario
        self.cellSize = cellSize
        self.configuration = configuration
        self.thermal = thermal
        self.cloud = cloud
        self.fragments = fragments
        self.groundShock = groundShock
    }

    /// The model options these inputs set.
    public var options: [ModelOption] { ModelOption.allCases.filter { $0.isSet(by: self) } }
}

// MARK: - Model options

/// A choice of model that changes some result's standing. Each has one entry in
/// `StandingTable.entry(for:)`; `StandingTable.fields` says which input sets it.
public enum ModelOption: String, Codable, CaseIterable, Sendable {
    // The air.
    case afterburning
    case hotAir
    case dissociatingAir
    case radiativeCooling
    case gravity
    case subgridMixing
    case afterburnLimit
    case shockRefinement
    case twoLevelRefinement
    case mappedCharge
    case structureFixedInAir
    case stationaryWalls
    case closedBoundaries
    case terrain
    case deflagration
    case ventPanels
    // The structure.
    case shellElements
    case shellSectionShear
    case latticeCrackAxes
    case fixedCrackAxes
    case noSecondCracks
    case noBareBars
    case removesFragments
    case noCrackSlip
    case slipKeepsCracksClosed
    case bondSlip
    case crackShearStiffness
    case pressedInterlock
    case barRateInElements
    case interfaceBond
    case smearedMasonry
    case inclinedBars
    case baseConnections
    case jointsBetweenParts
    case footings
    case cyclicSand
    case freeBase
    // Materials.
    case rateIndependent
    case designIncreaseFactors
    case alternativeRateLaws
    case nonlocalCrushing
    case studyMultipliers
    case barRuptureInElements
    // Models run alongside.
    case thermalVolume
    case thermalShape
    case thermalSphere
    case surfaceHeating
    case measuredSounding
    case cloudSpread
    case soilColumn
    case freestandingBoxes
    case freestandingCars

    public var title: String { StandingTable.entry(for: self).title }

    /// Whether `inputs` set this option.
    public func isSet(by inputs: StandingInputs) -> Bool {
        let config = inputs.configuration
        let structures = inputs.scenario.structuralObjects.compactMap(\.structure)
        let materials = structures.flatMap { [$0.material] + $0.solidMaterial.compactMap { $0 } }
        let concrete = materials.filter { $0.model == .concrete }
        // Reinforced and plain concrete, whose rate laws the comparisons tested; not masonry or glass.
        let structural = concrete.filter { $0.units == nil && !$0.isTransparent }
        func any(_ test: (StructureModel) -> Bool) -> Bool { structures.contains(where: test) }
        switch self {
        case .afterburning: return config.afterburning
        case .hotAir: return config.airModel == .thermallyPerfect
        case .dissociatingAir: return config.airModel == .dissociating
        case .radiativeCooling: return config.radiativeCooling != nil
        case .gravity: return config.gravity != nil
        case .subgridMixing: return config.mixing != nil
        case .afterburnLimit: return config.afterburning && config.afterburnLimit != nil
        case .shockRefinement: return config.refinement > 1 && config.refinementLevels == 1
        case .twoLevelRefinement: return config.refinement > 1 && config.refinementLevels > 1
        case .mappedCharge: return config.mappedCharge
        case .structureFixedInAir: return !structures.isEmpty && !config.twoWayCoupling
        case .stationaryWalls: return !structures.isEmpty && !config.movingWalls
        case .closedBoundaries: return inputs.scenario.reflectiveFaces != .ground
        case .terrain: return inputs.scenario.terrain.map { !$0.isFlat } ?? false
        case .deflagration: return inputs.scenario.deflagration != nil
        case .ventPanels: return !(inputs.scenario.ventPanels ?? []).isEmpty
        case .shellElements:
            return any { $0.elementKind == .shell || $0.solidElementKind.contains(.shell) }
        case .shellSectionShear: return any { $0.shellSectionShear }
        case .latticeCrackAxes: return !concrete.isEmpty && any { $0.crackAxes == .lattice }
        case .fixedCrackAxes: return !concrete.isEmpty && any { $0.crackAxes == .fixedAtFirstCrack }
        case .noSecondCracks:
            return !concrete.isEmpty && any { $0.crackAxes != .turningUntilOpen && !$0.secondCracks }
        case .noBareBars: return any { !$0.bareBars }
        case .removesFragments: return !concrete.isEmpty && any { $0.removesFragments }
        case .noCrackSlip: return !concrete.isEmpty && any { !$0.crackSlip }
        case .slipKeepsCracksClosed: return !concrete.isEmpty && any { $0.crackSlip && !$0.slipWidensCracks }
        case .bondSlip: return any { $0.bondSlip != nil }
        case .crackShearStiffness: return any { $0.crackShearStiffness }
        case .pressedInterlock: return any { $0.pressedInterlock }
        case .barRateInElements: return any { !$0.barRateAlongBars }
        case .interfaceBond: return any { $0.interfaceBond != nil }
        case .smearedMasonry: return materials.contains { $0.units != nil } && any { !$0.unitJoints }
        case .inclinedBars: return any { !$0.inclinedBars.isEmpty }
        case .baseConnections:
            return any { s in
                (s.fixedBase && s.baseAnchorage.map { $0.footing == nil } == true)
                    || s.supportAnchorages.contains { $0 != nil && $0?.footing == nil }
            }
        case .jointsBetweenParts:
            return any { s in
                s.baseAnchorage?.betweenParts == true
                    || s.supportAnchorages.contains { $0?.betweenParts == true }
            }
        case .footings:
            return any { s in
                (s.fixedBase && s.baseAnchorage?.footing != nil)
                    || s.supportAnchorages.contains { $0?.footing != nil }
            }
        case .cyclicSand:
            return any { s in
                (s.fixedBase && s.baseAnchorage?.footing?.soil.cyclic != nil)
                    || s.supportAnchorages.contains { $0?.footing?.soil.cyclic != nil }
            }
        case .freeBase: return any { !$0.fixedBase }
        case .rateIndependent: return structural.contains { !$0.rateDependent }
        case .designIncreaseFactors:
            return materials.contains { $0.concreteRateFactor != 1 || $0.steelRateFactor != 1 }
        case .alternativeRateLaws:
            return structural.contains {
                $0.rateDependent
                    && ($0.tensionRateLaw != .modelCode2010 || $0.steelRateLaw != .ceb
                        || !$0.steelRateDependent)
            }
        case .nonlocalCrushing: return structural.contains { $0.crushLength > 0 }
        case .studyMultipliers: return structural.contains { $0.dowelFactor != 1 || $0.interlockFactor != 1 }
        case .barRuptureInElements: return structural.contains { $0.steel != nil && !$0.bondSpreading }
        case .thermalVolume: return inputs.thermal?.fireball == .volume
        case .thermalShape: return inputs.thermal?.fireball == .shape
        case .thermalSphere: return inputs.thermal?.fireball == .sphere
        case .surfaceHeating: return inputs.thermal?.heating.enabled == true
        case .measuredSounding: return inputs.cloud?.sounding != nil
        case .cloudSpread: return inputs.cloud?.spread == true
        case .soilColumn: return inputs.groundShock?.model == .column
        case .freestandingBoxes: return !(inputs.scenario.rigidObjects ?? []).isEmpty
        case .freestandingCars: return !(inputs.scenario.rigidCars ?? []).isEmpty
        }
    }
}

// MARK: - The reviewed table

/// The reviewed content: each model option's effect on standing, and which input sets it. Keep
/// it in step with docs/validation.md and the roadmap's limitations table.
public enum StandingTable {
    /// What one model option does to the standing of the results it touches.
    public struct Entry: Sendable {
        public var title: String
        public var affects: [ResultKind]
        /// The strongest level a result can keep with this option set; nil leaves it.
        public var limit: EvidenceLevel?
        public var note: String
        public var document: String
    }

    /// The role of one stored property of an input type.
    public enum Field: Sendable, Equatable {
        /// Sets these model options.
        case option([ModelOption])
        /// A quantity of the scene (geometry, a mass, a position), not a choice of model; the
        /// standing reads what it needs of it directly.
        case input
        /// A numerical control whose effect the verification shows to be nil or which only
        /// sizes buffers and schedules work.
        case numerical
    }

    public static func entry(for option: ModelOption) -> Entry {
        let structure: [ResultKind] = [.structuralResponse, .structuralDamage]
        let air: [ResultKind] = [.peakOverpressure, .impulse]
        switch option {
        case .afterburning:
            return Entry(
                title: "Afterburning", affects: air + [.thermal, .cloud], limit: nil,
                note: "The products burn in the air they mix with; the burning time was fitted to "
                    + "Kingery–Bulmash's incident impulse.",
                document: "air-blast-model.md#afterburning")
        case .hotAir:
            return Entry(
                title: "Hot air", affects: air + [.thermal], limit: nil,
                note: "Air stores energy in molecular vibration, its γ falling towards 1.29 near 3000 K.",
                document: "air-blast-model.md#hot-air")
        case .dissociatingAir:
            return Entry(
                title: "Dissociating air", affects: air + [.thermal], limit: nil,
                note: "Oxygen and nitrogen also dissociate when hot; it changes little and has no "
                    + "comparison of its own.",
                document: "air-blast-model.md#dissociating-air")
        case .radiativeCooling:
            return Entry(
                title: "Gas losing what it radiates", affects: [.thermal, .cloud], limit: nil,
                note: "The luminous gas cools as the fireball's volume radiates; the cloud's comparison with "
                    + "Church's was made without it, and its tops come down a few per cent.",
                document: "thermal-radiation.md#the-gas-losing-what-it-radiates")
        case .gravity:
            return Entry(
                title: "Gravity in the air", affects: air + [.thermal, .cloud], limit: nil,
                note: "The air rests in a hydrostatic atmosphere, still to the bit, its energy kept to 1e-6; "
                    + "a hot bubble rises within 10% of the cloud's integral model and blast loads move by "
                    + "under 0.1%. Dial Pack's fireball rises under it but stays 600 to 900 K too hot.",
                document: "air-blast-model.md#gravity")
        case .subgridMixing:
            return Entry(
                title: "Sub-grid mixing", affects: air + [.thermal, .cloud], limit: nil,
                note: "An eddy viscosity after Smagorinsky, kept out of shocks; mass and energy kept to 1e-6 "
                    + "and blast loads within 0.5%, but on metre cells it changes a mixing layer, a rising "
                    + "thermal and Dial Pack's fireball little: the grid's resolved eddies do the mixing.",
                document: "air-blast-model.md#sub-grid-mixing")
        case .afterburnLimit:
            return Entry(
                title: "Afterburning's extinction limit", affects: air + [.thermal, .cloud], limit: nil,
                note: "Products burn only above 800 K and where they could reach 1,500 K; closed rooms are "
                    + "unchanged but the open incident impulse falls 8 to 9% below Kingery-Bulmash's fit, and "
                    + "Dial Pack's fireball is no cooler.",
                document: "air-blast-model.md#an-extinction-limit-for-afterburning")
        case .shockRefinement:
            return Entry(
                title: "Shock refinement", affects: air + structure + [.envelopeExposure], limit: nil,
                note: "Air refined by 2 near the shock gives about the peaks and impulses of the uniform "
                    + "grid twice as fine.",
                document: "validation.md#with-refinement")
        case .twoLevelRefinement:
            return Entry(
                title: "Two levels of shock refinement", affects: air + structure + [.envelopeExposure],
                limit: nil,
                note: "Two levels by 2 give the peaks and impulses of a grid four times as fine, within 3%.",
                document: "validation.md#with-refinement")
        case .mappedCharge:
            return Entry(
                title: "Finely resolved start", affects: air, limit: nil,
                note: "The charge mapped onto the grid from a fine one-dimensional burst: the same energy as "
                    + "the balloon within 3%.",
                document: "air-blast-model.md#a-finely-resolved-start")
        case .structureFixedInAir:
            return Entry(
                title: "Structure fixed in the air", affects: air + structure, limit: .approximation,
                note: "The air sees the structure as it was at the start, so breaches do not vent; the "
                    + "comparisons coupled both ways.",
                document: "structural-model.md#coupling-to-the-air")
        case .stationaryWalls:
            return Entry(
                title: "Stationary walls", affects: structure, limit: .approximation,
                note: "Moving parts do not push the air as pistons; the comparisons let them.",
                document: "structural-model.md#coupling-to-the-air")
        case .closedBoundaries:
            return Entry(
                title: "Reflecting domain faces", affects: air, limit: nil,
                note: "Faces of the domain other than the ground reflect, as walls of a closed room.",
                document: "validation.md#gas-pressure-in-a-closed-room")
        case .terrain:
            return Entry(
                title: "Terrain",
                affects: air + structure + [
                    .envelopeExposure, .thermal, .freestandingMotion, .fragments, .groundShock,
                ],
                limit: .approximation,
                note:
                    "A staircase of whole cells: it delays Mach reflection off a slope by 3–11° and under-reads "
                    + "the triple point's angle by 20–75% on 100–400 cells along the run; shielding behind "
                    + "ridges is consistency-checked only, and peaks focused far behind a round hill do not "
                    + "converge.",
                document: "terrain.md#limitations")
        case .deflagration:
            return Entry(
                title: "Gas deflagration", affects: air + structure + [.envelopeExposure],
                limit: .illustrative,
                note: "A methane or propane cloud's flame: checked against the thin-flame model in a closed "
                    + "vessel, but its acceleration by turbulence and instabilities is an uncalibrated factor, and "
                    + "vented rooms' pressures come out far below the venting correlations and FM Global's tests.",
                document: "deflagration.md#limitations")
        case .ventPanels:
            return Entry(
                title: "Vent panels", affects: air + structure + [.envelopeExposure], limit: .approximation,
                note: "Massless, instantaneous; verified only to open at the release pressure.",
                document: "deflagration.md#vent-panels")
        case .shellElements:
            return Entry(
                title: "Shell elements", affects: structure, limit: nil,
                note: "On the slab test shells peaked at 135 mm, 125% of that measured, against 105–115% "
                    + "for solid elements.",
                document: "validation.md#structural-response-against-a-real-test")
        case .shellSectionShear:
            return Entry(
                title: "Shells' section shear check", affects: structure, limit: .approximation,
                note: "Off by default: under a blast the slab test's shells carried shears near their "
                    + "supports that this static method says they cannot.",
                document: "shell-model.md")
        case .latticeCrackAxes:
            return Entry(
                title: "Cracks on the lattice planes", affects: structure, limit: .approximation,
                note: "This crack model mishandled inclined cracks; the comparisons used cracks that turn "
                    + "until they open.",
                document: "concrete-model.md#cracking")
        case .fixedCrackAxes:
            return Entry(
                title: "Cracks fixed at first cracking", affects: structure, limit: .approximation,
                note: "Stress locks across a crack whose principal directions turn; the comparisons used "
                    + "cracks that turn until they open.",
                document: "concrete-model.md#cracking")
        case .noSecondCracks:
            return Entry(
                title: "No second cracks", affects: structure, limit: .approximation,
                note: "Tension turned away from a fixed crack is carried across it by shear; without the "
                    + "second crack a cantilever wall stayed hinged over at 608 mm.",
                document: "validation.md#consistency-across-air-grids")
        case .noBareBars:
            return Entry(
                title: "Concrete removed with its bars", affects: [.structuralDamage], limit: .approximation,
                note: "A holed member takes its smeared bars with it rather than hanging on them.",
                document: "concrete-model.md#removal")
        case .removesFragments:
            return Entry(
                title: "Fragments removed", affects: [.structuralDamage], limit: .approximation,
                note: "Concrete cracked open two ways is removed; under close-in and contact charges it "
                    + "holed Hupfauf's and Wu's slabs near size but also slabs that held, not "
                    + "Chiquito's, and damaged struck beams.",
                document: "validation.md#holes-under-close-in-and-contact-charges")
        case .noCrackSlip:
            return Entry(
                title: "Cracks spring back after sliding", affects: structure, limit: .approximation,
                note: "Shear beyond interlock and dowels springs back instead of sliding for good; the "
                    + "comparisons let cracks slide.",
                document: "concrete-model.md#shear-across-cracks")
        case .slipKeepsCracksClosed:
            return Entry(
                title: "Slip does not widen cracks", affects: structure, limit: .approximation,
                note: "A crack's slide no longer opens it or the plane across it; not compared with a test.",
                document: "concrete-model.md#shear-across-cracks")
        case .bondSlip:
            return Entry(
                title: "Bars that slip", affects: structure, limit: nil,
                note: "The Model Code's bond-slip law; run against the slab, shear-beam and impact tests "
                    + "too (on the slab, 95 mm on 8 elements through).",
                document: "concrete-model.md#bars-that-slip-an-option")
        case .crackShearStiffness:
            return Entry(
                title: "Crack shear stiffness falling with width", affects: structure, limit: .approximation,
                note: "Walraven and Reinhardt's measurements on plain concrete; not compared with a "
                    + "structural test here.",
                document: "concrete-model.md#shear-across-cracks")
        case .pressedInterlock:
            return Entry(
                title: "Pressed interlock", affects: structure, limit: .approximation,
                note: "Brings the chamber's roof edge to 25 mm against 95 mm measured, but breaks beams "
                    + "under impact that the tests saw survive.",
                document: "concrete-model.md#shear-across-cracks")
        case .barRateInElements:
            return Entry(
                title: "Bar strain rate in elements", affects: structure, limit: .approximation,
                note: "A bar's strain rate is taken from the element it runs through, which grows as the "
                    + "mesh is refined where a crack localises.",
                document: "concrete-model.md#strain-rate-effects")
        case .interfaceBond:
            return Entry(
                title: "Bonded material joints", affects: structure, limit: nil,
                note: "Concrete and masonry pulled apart separate at the bond within 5% (verified); no "
                    + "infilled frame has been compared with a test.",
                document: "validation.md#verification-against-theory")
        case .smearedMasonry:
            return Entry(
                title: "Masonry without unit joints", affects: [.structuralDamage], limit: .approximation,
                note: "Masonry is smeared as a weak concrete, without its mortar joints.",
                document: "concrete-model.md#masonry-as-units-and-mortar-joints")
        case .inclinedBars:
            return Entry(
                title: "Inclined bars", affects: structure, limit: nil,
                note: "Bars at 45° were compared only in the chamber, whose joints are the least reliable "
                    + "prediction.",
                document: "validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber")
        case .baseConnections:
            return Entry(
                title: "Base connections", affects: structure, limit: .verified,
                note: "Connections that deform, open, slide and fail are checked against statics and "
                    + "theory, not against a test.",
                document: "structural-model.md#base-connections")
        case .jointsBetweenParts:
            return Entry(
                title: "Joints between parts", affects: structure, limit: .verified,
                note:
                    "Seats tying two moving parts across a gap keep momentum and bear weight as statics says; "
                    + "resting seats dissipate within 4% of three precast seats cycled slowly, never under a blast.",
                document: "structural-model.md#base-connections")
        case .footings:
            return Entry(
                title: "Footings on soil", affects: structure, limit: nil,
                note:
                    "One footing rocked slowly on dry sand: moment within 11% to 14 mrad and 5–16% low beyond. "
                    + "With the sand that settles under cycles (the default), settlement 1.7–2.2 times that "
                    + "measured, and 0.6–1.5 times in eight shaken events; a tenth on the elastic bed.",
                document: "validation.md#a-footing-rocked-on-dry-sand")
        case .cyclicSand:
            return Entry(
                title: "Sand that settles under cycles", affects: structure, limit: nil,
                note:
                    "Settlement under rocking 0.6–1.5 times that of eight shaken centrifuge events (FoRDy) and "
                    + "1.7–2.2 times a slowly rocked one's (FoRCy), against a tenth on the elastic bed; a sixth to "
                    + "a half of the energy the shaken footings dissipated.",
                document: "validation.md#a-footing-shaken-on-dry-sand")
        case .freeBase:
            return Entry(
                title: "Base resting on the ground", affects: structure, limit: .verified,
                note: "Nodes on the ground are held up, not held down (verified); no test.",
                document: "validation.md#verification-against-theory")
        case .rateIndependent:
            return Entry(
                title: "Rate-independent concrete", affects: structure, limit: .approximation,
                note: "Strength does not rise with strain rate; the blast and impact comparisons used "
                    + "rate-dependent concrete.",
                document: "concrete-model.md#strain-rate-effects")
        case .designIncreaseFactors:
            return Entry(
                title: "Design dynamic increase factors", affects: structure, limit: .approximation,
                note: "Fixed multipliers on strength, as in UFC 3-340-02, rather than the strain-rate laws "
                    + "the comparisons used.",
                document: "concrete-model.md#strain-rate-effects")
        case .alternativeRateLaws:
            return Entry(
                title: "Other strain-rate laws", affects: structure, limit: .approximation,
                note: "The impacts are decided by the strain-rate laws, and were compared with the Model "
                    + "Code's in tension and CEB's for bars.",
                document: "concrete-model.md#strain-rate-effects")
        case .nonlocalCrushing:
            return Entry(
                title: "Nonlocal crushing", affects: structure, limit: .approximation,
                note: "Tried for a collapsing fine mesh whose cause lay elsewhere; not compared since.",
                document: "roadmap.md#things-tried-and-set-aside")
        case .studyMultipliers:
            return Entry(
                title: "Interlock or dowel multipliers", affects: structure, limit: .approximation,
                note: "Multipliers for studying how much interlock and dowel action matter.",
                document: "validation.md#sensitivity")
        case .barRuptureInElements:
            return Entry(
                title: "Bar rupture in one element", affects: [.structuralDamage], limit: .approximation,
                note: "A bar's rupture is judged in the element a crack runs through, which depends on "
                    + "the mesh.",
                document: "concrete-model.md#reinforcement")
        case .thermalVolume:
            return Entry(
                title: "Fireball as a volume", affects: [.thermal], limit: nil,
                note: "The luminous cells as a partly transparent gas, its absorption an assumption.",
                document: "thermal-radiation.md#the-volume-against-the-shape")
        case .thermalShape:
            return Entry(
                title: "Fireball as an opaque shape", affects: [.thermal], limit: nil,
                note: "An opaque flame of the gas's shape, at a chosen emissivity.",
                document: "thermal-radiation.md#the-model")
        case .thermalSphere:
            return Entry(
                title: "Fireball as a sphere", affects: [.thermal], limit: nil,
                note: "The fireball's equivalent sphere, at a chosen emissivity.",
                document: "thermal-radiation.md#the-model")
        case .surfaceHeating:
            return Entry(
                title: "Surface heating", affects: [.surfaceHeating], limit: .illustrative,
                note: "Each surface heated as an inert solid, one dimension deep; ignition flags are test "
                    + "thresholds, not a fire model.",
                document: "surface-heating.md")
        case .measuredSounding:
            return Entry(
                title: "Measured sounding", affects: [.cloud], limit: nil,
                note: "A measured atmosphere sets the air, its wind and its humidity.",
                document: "fireball-rise.md#a-measured-sounding")
        case .cloudSpread:
            return Entry(
                title: "Spread after stopping", affects: [.cloud], limit: nil,
                note: "Once it stops rising the cloud spreads as a gravity current and a Pasquill–Gifford "
                    + "puff; no measured width of a high-explosive cloud has been found to check it.",
                document: "fireball-rise.md#limitations")
        case .soilColumn:
            return Entry(
                title: "Layered soil column", affects: [.groundShock], limit: .illustrative,
                note: "A layered soil column under each point, solved through the ground's overpressure "
                    + "history; checked against closed-form solutions, not against a measurement.",
                document: "ground-shock.md#the-soil-column")
        case .freestandingBoxes:
            return Entry(
                title: "Freestanding boxes", affects: [.freestandingMotion], limit: .verified,
                note: "Rigid boxes checked against statics, contact mechanics and theory.",
                document: "freestanding-objects.md#checks")
        case .freestandingCars:
            return Entry(
                title: "Simplified cars", affects: [.freestandingMotion], limit: .illustrative,
                note: "An illustrative saloon on locked tyres with rigid suspension.",
                document: "freestanding-objects.md")
        }
    }

    /// Every stored property of the input types the standing reads, keyed "Type.property". A
    /// property missing here fails `EvidentialStandingTests`: a new model option needs a
    /// standing entry before it lands.
    public static let fields: [String: Field] = [
        // Scenario.
        "Scenario.name": .input,
        "Scenario.domainSize": .input,
        "Scenario.objects": .input,
        "Scenario.rigidObjects": .option([.freestandingBoxes]),
        "Scenario.rigidCars": .option([.freestandingCars]),
        "Scenario.importNotes": .input,
        "Scenario.importedModels": .input,
        "Scenario.charge": .input,
        "Scenario.additionalCharges": .input,
        "Scenario.gauges": .input,
        "Scenario.atmosphere": .input,
        "Scenario.reflectiveFaces": .option([.closedBoundaries]),
        "Scenario.terrain": .option([.terrain]),
        "Scenario.deflagration": .option([.deflagration]),
        "Scenario.ventPanels": .option([.ventPanels]),
        "Deflagration.gas": .input,
        "Deflagration.concentration": .input,
        "Deflagration.region": .input,
        "Deflagration.ignition": .input,
        "Deflagration.acceleration": .option([.deflagration]),
        "FlameAcceleration.factor": .option([.deflagration]),
        "FlameAcceleration.wrinklingRadius": .option([.deflagration]),
        "FlameAcceleration.subgridCoefficient": .option([.deflagration]),
        "VentPanel.box": .input,
        "VentPanel.releasePressure": .input,
        "Terrain.origin": .input,
        "Terrain.spacing": .input,
        "Terrain.columns": .input,
        "Terrain.rows": .input,
        "Terrain.heights": .input,
        "Terrain.source": .input,
        "Charge.mass": .input,
        "Charge.position": .input,
        // The air solver.
        "SolverConfiguration.bodyCouplingLayout": .numerical,
        "SolverConfiguration.bodyCouplingTileCapacity": .numerical,
        "SolverConfiguration.gamma": .input,
        "SolverConfiguration.cfl": .numerical,
        "SolverConfiguration.ambientPressure": .input,
        "SolverConfiguration.reflectiveFaces": .option([.closedBoundaries]),
        "SolverConfiguration.riemannSolver": .numerical,
        "SolverConfiguration.limiterTheta": .numerical,
        "SolverConfiguration.densityFloor": .numerical,
        "SolverConfiguration.pressureFloor": .numerical,
        "SolverConfiguration.startupSteps": .numerical,
        "SolverConfiguration.twoWayCoupling": .option([.structureFixedInAir]),
        "SolverConfiguration.movingWalls": .option([.stationaryWalls]),
        "SolverConfiguration.skipStillAir": .numerical,
        "SolverConfiguration.airModel": .option([.hotAir, .dissociatingAir]),
        "SolverConfiguration.afterburning": .option([.afterburning]),
        "SolverConfiguration.afterburnEnergy": .input,
        "SolverConfiguration.afterburnTime": .option([.afterburning]),
        "SolverConfiguration.mappedCharge": .option([.mappedCharge]),
        "SolverConfiguration.airSleepThreshold": .numerical,
        "SolverConfiguration.airSleepCrossings": .numerical,
        "SolverConfiguration.minimumBalloonCells": .numerical,
        "SolverConfiguration.refinement": .option([.shockRefinement, .twoLevelRefinement]),
        "SolverConfiguration.refinementThreshold": .numerical,
        "SolverConfiguration.refinementLevels": .option([.twoLevelRefinement]),
        "SolverConfiguration.refinementFinerThreshold": .numerical,
        "SolverConfiguration.refinementMemory": .numerical,
        "SolverConfiguration.radiativeCooling": .option([.radiativeCooling]),
        "SolverConfiguration.gravity": .option([.gravity]),
        "SolverConfiguration.mixing": .option([.subgridMixing]),
        "SolverConfiguration.periodicSides": .numerical,
        "SolverConfiguration.afterburnLimit": .option([.afterburnLimit]),
        // The structure.
        "StructureModel.solids": .input,
        "StructureModel.openings": .input,
        "StructureModel.material": .input,
        "StructureModel.elementSize": .input,
        "StructureModel.fixedBase": .option([.freeBase]),
        "StructureModel.baseAnchorage": .option([.baseConnections, .footings]),
        "StructureModel.reinforcement": .input,
        "StructureModel.inclinedBars": .option([.inclinedBars]),
        "StructureModel.solidReinforcement": .input,
        "StructureModel.solidMaterial": .input,
        "StructureModel.solidSourceParts": .input,
        "StructureModel.elementKind": .option([.shellElements]),
        "StructureModel.solidElementKind": .option([.shellElements]),
        "StructureModel.shellElementSize": .input,
        "StructureModel.shellLayers": .input,
        "StructureModel.supports": .input,
        "StructureModel.supportAnchorages": .option([.baseConnections, .footings]),
        "StructureModel.interfaceBond": .option([.interfaceBond]),
        "StructureModel.unitJoints": .option([.smearedMasonry]),
        "StructureModel.shellSectionShear": .option([.shellSectionShear]),
        "StructureModel.crackAxes": .option([.latticeCrackAxes, .fixedCrackAxes]),
        "StructureModel.secondCracks": .option([.noSecondCracks]),
        "StructureModel.bareBars": .option([.noBareBars]),
        "StructureModel.removesFragments": .option([.removesFragments]),
        "StructureModel.crackSlip": .option([.noCrackSlip]),
        "StructureModel.slipWidensCracks": .option([.slipKeepsCracksClosed]),
        "StructureModel.bondSlip": .option([.bondSlip]),
        "StructureModel.crackShearStiffness": .option([.crackShearStiffness]),
        "StructureModel.pressedInterlock": .option([.pressedInterlock]),
        "StructureModel.barRateAlongBars": .option([.barRateInElements]),
        // Materials: properties are inputs; the switches between laws are options.
        "StructureMaterial.name": .input,
        "StructureMaterial.model": .input,
        "StructureMaterial.density": .input,
        "StructureMaterial.youngsModulus": .input,
        "StructureMaterial.poissonRatio": .input,
        "StructureMaterial.yieldStress": .input,
        "StructureMaterial.hardeningModulus": .input,
        "StructureMaterial.failureStrain": .input,
        "StructureMaterial.compressiveStrength": .input,
        "StructureMaterial.tensileStrength": .input,
        "StructureMaterial.fractureEnergy": .input,
        "StructureMaterial.crushingEnergy": .input,
        "StructureMaterial.erosionOpening": .input,
        "StructureMaterial.steel": .input,
        "StructureMaterial.crackSpacing": .input,
        "StructureMaterial.crushBand": .input,
        "StructureMaterial.crushLength": .option([.nonlocalCrushing]),
        "StructureMaterial.bondSpreading": .option([.barRuptureInElements]),
        "StructureMaterial.confinementCoefficient": .input,
        "StructureMaterial.aggregateSize": .input,
        "StructureMaterial.crackResidual": .input,
        "StructureMaterial.dowelFactor": .option([.studyMultipliers]),
        "StructureMaterial.interlockFactor": .option([.studyMultipliers]),
        "StructureMaterial.fractureRateExponent": .input,
        "StructureMaterial.tensionRateLaw": .option([.alternativeRateLaws]),
        "StructureMaterial.crackDilatancy": .input,
        "StructureMaterial.concreteRateFactor": .option([.designIncreaseFactors]),
        "StructureMaterial.steelRateFactor": .option([.designIncreaseFactors]),
        "StructureMaterial.rateDependent": .option([.rateIndependent]),
        "StructureMaterial.steelRateDependent": .option([.alternativeRateLaws]),
        "StructureMaterial.steelRateLaw": .option([.alternativeRateLaws]),
        "StructureMaterial.units": .option([.smearedMasonry]),
        "StructureMaterial.isTransparent": .input,
        // Connections.
        "Anchorage.normalStiffness": .input,
        "Anchorage.shearStiffness": .input,
        "Anchorage.tensileStrength": .input,
        "Anchorage.tensionPlateau": .input,
        "Anchorage.tensionOpening": .input,
        "Anchorage.cohesion": .input,
        "Anchorage.cohesionSlip": .input,
        "Anchorage.friction": .input,
        "Anchorage.bearingCapacity": .input,
        "Anchorage.footing": .option([.footings, .cyclicSand]),
        "Anchorage.side": .input,
        "Anchorage.jointNormal": .input,
        "Anchorage.betweenParts": .option([.jointsBetweenParts]),
        // Models run alongside.
        "ThermalSpec.luminousTemperature": .input,
        "ThermalSpec.emissivity": .input,
        "ThermalSpec.surfaceSpacing": .input,
        "ThermalSpec.groundSpacing": .input,
        "ThermalSpec.samples": .numerical,
        "ThermalSpec.fireball": .option([.thermalVolume, .thermalShape, .thermalSphere]),
        "ThermalSpec.absorption": .input,
        "ThermalSpec.sootYield": .input,
        "ThermalSpec.marchStep": .numerical,
        "ThermalSpec.heating": .option([.surfaceHeating]),
        "SurfaceHeatingSpec.enabled": .option([.surfaceHeating]),
        "SurfaceHeatingSpec.ambient": .input,
        "SurfaceHeatingSpec.convection": .input,
        "SurfaceHeatingSpec.ground": .input,
        "SurfaceHeatingSpec.blocks": .input,
        "SurfaceHeatingSpec.structure": .input,
        "SurfaceHeatingSpec.overrides": .input,
        "SurfaceHeatingSpec.materials": .input,
        "SurfaceHeatingSpec.cells": .numerical,
        "SurfaceHeatingSpec.resolvedTime": .numerical,
        "SurfaceHeatingSpec.horizon": .numerical,
        "SurfaceHeatingSpec.maximumStep": .numerical,
        "CloudSpec.handOverTemperature": .input,
        "CloudSpec.entrainment": .input,
        "CloudSpec.addedMass": .input,
        "CloudSpec.emissivity": .input,
        "CloudSpec.lapseRate": .input,
        "CloudSpec.tropopause": .input,
        "CloudSpec.specificHeat": .input,
        "CloudSpec.windSpeed": .input,
        "CloudSpec.windDirection": .input,
        "CloudSpec.windHeight": .input,
        "CloudSpec.windExponent": .input,
        "CloudSpec.windCeiling": .input,
        "CloudSpec.relativeHumidity": .input,
        "CloudSpec.productWater": .input,
        "CloudSpec.rainRate": .input,
        "CloudSpec.rainThreshold": .input,
        "CloudSpec.frictionVelocity": .input,
        "CloudSpec.convectiveVelocity": .input,
        "CloudSpec.boundaryLayerHeight": .input,
        "CloudSpec.turbulentEntrainment": .input,
        "CloudSpec.sounding": .option([.measuredSounding]),
        "CloudSpec.northDirection": .input,
        "CloudSpec.spread": .option([.cloudSpread]),
        "CloudSpec.frontFroude": .input,
        "CloudSpec.stabilityClass": .input,
        "CloudSpec.leastTransportSpeed": .input,
        "CloudSpec.duration": .input,
        "CloudSpec.frameInterval": .numerical,
        "FragmentSpec.casingMass": .input,
        "FragmentSpec.count": .input,
        "FragmentSpec.casing": .input,
        "FragmentSpec.axis": .input,
        "FragmentSpec.spread": .input,
        "FragmentSpec.gurneyVelocity": .input,
        "FragmentSpec.fragmentDensity": .input,
        "FragmentSpec.tracers": .input,
        "FragmentSpec.tracerRegion": .input,
        "FragmentSpec.seed": .numerical,
        "GroundShockSpec.soil": .input,
        "GroundShockSpec.points": .input,
        "GroundShockSpec.line": .input,
        "GroundShockSpec.depths": .input,
        "GroundShockSpec.arrivalThreshold": .input,
        "GroundShockSpec.model": .option([.soilColumn]),
        "GroundShockSpec.profile": .input,
        "GroundSoil.density": .input,
        "GroundSoil.waveSpeed": .input,
    ]

    /// Stored property names of `value`, keyed as `fields` keys them.
    public static func fieldNames(of value: Any) -> [String] {
        let type = String(describing: Swift.type(of: value))
        return Mirror(reflecting: value).children.compactMap { $0.label }.map {
            "\(type).\($0.hasPrefix("_") ? String($0.dropFirst()) : $0)"
        }
    }
}

// MARK: - Deriving a scene's standing

extension SceneStanding {
    /// The standing of each result `inputs` produce, by the table above.
    public init(_ inputs: StandingInputs) {
        let scene = StandingScene(inputs)
        var results = [scene.peakOverpressure(), scene.impulse()]
        if !scene.structures.isEmpty { results += [scene.structuralResponse(), scene.structuralDamage()] }
        if !inputs.scenario.envelopeObjects.isEmpty { results.append(scene.envelopeExposure()) }
        if scene.options.contains(.freestandingBoxes) || scene.options.contains(.freestandingCars) {
            results.append(scene.freestandingMotion())
        }
        if inputs.thermal != nil { results.append(scene.thermal()) }
        if scene.options.contains(.surfaceHeating) { results.append(scene.surfaceHeating()) }
        if inputs.cloud != nil { results.append(scene.cloud()) }
        if inputs.fragments != nil { results.append(scene.fragments()) }
        if inputs.groundShock != nil { results.append(scene.groundShock()) }
        // Each set option caps the results it touches and is named on them.
        for option in scene.options {
            let entry = StandingTable.entry(for: option)
            for index in results.indices where entry.affects.contains(results[index].kind) {
                if let limit = entry.limit, results[index].level < limit {
                    results[index].level = limit
                    results[index].summary +=
                        " \(entry.title) makes it \(limit.title.lowercased()): "
                        + entry.note.prefix(1).lowercased() + entry.note.dropFirst()
                }
                results[index].options.append(entry.title)
                results[index].assumptions.append("\(entry.title): \(entry.note)")
                if !results[index].documents.contains(entry.document) {
                    results[index].documents.append(entry.document)
                }
            }
        }
        self.init(results: results, resolution: scene.resolutionNotes(), unsupported: scene.unsupported())
    }
}

/// The scene's numbers the table needs, worked out once.
private struct StandingScene {
    let inputs: StandingInputs
    let options: [ModelOption]
    let structures: [StructureModel]
    /// The cube root of the primary charge's TNT mass, which scales distances and cells.
    let cubeRoot: Float
    /// The finest air cell near the shock, in metres.
    let fineCell: Float
    /// `fineCell` scaled by `cubeRoot`, in m/kg^(1/3).
    let scaledCell: Float
    /// Scaled distances of the gauges from the nearest charge, nearest first.
    let gaugeDistances: [Float]
    /// Scaled distance from the nearest charge to the nearest structure, envelope or block face.
    let structureDistance: Float?

    init(_ inputs: StandingInputs) {
        self.inputs = inputs
        options = inputs.options
        let scenario = inputs.scenario
        structures = scenario.structuralObjects.compactMap(\.structure)
        cubeRoot = cbrt(max(scenario.charge.mass, 1e-6))
        let config = inputs.configuration
        let refined =
            config.refinement > 1 ? pow(Float(config.refinement), Float(max(config.refinementLevels, 1))) : 1
        fineCell = inputs.cellSize / refined
        scaledCell = fineCell / cubeRoot
        let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
        func scaled(_ point: SIMD3<Float>) -> Float {
            charges.map { simd_distance($0.position, point) / cbrt(max($0.mass, 1e-6)) }.min()!
        }
        gaugeDistances = scenario.gauges.map { scaled($0.position) }.sorted()
        let boxes =
            structures.flatMap(\.solids) + scenario.envelopeObjects.compactMap(\.envelope).flatMap(\.solids)
        structureDistance =
            boxes.isEmpty
            ? nil
            : charges.flatMap { charge in
                boxes.map { box in
                    simd_distance(charge.position, simd_clamp(charge.position, box.min, box.max))
                        / cbrt(max(charge.mass, 1e-6))
                }
            }.min()
    }

    private func has(_ option: ModelOption) -> Bool { options.contains(option) }

    // MARK: Resolution

    /// The open-air comparison's grids, 0.5, 0.25 and 0.125 m on 100 kg, scaled.
    enum AirGrid: Int {
        case fine, medium, coarse, coarser

        /// Reached by a scaled cell, with 5% to spare.
        init(scaledCell s: Float) {
            let cube = cbrt(Float(100))
            self =
                s <= 0.125 / cube * 1.05
                ? .fine : s <= 0.25 / cube * 1.05 ? .medium : s <= 0.5 / cube * 1.05 ? .coarse : .coarser
        }

        var cells: String {
            switch self {
            case .fine: "0.125 m cells"
            case .medium: "0.25 m cells"
            case .coarse: "0.5 m cells"
            case .coarser: "cells coarser than any compared"
            }
        }
    }

    var grid: AirGrid { AirGrid(scaledCell: scaledCell) }

    /// The close-in comparison's cells, on 1 kg: 40, 20, 10 and 5 mm.
    var closeInCells: Float? { ([0.005, 0.01, 0.02, 0.04] as [Float]).first { scaledCell <= $0 * 1.1 } }

    var closeIn: Bool {
        (gaugeDistances.first.map { $0 < 0.75 } ?? false) || (structureDistance.map { $0 < 0.75 } ?? false)
    }

    private func millimetres(_ metres: Float) -> String { String(format: "%.0f mm", metres * 1000) }

    private var cellDescription: String {
        let refined = fineCell < inputs.cellSize ? " near the shock" : ""
        return String(format: "%@%@ (%.3f m/kg^(1/3) for %@ kg)", metres(fineCell), refined, scaledCell, mass)
    }

    private func metres(_ value: Float) -> String {
        value < 0.1 ? millimetres(value) : String(format: "%.3g m", value)
    }

    private var mass: String { String(format: "%.3g", inputs.scenario.charge.mass) }

    private var gaugeRange: String? {
        guard let near = gaugeDistances.first, let far = gaugeDistances.last else { return nil }
        return near == far
            ? String(format: "%.2f m/kg^(1/3)", near) : String(format: "%.2f to %.2f m/kg^(1/3)", near, far)
    }

    func resolutionNotes() -> [String] {
        var notes: [String] = []
        if closeIn, scaledCell > 0.011 {
            notes.append(
                "Close-in loading needs fine or twice-refined air: cells of about 0.01 W^(1/3) ("
                    + millimetres(0.01 * cubeRoot) + " here), or twice that refined by 2; this scene has "
                    + cellDescription + ".")
        }
        if closeIn, structures.contains(where: { $0.material.model == .concrete }) {
            let through = elementsThrough.map { " and \($0) through its thinnest member" } ?? ""
            notes.append(
                "Spall under a close-in charge needs cells of 0.005 W^(1/3) (" + millimetres(0.005 * cubeRoot)
                    + ") and 12 solid elements through a slab; this scene has " + metres(fineCell) + through
                    + ".")
        }
        if grid == .coarser {
            notes.append(
                "The air's cells, " + cellDescription
                    + ", are coarser than any grid compared with Kingery–Bulmash (0.108 m/kg^(1/3)).")
        }
        if let far = gaugeDistances.last, far > 6 {
            notes.append(
                String(
                    format: "Gauges as far as %.1f m/kg^(1/3) lie beyond the open-air comparison, which "
                        + "stopped at 6; the large-scene comparison, to 40, found the peaks' share the same "
                        + "there on the same scaled cells, but falling to the coarse cells' share where "
                        + "the shock is too weak to be refined.", far))
        }
        let near = nearOpenFace
        if !near.isEmpty {
            notes.append(
                "Gauges within 3 m of an open face (" + near.joined(separator: ", ")
                    + ") hear its small reflection; keep them a few metres inside.")
        }
        return notes
    }

    /// Solid elements through the thinnest solid member, when the structure has one.
    var elementsThrough: Int? {
        let counts = structures.flatMap { structure in
            structure.solids.indices.compactMap { index -> Int? in
                let kind = index < structure.solidElementKind.count ? structure.solidElementKind[index] : nil
                guard (kind ?? structure.elementKind) == .solid else { return nil }
                return max(1, Int((structure.solids[index].size.min() / structure.elementSize).rounded()))
            }
        }
        return counts.min()
    }

    private var nearOpenFace: [String] {
        let scenario = inputs.scenario
        let open = BoundaryFaces.all.subtracting(scenario.reflectiveFaces)
        let size = scenario.domainSize
        return scenario.gauges.filter { gauge in
            let p = gauge.position
            let gaps: [(BoundaryFaces, Float)] = [
                (.xMin, p.x), (.xMax, size.x - p.x), (.yMin, p.y), (.yMax, size.y - p.y),
                (.zMax, size.z - p.z),
            ]
            return gaps.contains { open.contains($0.0) && $0.1 < 3 }
        }.map(\.name)
    }

    // MARK: Results

    private func result(
        _ kind: ResultKind, _ level: EvidenceLevel, _ summary: String, evidence: [StandingEvidence] = [],
        assumptions: [String] = [], resolution: [String] = [], documents: [String]
    ) -> ResultStanding {
        ResultStanding(
            kind: kind, level: level, summary: summary, evidence: evidence, assumptions: assumptions,
            resolution: resolution, options: [], documents: documents)
    }

    private var sourceAssumptions: [String] {
        var lines = [
            "The charge is a sphere of hot compressed gas (a bursting balloon), poor within a few charge "
                + "diameters or cells of it.",
            "Shocks are smeared over two or three cells.",
        ]
        lines.append(
            has(.hotAir) || has(.dissociatingAir)
                ? "The detonation products are treated as hot air."
                : "The detonation products are treated as air, an ideal gas of γ = 1.4.")
        if !(inputs.scenario.additionalCharges ?? []).isEmpty {
            lines.append("Several charges fire together; the comparisons are of one charge.")
        }
        if inputs.scenario.charge.position.z > 0.1 * cubeRoot {
            lines.append(
                "The charge is above the ground: the open-air comparison is of surface bursts, and air "
                    + "bursts were compared only for the reflection beneath them close in.")
        }
        return lines
    }

    /// The terrain's checks, when the scene has one.
    private var terrainEvidence: [StandingEvidence] {
        guard has(.terrain) else { return [] }
        return [
            StandingEvidence(
                "Reflection off a smooth slope against three-shock theory",
                "Triple point within 0.4°; transition between 50 and 51° against 50.6–50.8° for Mach 2 "
                    + "(verified); on the staircase, Mach reflection 3–11° late",
                "terrain.md#a-slope-regular-and-mach-reflection"),
            StandingEvidence(
                "Shielding behind a ridge",
                "Arrival within 1–5% of the taut path over the crest; no measured "
                    + "shielding compared", "terrain.md#shielding-behind-a-ridge"),
            StandingEvidence(
                "A hill on 0.5 to 0.125 m cells",
                "The lee impulse within 6%; peaks focused far behind it not "
                    + "converged", "terrain.md#a-hills-resolution-sensitivity"),
        ]
    }

    /// The deflagration's checks: no charge fires, so the comparisons with Kingery–Bulmash do not
    /// apply.
    private var deflagrationEvidence: [StandingEvidence] {
        [
            StandingEvidence(
                "A closed sphere of stoichiometric methane against the thin-flame model (blastbench "
                    + "deflagration vessel)",
                "Burns out at the AICC pressure the heat was fitted to, energy conserved to 1e-5; rise times "
                    + "within 1–3% on 48 cells across the radius; K_G 51 bar m/s against 76, converging from "
                    + "below (verified)", "deflagration.md#a-closed-sphere"),
            StandingEvidence(
                "A laminar flame lit at a tube's closed end",
                "Runs at the expansion ratio times the burning velocity within 10% (verified)",
                "deflagration.md#a-closed-sphere"),
            StandingEvidence(
                "Vented rooms against EN 14994, NFPA 68 and Molkov (blastbench deflagration vented)",
                "A thirtieth to a fiftieth of Molkov's best fit with the default flame, a fifth to an eighth "
                    + "with the burning velocity tripled",
                "deflagration.md#vented-rooms-against-the-correlations"),
            StandingEvidence(
                "FM Global's 63.7 m³ chamber, Bauwens et al. 2008 (six tests, peaks only plotted)",
                "A tenth (lit in the middle) to a half (at the back wall) of the plots' axes",
                "deflagration.md#bauwens-chaffee-and-dorofeev-2008"),
        ]
    }

    /// Peak overpressure or impulse from a gas cloud's deflagration.
    private func deflagrationResult(_ kind: ResultKind) -> ResultStanding {
        var resolution = ["Air: \(cellDescription); the flame is about four cells thick."]
        if !(inputs.scenario.ventPanels ?? []).isEmpty {
            resolution.append("Vent panels have no mass and release at once.")
        }
        return result(
            kind, .illustrative,
            "A gas deflagration: its flame converges on the thin-flame model in a closed vessel, but its "
                + "acceleration by turbulence and instabilities is an uncalibrated factor, and vented rooms' "
                + "pressures fall far below EN 14994, NFPA 68 and FM Global's tests.",
            evidence: deflagrationEvidence + terrainEvidence,
            assumptions: [
                "Burnt and unburnt gas are treated as air; the heat released is the share of the heat of "
                    + "combustion that reaches the stoichiometric AICC pressure.",
                "The flame's acceleration is a constant factor, wrinkling with radius and a vorticity estimate "
                    + "of sub-grid turbulence; none is calibrated.",
            ], resolution: resolution, documents: ["deflagration.md#checks", "deflagration.md#limitations"])
    }

    func peakOverpressure() -> ResultStanding {
        if has(.deflagration) { return deflagrationResult(.peakOverpressure) }
        let incident = ["0.125": "86–97%", "0.25": "76–82%", "0.5": "57–69%"]
        let reflected = ["0.125": "67–92%", "0.25": "37–82%", "0.5": "20–69%"]
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.measured
        var summary: String
        switch grid {
        case .coarser:
            level = .approximation
            summary =
                "Under-resolved: the cells are coarser than any compared with Kingery–Bulmash, whose "
                + "coarsest grid gave 57–69% of the incident peak."
        default:
            let key = grid == .fine ? "0.125" : grid == .medium ? "0.25" : "0.5"
            summary =
                "Kingery–Bulmash's incident peak \(incident[key]!), reflected \(reflected[key]!), on air as "
                + "fine for this charge as the comparison's \(grid.cells) were for 100 kg; peaks read low as "
                + "shocks are smeared."
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, 100 kg surface burst from 0.75 to 6 m/kg^(1/3) (blastbench validate)",
                    "Incident peak \(incident[key]!) and reflected \(reflected[key]!) on \(grid.cells)",
                    "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        if has(.afterburning) {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash with afterburning (and hot air)",
                    "Incident peak 78–86% (72–84%) on 0.25 m cells", "validation.md#afterburning"))
        }
        var resolution: [String] = []
        if closeIn, let first = gaugeDistances.first, first < 0.75 {
            let closeAir: [Float: String] = [
                0.005: "92–104%", 0.01: "78–98%", 0.02: "45–72%", 0.04: "25–49%",
            ]
            if let cells = closeInCells {
                evidence.append(
                    StandingEvidence(
                        "1 kg burst above rigid ground, 0.3 to 1 m/kg^(1/3) (blastbench closeair)",
                        "Reflected peak \(closeAir[cells]!) on \(millimetres(cells)) cells per kg^(1/3)",
                        "validation.md#close-in"))
            } else {
                level = max(level, .approximation)
                resolution.append(
                    String(
                        format: "A gauge %.2f m/kg^(1/3) from the charge is close in, where 40 mm cells per "
                            + "kg^(1/3), the coarsest compared, gave a quarter to a half of the reflected peak.",
                        first))
            }
        }
        resolution.append(
            "Air: \(cellDescription); the comparison's 0.5, 0.25 and 0.125 m cells for 100 kg were 0.108, 0.054 "
                + "and 0.027 m/kg^(1/3).")
        if let range = gaugeRange { resolution.append("Gauges lie \(range) from the charge.") }
        evidence += terrainEvidence
        return result(
            .peakOverpressure, level, summary, evidence: evidence, assumptions: sourceAssumptions,
            resolution: resolution, documents: ["validation.md#blast-loads-against-empirical-references"])
    }

    func impulse() -> ResultStanding {
        if has(.deflagration) { return deflagrationResult(.impulse) }
        let reflected = ["0.125": "94–105%", "0.25": "84–102%", "0.5": "73–99%"]
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.measured
        var summary: String
        let burns = has(.afterburning)
        let hot = has(.hotAir) || has(.dissociatingAir)
        let incident =
            burns
            ? (hot
                ? "incident impulse 94–99% beyond 1 m/kg^(1/3) (the burning time fitted to it)"
                : "incident impulse 96–101% beyond 1 m/kg^(1/3) (the burning time fitted to it)")
            : "incident impulse 13–22% low on every grid, for want of afterburning"
        switch grid {
        case .coarser:
            level = .approximation
            summary =
                "Cells coarser than any compared; on the coarsest compared Kingery–Bulmash's reflected impulse "
                + "was 73–99%, and its \(incident)."
        default:
            let key = grid == .fine ? "0.125" : grid == .medium ? "0.25" : "0.5"
            summary =
                "Kingery–Bulmash's reflected impulse \(reflected[key]!) on the comparison's \(grid.cells) for 100 kg "
                + "(within 6% beyond 1.5 m/kg^(1/3) on 0.25 m or finer); \(incident)."
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, 100 kg surface burst from 0.75 to 6 m/kg^(1/3) (blastbench validate)",
                    "Reflected impulse \(reflected[key]!) on \(grid.cells)",
                    "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        if burns {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash with afterburning\(hot ? " and hot air" : "") (blastbench validate --afterburn)",
                    hot
                        ? "Incident impulse 94–99% beyond 1 m/kg^(1/3), fitted; reflected 6–13% high in the "
                            + "middle ranges, not fitted"
                        : "Incident impulse 96–101% beyond 1 m/kg^(1/3), fitted; reflected 6–15% high in the "
                            + "middle ranges, not fitted",
                    "validation.md#afterburning"))
        } else {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, incident impulse", "78–87% from 1 m/kg^(1/3) out, on every grid",
                    "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        if has(.closedBoundaries) {
            let room =
                burns && hot
                ? "98–108% of the design curve, nothing fitted"
                : burns
                    ? "124–131% of the design curve"
                    : hot ? "43–91% of the design curve" : "48–114% of the design curve"
            evidence.append(
                StandingEvidence(
                    "Gas pressure in a closed room against UFC 3-340-02 (blastbench gas)", room,
                    "validation.md#gas-pressure-in-a-closed-room"))
        }
        var resolution: [String] = []
        if closeIn {
            let closeAir: [Float: String] = [
                0.005: "94–103%", 0.01: "92–106%", 0.02: "79–94%", 0.04: "65–89%",
            ]
            if let cells = closeInCells {
                evidence.append(
                    StandingEvidence(
                        "1 kg burst above rigid ground, 0.3 to 1 m/kg^(1/3) (blastbench closeair)",
                        "Reflected impulse \(closeAir[cells]!) on \(millimetres(cells)) cells per kg^(1/3)",
                        "validation.md#close-in"))
            } else {
                level = max(level, .approximation)
                resolution.append(
                    "Close in, 40 mm cells per kg^(1/3), the coarsest compared, gave 65–89% of the reflected "
                        + "impulse; these are coarser.")
            }
        }
        evidence += terrainEvidence
        var assumptions = sourceAssumptions
        assumptions.append("Real ground is not rigid: the ground here reflects perfectly.")
        return result(
            .impulse, level, summary, evidence: evidence, assumptions: assumptions, resolution: resolution,
            documents: [
                "validation.md#blast-loads-against-empirical-references", "air-blast-model.md#limitations",
            ])
    }

    /// The kinds of material in the scene's structures, weakest standing last.
    private enum MaterialClass: Int, Comparable {
        case reinforcedConcrete, plainConcrete, steel, masonry, glass
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        init(_ material: StructureMaterial) {
            switch material.model {
            case .vonMises: self = .steel
            case .concrete:
                self =
                    material.isTransparent
                    ? .glass
                    : material.units != nil
                        ? .masonry : material.steel != nil ? .reinforcedConcrete : .plainConcrete
            }
        }
    }

    private var materialClasses: [MaterialClass] {
        Set(structures.flatMap { [$0.material] + $0.solidMaterial.compactMap { $0 } }.map(MaterialClass.init))
            .sorted()
    }

    func structuralResponse() -> ResultStanding {
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.measured
        var parts: [String] = []
        let classes = materialClasses
        if classes.contains(.reinforcedConcrete) {
            evidence += [
                StandingEvidence(
                    "A reinforced slab under a blast",
                    "Peak 113–124 mm against 108 mm measured (105–115%) on 4 to "
                        + "32 solid elements through; shells 135 mm (125%)",
                    "validation.md#structural-response-against-a-real-test"),
                StandingEvidence(
                    "A reinforced beam bent to failure",
                    "Peak moment 97–99%; failure at 38–52 mm against 42 mm",
                    "validation.md#a-reinforced-beam-bent-to-failure"),
                StandingEvidence(
                    "A beam without stirrups failing in shear",
                    "11–15% strong on fine meshes; coarse meshes far "
                        + "too strong", "validation.md#a-beam-failing-in-shear"),
                StandingEvidence(
                    "Beams struck by a falling weight",
                    "With stirrups within 12–24% under light drops and −5% to "
                        + "+3% under heavy ones on 16 elements",
                    "validation.md#beams-struck-by-a-falling-weight"),
                StandingEvidence(
                    "An internal explosion in a reinforced concrete chamber",
                    "Roof about twice as stiff; its edge "
                        + "left 15 mm up against 95 mm",
                    "validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber"),
            ]
            parts.append(
                "reinforced concrete within 5–15% of one slab test and close to beam tests, but too stiff "
                    + "in a full-scale chamber and springing back too far")
        }
        if classes.contains(.plainConcrete) {
            level = max(level, .verified)
            evidence.append(
                StandingEvidence(
                    "Concrete in tension and compression on two meshes",
                    "Peak at f_t within 3%, fracture energy "
                        + "within 5%; f_c within 2%", "validation.md#verification-against-theory"))
            parts.append("plain concrete verified against its own curves, no member compared")
        }
        if classes.contains(.steel) {
            level = max(level, .verified)
            evidence.append(
                StandingEvidence(
                    "Elastic bars and cantilevers",
                    "Wave speed, tip deflection and first period within 5% of "
                        + "theory", "validation.md#verification-against-theory"))
            parts.append("steel verified against beam and wave theory, no test")
        }
        if classes.contains(.masonry) {
            level = max(level, .verified)
            evidence.append(
                StandingEvidence(
                    "Blockwork pulled and sheared along its joints",
                    "Parts at the bond within 5%; slides at "
                        + "cohesion and friction within 10%", "validation.md#verification-against-theory"))
            parts.append("masonry's joints verified, no wall compared under a blast")
        }
        if classes.contains(.glass) {
            level = max(level, .approximation)
            evidence.append(
                StandingEvidence(
                    "A glass pane at 3 m", "Breaks under 1 kg and survives 0.5 g",
                    "validation.md#verification-against-theory"))
            parts.append("glass a brittle concrete, checked only to break and survive")
        }
        var resolution: [String] = []
        if let through = elementsThrough, through < 4, classes.contains(where: { $0 <= .plainConcrete }) {
            resolution.append(
                "\(through) solid element\(through == 1 ? "" : "s") through the thinnest member; the slab test "
                    + "used 4 to 32, and coarse meshes are far too strong in shear.")
        }
        if let distance = structureDistance, distance < 0.75 {
            level = max(level, .approximation)
            evidence.append(
                StandingEvidence(
                    "Full-scale slabs under close-in charges",
                    "Left a third to a half as far down as measured",
                    "validation.md#slabs-under-close-in-charges"))
            resolution.append(
                String(
                    format: "The structure is %.2f m/kg^(1/3) from a charge, close in, where slabs bend too "
                        + "little.", distance))
        }
        if structures.count > 1 {
            resolution.append(
                "Independent bodies have no contact with each other; overlapping ones stop the run.")
        }
        let summary =
            (parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No structure")
            + (parts.count > 1 ? "; " + parts.dropFirst().joined(separator: "; ") : "") + "."
        return result(
            .structuralResponse, level, summary, evidence: evidence,
            assumptions: [
                "Lattice-aligned geometry, a staircase of whole cells to the air.",
                "No structural damping beyond the material's own: ringing lasts too long.",
                "Not validated for engineering decisions or the safety of a real structure.",
            ], resolution: resolution,
            documents: ["validation.md#summary", "roadmap.md#limitations-most-important-first"])
    }

    func structuralDamage() -> ResultStanding {
        var evidence = [
            StandingEvidence(
                "A beam without stirrups failing in shear", "Fails suddenly, as the test did, 11–15% strong",
                "validation.md#a-beam-failing-in-shear"),
            StandingEvidence(
                "Beams struck by a falling weight",
                "The beam without stirrups broken by the heavy drop as in the "
                    + "test, but damaged by a light one it survived",
                "validation.md#beams-struck-by-a-falling-weight"),
        ]
        var level = EvidenceLevel.approximation
        var summary =
            "Indicative: shear failure, breach and joints are the least reliable predictions; debris has been "
            + "compared once, and collapse never."
        if let distance = structureDistance, distance < 0.75 {
            evidence.append(
                StandingEvidence(
                    "Full-scale slabs under close-in charges",
                    "Spalled only under the charge, on fine air and 12 "
                        + "elements through, and never holed", "validation.md#slabs-under-close-in-charges"))
            evidence.append(
                StandingEvidence(
                    "Slabs under contact charges (Hupfauf, 2024)",
                    "The far face thrown 1.2–1.9 times as fast as the debris at first; the loose layer held back "
                        + "rather than thrown, and no slab holed where four were",
                    "validation.md#slabs-under-contact-charges"))
            summary += " Close in, slabs spall too little, hold their debris back and are never holed."
        }
        if materialClasses.contains(.glass) || materialClasses.contains(.masonry) {
            level = .illustrative
            summary += " Masonry and glass breaking up has no comparison."
        }
        return result(
            .structuralDamage, level, summary, evidence: evidence,
            assumptions: [
                "Concrete broken under a close-in charge is never removed, so no hole opens.",
                "Debris is pushed crudely by the air, as cubes with a fixed drag.",
                "Collapse is chaotic: a slightly different input gives a different pattern of debris.",
            ],
            documents: [
                "concrete-model.md#limitations", "structural-model.md#limitations",
                "validation.md#what-is-missing",
            ])
    }

    func envelopeExposure() -> ResultStanding {
        result(
            .envelopeExposure, .approximation,
            "Stationary surfaces whose loads come from the air beside them; a wall facing a charge has Kingery–"
                + "Bulmash's reflected impulse, but no street of buildings has been compared.",
            evidence: [
                StandingEvidence(
                    "Surface integration against per-step pressure on the CPU",
                    "Agrees, with suction; uniform "
                        + "pressure cancels", "building-envelopes.md#scope-and-verification"),
                StandingEvidence(
                    "Kingery–Bulmash, a rigid wall facing the charge",
                    "Reflected impulse within 6% beyond 1.5 "
                        + "m/kg^(1/3) on 0.25 m cells or finer",
                    "validation.md#kingerybulmash-the-design-practice-standard"),
            ],
            assumptions: [
                "Fixed geometry: no broken windows, deformation, collapse or changing shielding.",
                "Openings and walls thinner than a cell can vanish.",
            ], documents: ["building-envelopes.md#scope-and-verification"])
    }

    func freestandingMotion() -> ResultStanding {
        result(
            .freestandingMotion, .verified,
            "Checked against statics, contact mechanics and theory; nothing compared with a blast test.",
            evidence: [
                StandingEvidence(
                    "Still air, flight and contact checks",
                    "No load in still air; contact conserves momentum to 1 "
                        + "part in 10⁹; reruns bit-identical", "freestanding-objects.md#checks")
            ],
            assumptions: [
                "Computed apart from the ordinary run, on air cropped around the objects.",
                "Every object takes the air's load on fine cells around it; objects that touch share whole "
                    + "cells.",
                "The air's load after about 0.4 s, with an object steeply tilted, is not converged.",
                "Furniture is solid boxes.",
            ], documents: ["freestanding-objects.md#limitations-and-future-work"])
    }

    func thermal() -> ResultStanding {
        let cooling = has(.radiativeCooling)
        var assumptions = [
            cooling
                ? "The luminous gas loses what it radiates, on the lattice's 26 directions, into black."
                : "The radiated energy is not taken from the gas, which stays hot and luminous too long.",
            "The air between the fireball and a surface is transparent; nothing scatters.",
            "Shows where surfaces see the fireball, not burns, ignition or damage.",
        ]
        if !has(.afterburning) {
            assumptions.append(
                "Without afterburning the products cool as cold air would: the fireball is a few metres across "
                    + "and gone within 50 ms. Use afterburning for a thermal study.")
        }
        var resolution: [String] = []
        if inputs.cellSize >= 0.5 {
            resolution.append(
                "On 0.5 m cells the charge's gas is spread over large cells and comes out cooler (0.5 kg starts "
                    + "under 800 K).")
        }
        return result(
            .thermal, .illustrative,
            "Set against one measurement of a TNT fireball's radiation, which it exceeds "
                + (cooling ? "two to three times, the gas cooling as it radiates." : "three to five times."),
            evidence: [
                StandingEvidence(
                    "A TNT fireball's measured radiation",
                    cooling
                        ? "Exceeded two to three times, with the gas cooling"
                        : "Exceeded three to five times",
                    "thermal-radiation.md#the-volume-against-the-shape")
            ], assumptions: assumptions, resolution: resolution,
            documents: ["thermal-radiation.md#limitations"])
    }

    func surfaceHeating() -> ResultStanding {
        result(
            .surfaceHeating, .illustrative,
            "Checked against conduction's exact solutions within 0.5%, but fed an illustrative irradiance; "
                + "the ignition flags say a surface passed a test's threshold, not that it ignites.",
            evidence: [
                StandingEvidence(
                    "Constant flux on a semi-infinite solid, and a slab against its series", "Within 0.5%",
                    "surface-heating.md#checks")
            ],
            assumptions: [
                "Inert solids of constant properties: nothing melts, chars, spalls or burns, and no moisture.",
                "Heat flows only along each receiver's normal, and only radiation heats the surfaces.",
                "Ignition thresholds are from nuclear thermal pulses of seconds, applied unscaled.",
            ], documents: ["surface-heating.md#limitations", "surface-heating.md#ignition-illustrative"])
    }

    func cloud() -> ResultStanding {
        var assumptions = [
            "A textbook integral model of a turbulent thermal, with coefficients from laboratory thermals, "
                + "started from whatever the gas model leaves."
        ]
        if !has(.afterburning) {
            assumptions.append("The comparison with Church's clouds was made with afterburning on.")
        }
        return result(
            .cloud, .illustrative,
            "Its top within 4% on average (21% shot by shot) of 22 TNT clouds Church measured, for their first two "
                + "minutes; it falls behind them later.",
            evidence: [
                StandingEvidence(
                    "Church's 22 detonations of 54 to 1,270 kg of TNT",
                    "Cloud top within 4% on average, 21% shot "
                        + "by shot, from half a minute to two minutes",
                    "fireball-rise.md#against-churchs-measured-clouds")
            ], assumptions: assumptions, documents: ["fireball-rise.md#limitations"])
    }

    func fragments() -> ResultStanding {
        result(
            .fragments, .illustrative, "Textbook ingredients; nothing compared with a fragmentation test.",
            assumptions: [
                "Gurney launch speeds and Mott masses; drag from the blast.",
                "One way: fragments do not push back on the air or the structure.",
                "Not for ranges or hazards.",
            ], documents: ["fragments.md#limitations"])
    }

    func groundShock() -> ResultStanding {
        let column = has(.soilColumn)
        return result(
            .groundShock, .illustrative,
            column
                ? "A layered soil column under each point, checked against closed-form solutions; nothing "
                    + "compared with a ground shock measurement."
                : "The design manuals' one-dimensional air-induced ground shock; nothing compared with a "
                    + "measurement.",
            evidence: column
                ? [
                    StandingEvidence(
                        "Uniform, layered and bilinear soil columns against closed-form solutions",
                        "Within 1% for pulses, reflections and resonance; 3–8% for bilinear unloading",
                        "ground-shock.md#checks")
                ] : [],
            assumptions: [
                "Away from the charge only; no direct-induced shock or crater.",
                "The ground stays rigid for the air.",
                "Not for design, buried services or vibration limits.",
            ], documents: ["ground-shock.md#limitations"])
    }

    // MARK: What the scene leaves out

    func unsupported() -> [String] {
        var effects = [
            "Nothing here is validated for engineering decisions or for judging the safety of a real structure.",
            "The ground is rigid and reflecting: no crater, displaced soil or ground coupling to the air.",
        ]
        if !structures.isEmpty {
            effects.append(
                "Collapse has never been compared with anything, and debris only once, off slabs under contact "
                    + "charges.")
            if structures.count > 1 { effects.append("Contact between independent structures.") }
        }
        if inputs.thermal == nil {
            effects.append("Radiant heat from the fireball (not reckoned in this scene).")
        }
        effects.append(
            has(.surfaceHeating)
                ? "Fire: ignition is flagged against test thresholds, but nothing burns or spreads."
                : "Ignition, material heating and fire.")
        if inputs.fragments == nil { effects.append("Casing fragments: the charge is bare.") }
        if has(.deflagration) {
            effects.append(
                "Flame acceleration is modelled but uncalibrated; there is no transition to detonation.")
        }
        if has(.terrain) {
            effects.append(
                "Over the terrain, footings and the ground's connection stay level and hold the base at z = 0 "
                    + "(a stepped base takes a support region a level); a ground point's soil column is level "
                    + "ground's, along the surface's normal; the fireball's radiated power is measured over the "
                    + "floor.")
        }
        if !(inputs.scenario.rigidObjects ?? []).isEmpty || !(inputs.scenario.rigidCars ?? []).isEmpty {
            effects.append("Freestanding objects in the ordinary run: they move only in Compute Motion.")
        }
        return effects
    }
}
