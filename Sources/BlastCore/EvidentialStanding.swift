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
    case envelopeExposure
    case envelopeDamage
    case freestandingMotion
    case thermal
    case surfaceHeating
    case cloud
    case fragments
    case groundShock
    case crater

    public var id: Self { self }

    public var title: String {
        switch self {
        case .peakOverpressure: "Peak overpressure"
        case .impulse: "Impulse"
        case .structuralResponse: "Structural deflection"
        case .structuralDamage: "Structural damage and failure"
        case .envelopeExposure: "Building surface exposure"
        case .envelopeDamage: "Envelope building damage"
        case .freestandingMotion: "Freestanding objects' motion"
        case .thermal: "Thermal radiation"
        case .surfaceHeating: "Surface heating and ignition"
        case .cloud: "Rise and cloud"
        case .fragments: "Fragments"
        case .groundShock: "Ground shock"
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
    /// Advance when the table's content changes, so that a kept run says which it was judged by.
    public static let currentTable = "standing-table-20"

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
    case shockRefinement
    case twoLevelRefinement
    case adaptiveSubsteps
    case mappedCharge
    case structureFixedInAir
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
    case interfaceBond
    case smearedMasonry
    case profiledSheets
    case inclinedBars
    case baseConnections
    case jointsBetweenParts
    case footings
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
                && !config.cutsTerrain(of: inputs.scenario)
        case .deflagration: return inputs.scenario.deflagration != nil
        case .ventPanels: return !(inputs.scenario.ventPanels ?? []).isEmpty
        case .congestion: return !(inputs.scenario.congestion ?? []).isEmpty
        case .importedEnvelopes:
            return !inputs.scenario.envelopeSources(.ifc).isEmpty
                || !inputs.scenario.envelopeSources(.mesh).isEmpty
        case .mapBuildings: return !inputs.scenario.envelopeSources(.map).isEmpty
        case .ventedGlazing:
            return inputs.ventsGlazing && inputs.scenario.hasEnvelopePanes
        case .shellElements:
            return any { $0.elementKind == .shell || $0.solidElementKind.contains(.shell) }
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
        case .interfaceBond: return any { $0.interfaceBond != nil }
        case .smearedMasonry: return materials.contains { $0.units != nil } && any { !$0.unitJoints }
        case .profiledSheets: return any { $0.solidSheets.contains { $0 != nil } }
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
        let structure: [ResultKind] = [.structuralResponse, .structuralDamage]
        let air: [ResultKind] = [.peakOverpressure, .impulse]
        switch option {
        case .afterburning:
            return Entry(
                title: "Afterburning", affects: air + [.thermal, .cloud], limit: nil,
                note: "The products burn in the air they mix with; the burning time was fitted to "
                    + "Kingery–Bulmash's incident impulse. The default, with hot air, since 15 October 2026.",
                document: "air-blast-model.md#afterburning")
        case .hotAir:
            return Entry(
                title: "Hot air", affects: air + [.thermal], limit: nil,
                note: "Air stores energy in molecular vibration, its γ falling towards 1.29 near 3000 K. The "
                    + "default, with afterburning, since 15 October 2026.",
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
                    + "unchanged but the open incident impulse falls by 8 to 9%, to 86–91% of Kingery-Bulmash's, and "
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
        case .adaptiveSubsteps:
            return Entry(
                title: "Adaptive substeps", affects: air + structure + [.envelopeExposure], limit: nil,
                note: "Each refined level takes only the substeps its own waves need: the open blast's peaks "
                    + "move 1 to 2.5% (up, towards Kingery-Bulmash), impulses and arrivals under 1%, inside the "
                    + "6 to 8% scatter of the references; close in, where the patches hold the fastest wave, "
                    + "nothing changes.",
                document: "air-blast-model.md#refining-near-the-shock")
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
        case .copiedOpenFaces:
            return Entry(
                title: "Open faces that copy", affects: air, limit: nil,
                note: "The open faces copy the air inside outward instead of standing still air beyond: "
                    + "a domain hardly bigger than the fireball traps its burning products (Wang's gauges "
                    + "3.8 times the impulse of a domain four times as wide), and one losing air drains below "
                    + "ambient. Far-field faces replaced them for every run on 15 October; the bands were derived "
                    + "with these.",
                document: "validation.md#afterburning-by-default-what-it-would-cost-and-move")
        case .terrain:
            return Entry(
                title: "Terrain",
                affects: air + structure + [
                    .envelopeExposure, .thermal, .freestandingMotion, .fragments, .groundShock,
                ],
                limit: .approximation,
                note:
                    "Rigid and smooth, cut through the cells: on 100–400 cells "
                    + "the triple point's angle within 0.25° of three-shock theory at 30–45° and Mach "
                    + "reflection 1–3° late; shielding behind ridges is consistency-checked only, and peaks "
                    + "focused far behind a round hill do not converge.",
                document: "terrain.md#limitations")
        case .terrainStaircase:
            return Entry(
                title: "Terrain as a staircase", affects: air + [.envelopeExposure], limit: .approximation,
                note:
                    "The staircase, when chosen, keeps the terrain as whole cells: it delays Mach "
                    + "reflection off a slope by 3–11° and under-reads the triple point's angle by 20–75% on "
                    + "100–400 cells, and windward faces' peaks read 1.3–1.5 times the cut cells', growing "
                    + "with resolution.",
                document: "terrain.md#cut-cells")
        case .deflagration:
            return Entry(
                title: "Gas deflagration", affects: air + structure + [.envelopeExposure],
                limit: .illustrative,
                note: "A methane or propane cloud's flame: checked against the thin-flame model in a closed "
                    + "vessel and wrinkled by sub-grid turbulence and its measured cellular instability; in FM "
                    + "Global's vented chamber it reaches 0.9–1.8 times the tests' peaks lit at the back wall, "
                    + "0.4–0.6 lit in the middle, and below the (conservative) venting correlations. An open, "
                    + "congested cloud, as at a process plant, has been compared with no test: congestion speeds "
                    + "real flames to hundreds of metres a second, beyond what it resolves.",
                document: "deflagration.md#limitations")
        case .importedEnvelopes:
            return Entry(
                title: "Envelopes from imports", affects: air + [.envelopeExposure], limit: .approximation,
                note:
                    "An import's sampled boxes kept as a stationary envelope, which on the IFC fixtures is the "
                    + "rigid import to the bit; windows and doors are cut as their bounding boxes (under 0.6% on "
                    + "the maps and 0.8% on the surface loading of the duplex); element identities and materials "
                    + "are lost, and nothing deforms or fails.",
                document: "building-envelopes.md#envelopes-from-imports-and-map-data")
        case .mapBuildings:
            return Entry(
                title: "Buildings from map data", affects: air + [.envelopeExposure], limit: .illustrative,
                note:
                    "Footprints from map data extruded as solid blocks to a tagged height, or levels at 3 m, or an "
                    + "assumed two levels: no openings, interiors or roof shapes, and positions and heights as "
                    + "accurate as the map.",
                document: "building-envelopes.md#buildings-from-map-data")
        case .congestion:
            return Entry(
                title: "Congestion below the grid", affects: air + structure + [.envelopeExposure],
                limit: .illustrative,
                note:
                    "Pipes and bars too small for the cells take room, resist the air, make turbulence and fold "
                    + "a flame, as PDRFoam's porous cells and sub-grid flame do; it is compared with no test yet.",
                document: "congestion-model.md")
        case .ventedGlazing:
            return Entry(
                title: "Glazing vented in the air", affects: [.envelopeExposure, .envelopeDamage],
                limit: nil,
                note:
                    "Envelopes' panes break in the air when their one-way glass does (within 0.3 ms on its own "
                    + "loads) and open their windows whole, so the blast fills the rooms and loads the walls from "
                    + "inside; walls, roofs and slabs judged failed open too; the default where it can run. The "
                    + "inside stays illustrative: the detailed "
                    + "references let broken glass go element by element and cannot judge it; against UFC "
                    + "3-340-02's loads through open windows the walls inside come at 0.31 to 1.22 of the UFC's "
                    + "(the back walls within 25%), where the one-way fill gives 0.15 to 0.42.",
                document: "building-envelopes.md#venting-glazing-that-breaks-in-the-air")
        case .ventPanels:
            return Entry(
                title: "Vent panels", affects: air + structure + [.envelopeExposure], limit: .approximation,
                note: "Massless, instantaneous; verified only to open at the release pressure.",
                document: "deflagration.md#vent-panels")
        case .shellElements:
            return Entry(
                title: "Shell elements", affects: structure, limit: nil,
                note: "On the slab test shells peaked at 135 mm, 124% of that measured, against 104–115% "
                    + "for solid elements.",
                document: "validation.md#structural-response-against-a-real-test")
        case .shellSectionShear:
            return Entry(
                title: "Shells' section shear check", affects: structure, limit: .approximation,
                note: "Off by default: under a blast the slab test's shells carried shears near their "
                    + "supports that this static method says they cannot.",
                document: "shell-model.md")
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
                note:
                    "Concrete cracked open two ways is removed; under contact charges it holed Wu's slabs at "
                    + "two thirds and 1.6 times the measured size and Hupfauf's 20 cm slabs, but also his 30 cm "
                    + "slabs that held; it did not hole Chiquito's, and damaged struck beams.",
                document: "validation.md#holes-under-close-in-and-contact-charges")
        case .noCrackSlip:
            return Entry(
                title: "Cracks spring back after sliding", affects: structure, limit: .approximation,
                note: "Shear beyond interlock and dowels springs back instead of sliding for good; the "
                    + "comparisons let cracks slide.",
                document: "concrete-model.md#shear-across-cracks")
        case .bondSlip:
            return Entry(
                title: "Bars that slip", affects: structure, limit: nil,
                note: "The Model Code's bond-slip law; run against the slab, shear-beam and impact tests "
                    + "too (on the slab, 95 mm on 8 elements through).",
                document: "concrete-model.md#bars-that-slip-an-option")
        case .discreteBars:
            return Entry(
                title: "Discrete bars", affects: structure, limit: .approximation,
                note: "Bars as trusses embedded in the elements, with the Model Code's bond; a tie cracks "
                    + "and stiffens as the Model Code says on two meshes, but no member test has judged them.",
                document: "concrete-model.md#discrete-bars")
        case .nonlocalCracking:
            return Entry(
                title: "Nonlocal cracking", affects: structure, limit: .approximation,
                note:
                    "Cracks soften by their strain averaged across their band; being judged on the case matrix.",
                document: "concrete-model.md#nonlocal-cracking")
        case .nonDefaultRateWindow:
            return Entry(
                title: "Strain-rate window off the default", affects: structure, limit: .approximation,
                note:
                    "The rate laws see the strain rate averaged over a window other than the default 100 µs, "
                    + "or over the last 50 steps as before 12 October 2026, which ties the result to the step.",
                document: "concrete-model.md#the-strain-rate-window")
        case .rubbleParticles:
            return Entry(
                title: "Rubble particles", affects: [.structuralDamage], limit: .approximation,
                note: "Failed concrete keeps its mass as particles in contact: Hupfauf's debris thrown at "
                    + "about 22% from the measured speed against 45%, but no slab holed that the tests holed.",
                document: "validation.md#rubble-kept-as-particles-stage-3")
        case .extremeFibreCracking:
            return Entry(
                title: "Cracking at the extreme fibre", affects: structure, limit: .approximation,
                note: "Elements with a free face crack when that face reaches the tensile strength; "
                    + "being judged on the case matrix.",
                document: "concrete-model.md#cracking-at-the-extreme-fibre")
        case .erodesCrushedBare:
            return Entry(
                title: "Crushed bare elements removed", affects: structure, limit: .approximation,
                note: "Bare concrete elements squeezed below a quarter of their volume are removed, as "
                    + "softer materials' are. It stops a runaway under contact charges, but sends Hupfauf's SN131 "
                    + "far face to 53 m/s against 21.5 by default and 14.6 measured, so it is not a default.",
                document: "concrete-model.md#crushed-bare-elements-two-options-neither-a-default")
        case .releasesCrushedBareHourglass:
            return Entry(
                title: "Crushed bare elements without hourglass control", affects: structure,
                limit: .approximation,
                note: "Bare concrete elements squeezed below a quarter of their volume keep their bars but "
                    + "lose their hourglass control. It stops a runaway under contact charges, but sends "
                    + "Hupfauf's SN131 far face to 46 m/s against 21.5 by default and 14.6 measured, so it is not "
                    + "a default.",
                document: "concrete-model.md#crushed-bare-elements-two-options-neither-a-default")
        case .pressedInterlock:
            return Entry(
                title: "Pressed interlock", affects: structure, limit: .approximation,
                note: "Brings the chamber's roof edge to 25 mm against 95 mm measured, but breaks beams "
                    + "under impact that the tests saw survive.",
                document: "concrete-model.md#shear-across-cracks")
        case .hourglassSecant:
            return Entry(
                title: "Hourglass control softening with cracking", affects: structure, limit: .approximation,
                note: "Brings the shear beam OA1 within 4% and the contest slab's residual within 1%, but "
                    + "makes struck beams go too far.",
                document: "validation.md#hourglass-control")
        case .hourglassWithoutSteel:
            return Entry(
                title: "Hourglass cap without the bars", affects: structure, limit: .approximation,
                note: "Halves the hourglass work in the contest slab and leaves the shear beam as it was; "
                    + "not run against the impact tests.",
                document: "validation.md#hourglass-control")
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
        case .profiledSheets:
            return Entry(
                title: "Profiled steel sheeting", affects: [.structuralDamage], limit: .illustrative,
                note: "Sheets are a skin with their ribs as beams, fixed to their rails and purlins without "
                    + "pull-out. Against Langdon's corrugated panels the elastic peaks are 0.5–1.3 of those "
                    + "measured, but plastic ones scatter from a tenth to three times, the connections give "
                    + "way above 2 bar where the panels held, and local buckling is not modelled.",
                document: "profiled-sheeting.md#against-langdons-corrugated-panels")
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
                    "One footing rocked slowly on dry sand: moment within 11% to 14 mrad and 5–14% low beyond. "
                    + "With the sand that settles under cycles (the default), settlement 1.3–1.7 times that "
                    + "measured, and 0.4–1.3 times in eight shaken events; a tenth on the elastic bed.",
                document: "validation.md#a-footing-rocked-on-dry-sand")
        case .softGround:
            return Entry(
                title: "Soft ground under debris", affects: [.structuralDamage], limit: nil,
                note:
                    "Debris lands on a Winkler bed of the soil's subgrade modulus instead of a hard ground that "
                    + "stops it dead. Compared once, on Keys's brick walls in the open at 5×10⁷ Pa/m (one run "
                    + "each): WR1A's debris came in from a mean 2.10 m to 1.36 m against 0.23 m measured, WR1B's "
                    + "from 2.15 to 1.36 m against 0.64 m. Not for paving or slabs; the air sees the ground as "
                    + "hard.",
                document: "validation.md#brick-walls-debris")
        case .groundCoupling:
            return Entry(
                title: "Ground that takes energy", affects: air, limit: .approximation,
                note:
                    "On earth or rock, a charge on the surface acts on the air as 1.8 times its mass in "
                    + "free air rather than rigid ground's 2, the middle of Kinney and Graham's 1.5 to 2, tapering "
                    + "back with height as the share going into the ground falls (Cooper). The same for every soil; "
                    + "nothing compared here with a burst measured over soft ground.",
                document: "cratering.md#the-air-on-soft-ground")
        case .cyclicSand:
            return Entry(
                title: "Sand that settles under cycles", affects: structure, limit: nil,
                note:
                    "Settlement under rocking 0.4–1.3 times that of eight shaken centrifuge events (FoRDy) and "
                    + "1.3–1.7 times a slowly rocked one's (FoRCy), its heave fitted on the latter, against a tenth "
                    + "on the elastic bed; a sixth to two thirds of the energy the shaken footings dissipated, "
                    + "damping ratios 10–27% against 17–32%.",
                document: "validation.md#a-footing-shaken-on-dry-sand")
        case .freeBase:
            return Entry(
                title: "Base resting on the ground", affects: structure, limit: .verified,
                note: "Nodes on the ground are held up, not held down (verified); no test.",
                document: "validation.md#verification-against-theory")
        case .importedStructure:
            return Entry(
                title: "Structure from IFC", affects: structure, limit: nil,
                note:
                    "Its shells and beams, their materials, the connections where they meet and the supports "
                    + "were inferred from an IFC building and are listed in its report, with each concrete "
                    + "member's reinforcement, read from the IFC where it gives it, else the stated default or none; "
                    + "the shell model's bands "
                    + "apply only where all of them match what was compared, and the standing says where they do not.",
                document: "structural-editing.md#structures-from-ifc")
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
                title: "Bars without their strain-rate law", affects: structure, limit: .approximation,
                note: "The impacts are decided by the strain-rate laws, and were compared with the Model "
                    + "Code's in tension and CEB's for bars.",
                document: "concrete-model.md#strain-rate-effects")
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
                    + "history; checked against closed-form solutions; against Xia's 1 t burst its vertical "
                    + "velocity 20 to 80 times the measured.",
                document: "ground-shock.md#the-soil-column")
        case .halfSpace:
            return Entry(
                title: "Half-space", affects: [.groundShock], limit: .illustrative,
                note:
                    "An axisymmetric half-space under the charge, elastic or with soil that yields, driven by "
                    + "the air's ground pressures and a direct source; checked against Lamb's problem, Cole and "
                    + "Huth's moving load, Haskell's dispersion and the bilinear column; against Xia's 1 t burst "
                    + "still far too high in the vertical.",
                document: "ground-shock-outrunning.md")
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
        "Scenario.importedModels": .option([.importedStructure]),
        "Scenario.charge": .input,
        "Scenario.additionalCharges": .input,
        "Scenario.gauges": .input,
        "Scenario.atmosphere": .input,
        "Scenario.reflectiveFaces": .option([.closedBoundaries]),
        "Scenario.terrain": .option([.terrain]),
        "Scenario.attributions": .input,
        "Scenario.envelopeSources": .option([.importedEnvelopes, .mapBuildings]),
        "EnvelopeSource.objectID": .input,
        "EnvelopeSource.kind": .option([.importedEnvelopes, .mapBuildings]),
        "EnvelopeSource.detail": .input,
        "Scenario.envelopeConstructions": .input,
        "EnvelopeConstruction.objectID": .input,
        "EnvelopeConstruction.walls": .input,
        "EnvelopeConstruction.wallThicknessM": .input,
        "EnvelopeConstruction.roof": .input,
        "EnvelopeConstruction.roofThicknessM": .input,
        "EnvelopeConstruction.reinforcementRatio": .input,
        "EnvelopeConstruction.glassThicknessM": .input,
        "EnvelopeConstruction.facadePaneM": .input,
        "EnvelopeConstruction.source": .input,
        "EnvelopeConstruction.detail": .input,
        "EnvelopeConstruction.barsInBothFaces": .input,
        "EnvelopeConstruction.barCoverM": .input,
        "EnvelopeConstruction.concreteStrengthMPa": .input,
        "EnvelopeConstruction.barYieldMPa": .input,
        "EnvelopeConstruction.blockworkGrouted": .input,
        "EnvelopeConstruction.masonryStrengthMPa": .input,
        "EnvelopeConstruction.capMassKgPerM": .input,
        "EnvelopeConstruction.wallSheet": .input,
        "EnvelopeConstruction.roofSheet": .input,
        "EnvelopeConstruction.sheetSpanM": .input,
        "EnvelopeConstruction.sheetContinuous": .input,
        "EnvelopeConstruction.screwsPerM": .input,
        "EnvelopeConstruction.railThicknessM": .input,
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
        "Deflagration.gas": .input,
        "Deflagration.concentration": .input,
        "Deflagration.region": .input,
        "Deflagration.ignition": .input,
        "Deflagration.acceleration": .option([.deflagration]),
        "FlameAcceleration.factor": .option([.deflagration]),
        "FlameAcceleration.instability": .option([.deflagration]),
        "FlameAcceleration.externalFactor": .option([.deflagration]),
        "FlameAcceleration.turbulence": .option([.deflagration]),
        "FlameTurbulence.scale": .option([.deflagration]),
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
        // Off, a run stops where independent bodies come close; what it gives up to there is the same.
        "SolverConfiguration.interBodyContact": .numerical,
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
        // Off, a structure swings under its own weight as the blast arrives; the comparisons that
        // carry their weight move by 1 mm or less with it (structural-model.md, "Settling under
        // its own weight").
        "SolverConfiguration.settlesStructures": .numerical,
        "SolverConfiguration.skipStillAir": .numerical,
        "SolverConfiguration.airModel": .option([.hotAir, .dissociatingAir]),
        "SolverConfiguration.afterburning": .option([.afterburning]),
        "SolverConfiguration.afterburnEnergy": .input,
        "SolverConfiguration.afterburnTime": .option([.afterburning]),
        "SolverConfiguration.mappedCharge": .option([.mappedCharge]),
        "SolverConfiguration.airSleepThreshold": .numerical,
        "SolverConfiguration.airSleepCrossings": .numerical,
        "SolverConfiguration.debrisReach": .numerical,
        "SolverConfiguration.openFaces": .option([.copiedOpenFaces]),
        "SolverConfiguration.minimumBalloonCells": .numerical,
        "SolverConfiguration.refinement": .option([.shockRefinement, .twoLevelRefinement]),
        "SolverConfiguration.refinementThreshold": .numerical,
        "SolverConfiguration.refinementMargin": .numerical,
        "SolverConfiguration.refinementLevels": .option([.twoLevelRefinement]),
        "SolverConfiguration.refinementOwnSteps": .option([.adaptiveSubsteps]),
        "SolverConfiguration.refinementFinerThreshold": .numerical,
        "SolverConfiguration.refinementMemory": .numerical,
        "SolverConfiguration.structureMaskSampling": .numerical,
        "SolverConfiguration.structureMaskFill": .numerical,
        "SolverConfiguration.structureMaskOverlap": .numerical,
        "SolverConfiguration.radiativeCooling": .option([.radiativeCooling]),
        "SolverConfiguration.gravity": .option([.gravity]),
        "SolverConfiguration.mixing": .option([.subgridMixing]),
        "SolverConfiguration.periodicSides": .numerical,
        "SolverConfiguration.afterburnLimit": .option([.afterburnLimit]),
        "SolverConfiguration.terrainCutCells": .option([.terrainStaircase]),
        "SolverConfiguration.groundStiffness": .option([.softGround]),
        "SolverConfiguration.ground": .option([.groundCoupling]),
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
        "StructureModel.tiesTouching": .option([.importedStructure]),
        "StructureModel.supports": .input,
        "StructureModel.supportAnchorages": .option([.baseConnections, .footings]),
        "StructureModel.interfaceBond": .option([.interfaceBond]),
        "StructureModel.unitJoints": .option([.smearedMasonry]),
        "StructureModel.solidSheets": .option([.profiledSheets]),
        "StructureModel.shellSectionShear": .option([.shellSectionShear]),
        "StructureModel.secondCracks": .option([.noSecondCracks]),
        "StructureModel.bareBars": .option([.noBareBars]),
        "StructureModel.removesFragments": .option([.removesFragments]),
        "StructureModel.crackSlip": .option([.noCrackSlip]),
        "StructureModel.bondSlip": .option([.bondSlip]),
        "StructureModel.discreteBars": .option([.discreteBars]),
        "StructureModel.barsAsTrusses": .option([.discreteBars]),
        "StructureModel.trussDiameter": .option([.discreteBars]),
        "StructureModel.crackAveraging": .option([.nonlocalCracking]),
        "StructureModel.strainRateWindow": .option([.nonDefaultRateWindow]),
        "StructureModel.rubbleParticles": .option([.rubbleParticles]),
        "StructureModel.extremeFibreCracking": .option([.extremeFibreCracking]),
        "StructureModel.erodesCrushedBare": .option([.erodesCrushedBare]),
        "StructureModel.releasesCrushedBareHourglass": .option([.releasesCrushedBareHourglass]),
        "StructureModel.pressedInterlock": .option([.pressedInterlock]),
        "StructureModel.hourglassFollowsCracking": .option([.hourglassSecant]),
        "StructureModel.hourglassCapsSteel": .option([.hourglassWithoutSteel]),
        "StructureModel.retiredOptions": .input,
        // The regime picks defaults for the options above (`StructuralRegime`); what it turns on
        // is read through those options, so the regime itself is an input of the scene.
        "StructureModel.regimeOverride": .input,
        "StructureModel.loadingOverride": .input,
        "StructureModel.regimeDefaults": .input,
        "StructureModel.detectedRegime": .input,
        "StructureModel.detectedLoading": .input,
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
        "StructureMaterial.bondSpreading": .option([.barRuptureInElements]),
        "StructureMaterial.confinementCoefficient": .input,
        "StructureMaterial.aggregateSize": .input,
        "StructureMaterial.crackResidual": .input,
        "StructureMaterial.dowelFactor": .option([.studyMultipliers]),
        "StructureMaterial.interlockFactor": .option([.studyMultipliers]),
        "StructureMaterial.fractureRateExponent": .input,
        "StructureMaterial.crackDilatancy": .input,
        "StructureMaterial.concreteRateFactor": .option([.designIncreaseFactors]),
        "StructureMaterial.steelRateFactor": .option([.designIncreaseFactors]),
        "StructureMaterial.rateDependent": .option([.rateIndependent]),
        "StructureMaterial.steelRateDependent": .option([.alternativeRateLaws]),
        "StructureMaterial.units": .option([.smearedMasonry]),
        "StructureMaterial.isTransparent": .input,
        // Timber's properties; its standing follows from its material class.
        "StructureMaterial.timber": .input,
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
        "FragmentSpec.wallThickness": .input,
        "FragmentSpec.innerDiameter": .input,
        "FragmentSpec.explosive": .input,
        "FragmentSpec.mottCoefficient": .input,
        "FragmentSpec.massExponent": .input,
        "GroundShockSpec.soil": .input,
        "GroundShockSpec.points": .input,
        "GroundShockSpec.line": .input,
        "GroundShockSpec.depths": .input,
        "GroundShockSpec.arrivalThreshold": .input,
        "GroundShockSpec.model": .option([.soilColumn, .halfSpace]),
        "GroundShockSpec.halfSpace": .input,
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
        self.init(results: results, resolution: scene.resolutionNotes(), unsupported: scene.unsupported())
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

    /// The deflagration's checks: no charge fires, so the comparisons with Kingery–Bulmash do not
    /// apply.
    private var deflagrationEvidence: [StandingEvidence] {
        [
            StandingEvidence(
                "A closed sphere of stoichiometric methane against the thin-flame model (blastbench "
                    + "deflagration vessel)",
                "Burns out at the AICC pressure the heat was fitted to, energy conserved to 1e-5; laminar rise "
                    + "times within 1–3% on 48 cells across the radius, the default (cellular) flame's 13–14% "
                    + "ahead; K_G 60 bar m/s against 76 on 96 cells, which a four-cell front cannot resolve "
                    + "(verified)",
                "deflagration.md#a-closed-sphere"),
            StandingEvidence(
                "A laminar flame lit at a tube's closed end",
                "Runs at the expansion ratio times the burning velocity within 10% (verified)",
                "deflagration.md#a-closed-sphere"),
            StandingEvidence(
                "Vented rooms against EN 14994, NFPA 68 and Molkov (blastbench deflagration vented)",
                "A seventh to a twenty-second of Molkov's best fit, which FM Global's tests show conservative; "
                    + "trend with vent area A^-0.9 against A^-2",
                "deflagration.md#vented-rooms-against-the-correlations"),
            StandingEvidence(
                "FM Global's 63.7 m³ chamber, Bauwens et al. 2008 (six tests, digitised)",
                "Lit at the back wall, 0.9–1.8 times the measured peaks; lit in the middle, 0.4–0.6, the "
                    + "flame stalling towards the back wall; geometric mean 0.76",
                "deflagration.md#bauwens-chaffee-and-dorofeev-2008"),
            StandingEvidence(
                "BP Texas City 2005 (CSB), a layout after it",
                "The model's own flame gives 0.01 psi at 37 m against the CSB's 2.5–2.8: congestion's "
                    + "acceleration is not resolved. With the burning velocity times 6.5, fitted there: 2.4 psi, "
                    + "the brick control room failing at 1.6 psi (1.5–2.5, heavily damaged)",
                "process-plant-explosion.md#results"),
        ]
    }

    /// Peak overpressure or impulse from a gas cloud's deflagration.
    private func deflagrationResult(_ kind: ResultKind) -> ResultStanding {
        var resolution = ["Air: \(cellDescription); the flame is about four cells thick."]
        if !(inputs.scenario.ventPanels ?? []).isEmpty {
            resolution.append("Vent panels have no mass and release at once.")
        }
        if let factor = inputs.scenario.deflagration?.acceleration.factor, factor != 1 {
            resolution.append(
                "The burning velocity is raised \(String(format: "%g", factor)) times, a fit standing for what "
                    + "the model does not resolve: the pressures follow it steeply, as about its third power."
            )
        }
        return result(
            kind, .illustrative,
            "Reads low, the unsafe side, where a vented room is lit in the middle: 0.4–0.6 of FM Global's "
                + "tests (0.9–1.8 lit at the back wall), the back of the flame stalling; all fall below EN 14994 "
                + "and NFPA 68, and a peak is uncertain by about ±20% on 0.1 m cells. The wrinkling's one "
                + "constant was fitted, and the instability's onset measured, in that chamber. In a closed "
                + "vessel the laminar rise times come within 1–3% of the thin-flame model, partly two errors "
                + "crossing, and K_G cannot converge on the four-cell front. An open, congested cloud (a process "
                + "plant's racks and vessels) has been compared with no test: there congestion speeds a real "
                + "flame to Mach 0.4–0.7 (Baker–Strehlow–Tang, medium to high congestion), which the flame "
                + "here does not reach, so its pressures are a lower bound, possibly several times low.",
            evidence: deflagrationEvidence + terrainEvidence,
            assumptions: [
                "Burnt and unburnt gas are treated as air; the heat released is the share of the heat of "
                    + "combustion that reaches the stoichiometric AICC pressure.",
                "The flame is wrinkled by sub-grid turbulence from the air's σ-model mixing through Bradley's "
                    + "correlation, and by its cellular instability from the onset radius measured in FM Global's "
                    + "chamber, held beyond four onset radii; a young flame is slow until it is about seventeen "
                    + "cells across.",
            ], resolution: resolution,
            documents: [
                "deflagration.md#checks", "deflagration.md#limitations",
                "process-plant-explosion.md#what-the-model-can-and-cannot-represent",
            ])
    }

    func peakOverpressure() -> ResultStanding {
        if has(.deflagration) { return deflagrationResult(.peakOverpressure) }
        // Today's defaults burn the products in hot air, compared on their own tables.
        let burning = has(.afterburning) && has(.hotAir)
        let incident = Self.columns.mapValues {
            ValidationTables.span(
                burning ? ValidationTables.burningIncidentPeak : ValidationTables.incidentPeak, grid: $0)
        }
        let reflected = Self.columns.mapValues {
            ValidationTables.span(
                burning ? ValidationTables.burningReflectedPeak : ValidationTables.reflectedPeak, grid: $0)
        }
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.compared
        var summary: String
        switch grid {
        case .coarser:
            level = .approximation
            summary =
                "Reads low, the unsafe side: the cells are coarser than any compared with Kingery–Bulmash, "
                + "whose coarsest grid gave \(incident["0.5"]!) of the incident peak."
        default:
            let key = grid == .fine ? "0.125" : grid == .medium ? "0.25" : "0.5"
            summary =
                "Reads low, the unsafe side, as shocks are smeared: Kingery–Bulmash's incident peak "
                + "\(incident[key]!), reflected \(reflected[key]!)\(burning ? " with afterburning and hot air" : ""), "
                + "on air as fine for this charge as the comparison's \(grid.cells) were for 100 kg."
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, a fit to many surface bursts whose scatter is not given; 100 kg from 0.75 to "
                        + "6 m/kg^(1/3) (blastbench validate"
                        + (burning ? ", afterburning, hot air and far-field faces)" : ")"),
                    "Incident peak \(incident[key]!) and reflected \(reflected[key]!) on \(grid.cells)",
                    burning
                        ? ValidationTables.burningDocument
                        : "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        var resolution: [String] = []
        if closeIn, let first = gaugeDistances.first, first < 0.75 {
            let table =
                burning ? ValidationTables.closeBurningReflectedPeak : ValidationTables.closeReflectedPeak
            if let cells = closeInCells, let column = Self.closeColumn(cells) {
                evidence.append(
                    StandingEvidence(
                        "1 kg burst above rigid ground, 0.3 to 1 m/kg^(1/3)"
                            + (burning ? ", on today's air" : ", the ideal gas") + " (blastbench closeair)",
                        "Reflected peak \(ValidationTables.span(table, grid: column)) on \(millimetres(cells)) "
                            + "cells per kg^(1/3)",
                        "validation.md#close-in"))
            } else {
                level = max(level, .approximation)
                resolution.append(
                    String(
                        format: "A gauge %.2f m/kg^(1/3) from the charge is close in, where 40 mm cells per "
                            + "kg^(1/3), the coarsest compared, gave %@ of the reflected peak.",
                        first, ValidationTables.span(table, grid: 0)))
            }
        }
        resolution.append(
            "Air: \(cellDescription); the comparison's 0.5, 0.25 and 0.125 m cells for 100 kg were 0.108, 0.054 "
                + "and 0.027 m/kg^(1/3).")
        if let range = gaugeRange { resolution.append("Gauges lie \(range) from the charge.") }
        if let distance = structureDistance, (0.75...1.3).contains(distance) {
            evidence.append(
                StandingEvidence(
                    "Yao et al.'s 4 × 5 m slabs, the reflected pressure at the top face's centre, 0.8 to 1.26 "
                        + "m/kg^(1/3) on today's air",
                    "Within 11% at 1.0 and 1.26 m/kg^(1/3), 19% low at 0.8; read off plots",
                    "validation.md#yaos-large-slabs"))
        }
        evidence += terrainEvidence
        return result(
            .peakOverpressure, level, summary, evidence: evidence, assumptions: sourceAssumptions,
            resolution: resolution, documents: ["validation.md#blast-loads-against-empirical-references"])
    }

    func impulse() -> ResultStanding {
        if has(.deflagration) { return deflagrationResult(.impulse) }
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.compared
        var summary: String
        let burns = has(.afterburning)
        let hot = has(.hotAir) || has(.dissociatingAir)
        // Today's defaults burn the products in hot air, compared on their own tables.
        let burning = burns && has(.hotAir)
        let reflected = Self.columns.mapValues {
            ValidationTables.span(
                burning ? ValidationTables.burningReflectedImpulse : ValidationTables.reflectedImpulse,
                grid: $0)
        }
        let key = grid == .fine ? "0.125" : grid == .medium ? "0.25" : "0.5"
        let incident =
            burning
            ? "incident impulse \(ValidationTables.span(ValidationTables.burningIncidentImpulse, grid: Self.columns[key]!, from: 1)) "
                + "beyond 1 m/kg^(1/3) (the burning time fitted to it)"
            : burns
                ? "incident impulse 96–101% beyond 1 m/kg^(1/3) (the burning time fitted to it)"
                : "incident impulse 13–22% low on every grid (the unsafe side for what the wave passes over), "
                    + "for want of afterburning"
        switch grid {
        case .coarser:
            level = .approximation
            summary =
                "Reads low on cells coarser than any compared: on the coarsest compared Kingery–Bulmash's "
                + "reflected impulse was \(reflected["0.5"]!), and its \(incident)."
        default:
            summary =
                "On walls, either way: Kingery–Bulmash's reflected impulse \(reflected[key]!) on the comparison's "
                + "\(grid.cells) for 100 kg ("
                + (burning
                    ? "3–14% high beyond 1.5 m/kg^(1/3) on 0.25 m or finer, not fitted"
                    : "within 6% beyond 1.5 m/kg^(1/3) on 0.25 m or finer") + "); \(incident)."
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, a fit to many surface bursts whose scatter is not given; 100 kg from 0.75 to "
                        + "6 m/kg^(1/3) (blastbench validate"
                        + (burning ? ", afterburning, hot air and far-field faces)" : ")"),
                    "Reflected impulse \(reflected[key]!) on \(grid.cells)",
                    burning
                        ? ValidationTables.burningDocument
                        : "validation.md#kingerybulmash-the-design-practice-standard"))
        }
        if burning {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash, incident impulse, on today's defaults",
                    "\(ValidationTables.span(ValidationTables.burningIncidentImpulse, grid: 1, from: 1)) beyond 1 "
                        + "m/kg^(1/3) on 0.25 m cells, fitted: the burning time was chosen on it",
                    ValidationTables.burningDocument))
        } else if burns {
            evidence.append(
                StandingEvidence(
                    "Kingery–Bulmash with afterburning alone (blastbench validate --afterburn)",
                    "Incident impulse 96–101% beyond 1 m/kg^(1/3), fitted; reflected 6–15% high in the "
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
                ? "98–108% of the design curve, read by hand and its scatter not given; the burning time, fitted "
                    + "to the open blast, hardly matters here (with the extinction limit 104–117%)"
                : burns
                    ? "124–131% of the design curve"
                    : hot
                        ? "43–91% of the design curve, low for light charges (the unsafe side)"
                        : "48–114% of the design curve, half for light charges (the unsafe side)"
            evidence.append(
                StandingEvidence(
                    "Gas pressure in a closed room against UFC 3-340-02 (blastbench gas)", room,
                    "validation.md#gas-pressure-in-a-closed-room"))
        }
        var resolution: [String] = []
        if closeIn {
            let table =
                burning
                ? ValidationTables.closeBurningReflectedImpulse : ValidationTables.closeReflectedImpulse
            if let cells = closeInCells, let column = Self.closeColumn(cells) {
                evidence.append(
                    StandingEvidence(
                        "1 kg burst above rigid ground, 0.3 to 1 m/kg^(1/3)"
                            + (burning ? ", on today's air" : ", the ideal gas") + " (blastbench closeair)",
                        "Reflected impulse \(ValidationTables.span(table, grid: column)) on \(millimetres(cells)) "
                            + "cells per kg^(1/3)",
                        "validation.md#close-in"))
            } else {
                level = max(level, .approximation)
                resolution.append(
                    "Close in, 40 mm cells per kg^(1/3), the coarsest compared, gave "
                        + "\(ValidationTables.span(table, grid: 0)) of the reflected impulse; these are coarser."
                )
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
    enum MaterialClass: Int, Comparable {
        case reinforcedConcrete, plainConcrete, steel, masonry, glass, timber
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        init(_ material: StructureMaterial) {
            switch material.model {
            case .vonMises: self = .steel
            case .timber: self = .timber
            case .concrete:
                self =
                    material.isTransparent
                    ? .glass
                    : material.units != nil
                        ? .masonry : material.steel != nil ? .reinforcedConcrete : .plainConcrete
            }
        }
    }

    var materialClasses: [MaterialClass] {
        Set(structures.flatMap { [$0.material] + $0.solidMaterial.compactMap { $0 } }.map(MaterialClass.init))
            .sorted()
    }

    func structuralResponse() -> ResultStanding {
        var evidence: [StandingEvidence] = []
        var level = EvidenceLevel.compared
        var parts: [String] = []
        let classes = materialClasses
        if classes.contains(.reinforcedConcrete) {
            evidence += [
                StandingEvidence(
                    "A reinforced slab under a blast",
                    "Either way by load. Reads high under the test's load: 113–125 mm against 109 mm measured, and 113 "
                        + "in its repeat (104–115% of the first), on 4 to 32 solid elements through, rising with the "
                        + "mesh towards about 119% and not converged (32 holding on half the step); shells 135 mm (124%); a 5% "
                        + "change in its hand-read load moves it 13–14%, a source's 68 ksi bar yield 9%. Under the "
                        + "contest's lower shot (a scaled record) 79–88% of the peak: too stiff, the unsafe side, "
                        + "though on another shot's shape it reads 97%, so the shortfall may be the scaled record's. "
                        + "Open, the same rig's 8 in slabs (RSCR4–6) 91–106%",
                    "validation.md#structural-response-against-a-real-test"),
                StandingEvidence(
                    "Blind: Mendonça's slabs under an open-air charge (defaults frozen at 047cee3, before the "
                        + "100 µs window; predicted before the measurements were unsealed)",
                    "Unsafe side: the two slabs nearest the charge collapsed, the model's barely cracked. The "
                        + "blast's own peak a tenth to a quarter of meters that likely include the supports' or "
                        + "rigid-body movement. The model's slab responds as its load would have it; that load's "
                        + "large suction was the harness's copying faces at 047cee3, which today's far-field faces "
                        + "do not have, and no bending slab under it reaches the meters, so what remains lies "
                        + "outside the slab's bending (an offset after lift-off, the underside's push, or the load). "
                        + "The declared peaks near the measured were made by an artefact of the sleeping air on "
                        + "landing, fixed since, and group B's scored readings came after a lift-off",
                    "validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge"),
                StandingEvidence(
                    "Blind: Reynolds's high-strength slabs in the contest slab's rig (v0.3.0, b524a9d; predicted "
                        + "before the measurements were unsealed)",
                    "Either way, a little stiff: five slabs 0.77–1.06 of the measured peak (0.87 on average with "
                        + "the closer bars); the sixth, lightly reinforced under the larger load, broken through "
                        + "where the test held at 182 mm (the safe side, its bars' rupture strain assumed); with a "
                        + "typical bar's, calibrated after the reveal, it holds at 161 mm (0.89)",
                    "validation.md#blind-test-3-reynoldss-high-strength-slabs-in-the-blast-load-simulator"),
                StandingEvidence(
                    "A reinforced beam bent to failure",
                    "Peak moment 100–101% on 12 and 24 elements through, failing at 44 mm on 12 and holding on "
                        + "24, against 42 mm; breaking at 11 and 7 mm on 36 and 48 (17% strong, the unsafe side, "
                        + "on 6 under the earlier defaults)",
                    "validation.md#a-reinforced-beam-bent-to-failure"),
                StandingEvidence(
                    "A beam without stirrups failing in shear",
                    "Unsafe side, not converged: 4–11% too strong on 24 to 48 elements, 32% on 12",
                    "validation.md#a-beam-failing-in-shear"),
                StandingEvidence(
                    "Beams struck by a falling weight",
                    "Either way on 16 elements, with stirrups: 12–23% high under light drops, −5% to −1% under "
                        + "heavy; on 24 (earlier defaults), +17% to +28% and −1% to +17%; struck about twice as hard as measured, the "
                        + "reactions up to 40% low; the rate laws were chosen on these tests",
                    "validation.md#beams-struck-by-a-falling-weight"),
                StandingEvidence(
                    "Beams without stirrups struck at rising speeds (Ando)",
                    "Within the 2 mm reading at 1 m/s and 15% at 3 m/s, 22% on average beyond on 16 elements. "
                        + "Once broken, at 5–6 m/s, they follow the strain-rate window's length steeply and not "
                        + "monotonically: windows of 90 to 105 µs give A24-5 30–44 mm, B48-5 65–85 and B36-5 44–55, "
                        + "where rounding moves them 2 mm at most; a broken beam is as uncertain as that choice",
                    "validation.md#convergence-on-todays-defaults"),
                StandingEvidence(
                    "Blind: Hrynyk's slabs struck repeatedly by a falling weight (defaults frozen at 1c85774, "
                        + "before the 100 µs strain-rate window; predicted before the measurements were unsealed)",
                    "First impacts 15–29% too flexible, as the calibrated beams were; once damaged, 17–44% too "
                        + "stiff, springing back to a seventh to a third of the residual",
                    "validation.md#blind-test-1-hrynyks-slabs-struck-by-a-falling-weight"),
                StandingEvidence(
                    "An internal explosion in a reinforced concrete chamber",
                    "Unsafe side, too stiff: its roof's edge left 25 mm up against 95 mm measured (a quarter) "
                        + "with the confined regime's pressed interlock, 27 mm with afterburning and hot air; not "
                        + "converged on 25 mm elements; the wall pressures 0.9 to 1.6 times those measured on either "
                        + "air",
                    "validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber"),
            ]
            parts.append(
                "reinforced concrete errs mostly on the unsafe side, towards too little damage: too strong in "
                    + "shear, too stiff in a full-scale chamber and close in. In bending one slab reads either way, "
                    + "4–15% high under the contest's load and 12–21% low under its lower shot, not converged, and its beams struck on 16 elements come within 12–23%; it "
                    + "springs back too far. Blind, open-air slabs that collapsed were left standing, the rest "
                    + "reading a tenth to a quarter of meters that likely include the supports' movement; blind "
                    + "in the contest's rig, high-strength slabs read 0.77–1.06 where they held and one broke "
                    + "through where the test held")
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
            evidence.append(
                StandingEvidence(
                    "Brick walls' debris (Keys, 2016)",
                    "Loads within 15%; the walls crack at the measured heights but fall as one column, lying "
                        + "1.5–2 m too far out in the open and thrown half as far as measured in a shock tube",
                    "validation.md#brick-walls-debris"
                ))
            if has(.softGround) {
                evidence.append(
                    StandingEvidence(
                        "Brick walls' debris on soft ground (Keys, 2016)",
                        "At 5×10⁷ Pa/m the mean distance 1.36 m against 0.23 and 0.64 m measured (2.10 and 2.15 m "
                            + "on the hard ground); one run of each wall", "validation.md#brick-walls-debris")
                )
            }
            parts.append(
                "masonry's joints verified; brick walls under blasts fall as one column, not in pieces")
        }
        if classes.contains(.glass) {
            level = max(level, .approximation)
            evidence.append(
                StandingEvidence(
                    "A glass pane at 3 m", "Breaks under 1 kg and survives 0.5 g",
                    "validation.md#verification-against-theory"))
            parts.append("glass a brittle concrete, checked only to break and survive")
        }
        if classes.contains(.timber) {
            evidence.append(
                StandingEvidence(
                    "Cross-laminated timber panels in the Ottawa shock tube (Poulin, 2019)",
                    "Static stiffness within 4–13%, peak 12–25% high (flexure, as tested); shots that left the "
                        + "panels elastic stay elastic (0.72–1.21 of the peak deflection), nine of twelve that broke "
                        + "them break or split the model's and three near the threshold hold; the dynamic increase "
                        + "of 1.28 comes from the same shots",
                    "validation.md#cross-laminated-timber-panels-in-a-shock-tube"))
            parts.append(
                "timber compared on CLT panels in a shock tube: stiffness close, strength 12–25% high")
        }
        var resolution: [String] = []
        if let through = elementsThrough, through <= 6, through >= 4, classes.contains(.reinforcedConcrete) {
            resolution.append(
                "\(through) solid elements through the thinnest member: a beam on 6 through was 17% strong in "
                    + "bending, the unsafe side.")
        }
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
                    "Unsafe side, too stiff: left a third to a half as far down as measured",
                    "validation.md#slabs-under-close-in-charges"))
            evidence.append(
                StandingEvidence(
                    "Wu et al.'s slabs with steel in both faces",
                    "Unsafe side under 0.2–0.8 kg, too stiff: 40–70% of the measured peak (S5 and D5 alike with "
                        + "afterburning and hot air); 0.91 and 1.18–1.19 times under 1.6 kg on today's build, two "
                        + "shots on one mesh, either air",
                    "validation.md#slabs-with-steel-in-both-faces"))
            resolution.append(
                String(
                    format: "The structure is %.2f m/kg^(1/3) from a charge, close in, where slabs bend too "
                        + "little.", distance))
        }
        if structures.count > 1 {
            resolution.append(
                "Independent bodies meet through contact between their nodes, the spring and damper of contact "
                    + "within a body, checked for momentum and energy but never against a test; they must start "
                    + "apart and never bond.")
        }
        let configuration = inputs.configuration
        if configuration.airSleepThreshold > 0 || configuration.airSleepCrossings > 0 {
            resolution.append(
                "The air sleeps once quiet or late: a structure moving on is loaded by the frozen air beside "
                    + "where it now is but feels no new flow, and loose debris feels no air at all. For debris "
                    + "in flight or a structure thrown far, keep the air awake (air sleep threshold and "
                    + "crossings 0).")
        }
        // Options a saved structure set that have since been retired, and what applies instead.
        for note in Set(structures.flatMap(\.retiredOptions)).sorted() { resolution.append(note) }
        let summary =
            (parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No structure")
            + (parts.count > 1 ? "; " + parts.dropFirst().joined(separator: "; ") : "") + "."
        return result(
            .structuralResponse, level, summary, evidence: evidence,
            assumptions: [
                "The defaults were chosen with these tests in view: a calibration set as much as a validation "
                    + "set, none run blind.",
                "Blind tests judge the defaults frozen for them: tests 1 (1c85774) and 2 (047cee3) the 50-step "
                    + "strain-rate average that the 100 µs window replaced on 12 October 2026; test 3 judged v0.3.0 "
                    + "(b524a9d), with the window and afterburning and hot air.",
                "Supports are assumed in every structural test, and move the results by 15–25% or more.",
                "Most tests are single specimens.",
                "Lattice-aligned geometry, a staircase of whole cells to the air.",
                "No structural damping beyond the material's own: ringing lasts too long.",
                "Not validated for engineering decisions or the safety of a real structure.",
            ], resolution: resolution,
            documents: ["validation.md#summary", "roadmap.md#limitations-most-important-first"])
    }

    func structuralDamage() -> ResultStanding {
        var evidence = [
            StandingEvidence(
                "A beam without stirrups failing in shear",
                "Unsafe side: fails suddenly, as the test did, but 4–11% too strong on 24 to 48 elements and 32% on 12, not converged",
                "validation.md#a-beam-failing-in-shear"),
            StandingEvidence(
                "Short beams struck to a shear failure (Peterson et al., 2026)",
                "Unsafe side: those with stirrups hold where the tests crushed their strut; the impact force is "
                    + "set by a pad fitted to it, so only the reactions are a comparison",
                "validation.md#short-beams-struck-to-a-shear-failure"),
            StandingEvidence(
                "Beams struck by a falling weight",
                "The beam without stirrups broken by the heavy drop as in the "
                    + "test, but damaged by a light one it survived",
                "validation.md#beams-struck-by-a-falling-weight"),
            StandingEvidence(
                "Blind: Hrynyk's slabs struck repeatedly by a falling weight (defaults before the 100 µs window)",
                "Unsafe side: all three slabs punched in the test, by the second or third impact; the model "
                    + "punched none in four",
                "validation.md#blind-test-1-hrynyks-slabs-struck-by-a-falling-weight"),
            StandingEvidence(
                "Blind: Mendonça's slabs under an open-air charge (defaults before the 100 µs window)",
                "Unsafe side: the two slabs nearest the charge collapsed in the test; the model left both "
                    + "standing, barely cracked",
                "validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge"),
            StandingEvidence(
                "Blind: Reynolds's high-strength slabs (v0.3.0)",
                "Either way: one slab broken through where the test held (the safe side), and no blast face "
                    + "crushed where four of the tests' were (the unsafe side)",
                "validation.md#blind-test-3-reynoldss-high-strength-slabs-in-the-blast-load-simulator"),
        ]
        var level = EvidenceLevel.approximation
        var summary =
            "Errs on the unsafe side, towards too little damage: too strong in shear, struck beams holding "
            + "where the tests crushed their strut. Failure depends on the mesh and, on fine meshes, the time "
            + "step: a beam that holds on 24 elements breaks on 36, a close-in slab holes on 16 only. Breach and "
            + "joints are the least reliable predictions; debris has been compared off slabs and brick walls, "
            + "and collapse once, blind, where both slabs that collapsed were left standing."
        if let distance = structureDistance, distance < 0.75 {
            evidence.append(
                StandingEvidence(
                    "Full-scale slabs under close-in charges",
                    "Unsafe side: spalled only under the charge, on fine air and 12 elements through, and never "
                        + "holed", "validation.md#slabs-under-close-in-charges"))
            evidence.append(
                StandingEvidence(
                    "Yao et al.'s 20 kg over a 4 × 5 m slab, 0.22 m/kg^(1/3)",
                    "Unsafe side: its top face undamaged where the test's cratered 1.02 × 0.76 m, bars exposed, "
                        + "and spalled wider beneath; one test, no measured deflection",
                    "validation.md#yaos-large-slabs"))
            evidence.append(
                StandingEvidence(
                    "Slabs under contact charges (Hupfauf, 2024)",
                    "The far face on the axis 0.9–2.3 times the fit on today's air, with the outline counted by "
                        + "overlap (0.9–1.3 on the 20 cm slabs; 0.88–1.82 at the elements' centres, 1.1–1.7 on the "
                        + "ideal gas), moving as much between builds as between outlines; the loose layer held back rather than thrown, and no "
                        + "slab holed where four were. SN131's close agreement rests partly on crushed bare "
                        + "elements' hourglass forces, not a physical tie",
                    "validation.md#slabs-under-contact-charges"))
            summary +=
                " Close in, unsafe again: slabs spall too little, hold their debris back and are holed only by "
                + "an option, at a stable step to a half and a third of the measured size."
            if distance < 0.15 {
                summary +=
                    " In contact a crushed bare element can run away in some roundings and outlines (two of six "
                    + "of SN144's runs threw nodes at about 2 km/s); two options stop it but move the debris "
                    + "away from the tests."
            }
        }
        if materialClasses.contains(.glass) || materialClasses.contains(.masonry) {
            level = .illustrative
            summary +=
                " Masonry breaks into too few pieces: brick walls fall as one column, lying 1.5–2 m too far out in "
                + "the open, and are thrown half as far as measured in a shock tube. Glass breaking up has no comparison."
        }
        return result(
            .structuralDamage, level, summary, evidence: evidence,
            assumptions: [
                "Concrete broken under a close-in charge is never removed, so no hole opens.",
                "Debris is pushed crudely by the air, as cubes with a fixed drag.",
                "Debris hazard (with rubble particles): pieces still moving at the end fly on in still air to "
                    + "where they land; those that had already landed are taken as they lie, with the energy "
                    + "they then had, which undercounts hazardous debris near the structure.",
                "Collapse is chaotic: a slightly different input gives a different pattern of debris.",
                "Bars rupture at a typical bar's elongation at fracture over a 100 mm window (15% for the "
                    + "default steel): checked only on the side of holding, where the record's bars held, since "
                    + "no test in the record ruptured its bars. Weaker or characteristic bars break sooner.",
                "Results after failure are one draw among roundings of the same arithmetic: another model, "
                    + "compiler or GPU draws again, a harmless rebuild does not. Failed elements, debris speeds "
                    + "and residuals move by about Hupfauf's SN142 far face 61.5–106.3 m/s and SN131's 22.4–27.7 "
                    + "on today's air, and Janney's moment at 60 mm 29–38 kN m; before failure they agree to "
                    + "about 1%.",
            ],
            documents: [
                "concrete-model.md#limitations", "structural-model.md#limitations",
                "validation.md#what-is-missing", "validation.md#convergence-on-todays-defaults",
            ])
    }

    /// Said of the envelopes in a scene with structures, which may move beside them.
    static let envelopesBesideStructures =
        "Beside moving structures, one way: a structure never takes the air at an envelope's faces, and its "
        + "debris passes the envelopes by, neither loading nor damaging them."

    func envelopeDamage() -> ResultStanding {
        let envelopes = inputs.scenario.envelopeObjects.map(\.id)
        let assumed = envelopes.filter { inputs.scenario.envelopeConstruction(for: $0).source == .assumed }
            .count
        let blocks = inputs.scenario.envelopeObjects.filter { object in
            (object.envelope?.solids ?? []).contains { BuildingEnvelope.role($0) == .block }
                && inputs.scenario.envelopeConstruction(for: object.id).facadePaneM.map {
                    $0.x > 0 && $0.y > 0
                } != false
        }.count
        let vented = inputs.ventsGlazing && inputs.scenario.hasEnvelopePanes
        return result(
            .envelopeDamage, .approximation,
            "One way, from each component's load, "
                + (vented
                    ? "with the air seeing each building whole but for its glazing, which opens in the air as "
                        + "it breaks: "
                    : "with the air seeing the building whole and the inside a one-way fill: ")
                + "glass breakage and its time, concrete panels' rotation between fixed and simply supported "
                + "edges, and freestanding walls as cantilevers from their foot, as approximations; brick panels, "
                + "profiled steel sheeting and the inside pressure through broken panes illustrative.",
            evidence: [
                StandingEvidence(
                    "UFC 3-340-02 §2-15.4's loads on the walls inside, through an open front window (16 cases, "
                        + "2–16 psi)",
                    vented
                        ? "Glazing vented: 0.31–1.22 of the UFC's (the back walls 0.74–1.22)"
                        : "The one-way fill, as venting cannot run here: 0.15–0.42 of the UFC's",
                    "validation.md#inside-buildings-against-ufc-3-340-02s-loads-through-openings"),
                StandingEvidence(
                    "UFC 3-340-02's worked examples 3A-5, 3A-6(a) and 4A-1", "Within 1%",
                    "building-envelopes.md#one-way-damage-single-degree-of-freedom"),
                StandingEvidence(
                    "The same buildings free to respond (19 runs, 2–500 kg)",
                    "Glass: all 45 panes the detailed buildings break, a median 0.3 ms later, and 6 more; "
                        + "the walls facing the charge between the fixed and simply supported bounds, roofs "
                        + "and walls beside a failing one beyond both",
                    "building-envelopes.md#one-way-damage-single-degree-of-freedom"),
                StandingEvidence(
                    "Freestanding walls against measurement: Alsubaei's perimeter walls and Keys's brick walls",
                    "6 of 7 outcomes as measured, built as tested; the blockwork's top within 16% (32 mm "
                        + "against 28); the half-scale concrete wall 5.4° where light cracking was seen, the safe "
                        + "side (the detailed model 2.1°)",
                    "building-envelopes.md#freestanding-walls"),
                StandingEvidence(
                    "One-way reinforced masonry walls under measured loads (Hayman, 2014)",
                    "1.16–1.91 times the measured mid-height displacement, a level worse on four of five, the "
                        + "one that blew out failed: the safe side",
                    "building-envelopes.md#one-way-walls"),
                StandingEvidence(
                    "Slabs held on their edges against measurement (the contest slab, Reynolds, Wu, Wang, Mendonça)",
                    "Under measured loads the measured peak between the fixed and simply supported bounds on all "
                        + "eight; under the model's own close-in loads under-read, as the detailed model is, and "
                        + "Mendonça's two collapses missed",
                    "building-envelopes.md#slabs-held-on-their-edges"),
                StandingEvidence(
                    "Monk and Clubley's annealed windows in the Shoeburyness tunnel (12 timed panes)",
                    "Every pane broken, as in the tests, at 0.82–1.07 of the measured time and 0.69–1.15 of the "
                        + "deflection", "validation.md#window-glass"),
                StandingEvidence(
                    "ASTM E1300's load resistance of eight annealed panes",
                    "Its stresses within 8%; panes break at 0.57–0.72 of its load resistance (the safe side)",
                    "validation.md#the-threshold-against-astm-e1300"),
            ],
            assumptions: [
                "Compared with measurement as freestanding and one-way walls, as slabs held on their edges "
                    + "(mostly on two; one panel clamped all round), and glass only under a load far past what "
                    + "breaks it (its threshold against E1300's design resistance); references on one mesh and "
                    + "one air grid.",
                "Reinforced blockwork is judged as a concrete of the masonry's strength, graded by the "
                    + "concrete's limits; a freestanding wall's cap adds only the mass its construction gives.",
                "Profiled steel sheeting spans one way between its rails or purlins by UFC 3-340-02's method for "
                    + "cold-formed panels on the maker's effective section, graded by PDC-TR 06-08's limits for "
                    + "deck whose membrane action its fixings limit, and blown off when its dynamic reaction passes "
                    + "what its screws hold by EN 1993-1-3; no blast test of cladding or its fixings compared.",
                "Each panel alone: frame action, junctions and neighbouring walls are not seen; a panel past "
                    + "2° is flagged as beyond the one-way model.",
                "Glass is annealed, on Moore's large-deflection plate, simply supported, breaking at E1300's "
                    + "median strength with the whole pane at its largest stress.",
                "The glass's hazard is graded by GSA's conditions and ASTM F1642's ratings from where it "
                    + "would land, thrown whole from the pane's middle at its speed on breaking, the load pushing "
                    + "it on, over a 0.9 m sill; no test's fragments compared. A cased charge's fragments hole a "
                    + "pane past Kim et al.'s breaking momentum, breaking it then if first. With glazing vented "
                    + "it opens in the air then, at a time from the fragments flown in still air before the run, "
                    + "independent of the blast's effect on their flight: fine near the charge, where fragments "
                    + "lead the shock.",
                "Concrete by ASCE/SEI 59-11's limits for single-reinforced slabs; brick cracked or fallen, with "
                    + "no arching, a wall rocking against the weight of its own masonry above it.",
            ]
                + (assumed > 0
                    ? [
                        "\(assumed) of \(envelopes.count) envelopes' construction assumed (0.2 m concrete, 0.3%)."
                    ]
                    : [])
                + (blocks > 0
                    ? [
                        "\(blocks) buildings of solid blocks (as map buildings are) taken to hold a window "
                            + "in each storey of each façade, 1.2 × 1.5 m unless set, judged on the storey's "
                            + "mean load."
                    ]
                    : [])
                + (inputs.scenario.structuralObjects.isEmpty ? [] : [Self.envelopesBesideStructures]),
            documents: ["building-envelopes.md#one-way-damage-single-degree-of-freedom"])
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
                    "Kingery–Bulmash, a rigid wall facing the charge, on the shipped air",
                    "Reflected impulse 93–113% from 1 m/kg^(1/3) on 0.25 m cells",
                    ValidationTables.burningDocument),
            ],
            assumptions: [
                "Fixed geometry: no broken windows, deformation, collapse or changing shielding.",
                "Openings and walls thinner than a cell can vanish.",
            ] + (inputs.scenario.structuralObjects.isEmpty ? [] : [Self.envelopesBesideStructures]),
            documents: ["building-envelopes.md#scope-and-verification"])
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
        } else if !has(.hotAir) {
            assumptions.append(
                "The comparisons were run with afterburning and hot air, today's defaults; afterburning alone "
                    + "radiates more (29% of the street's charge against 21%).")
        }
        var resolution: [String] = []
        if inputs.cellSize >= 0.5 {
            resolution.append(
                "On 0.5 m cells the charge's gas is spread over large cells and comes out cooler (0.5 kg starts "
                    + "under 800 K).")
        }
        return result(
            .thermal, .illustrative,
            "Set against two TNT fireballs measured by one group: a 100 kg run, scaled, exceeds the 100 t "
                + "shot's total "
                + (cooling
                    ? "two to three and a half times, the gas cooling as it radiates"
                    : "three to five and a half times")
                + ", and Dial Pack's 500 t pulse comes out far too faint early and two to five times too bright "
                + "after a second.",
            evidence: [
                StandingEvidence(
                    "The 100 t TNT shot's measured radiation, against a 100 kg run scaled by the cube root",
                    cooling
                        ? "Exceeded two to three and a half times, with the gas cooling"
                        : "Exceeded three to five and a half times",
                    "thermal-radiation.md#the-volume-against-the-shape"),
                StandingEvidence(
                    "Dial Pack, 500 t of TNT, at full size on 2 to 8 m cells",
                    "A sixth as bright at the first maximum, dark from 40 to 350 ms, two to five times too "
                        + "bright after 1 s", "validation.md#the-fireballs-radiation-against-dial-pack"),
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
        } else if !has(.hotAir) {
            assumptions.append(
                "The comparison with Church's clouds was made with afterburning and hot air together, today's "
                    + "defaults; afterburning alone was not run against them.")
        }
        return result(
            .cloud, .illustrative,
            "Either way: its top within 4% on average of 22 TNT clouds Church measured, for their first two "
                + "minutes, a geometric spread of 21% shot by shot, not a bound; it falls behind them later. It "
                + "needs afterburning, whose burning time was fitted to the open blast, and the entrainment "
                + "coefficient's plausible range moves the tops −9% to +13%.",
            evidence: [
                StandingEvidence(
                    "Church's 22 detonations of 54 to 1,270 kg of TNT",
                    "Cloud top within 4% on average, 21% shot "
                        + "by shot, from half a minute to two minutes",
                    "fireball-rise.md#against-churchs-measured-clouds")
            ], assumptions: assumptions, documents: ["fireball-rise.md#limitations"])
    }

    func fragments() -> ResultStanding {
        let evidence = [
            StandingEvidence(
                "Cooper's worked examples 27.7 and 27.8 (Mott's counts, Gurney's speed)",
                "The same, to rounding",
                "fragments.md#against-coopers-data"),
            StandingEvidence(
                "Cooper's Fig. 27.13: a cast-iron aerial bomb's counted fragments, 0.13 to 8.8 g",
                "Mott's form within a factor of 1.36 (rms), too many small and too many of the largest; "
                    + "Grady's exponential (massExponent 1) within 1.12", "fragments.md#against-coopers-data"),
            StandingEvidence(
                "Hansche and Rinehart's measured drag of tumbling cubes, Mach 0.5 to 3.5 (as Moxnes et al. 2017 restate it)",
                "The drag curve itself; Hoerner's fixed orientations (Cooper's Figs. 27.15–27.18) put the "
                    + "distance to 79 J 30% shorter to 50% longer", "fragments.md#against-coopers-data"),
            StandingEvidence(
                "UFC 3-340-02's worked Examples 4A-10 to 4A-12 (fragments into concrete), and its steel "
                    + "plate equation against THOR's mild steel",
                "The examples within 1%; the two steel methods' speeds to perforate within 2%; no "
                    + "penetration test compared", "fragments.md#what-fragments-do-to-what-they-strike"),
        ]
        let shared = [
            "One way: fragments do not push back on the air or the structure, and stop where they first hit.",
            "Tumbling cubes of the casing's steel, no break-up or ricochet. What they strike is judged one "
                + "way by UFC 3-340-02 (concrete; masonry as concrete of its strength, for want of its own "
                + "method), THOR (metal plates) and a measured breaking momentum (glass); a fragment stops at "
                + "the first surface, through or not, and does not load it.",
            "Hazard distance: the DDESB's, where landings of 79 J or more on open ground fall below one per "
                + "55.7 m², in 8 directions; as good as the ranges, which no arena test has checked.",
        ]
        guard inputs.fragments?.mottFactor != nil else {
            return result(
                .fragments, .illustrative,
                "Their number is chosen, not derived: give the casing's thickness and diameter for Mott's.",
                evidence: evidence,
                assumptions: ["The number of fragments is the description's, sharing the casing's mass."]
                    + shared,
                documents: ["fragments.md#limitations"])
        }
        return result(
            .fragments, .approximation,
            "Mott's masses and number, Gurney's speed and measured drag: the recognised method, checked against "
                + "Cooper's data; no arena test of speeds or ranges.",
            evidence: evidence,
            assumptions: [
                "Mott's B for mild steel cylinders, Cooper's Table 27.2; other metals and shapes are not covered."
            ] + shared, documents: ["fragments.md#limitations"])
    }

    func crater() -> ResultStanding {
        result(
            .crater, .approximation,
            "Cooper's cube-root scaling for the apparent crater's radius by soil and height of burst, with "
                + "Kinney and Graham's one-sigma scatter of a third; the depth is a rule of thumb, slumped below a "
                + "shallow water table.",
            evidence: [
                StandingEvidence(
                    "Six measured craters: three 500-ton TNT shots at Suffield, Sailor Hat, Minor Scale and Beirut",
                    "Five of six apparent diameters within a third (the Suffield shots 1.04–1.26); the three wet "
                        + "sites' depths 0.84–1.41 of the estimate with the water table near the surface",
                    "cratering.md#against-measured-craters")
            ],
            assumptions: [
                "The crater does not act on the blast: it forms after the blast has gone, so the air keeps the "
                    + "ground as it was.",
                "Bursts on or above the ground, not buried ones.",
                "Depth and lip are rules of thumb; below a water table the walls are taken to slump to 10–15°, "
                    + "and flowing fill can leave a shallower crater still.",
            ], documents: ["cratering.md#limitations"])
    }

    func halfSpaceGroundShock() -> ResultStanding {
        result(
            .groundShock, .illustrative,
            "A half-space about the charge, checked against Lamb's problem, Cole and Huth and Haskell; "
                + "against one measured surface burst, its vertical velocity 15 to 90 times too high (the safe "
                + "side), its horizontal within one and a half (elastic) to two and a half (yielding) times "
                + "at 21 m but 10 to 20 times too high at 42 m.",
            evidence: [
                StandingEvidence(
                    "The axisymmetric solver against Lamb's problem, Cole and Huth's moving load and Haskell's "
                        + "Rayleigh dispersion",
                    "Within 8% of Lamb's surface pulse; 5–8% behind a superseismic front; 4% in phase speed",
                    "ground-shock-outrunning.md#stage-1-the-solver-and-its-checks"),
                StandingEvidence(
                    "Xia et al.'s 1 t surface burst, 0.5 m deep at 21 and 42 m",
                    "Vertical 15–60 times the measured accelerations' integral; horizontal 1.5 times at 21 m, "
                        + "15–20 times at 42 m",
                    "ground-shock-outrunning.md#stage-2-against-xia-et-al"),
                StandingEvidence(
                    "Soil that yields, against the bilinear column and the same burst",
                    "The column within 4–6%; at Xia's gauges vertical 16–90 times, horizontal 2.1–2.4 times at "
                        + "21 m and 10–11 times at 42 m; falling as R^(-1.5) against the measured R^(-3.3) to "
                        + "R^(-3.8)",
                    "ground-shock-outrunning.md#stage-3-soil-that-yields"),
            ],
            assumptions: [
                "Axisymmetric about the charge: no buildings or terrain. Elastic unless its layers are given "
                    + "a friction angle or unloading speed; then compaction and a Mohr–Coulomb cone, untested "
                    + "against measured soil.",
                "The charge's direct source: on elastic soil calibrated once against UFC 3-340-01 at "
                    + "8 ft/lb^(1/3), its waves falling away as r^(-1/2) against UFC's r^(-2.5); on yielding soil "
                    + "the crater's share of the energy, within 0.3–1.7 times UFC from 4 to 16 ft/lb^(1/3).",
                "One way: the ground stays rigid for the air.",
                "Not for design, buried services or vibration limits.",
            ], documents: ["ground-shock-outrunning.md"])
    }

    func groundShock() -> ResultStanding {
        let column = has(.soilColumn)
        if has(.halfSpace) { return halfSpaceGroundShock() }
        return result(
            .groundShock, .illustrative,
            column
                ? "A layered soil column under each point, checked against closed-form solutions; against "
                    + "one measured surface burst, its vertical velocity 20 to 80 times too high (the safe side), "
                    + "while the horizontal motion that dominated it is not modelled (the unsafe side)."
                : "The design manuals' one-dimensional air-induced ground shock; against one measured surface "
                    + "burst, its vertical velocity 20 to 80 times too high (the safe side), while the horizontal "
                    + "motion that dominated it is not modelled (the unsafe side).",
            evidence: (column
                ? [
                    StandingEvidence(
                        "Uniform, layered and bilinear soil columns against closed-form solutions",
                        "Within 1% for pulses, reflections and resonance; 3–8% for bilinear unloading",
                        "ground-shock.md#checks")
                ] : [])
                + [
                    StandingEvidence(
                        "Xia et al.'s 1 t surface burst, 0.5 m deep at 21 and 42 m",
                        "Vertical velocity 20–30 and 50–80 times the measured accelerations' integral; "
                            + "within three times a clipped velocity gauge; the measured motion mostly horizontal",
                        "ground-shock.md#against-measured-ground-motion")
                ],
            assumptions: [
                "Away from the charge only; no direct-induced shock or crater.",
                "No motion carried by the ground's own wave where it outruns the air, which dominated the one "
                    + "measured test.",
                "The ground stays rigid for the air.",
                "Not for design, buried services or vibration limits.",
            ], documents: ["ground-shock.md#limitations"])
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
