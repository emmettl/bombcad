import Foundation
import simd

// Structures: the standing's entries, fields and results for the structure's part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of the structure's options; `entry(for:)` sends them here.
    static func structureEntry(for option: ModelOption) -> Entry {
        let structure: [ResultKind] = [.structuralResponse, .structuralDamage, .collapse]
        let air: [ResultKind] = [.peakOverpressure, .impulse]
        switch option {
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
        case .assumedStrainCracking:
            return Entry(
                title: "Cracked elements that bend in their concrete", affects: structure,
                limit: .approximation,
                note:
                    "Cracked concrete elements work at eight points with an assumed strain and no hourglass "
                    + "control. Right against section analysis, but it sends a struck beam 20% further than its "
                    + "test and leaves a shear beam 27% strong on 12 elements, so it is not a default.",
                document:
                    "concrete-model.md#an-element-that-bends-in-its-cracked-concrete-stage-3-20-october-2026")
        case .perfectMembers:
            return Entry(
                title: "Steel members perfectly straight", affects: structure, limit: .approximation,
                note: "Without Eurocode 3's equivalent bow a strut of middling slenderness carries its "
                    + "perfect load, up to 1.5 times the design curves' resistance near λ̄ = 1: the unsafe side.",
                document: "shell-model.md#buckling")
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
                title: "Profiled steel sheeting", affects: [.structuralDamage], limit: .approximation,
                note:
                    "Sheets are a skin with their ribs as beams, their thin flanges buckling (collapsing or "
                    + "keeping their effective width by how they buckle), screwed to their rails and purlins "
                    + "by screws that pull through. Langdon's corrugated panels: 10 of 13 permanent sets within "
                    + "half to twice of measured. ADBLAST's screwed cladding in air: first deflection 0.90–1.35 "
                    + "of measured on all ten tests; with the buckled flanges' folds straightened at their "
                    + "hinges' strength, what is left after misses by 27 mm on average (66 without), the 1.5 mm "
                    + "sheets level or lifted as tested, the 0.75 mm still 14–40 mm down where they ended within "
                    + "23 mm of level. Cladding torn off a deforming purlin is not compared. Sheeted purlins and rails are held straight by the "
                    + "screws, which under uplift, their free flange in compression, is the unsafe side.",
                document: "profiled-sheeting.md#against-adblasts-cladding-tests")
        case .steelConnections:
            return Entry(
                title: "Steel connections that hinge and fracture", affects: [.structuralDamage],
                limit: .approximation,
                note:
                    "Each steel beam that stops at a joint is held to it by a hinge that turns plastically at the "
                    + "connection's moment and lets the beam go at its fracture turn: a welded flange (WUF-B) or "
                    + "reduced beam section from NIST TN 1669, a fin plate from Weigand and Berman's thirteen "
                    + "tests, bolted end plates from Culache's tests loaded in 40 ms. Under a column's removal "
                    + "the hinged assemblies fail 5–27% past the measured drop at 1.07–1.16 of the measured "
                    + "load, where rigid joints never fail; but their fracture turns come from those slow tests. "
                    + "A hinge is independent of rate: from Culache's slow tests it would read bolted end plates "
                    + "13–41% too strong and 1.5–1.7 times too ductile at a blast's rate, and the welded and "
                    + "fin-plate types, from slow tests, may be too ductile too.",
                document: "shell-model.md#steel-connections")
        case .pitchedShells:
            return Entry(
                title: "Shells at a pitch", affects: structure, limit: .approximation,
                note:
                    "Roof slopes meshed in their own planes: a plate cantilevered at 30° bends within 2% as the "
                    + "flat one does under its weight's share across it. Rafters are smeared into a plate, not "
                    + "beams; the tiles hang on their nibs by an assumed 5 kPa, not on friction alone; the "
                    + "terraced row's 40° is assumed (plain tiles want 35° or more). No pitched roof under "
                    + "blast was found to compare with. Walls turned in plan, and curved walls' chords, are "
                    + "meshed the same way, upright, each node within reach of what they meet following its "
                    + "nearest node; not compared with a test either.",
                document: "shell-model.md#shells-at-a-pitch")
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
        case .footingsOnSlope:
            return Entry(
                title: "Footings on a slope", affects: structure, limit: .approximation,
                note:
                    "Level footings stepped into the slope, their sides buried and their earth pressures set "
                    + "by the ground round them, their bearing capacity cut by Vesić's (1 − tan β)², 0.88–1.39 "
                    + "of Meyerhof's on a slope's face and 0.85–1.14 near a 20° crest; their stiffness the level "
                    + "ground's. Judged on closed forms only: no measured footing near a slope under fast "
                    + "loading was found.",
                document: "validation.md#footings-on-a-slope")
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
        default:
            preconditionFailure("\(option) is not one of the structure's options")
        }
    }

    /// The fields of the structure's inputs; part of `fields`.
    static let structureFields: [String: Field] = [
        // The structure.
        "StructureModel.solids": .input,
        "StructureModel.openings": .input,
        "StructureModel.material": .input,
        "StructureModel.elementSize": .input,
        "StructureModel.fixedBase": .option([.freeBase]),
        "StructureModel.baseAnchorage": .option([.baseConnections, .footings]),
        "StructureModel.reinforcement": .input,
        "StructureModel.inclinedBars": .option([.inclinedBars]),
        "StructureModel.solidInclinations": .option([.pitchedShells]),
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
        "StructureModel.springSupports": .input,
        "StructureModel.sheetFastenings": .input,
        "StructureModel.memberImperfections": .option([.perfectMembers]),
        "StructureModel.bucklingCurve": .input,
        "StructureModel.solidBucklingCurves": .input,
        "StructureModel.steelConnection": .option([.steelConnections]),
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
        "StructureModel.assumedStrainCracking": .option([.assumedStrainCracking]),
        "StructureModel.retiredOptions": .input,
        // The regime picks defaults for the options above (`StructuralRegime`); what it turns on
        // is read through those options, so the regime itself is an input of the scene.
        "StructureModel.regimeOverride": .input,
        "StructureModel.loadingOverride": .input,
        "StructureModel.regimeDefaults": .input,
        "StructureModel.detectedRegime": .input,
        "StructureModel.ground": .input,
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
        "StructureMaterial.localBuckling": .input,
        "StructureMaterial.rateLaw": .input,
        "StructureMaterial.interlayerThickness": .input,
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
        "Anchorage.closingGap": .input,
        "Anchorage.frictionExponent": .input,
        "Anchorage.frictionReferencePressure": .input,
        "Anchorage.solids": .input,
        "Anchorage.partners": .input,
        "Anchorage.footing": .option([.footings, .cyclicSand, .footingsOnSlope]),
        "Anchorage.side": .input,
        "Anchorage.jointNormal": .input,
        "Anchorage.betweenParts": .option([.jointsBetweenParts]),
    ]
}

