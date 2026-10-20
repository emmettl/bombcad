import Foundation
import simd

// The evidential standing of each result a scene produces: whether it rests on agreement with
// measurements, on agreement with theory, on stated assumptions, or on nothing but plausibility.
// The content is one reviewed table (`StandingTable`) that mirrors docs/validation.md and the
// roadmap's limitations table; `SceneStanding.init(_:)` picks from it by the scene's settings.
// See docs/standing.md.

/// How far a result has been established, strongest first.
public enum EvidenceLevel: String, Codable, CaseIterable, Sendable, Comparable {
    /// Compared with measurements, and the comparison says how close it came (not that it
    /// agrees: its bands say how far and which way).
    case compared
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
        case .compared: "Compared with measurement"
        case .verified: "Verified against theory"
        case .approximation: "Approximation"
        case .illustrative: "Illustrative"
        }
    }

    /// One word for a badge.
    public var badge: String {
        switch self {
        case .compared: "Compared"
        case .verified: "Verified"
        case .approximation: "Approximate"
        case .illustrative: "Illustrative"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }

    /// Reads "measured", the level's name in standings recorded before 11 October 2026.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let level = Self(rawValue: raw == "measured" ? "compared" : raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown evidence level \(raw)"))
        }
        self = level
    }

    /// Stronger evidence sorts first.
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// The results a scene can produce, each with a standing of its own.
public enum ResultKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case peakOverpressure
    case impulse
    case structuralResponse
    case structuralDamage
    /// Parts of a structure losing their support and falling: a storey lost, a structure down,
    /// collapse spreading. Apart from `structuralDamage`, the members' and elements' own damage,
    /// so that it never takes that band.
    case collapse
    case envelopeExposure
    case envelopeDamage
    case freestandingMotion
    case thermal
    case surfaceHeating
    case cloud
    case fragments
    case groundShock
    case blastInjury
    case crater

    public var id: Self { self }

    public var title: String {
        switch self {
        case .peakOverpressure: "Peak overpressure"
        case .impulse: "Impulse"
        case .structuralResponse: "Structural deflection"
        case .structuralDamage: "Structural damage and failure"
        case .collapse: "Collapse: storeys lost, structures down"
        case .envelopeExposure: "Building surface exposure"
        case .envelopeDamage: "Envelope building damage"
        case .freestandingMotion: "Freestanding objects' motion"
        case .thermal: "Thermal radiation"
        case .surfaceHeating: "Surface heating and ignition"
        case .cloud: "Rise and cloud"
        case .fragments: "Fragments"
        case .groundShock: "Ground shock"
        case .blastInjury: "Blast injury and safety distances"
        case .crater: "Crater"
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
    /// How far it has been from measurement, where the scene lies within a comparison's range
    /// (see `ErrorBand`); nil in standings recorded before bands were.
    public var bands: [ErrorBand]? = nil
    /// Why no band applies, where none does.
    public var unbanded: [String]? = nil
    /// Whether the chosen options suit the scene's regime.
    public var regimes: [RegimeAdvice]? = nil

    public var id: ResultKind { kind }
}

/// The standing of everything a scene produces, with what its resolution does to it and what
/// it leaves out. Saved with a kept run, so that the run keeps the standing it was made under
/// when the table is later revised.
public struct SceneStanding: Codable, Hashable, Sendable {
    /// The table's identity, derived from its content (`StandingFingerprint`), so that a kept run
    /// says which it was judged by. Before 18 October 2026 it was numbered by hand,
    /// "standing-table-1" to "standing-table-36", and kept runs still carry those.
    public static var currentTable: String { StandingFingerprint.current }

    /// The table's identity as shown: "standing table 36" for a numbered one, else
    /// "standing a1b2c3d4".
    public var tableTitle: String {
        table.hasPrefix("standing-table-")
            ? "standing table " + table.dropFirst("standing-table-".count)
            : "standing " + table.dropFirst("standing-".count)
    }

    public var table = Self.currentTable
    public var results: [ResultStanding]
    /// Scene-wide notes on resolution.
    public var resolution: [String]
    /// Effects this scene could involve that no model here represents.
    public var unsupported: [String]
    /// Each gauge's bands; nil in standings recorded before bands were.
    public var gauges: [GaugeBands]? = nil

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
            if let direction = result.direction { text.append("    \(direction)") }
            for band in result.bands ?? [] {
                text.append("    Band: \(band.summary), for \(band.validity)")
                if let mesh = band.derivedMesh {
                    text.append("      Derived on \(mesh); it holds only there.")
                }
                if let verdict = band.againstReference { text.append("      \(verdict)") }
            }
            for note in result.unbanded ?? [] { text.append("    No band: \(note)") }
            for advice in result.regimes ?? [] {
                let verdict = advice.suits.map { $0 ? "suits it" : "does not suit it" } ?? "note"
                text.append(
                    "    Regime (\(advice.regime)): \(advice.option), \(verdict). \(advice.note)"
                        + (advice.suggestion.map { " \($0)" } ?? ""))
            }
            for note in result.resolution { text.append("    Resolution: \(note)") }
        }
        for gauge in gauges ?? [] {
            let bands = [gauge.peak, gauge.impulse].compactMap {
                $0.map { "\($0.quantity.lowercased()) \($0.ratio)" }
            }
            text.append(
                String(format: "  Gauge %@ at %.2f m/kg^(1/3): ", gauge.name, gauge.scaledDistance)
                    + (bands.isEmpty ? "no band. \(gauge.note ?? "")" : bands.joined(separator: ", ")))
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
public struct StandingInputs: Sendable, Equatable {
    public var scenario: Scenario
    /// The coarse air cell, in metres.
    public var cellSize: Float
    public var configuration: SolverConfiguration
    public var thermal: ThermalSpec?
    public var cloud: CloudSpec?
    public var fragments: FragmentSpec?
    public var groundShock: GroundShockSpec?
    /// Envelopes' glazing breaks in the air (`BlastSolver.configureEnvelopeVenting`).
    public var ventsGlazing: Bool

    public init(
        scenario: Scenario, cellSize: Float, configuration: SolverConfiguration = SolverConfiguration(),
        thermal: ThermalSpec? = nil, cloud: CloudSpec? = nil, fragments: FragmentSpec? = nil,
        groundShock: GroundShockSpec? = nil, ventsGlazing: Bool = false
    ) {
        self.scenario = scenario
        self.cellSize = cellSize
        self.configuration = configuration
        self.thermal = thermal
        self.cloud = cloud
        self.fragments = fragments
        self.groundShock = groundShock
        self.ventsGlazing = ventsGlazing
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
    case mixedAfterburning
    case shockRefinement
    case twoLevelRefinement
    case adaptiveSubsteps
    case mappedCharge
    case structureFixedInAir
    /// Structures' outlines as cut cells (`SolverConfiguration.structureCutCells`).
    case structureCutCells
    case stationaryWalls
    case closedBoundaries
    case copiedOpenFaces
    case terrain
    case terrainStaircase
    case deflagration
    case ventPanels
    case congestion
    case importedEnvelopes
    case mapBuildings
    case ventedGlazing
    /// Glass judged new or tested, stronger than E1300's weathered glass (`GlassCondition`).
    case newGlass
    /// Unreinforced masonry walls arch between their returns (`EnvelopeConstruction.masonryArching`).
    case masonryArching
    /// Gauges beside a wall read the pressure at it (`SolverConfiguration.gaugesReadWallPressure`).
    case wallReadGauges
    // The structure.
    case shellElements
    case shellSectionShear
    case noSecondCracks
    case noBareBars
    case removesFragments
    case noCrackSlip
    case bondSlip
    case discreteBars
    case nonlocalCracking
    case nonDefaultRateWindow
    case rubbleParticles
    case extremeFibreCracking
    case erodesCrushedBare
    case releasesCrushedBareHourglass
    case pressedInterlock
    case hourglassSecant
    case hourglassWithoutSteel
    /// Cracked concrete elements at eight points with an assumed strain (`StructureModel.assumedStrainCracking`).
    case assumedStrainCracking
    case perfectMembers
    case interfaceBond
    case smearedMasonry
    case profiledSheets
    /// Steel beams hinged at their joints by connections that fracture (`StructureModel.steelConnection`).
    case steelConnections
    case inclinedBars
    /// Shells laid at a pitch, as a roof's slopes (`Inclination`).
    case pitchedShells
    case baseConnections
    case jointsBetweenParts
    case footings
    /// Footings on a terrain: their soil read from the slope round them (`FootingGround`).
    case footingsOnSlope
    case softGround
    /// Earth or rock under the charge (`SolverConfiguration.ground`): less of its energy for the air.
    case groundCoupling
    case cyclicSand
    case freeBase
    case importedStructure
    // Materials.
    case rateIndependent
    case designIncreaseFactors
    case alternativeRateLaws
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
    case halfSpace
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
        case .mixedAfterburning: return config.afterburning && config.afterburnMixing != nil
        case .shockRefinement: return config.refinement > 1 && config.refinementLevels == 1
        case .twoLevelRefinement: return config.refinement > 1 && config.refinementLevels > 1
        case .adaptiveSubsteps: return config.refinement > 1 && config.refinementOwnSteps
        case .mappedCharge: return config.mappedCharge
        case .structureFixedInAir: return !structures.isEmpty && !config.twoWayCoupling
        case .stationaryWalls: return !structures.isEmpty && !config.movingWalls
        case .closedBoundaries: return inputs.scenario.reflectiveFaces != .ground
        case .copiedOpenFaces: return config.openFaces == .copy && config.gravity == nil
        case .terrain: return inputs.scenario.terrain.map { !$0.isFlat } ?? false
        case .terrainStaircase:
            return (inputs.scenario.terrain.map { !$0.isFlat } ?? false)
                && !config.cutsTerrain(of: inputs.scenario, cellSize: inputs.cellSize)
        case .deflagration: return inputs.scenario.deflagration != nil
        case .ventPanels: return !(inputs.scenario.ventPanels ?? []).isEmpty
        case .congestion: return !(inputs.scenario.congestion ?? []).isEmpty
        case .importedEnvelopes:
            return !inputs.scenario.envelopeSources(.ifc).isEmpty
                || !inputs.scenario.envelopeSources(.mesh).isEmpty
        case .mapBuildings: return !inputs.scenario.envelopeSources(.map).isEmpty
        case .ventedGlazing:
            return inputs.ventsGlazing && inputs.scenario.hasEnvelopePanes
        case .newGlass:
            return (inputs.scenario.envelopeConstructions ?? []).contains { construction in
                construction.glassCondition == .newOrTested
                    || ([construction.glazing] + (construction.sideGlazing.map { Array($0.values) } ?? []))
                        .contains { $0?.condition == .newOrTested }
            }
        case .masonryArching:
            return (inputs.scenario.envelopeConstructions ?? []).contains { $0.masonryArching == true }
        case .wallReadGauges: return config.gaugesReadWallPressure
        // Refined air keeps the staircase (`BlastSolver.setUpStructureCut`).
        case .structureCutCells:
            return config.structureCutCells && config.refinement <= 1 && !structures.isEmpty
        case .shellElements:
            return any { model in model.solids.indices.contains { model.elementKind(of: $0) == .shell } }
        case .shellSectionShear: return any { $0.shellSectionShear }
        case .noSecondCracks: return !concrete.isEmpty && any { !$0.secondCracks }
        case .noBareBars: return any { !$0.bareBars }
        case .removesFragments: return !concrete.isEmpty && any { $0.removesFragments }
        case .noCrackSlip: return !concrete.isEmpty && any { !$0.crackSlip }
        case .bondSlip: return any { $0.bondSlip != nil }
        case .discreteBars: return any { !$0.allDiscreteBars.isEmpty }
        case .nonlocalCracking: return !concrete.isEmpty && any { $0.crackAveraging != nil }
        case .nonDefaultRateWindow:
            return any { $0.strainRateWindow != StructureModel.defaultStrainRateWindow }
        case .rubbleParticles: return !concrete.isEmpty && any { $0.rubbleParticles }
        case .extremeFibreCracking: return !concrete.isEmpty && any { $0.extremeFibreCracking }
        case .erodesCrushedBare: return !concrete.isEmpty && any { $0.erodesCrushedBare }
        case .releasesCrushedBareHourglass:
            return !concrete.isEmpty && any { $0.releasesCrushedBareHourglass }
        case .pressedInterlock: return any { $0.pressedInterlock }
        case .hourglassSecant: return !concrete.isEmpty && any { $0.hourglassFollowsCracking }
        case .hourglassWithoutSteel: return !concrete.isEmpty && any { !$0.hourglassCapsSteel }
        case .assumedStrainCracking: return !concrete.isEmpty && any { $0.assumedStrainCracking }
        case .perfectMembers: return any { !$0.memberImperfections && $0.elementKind == .shell }
        case .interfaceBond: return any { $0.interfaceBond != nil }
        case .smearedMasonry: return materials.contains { $0.units != nil } && any { !$0.unitJoints }
        case .profiledSheets: return any { $0.solidSheets.contains { $0 != nil } }
        case .steelConnections: return any { $0.steelConnection != nil }
        case .inclinedBars: return any { !$0.inclinedBars.isEmpty }
        case .pitchedShells: return any(\.hasInclinedSolids)
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
        case .footingsOnSlope:
            return (inputs.scenario.terrain.map { !$0.isFlat } ?? false)
                && any { s in
                    (s.fixedBase && s.baseAnchorage?.footing != nil)
                        || s.supportAnchorages.contains { $0?.footing != nil }
                }
        case .softGround: return config.groundStiffness != nil && !structures.isEmpty
        case .groundCoupling: return config.ground.map { $0 != .rigid } ?? false
        case .cyclicSand:
            return any { s in
                (s.fixedBase && s.baseAnchorage?.footing?.soil.cyclic != nil)
                    || s.supportAnchorages.contains { $0?.footing?.soil.cyclic != nil }
            }
        case .freeBase: return any { !$0.fixedBase }
        case .importedStructure:
            return inputs.scenario.importedModels?.contains(where: \.isStructural) == true
        case .rateIndependent: return structural.contains { !$0.rateDependent }
        case .designIncreaseFactors:
            return materials.contains { $0.concreteRateFactor != 1 || $0.steelRateFactor != 1 }
        case .alternativeRateLaws:
            return structural.contains { $0.rateDependent && !$0.steelRateDependent }
        case .studyMultipliers: return structural.contains { $0.dowelFactor != 1 || $0.interlockFactor != 1 }
        case .barRuptureInElements: return structural.contains { $0.steel != nil && !$0.bondSpreading }
        case .thermalVolume: return inputs.thermal?.fireball == .volume
        case .thermalShape: return inputs.thermal?.fireball == .shape
        case .thermalSphere: return inputs.thermal?.fireball == .sphere
        case .surfaceHeating: return inputs.thermal?.heating.enabled == true
        case .measuredSounding: return inputs.cloud?.sounding != nil
        case .cloudSpread: return inputs.cloud?.spread == true
        case .soilColumn: return inputs.groundShock?.model == .column
        case .halfSpace: return inputs.groundShock?.model == .halfspace
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
        switch option {
        case .afterburning, .hotAir, .dissociatingAir, .radiativeCooling, .gravity, .subgridMixing,
            .afterburnLimit, .mixedAfterburning, .shockRefinement, .twoLevelRefinement, .adaptiveSubsteps,
            .mappedCharge, .structureFixedInAir, .structureCutCells, .stationaryWalls, .closedBoundaries,
            .copiedOpenFaces, .terrain, .terrainStaircase, .wallReadGauges:
            return airEntry(for: option)
        case .deflagration, .congestion, .ventPanels:
            return deflagrationEntry(for: option)
        case .importedEnvelopes, .mapBuildings, .newGlass, .masonryArching, .ventedGlazing:
            return envelopeEntry(for: option)
        case .shellElements, .shellSectionShear, .noSecondCracks, .noBareBars, .removesFragments,
            .noCrackSlip, .bondSlip, .discreteBars, .nonlocalCracking, .nonDefaultRateWindow,
            .rubbleParticles, .extremeFibreCracking, .erodesCrushedBare, .releasesCrushedBareHourglass,
            .pressedInterlock, .hourglassSecant, .hourglassWithoutSteel, .assumedStrainCracking,
            .perfectMembers,
            .interfaceBond,
            .smearedMasonry, .profiledSheets, .steelConnections, .pitchedShells, .inclinedBars,
            .baseConnections, .jointsBetweenParts, .footings, .footingsOnSlope, .softGround, .groundCoupling,
            .cyclicSand, .freeBase, .importedStructure, .rateIndependent, .designIncreaseFactors,
            .alternativeRateLaws, .studyMultipliers, .barRuptureInElements:
            return structureEntry(for: option)
        case .thermalVolume, .thermalShape, .thermalSphere, .surfaceHeating, .measuredSounding, .cloudSpread:
            return thermalEntry(for: option)
        case .soilColumn, .halfSpace:
            return groundEntry(for: option)
        case .freestandingBoxes, .freestandingCars:
            return hazardEntry(for: option)
        }
    }

    /// Every stored property of the input types the standing reads, keyed "Type.property". A
    /// property missing here fails `EvidentialStandingTests`: a new model option needs a
    /// standing entry before it lands.
    public static let fields: [String: Field] = [
        sceneFields, airFields, deflagrationFields, envelopeFields, structureFields, thermalFields,
        hazardFields, groundFields,
    ].reduce(into: [:]) { all, part in
        all.merge(part) { _, _ in preconditionFailure("A field is classified twice") }
    }

    /// The scene's own fields: the scenario's, the standing's inputs, the terrain and the charges.
    static let sceneFields: [String: Field] = [
        // Scenario.
        "Scenario.name": .input,
        "Scenario.domainSize": .input,
        "Scenario.objects": .input,
        "Scenario.rigidObjects": .option([.freestandingBoxes]),
        "Scenario.rigidCars": .option([.freestandingCars]),
        "Scenario.importNotes": .input,
        "Scenario.importedModels": .option([.importedStructure]),
        "Scenario.charge": .input,
        "Scenario.additionalCharges": .input,
        "Scenario.gauges": .input,
        "Scenario.atmosphere": .input,
        "Scenario.reflectiveFaces": .option([.closedBoundaries]),
        "Scenario.terrain": .option([.terrain, .footingsOnSlope]),
        "Scenario.attributions": .input,
        "Scenario.standOffLines": .input,
        "Scenario.envelopeSources": .option([.importedEnvelopes, .mapBuildings]),
        "Scenario.envelopeConstructions": .input,
        "Scenario.deflagration": .option([.deflagration]),
        "Scenario.ventPanels": .option([.ventPanels]),
        "Scenario.congestion": .option([.congestion]),
        // What the standing is derived from: the scene and the specs above, and one choice of its own.
        "StandingInputs.scenario": .input,
        "StandingInputs.cellSize": .input,
        "StandingInputs.configuration": .input,
        "StandingInputs.thermal": .input,
        "StandingInputs.cloud": .input,
        "StandingInputs.fragments": .input,
        "StandingInputs.groundShock": .input,
        "StandingInputs.ventsGlazing": .option([.ventedGlazing]),
        "Terrain.origin": .input,
        "Terrain.spacing": .input,
        "Terrain.columns": .input,
        "Terrain.rows": .input,
        "Terrain.heights": .input,
        "Terrain.source": .input,
        "Charge.mass": .input,
        "Charge.delay": .input,
        "Charge.position": .input,
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
    public init(_ inputs: StandingInputs) { self.init(inputs, table: Self.currentTable) }

    /// The standing of `inputs`, recorded as judged by `table`.
    init(_ inputs: StandingInputs, table: String) {
        let scene = StandingScene(inputs)
        var results = [scene.peakOverpressure(), scene.impulse(), scene.blastInjury()]
        if !scene.structures.isEmpty {
            results += [scene.structuralResponse(), scene.structuralDamage(), scene.collapse()]
        }
        if !inputs.scenario.envelopeObjects.isEmpty {
            results += [scene.envelopeExposure(), scene.envelopeDamage()]
        }
        if scene.options.contains(.freestandingBoxes) || scene.options.contains(.freestandingCars) {
            results.append(scene.freestandingMotion())
        }
        if inputs.thermal != nil { results.append(scene.thermal()) }
        if scene.options.contains(.surfaceHeating) { results.append(scene.surfaceHeating()) }
        if inputs.cloud != nil { results.append(scene.cloud()) }
        if inputs.fragments != nil { results.append(scene.fragments()) }
        if inputs.groundShock != nil { results.append(scene.groundShock()) }
        if scene.options.contains(.groundCoupling) { results.append(scene.crater()) }
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
        for index in results.indices {
            let (bands, unbanded) = scene.bands(for: results[index].kind)
            results[index].bands = bands
            results[index].unbanded = unbanded
            results[index].regimes = scene.regimes(for: results[index].kind)
        }
        self.init(
            table: table, results: results, resolution: scene.resolutionNotes(),
            unsupported: scene.unsupported())
        gauges = scene.gaugeBands()
    }
}

/// The scene's numbers the table needs, worked out once.
struct StandingScene {
    /// The Kingery–Bulmash comparison's grids for 100 kg, by name, as the tables' columns.
    static let columns = ["0.5": 0, "0.25": 1, "0.125": 2]
    /// The close-in comparison's column for cells of `cells` per kg^(1/3).
    static func closeColumn(_ cells: Float) -> Int? {
        ValidationTables.closeGrids.firstIndex { abs($0 - Double(cells)) < 1e-6 }
    }
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

    func has(_ option: ModelOption) -> Bool { options.contains(option) }

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

    func millimetres(_ metres: Float) -> String { String(format: "%.0f mm", metres * 1000) }

    var cellDescription: String {
        let refined = fineCell < inputs.cellSize ? " near the shock" : ""
        return String(format: "%@%@ (%.3f m/kg^(1/3) for %@ kg)", metres(fineCell), refined, scaledCell, mass)
    }

    private func metres(_ value: Float) -> String {
        value < 0.1 ? millimetres(value) : String(format: "%.3g m", value)
    }

    private var mass: String { String(format: "%.3g", inputs.scenario.charge.mass) }

    var gaugeRange: String? {
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

    func result(
        _ kind: ResultKind, _ level: EvidenceLevel, _ summary: String, evidence: [StandingEvidence] = [],
        assumptions: [String] = [], resolution: [String] = [], documents: [String]
    ) -> ResultStanding {
        ResultStanding(
            kind: kind, level: level, summary: summary, evidence: evidence, assumptions: assumptions,
            resolution: resolution, options: [], documents: documents)
    }

    var sourceAssumptions: [String] {
        var lines = [
            has(.mappedCharge)
                ? "Each charge starts from a fine one-dimensional burst laid on the grid where it has room "
                    + "(3 cells or more, at most half the way to another charge); one nearer anything is a "
                    + "sphere of hot compressed gas (a bursting balloon), poor within a few charge diameters or "
                    + "cells of it."
                : "The charge is a sphere of hot compressed gas (a bursting balloon), poor within a few charge "
                    + "diameters or cells of it.",
            "Shocks are smeared over two or three cells.",
        ]
        lines.append(
            has(.hotAir) || has(.dissociatingAir)
                ? "The detonation products are treated as hot air."
                : "The detonation products are treated as air, an ideal gas of γ = 1.4.")
        let further = inputs.scenario.additionalCharges ?? []
        if further.contains(where: { $0.firingTime > 0 }) {
            lines.append(
                "Several charges fire, some after the main one; the comparisons are of one charge, and of "
                    + "two delayed ones against a finer run. A delayed charge is laid down when the run's clock "
                    + "reaches it: with the fine start, from its one-dimensional solution where the air about "
                    + "it stays still until that is due, else (and without the fine start) as a ball of hot "
                    + "gas; laid during the run where the air is not yet refined, it is resolved by the coarse cells "
                    + "until the refinement takes it up, and its fireball's first moments are not in the thermal record."
            )
        } else if !further.isEmpty {
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
    var terrainEvidence: [StandingEvidence] {
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
            + (!has(.terrainStaircase)
                ? [
                    StandingEvidence(
                        "Cut cells on a slope against three-shock theory",
                        "Triple point within 0.25° at 30–45° and 0.4–0.65° low at 48° on 100–400 cells (refined "
                            + "once or twice, 0.2–0.35° off on average, up to 0.5° low at 30°); transition between "
                            + "48 and 50° against 50.6–50.8° for Mach 2; conservative to round-off across the levels",
                        "terrain.md#cut-cells")
                ] : [])
    }

    // MARK: What the scene leaves out

    func unsupported() -> [String] {
        var effects = [
            "Nothing here is validated for engineering decisions or for judging the safety of a real structure.",
            options.contains(.groundCoupling)
                ? "The crater is estimated, not modelled: no displaced soil, ejecta or ground shock driven by the "
                    + "charge, and the air keeps the ground as it was before the blast."
                : "The ground is rigid and reflecting: no crater, displaced soil or ground coupling to the air.",
        ]
        if !structures.isEmpty {
            effects.append(
                "Collapse compared once, blind, and missed (two slabs under a blast left standing), and debris "
                    + "only off slabs under contact charges and brick walls under blasts, neither well.")
            effects.append(
                "A failure mode that holds under mesh refinement: none yet, as cracks and removal regularise "
                    + "their energy over one element.")
            if structures.count > 1 { effects.append("Bonds or connections between independent structures.") }
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
                "Flame acceleration is modelled, its one constant fitted in the chamber it is compared in; "
                    + "there is no transition to detonation.")
        }
        if has(.terrain) {
            effects.append(
                "Over the terrain, footings stay level, their sides and bearing capacity read from the slope "
                    + "round them, their stiffness the level ground's; what falls lands along z; a ground point's soil column is level "
                    + "ground's, along the surface's normal; the fireball's radiated power is measured over the "
                    + "floor.")
        }
        if !(inputs.scenario.rigidObjects ?? []).isEmpty || !(inputs.scenario.rigidCars ?? []).isEmpty {
            effects.append("Freestanding objects in the ordinary run: they move only in Compute Motion.")
        }
        return effects
    }
}
