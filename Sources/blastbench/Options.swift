import BlastCore
import Foundation
import Metal
import simd

// The command line's options and the helpers the commands share.
// Split from main.swift (emmettl/bombcad-work#51).

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func flag(_ name: String) -> Bool { arguments.contains("--\(name)") }

func preset(named name: String?) -> ScenarioPreset {
    switch name {
    case "open": .openGround
    case "single": .singleBuilding
    case "courtyard": .courtyard
    case "wall": .blastWall
    case "box": .concreteBox
    case "frame": .frame
    case "infill": .infilledFrame
    case "storeys": .threeStorey
    case "tall": .tallFrame
    case "tower": .coreTower
    case "office": .officeTower
    case "column": .columnCloseIn
    case "protected": .protectedBuilding
    case "glass": .glassFacade
    case "carpark": .carPark
    case "underpass": .underpass
    case "house": .blockHouse
    case "blockwall": .blockWall
    case "chamber": .internalExplosion
    case "gasroom": .ventedGasRoom
    case "panel-gas": .largePanelGas
    case "panel-street": .largePanelStreet
    case "plant": .processPlantExplosion
    case "warehouse": .portalWarehouse
    case "terraced": .terracedHouses
    case "hub": .transportHub
    case "hillside": .hillsideFrame
    default: .streetCanyon
    }
}