extension StandingScene {
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
                        + "reactions up to 40% low; the rate laws were chosen on these tests. The agreement leans on "
                        + "the elements' hourglass control: an element without it sends the heavy drop 20% further "
                        + "and the light one breaks up (low)",
                    "validation.md#hourglass-control"),
                StandingEvidence(
                    "Beams without stirrups struck at rising speeds (Ando)",
                    "Within the 2 mm reading at 1 m/s and 15% at 3 m/s, 22% on average beyond on 16 elements. "
                        + "Once broken, at 5–6 m/s, they follow the strain-rate window's length steeply and not "
                        + "monotonically: windows of 90 to 105 µs give A24-5 30–44 mm, B48-5 65–85 and B36-5 44–55, "
                        + "where rounding moves them 2 mm at most; a broken beam is as uncertain as that choice. Like "
                        + "Saatci's, their agreement leans on the elements' hourglass control (low)",
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
                        + "with the confined regime's pressed interlock, on today's air with the open faces at the "
                        + "clearance rule (27 mm in the test's tighter box); not "
                        + "converged on 25 mm elements; the wall pressures 0.9 to 1.6 times those measured on either "
                        + "air",
                    "validation.md#an-internal-explosion-in-a-reinforced-concrete-chamber"),
            ]
            parts.append(
                "reinforced concrete errs mostly on the unsafe side, towards too little damage: too strong in "
                    + "shear, too stiff in a full-scale chamber and close in. In bending one slab reads either way, "
                    + "4–15% high under the contest's load and 12–21% low under its lower shot, not converged, and its beams struck on 16 elements come within 12–23%, leaning on the elements' hourglass control; it "
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
            level = max(level, .compared)
            evidence += [
                StandingEvidence(
                    "Elastic bars and cantilevers",
                    "Wave speed, tip deflection and first period within 5% of "
                        + "theory", "validation.md#verification-against-theory"),
                StandingEvidence(
                    "Steel struts buckling (blastbench buckling)",
                    "Straight, elastic buckling within 2% of Euler; bowed by default, 0.97–1.02 of Eurocode 3's "
                        + "curves a, b and c over slenderness 0.2–2; an impact's buckled wavelength 1.03–1.20 times "
                        + "Lindberg's", "shell-model.md#buckling"),
                StandingEvidence(
                    "Kenny's strips struck by a drop hammer (steel and aluminium, 137–550 mm, 6.2 m/s)",
                    "Final deflection of the peak buckle, default bows: 13 of 16 series within half to twice "
                        + "(steel 1.26–3.68, aluminium 0.71–1.70); with the measured bows 15 of 16 (0.45–1.97); "
                        + "the buckle near mid-length where the tests' lay near the clamp; the hammer's 10 mm stroke "
                        + "read from the set-up", "shell-model.md#buckling"),
                StandingEvidence(
                    "Nassr's steel beams and columns in the open (W150 and W200, 50–250 kg of ANFO)",
                    "With the steel's strain-rate law by grade, unfitted: beams 0.57–1.12 of the measured "
                        + "deflection, columns 0.30–1.61; the beams near elastic and the curtain shot's within 14%; "
                        + "a column bent about its weak axis 1.6 times; low where the readings likely include the "
                        + "frame's movement", "validation.md#steel-beams-and-columns-in-the-open"),
            ]
            parts.append(
                "steel members compared with one series of blasted beams and columns, within half to twice "
                    + "either way; their yield rising with strain rate by Cowper and Symonds's law, mild steel's "
                    + "constants (Jones) to 300 MPa and ERDC's measured A992 and A572 grade 50 above; their "
                    + "connections not compared at blast rates")
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
                    "Loads within 15%; the walls crack at the measured heights but fall as one column where the "
                        + "tests' folded, so how they come apart is wrong; their debris lies 1.0–1.5 m too far out "
                        + "in the open, the safe side for its reach, and is thrown half as far as measured in a "
                        + "shock tube, the unsafe side",
                    "validation.md#brick-walls-debris"
                ))
            if has(.softGround) {
                evidence.append(
                    StandingEvidence(
                        "Brick walls' debris on soft ground (Keys, 2016)",
                        "At 5×10⁷ Pa/m the mean distance 1.21–1.63 m against 0.23–0.64 m measured (1.62–1.77 m "
                            + "on the hard ground); one run of each wall", "validation.md#brick-walls-debris")
                )
            }
            evidence.append(
                StandingEvidence(
                    "Terraced brick houses graded against wartime bomb damage (Gilbert, 1994)",
                    "From 96 kg, with the solid one-brick walls most of the surveyed houses had, within a "
                        + "category of the surveyed median at every distance to 23 m by 0.3 s (one above beyond "
                        + "14 m), the fronts standing by arching between the party walls; the 1930s cavity row's "
                        + "front leaves go over by 0.3 s, one or two categories worse than surveyed beyond 11 m",
                    "validation.md#terraced-houses-against-wartime-bomb-damage"))
            parts.append(
                "masonry's joints verified; brick walls under blasts fall as one column, not in pieces; "
                    + "cavity-walled brick houses too damaged at the longer ranges of wartime bombs")
        }
        if classes.contains(.glass) {
            level = max(level, .approximation)
            evidence.append(
                StandingEvidence(
                    "A glass pane at 3 m", "Breaks under 1 kg and survives 0.5 g",
                    "validation.md#verification-against-theory"))
            parts.append("glass a brittle concrete, checked only to break and survive")
            let laminated = structures.contains { model in
                ([model.material] + model.solidMaterial.compactMap { $0 }).contains {
                    $0.interlayerThickness != nil
                }
            }
            if laminated {
                evidence.append(
                    StandingEvidence(
                        "Laminated panes as shells (Osnes et al., 2019; Hooper, 2011)",
                        "Ten of fifteen shock-tube panes crack or hold as measured at E1300's median strength, "
                            + "the cracked ones going 0.80–1.28 of the measured deflection untorn; six of eight "
                            + "bonded panes leave their silicone at 0.87–1.24 of the measured speed, the two "
                            + "largest as soon as they crack",
                        "validation.md#laminated-glass"))
            }
        }
        if classes.contains(.timber) {
            evidence.append(
                StandingEvidence(
                    "Cross-laminated timber panels in the Ottawa shock tube (Poulin, 2019)",
                    "Strength along the grain calibrated on the static tests (stiffness within 4–13%); all twenty "
                        + "shots classified as tested, the eight that left the panels elastic at 0.72–1.21 of the "
                        + "peak deflection; flexure always breaks first, where five broke in rolling shear; the "
                        + "dynamic increase of 1.28 comes from the same shots",
                    "validation.md#cross-laminated-timber-panels-in-a-shock-tube"))
            evidence.append(
                StandingEvidence(
                    "Glulam beams in the Ottawa shock tube (Lacroix, 2017)",
                    "Calibrated on the static tests; the 137 mm beams' elastic shots 1.06–1.30 of measured, all "
                        + "five destructive shots broken at 28–29 mm against 21–31; deep narrow beams meshed as "
                        + "walls 43% too stiff in their plane",
                    "validation.md#glulam-beams-in-a-shock-tube"))
            evidence.append(
                StandingEvidence(
                    "Cross-laminated timber buildings at Tyndall, 22.9 m from 14.5–90 kg (Weaver et al., 2017)",
                    "The front's impulse within 5% of the report's, the faces 4 m/kg^(1/3) out; the first storey "
                        + "inbound 0.61–0.62 of measured on the two lighter charges and 1.9 times on the heaviest, "
                        + "where the front broke more than the test's (1.5–1.6 on the balloon start, as more or less "
                        + "of it broke), the second storey 1.05–1.4 times, rebound 51–168%",
                    "validation.md#cross-laminated-timber-buildings-at-tyndall"))
            parts.append(
                "timber compared on CLT panels and glulam beams in a shock tube, its strength calibrated, and on "
                    + "full-scale CLT buildings")
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
                        + "afterburning and hot air); 0.90 and 1.19 times under 1.6 kg on the mapped start, the open "
                        + "faces at the clearance rule, two shots on one mesh, in all three roundings",
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
        // Open faces too near: their reflections move the response after the positive phase.
        if let note = inputs.scenario.tightFacesNote {
            resolution.append(
                note + " On Tyndall's CLT building a domain this tight gave 29 mm at the first storey where "
                    + "18 mm is converged.")
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
            + "joints are the least reliable predictions; debris has been compared off slabs and brick walls. "
            + "A storey lost or a structure down is collapse, a result of its own (illustrative)."
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
                " Masonry breaks into too few pieces: brick walls fall as one column, lying 1.0–1.5 m too far out in "
                + "the open (the safe side for their reach) and thrown half as far as measured in a shock tube (the "
                + "unsafe side). Glass breaking up has no comparison."
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

    /// Parts of the structure losing their support and falling: a storey lost, a structure down,
    /// collapse spreading. Illustrative: no compared case of collapse agreed. A structural system's
    /// collapse may rise to an approximation only once a compared collapse case of that system
    /// agrees within its band, and none does yet.
    func collapse() -> ResultStanding {
        result(
            .collapse, .illustrative,
            "Not compared where it agreed: collapse has been compared once for slabs, blind, and missed (both "
                + "slabs that collapsed left standing), and for brick houses against wartime surveys, within a "
                + "category by 0.3 s with solid walls but toppling cavity walls' fronts (one or two categories "
                + "too severe). Steel "
                + "connections' fracture comes from slow column-removal tests, and no frame, large-panel block "
                + "or storey has been compared falling. The local damage's standing does not carry over to it.",
            evidence: [
                StandingEvidence(
                    "Blind: Mendonça's slabs under an open-air charge",
                    "Unsafe side: the two slabs nearest the charge collapsed in the test; the model left both "
                        + "standing, barely cracked",
                    "validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge"),
                StandingEvidence(
                    "Terraced brick houses against the Second World War's bomb surveys (Gilbert, Jarrett)",
                    "Solid one-brick walls, as most surveyed houses had: within a category to 23 m by 0.3 s, the "
                        + "fronts standing. Cavity walls: by 0.3 s the cracked front leaves go over, one or two "
                        + "categories too severe beyond 11 m: the safe side",
                    "validation.md#terraced-houses-against-wartime-bomb-damage"),
                StandingEvidence(
                    "Beirut, 2020: 0.5 m stone carrying the masonry above it",
                    "Falls in 8 of 293 buildings at 0.5–0.75 km, where 7 of GEER's 13 sandstone houses partly "
                        + "collapsed; not converged, and once matched by an error",
                    "validation.md#a-district-beirut-2020"),
                StandingEvidence(
                    "Alsubaei's blockwork wall under 125 kg",
                    "Collapses, as in the test: one freestanding wall, not a structure",
                    "validation.md#perimeter-walls-under-field-blasts"),
                StandingEvidence(
                    "Steel connections: NIST TN 1669's and Weigand and Berman's slow column-removal tests",
                    "Their fracture turns are taken from these tests, a calibration; no frame has been compared "
                        + "losing a column or falling",
                    "validation.md#steel-beams-and-columns-in-the-open"),
                StandingEvidence(
                    "Large-panel flats against the Ronan Point inquiry's estimates",
                    "The inquiry's estimates of what each wall needed, not measurements; the progressive "
                        + "collapse is the model's alone",
                    "large-panel-flats.md#against-the-inquirys-estimates"),
                StandingEvidence(
                    "Large-panel flats coming down: today's element against assumed strain (a range)",
                    "Not a test: the spread from one cause, the hinges' energy taken by hourglass control or "
                        + "by the concrete, on the whole-event runs' ground with Coulomb friction 0.6. Twelve "
                        + "storeys: 237–309 m² of floor down, 11–12 storeys past 15%, 22,600–52,400 elements "
                        + "failed, 34–78 t of rubble; three storeys: none to 74% of the floor down. The debris "
                        + "comes to rest, 99% of it within 1.5–7.4 m of the plan. Assumed strain is the more "
                        + "damaging end but for the twelve storeys' debris reach (5.8 against 7.4 m), and errs "
                        + "that way on the member tests; neither end is a bound",
                    "whole-event.md#adopted-ground-friction-06-30-october-2026"),
                StandingEvidence(
                    "Large-panel flats coming down on a frictionless ground (the runs before 30 October)",
                    "Not a test: on the solver's frictionless ground broken pieces slide on for seconds, "
                        + "99% of the debris out to 16.9 m and growing when the runs ended, and three storeys "
                        + "lose 15% of their floor with today's element where with friction they stand. "
                        + "Twelve storeys: 245–321 m² of floor down",
                    "whole-event.md#ground-friction-30-october-2026"),
            ],
            assumptions: [
                "Collapse is chaotic: a slightly different input, rounding or mesh gives a different pattern and "
                    + "extent.",
                "Failure does not converge with the mesh or the step on today's defaults, and collapse "
                    + "follows from failure.",
                "Not validated for engineering decisions or the safety of a real structure.",
            ],
            documents: ["validation.md#summary", "standing.md#collapse"])
    }
}