/// The preset named by `--preset`, with its structure meshed with shells of `--shells` metres
/// (0.25 when given without a size) if asked.
func chosenScenario() -> Scenario {
    var scenario = preset(named: option("preset")).scenario
    // `--layout scene.json`: a scene saved as a layout (Scenario JSON), such as
    // `scenebench district-scene` writes, in place of a preset.
    if let path = option("layout") {
        do {
            scenario = try JSONDecoder().decode(
                Scenario.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("Could not read \(path): \(error)")
            exit(1)
        }
    }
    // `--congested`: the process plant with its racks' pipes as congestion and the factor at 1.
    if flag("congested"), option("preset") == "plant" { scenario = ProcessPlantScene.congestedScenario }
    // `--flame-factor 12`: a gas cloud's burning velocity times this (`FlameAcceleration.factor`).
    if let factor = option("flame-factor").flatMap({ Float($0) }) {
        scenario.deflagration?.acceleration.factor = factor
    }
    if flag("shells") || option("shells") != nil, var structure = scenario.structure {
        structure.elementKind = .shell
        structure.elementSize = option("shells").flatMap { Float($0) } ?? 0.25
        if let layers = option("shell-layers").flatMap({ Int($0) }) { structure.shellLayers = layers }
        scenario.structure = structure
    }
    // `--rigid-joints`: steel members sharing their joints' nodes, without connections' hinges.
    if flag("rigid-joints") { scenario.structure?.steelConnection = nil }
    // `--straight-members`: steel members without Eurocode 3's bow; `--no-steel-rate`: steel without
    // its strain-rate law. For finding what changed a result.
    if flag("straight-members") { scenario.structure?.memberImperfections = false }
    if flag("no-steel-rate"), var structure = scenario.structure {
        structure.material.rateLaw = nil
        structure.solidMaterial = structure.solidMaterial.map {
            $0.map {
                var m = $0
                m.rateLaw = nil
                return m
            }
        }
        scenario.structure = structure
    }
    // `--no-second-crack` carries tension that turns away from fixed crack axes across them.
    if flag("no-second-crack") { scenario.structure?.secondCracks = false }
    // `--dowel 0.3` scales the bars' dowel action in every material of the structure.
    if let dowel = option("dowel").flatMap({ Float($0) }), var structure = scenario.structure {
        structure.material.dowelFactor = dowel
        structure.solidMaterial = structure.solidMaterial.map {
            $0.map {
                var m = $0
                m.dowelFactor = dowel
                return m
            }
        }
        scenario.structure = structure
    }
    if var structure = scenario.structure {
        applyRateOptions(&structure)
        scenario.structure = structure
    }
    // `--no-units` gives masonry its wall's strength throughout, without units and joints.
    if flag("no-units") { scenario.structure?.unitJoints = false }
    // `--bond` (or `--bond mortar`) lets masonry come away from concrete at the bond of mortar
    // to concrete; `--bond pullout` and the like make the bars slip instead.
    if chosenBond == .mortar, var structure = scenario.structure {
        structure.interfaceBond = StructureModel.masonryBond
        scenario.structure = structure
    }
    if let bond = chosenBondSlip(diameter: 0.016) { scenario.structure?.bondSlip = bond }
    // `--solid-near 4` meshes the pieces within 4 m of the charge with solid elements and the
    // rest with shells.
    if let distance = option("solid-near").flatMap({ Float($0) }), let structure = scenario.structure {
        scenario.structure = structure.solidNear(scenario.charge.position, within: distance, shellSize: 0.25)
    }
    // `--terrain hill|ridge|slope|flat|dem.asc` lays a terrain under the scene (TerrainBench.swift).
    if let terrain = option("terrain") { applyTerrain(terrain, to: &scenario) }
    // `--buildings map.geojson` places map buildings on it, on `--dx`'s first cells.
    if let buildings = option("buildings"), option("study") == nil {
        let cell = option("dx").flatMap { $0.split(separator: ",").first.flatMap { Float($0) } } ?? 0.5
        applyMapBuildings(buildings, to: &scenario, resolution: cell)
    }
    return scenario
}

/// `--bond pullout`, `--bond splitting` or `--bond confined`: bars that slip in their concrete
/// by the Model Code's law for those conditions (see `BondSlip`), of `diameter` metres unless
/// `--bar` gives it in millimetres; nil, perfect bond, without the option.
func chosenBondSlip(diameter: Float) -> BondSlip? {
    let bar = option("bar").flatMap { Float($0) }.map { $0 / 1000 } ?? diameter
    // `--keep-yielded-bond`: bars hold as well after yielding as before.
    return chosenBond.bondSlip(diameter: bar, yieldedBondLoss: !flag("keep-yielded-bond"))
}

/// What `--bond` asks for: bars that slip (`pullout`, `splitting`, `confined`), perfect bond
/// (`none`), or, alone or as `--bond mortar`, the joint where masonry meets concrete.
let chosenBond = BondArgument(present: flag("bond"), value: option("bond"))

/// Afterburning and hot air are the default since 15 October 2026: `--no-afterburn` turns
/// afterburning off, and hot air with it unless `--air` says otherwise, for the earlier default.
/// `--afterburn` changes nothing there, and still turns afterburning on in the studies that start
/// from the bare core (the terrain's numerical studies).
let burning = !flag("no-afterburn")

/// The air model `--air ideal`, `--air thermal` or `--air dissociating` asks for (the ideal gas
/// with `--no-afterburn`), or nil for the default.
func chosenAirModel() -> AirModel? {
    switch option("air") {
    case "ideal": .idealGas
    case "thermal": .thermallyPerfect
    case "dissociating": .dissociating
    default: burning ? nil : .idealGas
    }
}

/// The air's gas as the command line asks: `--air`, or hot air while afterburning and the ideal
/// gas with `--no-afterburn`.
func chosenGas() -> AirModel { chosenAirModel() ?? SolverConfiguration.recommended.airModel }

/// The open faces as the command line asks: far field, or `--copy-faces` for those before
/// 15 October 2026.
func chosenFaces() -> OpenFaces { flag("copy-faces") ? .copy : SolverConfiguration.recommended.openFaces }

/// The structure's outline in the air as the command line sets it: `--mask-sampling 2`,
/// `--mask-fill 0.5`, `--no-mask-overlap` for the elements counted at their centres, as before
/// 16 October 2026 (see `SolverConfiguration.structureMaskOverlap`).
func applyChosenMask(_ configuration: inout SolverConfiguration) {
    configureHold(&configuration)
    if let n = option("mask-sampling").flatMap({ Int($0) }) { configuration.structureMaskSampling = n }
    if let f = option("mask-fill").flatMap({ Float($0) }) { configuration.structureMaskFill = f }
    if flag("mask-overlap") { configuration.structureMaskOverlap = true }
    if flag("no-mask-overlap") { configuration.structureMaskOverlap = false }
}

/// The air every run ships with (`SolverConfiguration.recommended`) as the command line changes
/// it: `--no-afterburn`, `--air` and `--copy-faces`. Every bench that runs a scene starts here;
/// those that pin the bare core for numerics say so.
func applyChosenAir(_ configuration: inout SolverConfiguration) {
    configuration.afterburning = burning
    configuration.airModel = chosenGas()
    configuration.openFaces = chosenFaces()
    configuration.afterburnMixing = chosenBurnMixing()
    // `--wall-read`: gauges beside a wall read the pressure at the wall (`gaugesReadWallPressure`).
    if flag("wall-read") { configuration.gaugesReadWallPressure = true }
}

/// `--fracture-rate 0.5`: how the fracture energy follows the tensile strain-rate law, and the
/// like, for any command that builds concrete.
func applyRateOptions(_ material: inout StructureMaterial) {
    // `--rupture 0.15`: the bars' plastic strain at rupture, over the debonded window; with a
    // measured curve, its last point moved there (the bar breaks at the last point).
    if let rupture = option("rupture").flatMap({ Float($0) }), var steel = material.steel {
        steel.ruptureStrain = rupture
        if var curve = steel.measuredCurve, curve.count >= 2 {
            curve[curve.count - 1].x = max(rupture, curve[curve.count - 2].x * 1.001)
            steel.measuredCurve = curve
        }
        material.steel = steel
    }
    if let residual = option("crack-residual").flatMap({ Float($0) }) { material.crackResidual = residual }
    if let dilatancy = option("dilatancy").flatMap({ Float($0) }) { material.crackDilatancy = dilatancy }
    // `--steel-plateau`: the bars' measured curve held at its peak instead of falling after it
    // (a study: the fall is the test bar's necking over its gauge length).
    if flag("steel-plateau"), var steel = material.steel, let curve = steel.measuredCurve,
        let peak = curve.firstIndex(where: { $0.y == curve.map(\.y).max() })
    {
        steel.measuredCurve = curve.enumerated().map {
            $0.offset > peak ? SIMD2($0.element.x, curve[peak].y) : $0.element
        }
        material.steel = steel
    }
    // `--static-steel`: the bars without their strain-rate law.
    if flag("static-steel") { material.steelRateDependent = false }
    // `--steel-strength 0.944`: the bars' whole stress-strain curve scaled, to see what a source's
    // different yield (68 ksi against the measured curve's 72 for the contest slab) does.
    if let factor = option("steel-strength").flatMap({ Float($0) }), var steel = material.steel {
        steel.yieldStress *= factor
        steel.ultimateStress *= factor
        steel.measuredCurve = steel.measuredCurve?.map { SIMD2($0.x, $0.y * factor) }
        material.steel = steel
    }
    if let exponent = option("fracture-rate").flatMap({ Float($0) }) {
        material.fractureRateExponent = exponent
    }
    // `--interlock 0.2`, `--dowel 0`, `--confinement 0`, `--fracture-energy 0.5` and
    // `--tensile-strength 0.8` scale aggregate interlock, the bars' dowel action, confinement, the
    // fracture energy and the tensile strength, to see what each mechanism carries.
    if let factor = option("interlock").flatMap({ Float($0) }) { material.interlockFactor = factor }
    if let factor = option("dowel").flatMap({ Float($0) }) { material.dowelFactor = factor }
    if let factor = option("confinement").flatMap({ Float($0) }) { material.confinementCoefficient *= factor }
    if let factor = option("fracture-energy").flatMap({ Float($0) }) { material.fractureEnergy *= factor }
    if let factor = option("tensile-strength").flatMap({ Float($0) }) { material.tensileStrength *= factor }
    // `--crushing-energy 0.1`: scales the energy crushing dissipates, which one element's softening
    // spreads over its own size; a tenth stands for crushing gathered into a zone ten elements long.
    if let factor = option("crushing-energy").flatMap({ Float($0) }) { material.crushingEnergy *= factor }
}

/// `--hourglass-secant` and `--hourglass-no-steel`: hourglass control that softens with cracking,
/// and a cap on it without the bars' strength (`StructureModel.hourglassFollowsCracking` and
/// `hourglassCapsSteel`).
func applyHourglassOptions(_ model: inout StructureModel) {
    if flag("hourglass-secant") { model.hourglassFollowsCracking = true }
    if flag("hourglass-no-steel") { model.hourglassCapsSteel = false }
    // `--extreme-fibre`: elements with a free face crack when that face reaches the tensile strength.
    if flag("extreme-fibre") { model.extremeFibreCracking = true }
    // `--nonlocal 0.05`: cracks soften by their strain averaged over that length either side.
    if let length = option("nonlocal").flatMap({ Float($0) }) { model.crackAveraging = length }
    // `--rate-window 120` (µs): the strain-rate laws see the rate averaged over that time
    // (`strainRateWindow`, 100 µs by default); `--rate-window steps`, over the last 50 steps, as
    // before 12 October 2026.
    if let text = option("rate-window") {
        model.strainRateWindow =
            text == "steps" ? nil : Float(text).map { $0 * 1e-6 } ?? model.strainRateWindow
    }
    // `--discrete [mm]`: the layers' bars as discrete trusses (`barsAsTrusses`), of that diameter,
    // or the bond's (`--bond`), or 12 mm; they slip by `--bond` or are bonded perfectly.
    if flag("discrete") {
        model.barsAsTrusses = true
        if let diameter = option("discrete").flatMap({ Float($0) }) { model.trussDiameter = diameter / 1000 }
    }
}

func applyRateOptions(_ model: inout StructureModel) {
    // `--fragments`: concrete broken into fragments is removed (`removesFragments`).
    if flag("fragments") { model.removesFragments = true }
    // `--rubble`: failed concrete becomes particles that keep its mass (`rubbleParticles`).
    if flag("rubble") { model.rubbleParticles = true }
    // `--crushed-bare`: bare concrete squeezed below a quarter of its volume is removed.
    if flag("crushed-bare") { model.erodesCrushedBare = true }
    // `--crushed-bare-hourglass`: crushed bare elements keep their bars but lose their hourglass control.
    if flag("crushed-bare-hourglass") { model.releasesCrushedBareHourglass = true }
    // `--no-crack-slip`: cracks spring back from sliding, as before slip was stored.
    if flag("no-crack-slip") { model.crackSlip = false }
    // `--pressed-interlock`: cracks press as they slide, and carry more shear pressed.
    if flag("pressed-interlock") { model.pressedInterlock = true }
    applyHourglassOptions(&model)
    applyRateOptions(&model.material)
    model.solidMaterial = model.solidMaterial.map {
        $0.map {
            var m = $0
            applyRateOptions(&m)
            return m
        }
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

/// Time at which a gauge's overpressure first reaches half of its peak, in seconds.
func arrivalTime(_ history: [GaugeSample], ambient: Float) -> Double {
    let peak = (history.map(\.pressure).max() ?? ambient) - ambient
    return history.first { $0.pressure - ambient >= 0.5 * peak }?.time ?? 0
}

/// Gas pressure in a closed room against UFC 3-340-02 Figure 2-152.
/// A solver for `scenario`, with the air options given on the command line (`--afterburn`).
/// The air's refinement from `--refine 2|4`, `--refine-levels 1|2`, `--refine-margin 1|2` (cells of
/// margin around the shock), `--refine-own-steps` (each level takes only the substeps its own waves
/// need), `--refine-threshold`,
/// `--refine-finer-threshold` (the second level's) and `--refine-memory` (MB).
/// `--hold-structures <Pa>` and `--hold-envelopes <Pa>` hold refinement about structures and
/// beside envelopes' recorded faces while their air is loaded past so many pascals; `0` for none.
func configureHold(_ configuration: inout SolverConfiguration) {
    if let hold = option("hold-structures").flatMap({ Float($0) }) {
        configuration.refinementHoldsStructures = hold > 0 ? hold : nil
    }
    if let hold = option("hold-envelopes").flatMap({ Float($0) }) {
        configuration.refinementHoldsEnvelopes = hold > 0 ? hold : nil
    }
}

func configureRefinement(_ configuration: inout SolverConfiguration) {
    // The terrain's ground is cut through the cells by default (TerrainCutCells.swift); `--staircase`
    // lays it as whole cells. `--cut-cells` is the default, kept for old command lines.
    if flag("staircase") { configuration.terrainCutCells = false }
    if let cfl = option("cfl").flatMap({ Float($0) }) { configuration.cfl = cfl }
    if let ratio = option("refine").flatMap({ Int($0) }) { configuration.refinement = ratio }
    if let threshold = option("refine-threshold").flatMap({ Float($0) }) {
        configuration.refinementThreshold = threshold
    }
    if let levels = option("refine-levels").flatMap({ Int($0) }) { configuration.refinementLevels = levels }
    if let margin = option("refine-margin").flatMap({ Int($0) }) { configuration.refinementMargin = margin }
    if flag("refine-own-steps") { configuration.refinementOwnSteps = true }
    if let threshold = option("refine-finer-threshold").flatMap({ Float($0) }) {
        configuration.refinementFinerThreshold = threshold
    }
    if let memory = option("refine-memory").flatMap({ Int($0) }) {
        configuration.refinementMemory = memory << 20
    }
    // `--refine-start full` makes the pools whole from the start, as before they grew; a number,
    // in MB, starts them there instead of `refinementStartMemory`. The run is the same either way.
    if let start = option("refine-start") {
        configuration.refinementStartMemory = start == "full" ? nil : Int(start).map { $0 << 20 }
    }
    configureHold(&configuration)
}

/// With `--radiate`, the luminous gas loses the heat it radiates: as `--thermal`'s description
/// absorbs, when one is given, else by `--absorption` (1/m) and `--soot-yield`, or their defaults.
func chosenCooling() throws -> RadiativeCooling? {
    guard flag("radiate") else { return nil }
    if let path = option("thermal") {
        return RadiativeCooling(
            spec: try JSONDecoder().decode(
                ThermalSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path))))
    }
    var cooling = RadiativeCooling()
    if let value = option("absorption").flatMap({ Float($0) }) { cooling.absorption = value }
    if let value = option("soot-yield").flatMap({ Float($0) }) { cooling.sootYield = value }
    return cooling
}

/// With `--gravity`, gravity acts on the air, which starts in a hydrostatic atmosphere cooling
/// with height at `--lapse` K/km (6.5, the standard atmosphere's, by default; 0 for isothermal).
func chosenGravity() -> AirGravity? {
    guard flag("gravity") else { return nil }
    return AirGravity(lapseRate: (option("lapse").flatMap { Float($0) } ?? 6.5) / 1000)
}

/// With `--mixing`, sub-grid turbulent mixing in the air, of Smagorinsky coefficient `--smagorinsky`.
func chosenMixing() -> SubgridMixing? {
    guard flag("mixing") else { return nil }
    var mixing = SubgridMixing()
    if let value = option("smagorinsky").flatMap({ Float($0) }) { mixing.coefficient = value }
    return mixing
}

/// With `--burn-limit`, afterburning's extinction limit, of ignition temperature `--ignition` and
/// limit flame temperature `--limit-flame` (K).
func chosenBurnLimit() -> AfterburnLimit? {
    guard flag("burn-limit") else { return nil }
    var limit = AfterburnLimit()
    if let value = option("ignition").flatMap({ Float($0) }) { limit.ignitionTemperature = value }
    if let value = option("limit-flame").flatMap({ Float($0) }) { limit.limitFlameTemperature = value }
    return limit
}

/// With `--burn-mixing C`, afterburning limited by the sub-grid mixing as well as its fitted time, an
/// eddy-break-up rate of coefficient C (`MixedAfterburning`); the solver turns sub-grid mixing on with
/// it (Smagorinsky's, or `--mixing`'s).
func chosenBurnMixing() -> MixedAfterburning? {
    guard let text = option("burn-mixing") else { return nil }
    return MixedAfterburning(coefficient: Float(text) ?? MixedAfterburning().coefficient)
}

func makeAirSolver(_ scenario: Scenario, cellSize: Float) throws -> BlastSolver {
    // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
    var configuration = SolverConfiguration.recommended.balloonStart
    configureRefinement(&configuration)
    configuration.radiativeCooling = try chosenCooling()
    configuration.gravity = chosenGravity()
    configuration.mixing = chosenMixing()
    configuration.afterburnLimit = chosenBurnLimit()
    applyChosenAir(&configuration)
    if flag("mapped") { configuration.mappedCharge = true }
    // The mapped start's products with their own equation of state (JWL).
    if flag("products") { configuration.mappedChargeProducts = true }
    if let time = option("burn-time").flatMap({ Float($0) }) { configuration.afterburnTime = time / 1000 }
    if let energy = option("afterburn-energy").flatMap({ Float($0) }) {
        configuration.afterburnEnergy = energy * 1e6
    }
    return try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
}
