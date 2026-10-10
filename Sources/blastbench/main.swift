import BlastCore
import BlastRender
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// Command-line companion to the app: measures solver throughput, compares a surface burst
// against the Kinney-Graham curve and renders offscreen snapshots.
//
//   blastbench [throughput] [--preset open|single|street|courtyard|wall|box|frame|infill|storeys|tall|tower|column|
//               protected|glass|carpark|underpass|house|blockwall|chamber] [--full] [--dx 0.5,0.25]
//   blastbench structure [--preset wall|box] [--contact] [--elastic]
//   blastbench validate [--dx 0.25]
//   blastbench beam [--layers 12,24] [--rate 0.1]
//   blastbench shear [--layers 12,24] [--rate 0.05] [--slice 92] [--dowel 1] [--map 9]
//               [--bond pullout|splitting|confined] [--crack-shear] [--slide-apart]   (also on beam and slab)
//               [--pressed-interlock]   (also on beam, slab, pushoff, impact, chamber and closein)
//               [--work] [--hourglass 0.5] [--interlock 0.2] [--dowel 0] [--confinement 0]
//               [--fracture-energy 0.5] [--tensile-strength 0.8]   (work trace on slab too; knobs everywhere)
//   blastbench pushoff [--specimens 1/.2/.4,1/.4/.3] [--size 50] [--crack-shear] [--dilatancy 0.5] [--slide-apart] [--close]
//   blastbench impact [--tests SS0a-1,SS0b-1] [--layers 16] [--time 0.2] [--beams 0.1] [--map] [--bond ...] [--spread]
//   blastbench closeair [--z 0.3,0.5,0.75,1] [--dx 0.02] [--mapped] [--refine 2] [--refine-levels 2]
//   blastbench closein [--tests P1,P7] [--dx 0.05] [--h 0.025] [--time 0.3] [--refine 2] [--afterburn] [--progress] [--bond ...]
//                      [--trace out-%.csv [--trace-until 0.001]] [--faces] [--energy] [--under] [--skirts]
//   blastbench slab [--history] [--sensitivity [--convergence]] [--layers 16,32] [--strip 25] [--map] [--plan [0.1]]
//                   [--stiffening [--profile [--line] [--column -44]]]   (where the tension along the span is carried)
//   blastbench tie [--h 0.02,0.01] [--bond none|splitting] [--factor 1.25]   (a tie against the Model Code)
//                   [--shells 2,1 [--shell-layers 8] [--shell-rate none|designFactors|strainRate]]
//   blastbench anchorage [--mass 50] [--standoff 6,10,15,25] [--time 0.5] [--h 0.0625] [--shells]
//                        [--bases clamped,resting] [--air [--cell 0.25] [--margin 12] [--height 18] [--progress]]
//                        [--massless] [--layer 3 [--beneath rock|sand|clay]]   (the footing's soil)
//                        [--panel]   (a 3 m panel resting on the ground, its edges tied to columns by each base)
//   blastbench rocking [--shear 40] [--bearing 814] [--packets a,b,c,d,e] [--speed 0.2] [--history out.csv]
//   blastbench snapshot --out frame.png [--preset street] [--dx 0.25] [--time 0.03]
//                       [--mode peak|now|impulse|fluence|irradiance]
//                       [--fragments spec.json [--dot 5]] [--ground-shock spec.json]
//                       [--thermal spec.json [--thermal-compare [--thermal-compare-with shape]]
//                        [--thermal-variants a.json,b.json]]
//                       [--air thermal] [--afterburn] [--radiate [--absorption 0.1] [--soot-yield 0.185]]
//                       [--stationary-walls] [--cloud spec.json [--frame-cloud] [--cloud-results out.json]]
//   blastbench dialpack [--dx 4] [--time 1] [--tons 500] [--domain 480] [--radiate] [--refine 2]
//                       [--csv out.csv]   (500 t of TNT's fireball radiation, against DREO 642)
//   blastbench thermal [--preset street] [--frames 60] [--samples 128] [--model volume] [--absorption 0.1]
//                      (the volume's march, or the shape's and sphere's visibility, on CPU and GPU)
//   blastbench digest [--refine 2] [--refine-levels 2] [--steps 80]   (hashes of short runs, to compare builds)

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "throughput"

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
    case "column": .columnCloseIn
    case "protected": .protectedBuilding
    case "glass": .glassFacade
    case "carpark": .carPark
    case "underpass": .underpass
    case "house": .blockHouse
    case "blockwall": .blockWall
    case "chamber": .internalExplosion
    default: .streetCanyon
    }
}

/// The preset named by `--preset`, with its structure meshed with shells of `--shells` metres
/// (0.25 when given without a size) if asked.
func chosenScenario() -> Scenario {
    var scenario = preset(named: option("preset")).scenario
    if flag("shells") || option("shells") != nil, var structure = scenario.structure {
        structure.elementKind = .shell
        structure.elementSize = option("shells").flatMap { Float($0) } ?? 0.25
        if let layers = option("shell-layers").flatMap({ Int($0) }) { structure.shellLayers = layers }
        scenario.structure = structure
    }
    if option("cracks") != nil || flag("oriented"), var structure = scenario.structure {
        structure.crackAxes = chosenCrackAxes()
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
    // `--bond` lets masonry come away from concrete at the bond of mortar to concrete.
    if flag("bond"), var structure = scenario.structure {
        structure.interfaceBond = StructureModel.masonryBond
        scenario.structure = structure
    }
    // `--solid-near 4` meshes the pieces within 4 m of the charge with solid elements and the
    // rest with shells.
    if let distance = option("solid-near").flatMap({ Float($0) }), let structure = scenario.structure {
        scenario.structure = structure.solidNear(scenario.charge.position, within: distance, shellSize: 0.25)
    }
    return scenario
}

/// `--cracks lattice` or `--cracks fixed` (or `--oriented`, the same as fixed); turning by default.
func chosenCrackAxes() -> CrackAxes {
    switch option("cracks") {
    case "lattice": .lattice
    case "fixed": .fixedAtFirstCrack
    default: flag("oriented") ? .fixedAtFirstCrack : .turningUntilOpen
    }
}

/// `--bond pullout`, `--bond splitting` or `--bond confined`: bars that slip in their concrete
/// by the Model Code's law for those conditions (see `BondSlip`), of `diameter` metres unless
/// `--bar` gives it in millimetres; nil, perfect bond, without the option.
func chosenBondSlip(diameter: Float) -> BondSlip? {
    let bar = option("bar").flatMap { Float($0) }.map { $0 / 1000 } ?? diameter
    // `--keep-yielded-bond`: bars hold as well after yielding as before.
    let loss = !flag("keep-yielded-bond")
    switch option("bond") {
    case "pullout": return BondSlip(condition: .pullOut, barDiameter: bar, yieldedBondLoss: loss)
    case "splitting": return BondSlip(condition: .splitting, barDiameter: bar, yieldedBondLoss: loss)
    case "confined": return BondSlip(condition: .confinedSplitting, barDiameter: bar, yieldedBondLoss: loss)
    default: return nil
    }
}

/// The air model `--air thermal` or `--air dissociating` asks for, or nil for the default.
func chosenAirModel() -> AirModel? {
    switch option("air") {
    case "thermal": .thermallyPerfect
    case "dissociating": .dissociating
    default: nil
    }
}

/// `--tension-law mc2010` and `--fracture-rate 0.5`: the tensile strain-rate law and how the
/// fracture energy follows it, for any command that builds concrete.
func applyRateOptions(_ material: inout StructureMaterial) {
    if let residual = option("crack-residual").flatMap({ Float($0) }) { material.crackResidual = residual }
    if let dilatancy = option("dilatancy").flatMap({ Float($0) }) { material.crackDilatancy = dilatancy }
    // `--static-steel`: the bars without their strain-rate law.
    if flag("static-steel") { material.steelRateDependent = false }
    // `--steel-law ceb|malvar`: the bars' strain-rate law.
    if option("steel-law") == "ceb" { material.steelRateLaw = .ceb }
    if option("steel-law") == "malvar" { material.steelRateLaw = .malvarCrawford }
    if option("tension-law") == "mc2010" { material.tensionRateLaw = .modelCode2010 }
    if option("tension-law") == "malvar" { material.tensionRateLaw = .malvarRoss }
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
}

/// `--work`: the work trace (`StructureSolver.tracesWork`), and `--hourglass 0.5` scales the
/// hourglass control, for any bench that builds a solid body.
func prepareTrace(_ solver: StructureSolver) {
    solver.tracesWork = flag("work")
    if let factor = option("hourglass").flatMap({ Float($0) }) { solver.hourglassCoefficient = factor }
}

/// The work trace's channels in the order printed.
let workOrder: [StructureSolver.WorkChannel] = [
    .tensionNormal, .tensionHairline, .tensionCracked, .compressionNormal, .compressionCrushed,
    .uncrackedShear, .crackShear,
    .crackShearPressed, .interlock, .interlockPressed, .dowel, .kink, .bars, .bond, .hourglass, .other,
    .viscosity,
]

func workHeader(_ first: String, _ width: Int) -> String {
    let short = [
        "tension", "hairline", "cracked", "compr.", "crushed", "uncr. sh.", "crack sh.", "pressed",
        "interlock", "pressed",
        "dowel", "kinking", "bars", "bond", "hourglass", "other", "viscous",
    ]
    return pad(first, width) + short.map { pad($0, 10) }.joined() + pad("total", 10)
}

/// A row of the work trace: each mechanism's work, in joules.
func workRow(_ label: String, _ width: Int, _ totals: [Double]) -> String {
    pad(label, width) + workOrder.map { pad(format(totals[$0.rawValue], 1), 10) }.joined()
        + pad(format(totals.reduce(0, +), 1), 10)
}

func applyRateOptions(_ model: inout StructureModel) {
    // `--element-bar-rate`: bars take the strain rate of the element they run through.
    if flag("element-bar-rate") { model.barRateAlongBars = false }
    // `--no-crack-slip`: cracks spring back from sliding, as before slip was stored.
    if flag("no-crack-slip") { model.crackSlip = false }
    // `--slide-apart`: what a crack has slid by no longer counts as opening it.
    if flag("slide-apart") { model.slipWidensCracks = false }
    // `--pressed-interlock`: cracks press as they slide, and carry more shear pressed.
    if flag("pressed-interlock") { model.pressedInterlock = true }
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

guard let device = MTLCreateSystemDefaultDevice() else {
    print("No Metal device available")
    exit(1)
}

func runThroughput() throws {
    let scenario = chosenScenario()
    let event = scenario.acousticCrossingTime
    print("Device: \(device.name)")
    print(
        "Scenario: \(scenario.name), \(Int(scenario.charge.mass)) kg TNT equivalent, "
            + "\(format(event * 1000, 0)) ms event (charge to farthest corner at ambient sound speed)")
    print("")
    print(
        pad("cell", 8) + pad("cells", 12) + pad("memory", 10) + pad("steps/s", 10) + pad("Mcell/s", 10)
            + pad("slow-mo", 10) + pad("steps", 8) + pad("swept", 8) + pad("event wall time", 20))

    var stepsPerMetre = 0.0
    var lastSwept = 1.0
    let cellSizes =
        option("dx").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.5, 0.25, 0.125]
    for cellSize in cellSizes {
        let solver = try makeAirSolver(scenario, cellSize: cellSize)
        let cells = solver.grid.cellCount
        // Run the whole event unless it would take minutes; then time a sample and extrapolate
        // the step count from the previous, coarser run. The sample sweeps every tile, since
        // early steps skip far more air than the event as a whole; the estimate assumes the
        // coarser run's swept fraction.
        let runWholeEvent = cells < 20_000_000 || flag("full")
        if flag("no-skip") || !runWholeEvent {
            solver.configuration.skipStillAir = false
            solver.restart()
        }
        let start = ContinuousClock.now
        var steps = 0
        var swept = 1.0
        if runWholeEvent && solver.configuration.refinement > 1 {
            // Batch by batch, to follow how much of the air is refined.
            var refined = 0.0
            var finer = 0.0
            var (most, finerMost) = (0, 0)
            var batches = 0
            while solver.time < event {
                let result = solver.advance(steps: 64, timeLimit: event)
                if result.steps == 0 { break }
                swept =
                    (swept * Double(steps) + result.sweptFraction * Double(result.steps))
                    / Double(steps + result.steps)
                steps += result.steps
                refined += Double(result.refinedTiles)
                finer += Double(result.finerRefinedTiles)
                most = max(most, result.refinedTiles)
                finerMost = max(finerMost, result.finerRefinedTiles)
                batches += 1
            }
            let blocks = Double(
                ((solver.grid.nx + 3) / 4) * ((solver.grid.ny + 3) / 4) * ((solver.grid.nz + 3) / 4))
            print(
                "  refined blocks of 4 x 4 x 4 cells: \(format(refined / Double(max(batches, 1)), 0)) on average, "
                    + "at most \(most) (room for \(solver.refinementPatchCapacity)), of \(Int(blocks))"
                    + (solver.configuration.refinementLevels > 1
                        ? "; at the second level \(format(finer / Double(max(batches, 1)), 0)) on average, "
                            + "at most \(finerMost) (room for \(solver.finerRefinementPatchCapacity))" : ""))
        } else if runWholeEvent {
            let result = solver.advance(until: event)
            (steps, swept) = (result.steps, result.sweptFraction)
        } else {
            let result = solver.advance(steps: 192)
            (steps, swept) = (result.steps, result.sweptFraction)
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let stepRate = Double(steps) / seconds

        var totalSteps = Double(steps)
        var wallTime = seconds
        if runWholeEvent {
            stepsPerMetre = Double(steps) * Double(cellSize)
            lastSwept = swept
        } else {
            // The step count scales inversely with cell size.
            totalSteps = stepsPerMetre / Double(cellSize)
            swept = flag("no-skip") ? 1 : lastSwept
            wallTime = totalSteps / stepRate * swept
        }
        let slowMotion = wallTime / event
        print(
            pad("\(format(Double(cellSize), 3)) m", 8)
                + pad("\(format(Double(cells) / 1e6, 1)) M", 12)
                + pad("\(format(Double(solver.memoryFootprint) / 1e9, 2)) GB", 10)
                + pad(format(stepRate, 0), 10)
                + pad(format(stepRate * Double(cells) / 1e6, 0), 10)
                + pad("\(format(slowMotion, 0))x", 10)
                + pad(format(totalSteps, 0), 8)
                + pad("\(format(100 * swept, 0))%", 8)
                + pad("\(format(wallTime, 1)) s" + (runWholeEvent ? "" : " (est.)"), 20))
    }
}

/// Time at which a gauge's overpressure first reaches half of its peak, in seconds.
func arrivalTime(_ history: [GaugeSample], ambient: Float) -> Double {
    let peak = (history.map(\.pressure).max() ?? ambient) - ambient
    return history.first { $0.pressure - ambient >= 0.5 * peak }?.time ?? 0
}

/// The internal explosion test of Shang et al. (2026).
func runChamber() throws {
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.1
    let elementSize = option("h").flatMap { Float($0) } ?? 0.1
    let duration = option("time").flatMap { Double($0) } ?? 0.3
    let downstand = !flag("no-downstand")
    let chargeScale = option("charge-scale").flatMap { Float($0) } ?? 1
    if let text = option("pressures") {
        // The roof's resistance: the vent closed, the chamber filled with air at a steady
        // overpressure, and the roof edge watched.
        print(
            "Chamber of Shang et al. (2026), vent closed, filled with steady overpressure; roof edge at mid-span"
        )
        print(pad("kPa", 8) + pad("peak", 10) + pad("end", 10) + "failed")
        for kilopascals in text.split(separator: ",").compactMap({ Float($0) }) {
            let result = try ChamberTest.pressureTest(
                device: device, overpressure: kilopascals * 1000, elementSize: elementSize, duration: duration
            )
            print(
                pad(format(Double(kilopascals), 0), 8)
                    + pad("\(format(Double(result.peakDeflection) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.edgeHistory.last?.y ?? 0) * 1000, 0)) mm", 10)
                    + "\(result.summary.erodedElements)")
        }
        return
    }
    print(
        "Internal explosion in a reinforced concrete chamber (Shang et al., 2026): "
            + "4 x \(format(Double(50 * chargeScale), 1)) kg TNT, half-model")
    print(
        "Air cells \(format(Double(cellSize), 3)) m, elements \(format(Double(elementSize), 3)) m, \(format(duration * 1000, 0)) ms"
            + (downstand ? "" : ", no down-stand"))
    var scenario = ChamberTest.scenario(
        elementSize: elementSize, downstand: downstand, ties: !flag("no-ties"), elastic: flag("elastic"),
        chargeScale: chargeScale, crackAxes: chosenCrackAxes())
    if let residual = option("crack-residual").flatMap({ Float($0) }) {
        scenario.structure?.material.crackResidual = residual
        print("Residual crack opening \(format(Double(residual) * 100, 0))%")
    }
    if flag("no-second-crack") { scenario.structure?.secondCracks = false }
    if let dowel = option("dowel").flatMap({ Float($0) }) { scenario.structure?.material.dowelFactor = dowel }
    if var structure = scenario.structure {
        applyRateOptions(&structure)
        // `--bond pullout`: bars that slip, of the 16 mm bars' diameter.
        if let bond = chosenBondSlip(diameter: 0.016) { structure.bondSlip = bond }
        scenario.structure = structure
    }
    let result = try ChamberTest.run(
        device: device, scenario: scenario, cellSize: cellSize, duration: duration,
        afterburning: flag("afterburn"),
        afterburnEnergy: option("afterburn-energy").flatMap { Float($0) }.map { $0 * 1e6 },
        airModel: chosenAirModel() ?? .idealGas,
        refinement: option("refine").flatMap { Int($0) } ?? 1,
        contact: flag("no-contact") ? .off : nil,
        // `--progress` reports every 10 ms of a long run.
        progress: flag("progress")
            ? { line in
                print(line)
                fflush(stdout)
            } : nil)
    print(
        "\nPeak reflected overpressure (MPa); the six sensors measured \(ChamberTest.measuredPeaks.map { format(Double($0.pressure) / 1e6, 2) }.joined(separator: ", "))"
    )
    for (name, pressure) in result.gaugePeaks {
        print("  \(pad(format(Double(pressure) / 1e6, 2), 6))  \(name)")
    }
    print(
        "\nRoof free edge at mid-span: peak \(format(Double(result.peakDeflection) * 1000, 0)) mm, "
            + "\(format(Double(result.residual) * 1000, 0)) mm at the end (measured residual \(format(Double(ChamberTest.measuredResidual) * 1000, 0)) mm)"
    )
    print(
        "Structure: \(result.summary.erodedElements) of \(result.summary.activeElements + result.summary.erodedElements) elements failed; "
            + "run took \(format(result.wallSeconds, 1)) s")
    for (part, failed, total) in result.failures {
        print("  \(pad("\(failed)", 6)) of \(pad("\(total)", 6))  \(part)")
    }
    for probe in result.probes {
        print("\(probe.name): peak \(format(Double(probe.history.map(\.y).max() ?? 0) * 1000, 0)) mm outward")
    }
    if flag("history") {
        print("    time      roof edge" + result.probes.map { pad($0.name, 24) }.joined())
        for (n, sample) in result.edgeHistory.enumerated() where Int((sample.x * 1000).rounded()) % 5 == 0 {
            print(
                "    \(pad(format(Double(sample.x) * 1000, 1), 6)) ms \(pad(format(Double(sample.y) * 1000, 1), 9))"
                    + result.probes.map { pad(format(Double($0.history[n].y) * 1000, 1), 24) }.joined())
        }
    }
}

/// Gas pressure in a closed room against UFC 3-340-02 Figure 2-152.
/// A solver for `scenario`, with the air options given on the command line (`--afterburn`).
/// The air's refinement from `--refine 2|4`, `--refine-levels 1|2`, `--refine-threshold`,
/// `--refine-finer-threshold` (the second level's) and `--refine-memory` (MB).
func configureRefinement(_ configuration: inout SolverConfiguration) {
    if let ratio = option("refine").flatMap({ Int($0) }) { configuration.refinement = ratio }
    if let threshold = option("refine-threshold").flatMap({ Float($0) }) {
        configuration.refinementThreshold = threshold
    }
    if let levels = option("refine-levels").flatMap({ Int($0) }) { configuration.refinementLevels = levels }
    if let threshold = option("refine-finer-threshold").flatMap({ Float($0) }) {
        configuration.refinementFinerThreshold = threshold
    }
    if let memory = option("refine-memory").flatMap({ Int($0) }) {
        configuration.refinementMemory = memory << 20
    }
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

func makeAirSolver(_ scenario: Scenario, cellSize: Float) throws -> BlastSolver {
    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    configuration.radiativeCooling = try chosenCooling()
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    if let air = chosenAirModel() {
        solver.configuration.airModel = air
        try solver.load(scenario)
    }
    if flag("mapped") {
        solver.configuration.mappedCharge = true
        try solver.load(scenario)
    }
    if flag("afterburn") {
        solver.configuration.afterburning = true
        if let time = option("burn-time").flatMap({ Float($0) }) {
            solver.configuration.afterburnTime = time / 1000
        }
        if let energy = option("afterburn-energy").flatMap({ Float($0) }) {
            solver.configuration.afterburnEnergy = energy * 1e6
        }
        try solver.load(scenario)
    }
    return solver
}

func runGasPressure() throws {
    let side: Float = 6
    let settle = option("time").flatMap { Double($0) } ?? 0.08
    print(
        "Charge in the middle of a closed \(Int(side)) m cubic room, after the shocks have settled (\(format(settle * 1000, 0)) ms)"
            + (flag("afterburn") ? ", with afterburning" : "")
            + (chosenAirModel().map { ", \($0) air" } ?? ""))
    print(
        pad("W/V kg/m3", 11) + pad("charge", 10) + pad("model", 12) + pad("(g-1)E/V", 12)
            + pad("UFC 2-152", 12)
            + pad("model/UFC", 11) + pad("burnt", 8) + (flag("radiate") ? pad("radiated", 9) : ""))
    // `--per-volume 0.1415` runs other ratios (that one is Cooper's closed-vessel example).
    let ratios =
        option("per-volume").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [
            0.25, 0.5, 1, 2, 4,
        ]
    for chargePerVolume in ratios {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: chargePerVolume * side * side * side, position: SIMD3(repeating: side / 2)))
        scenario.reflectiveFaces = .all
        let solver = try makeAirSolver(scenario, cellSize: option("dx").flatMap { Float($0) } ?? 0.25)
        solver.advance(until: settle)
        let burnt = 1 - solver.speciesTotals().fuel / Double(scenario.charge.mass)
        let volume = Double(side * side * side)
        let totals = solver.totals()
        // Mean pressure of the gas: (gamma - 1) times its internal energy per volume, less the
        // kinetic energy still sloshing about (small by now).
        var kinetic = 0.0
        solver.withState { cells in
            for cell in cells {
                kinetic +=
                    0.5
                    * Double(
                        cell.momentumX * cell.momentumX + cell.momentumY * cell.momentumY
                            + cell.momentumZ * cell.momentumZ) / Double(max(cell.density, 1e-6))
            }
        }
        let cellVolume = Double(pow(solver.grid.cellSize, 3))
        let gamma = Double(solver.configuration.gamma)
        let mean =
            Double(
                solver.configuration.airModel.pressure(
                    density: Float(totals.mass / volume),
                    internalEnergy: Float((totals.energy - kinetic * cellVolume) / volume),
                    gamma: Float(gamma)))
            - Double(scenario.atmosphere.pressure)
        let ideal = (gamma - 1) * Double(scenario.charge.energy) / volume
        let reference = UFC340.peakGasPressure(chargePerVolume: Double(chargePerVolume)) ?? .nan
        print(
            pad(format(Double(chargePerVolume), 2), 11) + pad("\(Int(scenario.charge.mass)) kg", 10)
                + pad("\(format(mean / 1e6, 2)) MPa", 12) + pad("\(format(ideal / 1e6, 2)) MPa", 12)
                + pad("\(format(reference / 1e6, 2)) MPa", 12)
                + pad("\(format(100 * mean / reference, 0))%", 11)
                + pad(solver.configuration.afterburning ? "\(format(100 * burnt, 0))%" : "-", 8)
                + (flag("radiate")
                    ? pad("\(format(100 * solver.radiatedEnergy / Double(scenario.charge.energy), 1))%", 9)
                    : ""))
    }
}

func runValidation() throws {
    var cellSizes: [Float] = [0.5, 0.25, 0.125]
    if let text = option("dx"), let value = Float(text) {
        cellSizes = [value]
    }
    func configure(_ solver: BlastSolver) {
        if let theta = option("theta").flatMap({ Float($0) }) { solver.configuration.limiterTheta = theta }
        if let cfl = option("cfl").flatMap({ Float($0) }) { solver.configuration.cfl = cfl }
        if let cells = option("balloon").flatMap({ Float($0) }) {
            solver.configuration.minimumBalloonCells = cells
        }
        if flag("hll") { solver.configuration.riemannSolver = .hll }
        if flag("afterburn") { solver.configuration.afterburning = true }
        if let air = chosenAirModel() { solver.configuration.airModel = air }
        if flag("mapped") { solver.configuration.mappedCharge = true }
        if let time = option("burn-time").flatMap({ Float($0) }) {
            solver.configuration.afterburnTime = time / 1000
        }
        configureRefinement(&solver.configuration)
        solver.configuration.radiativeCooling = try? chosenCooling()
    }
    func header(_ first: String) -> String {
        pad(first, 10) + pad("reference", 12)
            + cellSizes.map { pad("dx \(format(Double($0), 3))", 16) }.joined()
    }
    func row(_ label: String, _ reference: Double, _ values: [Double], digits: Int = 1) -> String {
        pad(label, 10) + pad(format(reference, digits), 12)
            + values.map { pad("\(format($0, digits)) (\(format(100 * $0 / reference, 0))%)", 16) }.joined()
    }

    // 1. Kingery-Bulmash: the design-practice standard for a surface burst.
    var scenario = ScenarioPreset.openGround.scenario
    let mass = Double(scenario.charge.mass)
    // Scaled distances from close in to as far as the domain allows (`--z` overrides).
    let distances =
        option("z").map { $0.split(separator: ",").compactMap { Double($0) } }
        ?? [0.75, 1, 1.5, 2, 3, 4, 5, 6]
    let points = distances.compactMap { KingeryBulmash.point(at: $0) }
    scenario.gauges = points.map { point in
        Gauge(
            "Z = \(format(point.scaledDistance, 2))", at: SIMD3(32 + Float(point.range(mass: mass)), 32, 0.05)
        )
    }
    print("Surface burst of \(Int(mass)) kg on rigid ground against the Kingery-Bulmash hemispherical")
    print(
        "surface-burst curves (Swisdak's polynomials), at scaled distances \(distances.map { format($0, 2) }.joined(separator: ", ")) m/kg^(1/3)."
    )

    var incident: [[(peak: Double, impulse: Double, arrival: Double)]] = []
    for cellSize in cellSizes {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        configure(solver)
        try solver.load(scenario)
        solver.advance(until: 0.1)
        incident.append(
            zip(scenario.gauges, solver.gaugeHistories).map { gauge, history in
                let cell = solver.nearestFluidCell(to: gauge.position)
                return (
                    Double((history.map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure) / 1000,
                    Double(solver.impulse(cell.i, cell.j, cell.k)),
                    arrivalTime(history, ambient: scenario.atmosphere.pressure) * 1000
                )
            })
    }
    print("\nIncident peak overpressure (kPa)\n" + header("range"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.incidentPressure / 1000,
                incident.map { $0[n].peak }))
    }
    print("\nIncident positive impulse (Pa s)\n" + header("range"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.incidentImpulse(mass: mass),
                incident.map { $0[n].impulse }, digits: 0))
    }
    print("\nArrival time (ms)\n" + header("range"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.arrival(mass: mass) * 1000,
                incident.map { $0[n].arrival }))
    }

    // 2. Reflected: the far x face of the domain becomes a rigid wall at each stand-off.
    var reflected: [[(peak: Double, impulse: Double)]] = []
    for cellSize in cellSizes {
        var column: [(peak: Double, impulse: Double)] = []
        for point in points {
            var wall = ScenarioPreset.openGround.scenario
            wall.reflectiveFaces = [.zMin, .xMax]
            wall.charge.position = SIMD3(64 - Float(point.range(mass: mass)), 32, 0)
            wall.gauges = [Gauge("Wall", at: SIMD3(63.99, 32, 0.05))]
            let solver = try BlastSolver(device: device, scenario: wall, cellSize: cellSize)
            configure(solver)
            try solver.load(wall)
            solver.advance(until: 0.1)
            let cell = solver.nearestFluidCell(to: wall.gauges[0].position)
            column.append(
                (
                    Double((solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - wall.atmosphere.pressure)
                        / 1000,
                    Double(solver.impulse(cell.i, cell.j, cell.k))
                ))
        }
        reflected.append(column)
    }
    print("\nReflected peak overpressure on a rigid wall (kPa)\n" + header("stand-off"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.reflectedPressure / 1000,
                reflected.map { $0[n].peak }))
    }
    print("\nReflected positive impulse on a rigid wall (Pa s)\n" + header("stand-off"))
    for (n, point) in points.enumerated() {
        print(
            row(
                "\(format(point.range(mass: mass))) m", point.reflectedImpulse(mass: mass),
                reflected.map { $0[n].impulse }, digits: 0))
    }

    // 3. Kinney-Graham free air, for twice the mass (perfectly rigid ground acts as a mirror).
    let open = ScenarioPreset.openGround.scenario
    let equivalentMass = 2 * mass
    print("\nThe same burst against Kinney-Graham free air for \(Int(equivalentMass)) kg.")
    var peaks: [[Double]] = []
    var impulses: [[Double]] = []
    for cellSize in cellSizes {
        let solver = try BlastSolver(device: device, scenario: open, cellSize: cellSize)
        configure(solver)
        try solver.load(open)
        solver.advance(until: 0.1)
        peaks.append(
            solver.gaugeHistories.map { history in
                Double((history.map(\.pressure).max() ?? 0) - open.atmosphere.pressure) / 1000
            })
        impulses.append(
            open.gauges.map { gauge in
                let cell = solver.nearestFluidCell(to: gauge.position)
                return Double(solver.impulse(cell.i, cell.j, cell.k))
            })
    }
    print("\nPeak overpressure (kPa)\n" + header("range"))
    for (n, gauge) in open.gauges.enumerated() {
        let range = Double(simd_distance(gauge.position, open.charge.position))
        print(
            row(
                "\(format(range, 0)) m",
                KinneyGraham.peakOverpressure(mass: equivalentMass, range: range) / 1000, peaks.map { $0[n] })
        )
    }
    print("\nPositive impulse (Pa s)\n" + header("range"))
    for (n, gauge) in open.gauges.enumerated() {
        let range = Double(simd_distance(gauge.position, open.charge.position))
        print(
            row(
                "\(format(range, 0)) m", KinneyGraham.positiveImpulse(mass: equivalentMass, range: range),
                impulses.map { $0[n] }, digits: 0))
    }
}

func runSnapshot() throws {
    var scenario = chosenScenario()
    if let mass = option("mass").flatMap({ Float($0) }) { scenario.charge.mass = mass }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let time = option("time").flatMap { Double($0) } ?? 0.03
    let output = option("out") ?? "snapshot.png"
    let width = option("width").flatMap { Int($0) } ?? 1600
    let height = option("height").flatMap { Int($0) } ?? 1000

    let solver = try makeAirSolver(scenario, cellSize: cellSize)
    solver.configuration.movingWalls = !flag("stationary-walls")
    let started = ContinuousClock.now
    var sleptAt: Double?
    var largest: Float = 0  // the structure's largest deflection, sampled every batch
    // Fragments, flown alongside a frame a millisecond, as the app does a batch at a time.
    var fragments = try option("fragments").map { path in
        FragmentConsumer(
            spec: try JSONDecoder().decode(
                FragmentSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path))),
            scene: FragmentScene(scenario), keepsFrames: false)
    }
    func feedFragments() {
        guard var consumer = fragments else { return }
        let region = consumer.report.region(
            for: consumer.frame + 1, interval: 0.001, domain: scenario.domainSize,
            cellSize: solver.grid.cellSize)
        consumer.consume(solver.airSlice(region: region.box, stride: region.stride))
        fragments = consumer
    }
    // Ground points, a sample each at every batch's end, as in the app.
    var ground = try option("ground-shock").map { path in
        GroundShockConsumer(
            spec: try JSONDecoder().decode(
                GroundShockSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path))))
    }
    func feedGround() {
        guard let region = ground?.region(cellSize: solver.grid.cellSize) else { return }
        ground?.consume(solver.groundSlice(low: region.low, high: region.high))
    }
    // The fireball's thermal radiation, reckoned a frame a millisecond, as the app does.
    var thermal = try option("thermal").map { path in
        let spec = try JSONDecoder().decode(
            ThermalSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try spec.validate()
        return ThermalExposure(spec: spec, scene: FragmentScene(scenario))
    }
    // With --thermal-compare, the same frames reckoned with another fireball model too (the
    // shape against the volume, the sphere against the shape, or --thermal-compare-with's), and
    // each timed.
    var other = thermal.map { exposure in
        var spec = exposure.spec
        if let model = option("thermal-compare-with").flatMap(FireballModel.init(rawValue:)) {
            spec.fireball = model
        } else {
            spec.fireball = spec.fireball == .shape ? .sphere : .shape
        }
        return ThermalExposure(spec: spec, scene: FragmentScene(scenario))
    }
    if !flag("thermal-compare") { other = nil }
    // With --thermal-variants a.json,b.json, the same frames reckoned under each description too.
    var variants = try (option("thermal-variants")?.split(separator: ",") ?? []).map { path in
        let spec = try JSONDecoder().decode(
            ThermalSpec.self, from: Data(contentsOf: URL(fileURLWithPath: String(path))))
        try spec.validate()
        return (name: String(path), exposure: ThermalExposure(spec: spec, scene: FragmentScene(scenario)))
    }
    var thermalSeconds = (0.0, 0.0)
    var fireballSeconds = 0.0
    // What the compared model's fireball radiated, measured round it as the volume's is.
    var otherRadiated: [(time: Double, power: Double)] = []
    var largestShape: FireballShape?
    var largestCells: LuminousCells?
    func feedThermal() {
        guard var exposure = thermal else { return }
        let extracting = ContinuousClock.now
        let frame = solver.fireball(for: exposure.spec)
        fireballSeconds += (ContinuousClock.now - extracting) / .seconds(1)
        if let shape = frame.shape, shape.volume > largestShape?.volume ?? 0 { largestShape = shape }
        if let cells = frame.cells, cells.fills.count > largestCells?.fills.count ?? 0 {
            largestCells = cells
        }
        var started = ContinuousClock.now
        exposure.add(frame)
        thermalSeconds.0 += (ContinuousClock.now - started) / .seconds(1)
        thermal = exposure
        if var compared = other {
            started = ContinuousClock.now
            compared.add(frame)
            thermalSeconds.1 += (ContinuousClock.now - started) / .seconds(1)
            otherRadiated.append((frame.time, compared.radiatedPower(frame)))
            other = compared
        }
        for n in variants.indices { variants[n].exposure.add(frame) }
    }
    feedFragments()
    feedGround()
    feedThermal()
    // The fireball cut out on the GPU at the end of each batch that lands on a frame, as a
    // headless run does.
    if let thermal { solver.frameRequest = FrameRequest(thermal: thermal.spec) }
    while solver.time < time - 1e-9 {
        let result = solver.advance(
            steps: 64,
            timeLimit: fragments == nil && thermal == nil ? time : min(time, solver.time + 0.001))
        feedFragments()
        feedGround()
        feedThermal()
        if solver.airIsAsleep, sleptAt == nil { sleptAt = solver.time }
        if let summary = solver.bodySummary() { largest = max(largest, summary.maxDisplacement) }
        if result.steps == 0 || !result.isStable { break }
    }
    let wall = ContinuousClock.now - started
    solver.refreshVisualization()

    let renderer = try SceneRenderer(device: device)
    renderer.setScene(scenario, solver: solver)
    switch option("mode") {
    case "now": renderer.settings.mode = .overpressure
    case "impulse": renderer.settings.mode = .impulse
    case "fluence": renderer.settings.thermal = .fluence
    case "irradiance": renderer.settings.thermal = .peakIrradiance
    case "temperature": renderer.settings.thermal = .surfaceTemperature
    case "ignition": renderer.settings.thermal = .ignition
    default: renderer.settings.mode = .peakOverpressure
    }
    renderer.settings.showWave = !flag("no-wave")
    if flag("highlight") {
        renderer.settings.highlight = scenario.structure?.solids.first ?? scenario.boxes.first
    }
    if let opacity = option("opacity").flatMap({ Float($0) }) { renderer.settings.waveOpacity = opacity }
    if let scale = option("scale").flatMap({ Float($0) }) { renderer.settings.pressureScale = scale }
    renderer.settings.showCharge = time == 0
    var dots: [SIMD4<Float>] = []
    if let ground {
        let result = ground.result(frameInterval: 0)
        dots += result.dots
        print("  " + result.summary)
    }
    if let thermal {
        // Painted onto the surfaces with --mode fluence, irradiance, temperature or ignition, as
        // the app paints them.
        let quantity = renderer.settings.thermal ?? .fluence
        let heating = thermal.result.heating
        let values: [Float] =
            switch quantity {
            case .fluence: thermal.fluence.map { Float($0) }
            case .peakIrradiance: thermal.peakIrradiance
            case .surfaceTemperature: heating.map { h in h.peakTemperature.map { $0 - h.ambient } } ?? []
            case .ignition: heating?.ignition.map(Float.init) ?? []
            }
        renderer.setSurfacePaint(
            SurfacePaint(
                grids: ThermalExposure.surfaceGrids(scene: FragmentScene(scenario), spec: thermal.spec),
                shades: values.map(quantity.shade)))
        print("Thermal radiation, the fireball as its \(thermal.spec.fireball.rawValue):")
        for line in thermal.result.summary { print(line) }
        // What it had radiated by each of a few moments.
        let result = thermal.result
        if result.isRadiationMeasured {
            var line = "  radiated by"
            for moment in [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.17] where moment <= time + 1e-9 {
                var sum = 0.0
                for (a, b) in zip(result.fireball, result.fireball.dropFirst()) where b.time <= moment + 1e-9
                {
                    sum += 0.5 * ((a.radiatedPower ?? 0) + (b.radiatedPower ?? 0)) * (b.time - a.time)
                }
                line += String(
                    format: " %.0f ms: %.1f%%;", moment * 1000, 100 * sum / max(result.chargeEnergy, 1))
            }
            print(line)
        }
        // How large and hot it was at each of a few moments.
        var across = "  across, and its temperature, at"
        for moment in [0.01, 0.02, 0.05, 0.1, 0.17, 0.3, 0.5] where moment <= time + 1e-9 {
            guard let frame = result.fireball.last(where: { $0.time <= moment + 1e-9 }) else { continue }
            across += String(
                format: " %.0f ms: %.1f m, %.0f K;", moment * 1000, 2 * frame.radius, frame.temperature)
        }
        print(across)
        if let other {
            print("The same frames, the fireball as its \(other.spec.fireball.rawValue):")
            for line in other.result.summary { print(line) }
            print(
                String(
                    format:
                        "Reckoned in %.2f s as its %@ and %.2f s as its %@, over %d frames; found in %.2f ms a frame",
                    thermalSeconds.0, thermal.spec.fireball.rawValue, thermalSeconds.1,
                    other.spec.fireball.rawValue,
                    thermal.frames.count, 1000 * fireballSeconds / Double(max(thermal.frames.count, 1))))
            for exposure in [thermal, other] {
                if let gpu = exposure.marchGPUSeconds {
                    print(
                        String(
                            format: "  The %@'s march: %.2f ms of GPU time a frame",
                            exposure.spec.fireball.rawValue,
                            1000 * gpu / Double(max(exposure.frames.count, 1))))
                }
            }
            let measured = zip(otherRadiated, otherRadiated.dropFirst()).reduce(0.0) {
                $0 + 0.5 * ($1.0.power + $1.1.power) * ($1.1.time - $1.0.time)
            }
            print(
                String(
                    format:
                        "As its %@, measured round it as the volume is: radiated %.1f MJ, %.1f%% of the charge's energy",
                    other.spec.fireball.rawValue, measured / 1e6,
                    100 * measured / max(other.result.chargeEnergy, 1)))
            // Each receiver's fluence by the first model against the second, by surface.
            let (shape, sphere) = (thermal, other)
            var surfaces: [String] = []
            for receiver in shape.receivers where !surfaces.contains(receiver.surface) {
                surfaces.append(receiver.surface)
            }
            for surface in surfaces {
                let indices = shape.receivers.indices.filter { shape.receivers[$0].surface == surface }
                let a = indices.reduce(0.0) { $0 + shape.fluence[$1] }
                let b = indices.reduce(0.0) { $0 + sphere.fluence[$1] }
                let lit = indices.filter { shape.fluence[$0] > 0 || sphere.fluence[$0] > 0 }
                let ratios = lit.map { (shape.fluence[$0] + 1) / (sphere.fluence[$0] + 1) }.sorted()
                let median = ratios.isEmpty ? 0 : ratios[ratios.count / 2]
                let shapeOnly = indices.filter { shape.fluence[$0] > 1000 && sphere.fluence[$0] < 1 }.count
                let sphereOnly = indices.filter { sphere.fluence[$0] > 1000 && shape.fluence[$0] < 1 }.count
                print(
                    String(
                        format:
                            "  %@: mean fluence %.1f kJ/m² as the %@, %.1f as the %@ (%+.0f%%); median ratio %.2f; over 1 kJ/m² by one only: %d, %d",
                        surface, a / Double(indices.count) / 1000, shape.spec.fireball.rawValue,
                        b / Double(indices.count) / 1000, sphere.spec.fireball.rawValue,
                        100 * (a / max(b, 1) - 1), median, shapeOnly, sphereOnly))
            }
        }
        for variant in variants {
            print("The same frames, as \(variant.name) describes them:")
            for line in variant.exposure.result.summary { print(line) }
        }
        if let largestCells {
            print(
                String(
                    format: "Largest cells: %d by %d by %d voxels %.3f m a side, %.2f MB a frame",
                    largestCells.counts.x,
                    largestCells.counts.y, largestCells.counts.z, largestCells.voxelSize,
                    Double(largestCells.binary.count) / 1e6))
        }
        if solver.configuration.radiativeCooling != nil {
            // What the gas lost to its radiation by each of the same moments.
            var line = String(
                format: "The gas lost %.1f MJ to its radiation, %.1f%% of the charge's energy; by",
                solver.radiatedEnergy / 1e6, 100 * solver.radiatedEnergy / max(thermal.result.chargeEnergy, 1)
            )
            for moment in [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.17] where moment <= time + 1e-9 {
                let lost = solver.radiationHistory.last { $0.time <= moment + 1e-9 }?.energy ?? 0
                line += String(
                    format: " %.0f ms: %.1f%%;", moment * 1000,
                    100 * lost / max(thermal.result.chargeEnergy, 1))
            }
            print(line)
        }
        let unburnt = solver.speciesTotals()
        if unburnt.fuel > 0 {
            print(
                String(
                    format: "Unburnt products left: %.1f kg of %.1f kg", unburnt.fuel, scenario.charge.mass))
        }
        if let largestShape {
            print(
                String(
                    format: "Largest shape: %.1f m³ in blocks %.2f m a side, %d by %d by %d, %d tiles",
                    largestShape.volume, largestShape.blockSize, largestShape.counts.x, largestShape.counts.y,
                    largestShape.counts.z, largestShape.tileCount))
        }
    }
    if let fragments {
        let launch = max(fragments.cloud.launchSpeed, 1)
        for (n, particle) in fragments.cloud.particles.enumerated() where !particle.landed {
            let value =
                n < fragments.cloud.fragmentCount ? min(simd_length(particle.velocity) / launch, 0.999) : 1
            dots.append(SIMD4(particle.position, value))
        }
        for impact in fragments.cloud.impacts {
            dots.append(SIMD4(impact.position, 2 + min(max(log10(max(impact.energy, 1)) / 7, 0), 0.999)))
        }
        print("Fragments: \(fragments.cloud.airborne) in flight, \(fragments.cloud.impacts.count) landed")
    }
    renderer.setDots(dots)
    if let size = option("dot").flatMap({ Float($0) }) { renderer.settings.dotSize = size }
    var camera = OrbitCamera.framing(scenario)
    if let distance = option("distance").flatMap({ Float($0) }) { camera.distance = distance }
    if let azimuth = option("azimuth").flatMap({ Float($0) }) { camera.azimuth = azimuth }
    if let elevation = option("elevation").flatMap({ Float($0) }) { camera.elevation = elevation }
    // The fireball's cloud, handed over at the end and followed, drawn as the app draws it, and
    // with --frame-cloud seen as its button frames it.
    if let path = option("cloud") {
        let spec = try JSONDecoder().decode(
            CloudSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let cloud = CloudResult(
            spec: spec, handOver: solver.cloudHandOver(hotterThan: spec.handOverTemperature))
        for line in cloud.summary { print(line) }
        if let results = option("cloud-results") {
            try JSONEncoder().encode(cloud).write(to: URL(fileURLWithPath: results))
        }
        if flag("frame-cloud") { camera = CloudOverlay.framing(cloud) }
        if let distance = option("distance").flatMap({ Float($0) }) { camera.distance = distance }
        if let azimuth = option("azimuth").flatMap({ Float($0) }) { camera.azimuth = azimuth }
        if let elevation = option("elevation").flatMap({ Float($0) }) { camera.elevation = elevation }
        renderer.setLines(CloudOverlay.lines(cloud, eye: camera.eye))
    }

    guard
        let frame = renderer.snapshot(
            commandQueue: solver.commandQueue, width: width, height: height, camera: camera),
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        print("Could not render the snapshot")
        exit(1)
    }
    CGImageDestinationAddImage(destination, frame.image, nil)
    CGImageDestinationFinalize(destination)
    print(
        "Wrote \(output): t = \(format(solver.time * 1000)) ms after \(solver.stepCount) steps, "
            + "frame rendered in \(format(frame.gpuSeconds * 1000, 2)) ms")
    print(
        "Simulated in \(format(Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18, 1)) s"
            + (sleptAt.map { "; the air went quiet and was frozen at \(format($0 * 1000, 0)) ms" } ?? ""))
    if let summary = solver.bodySummary() {
        print(
            "Structure: \(summary.activeElements) elements intact, \(summary.erodedElements) failed, "
                + "deflection \(format(Double(summary.maxDisplacement) * 1000, 0)) mm "
                + "(largest \(format(Double(largest) * 1000, 0)) mm), "
                + "worst damage \(format(Double(min(summary.maxDamage, 1)) * 100, 0))%")
    }
}

/// Times a structure meshed with shells (and beams) on its own.
func runShellStructure(_ base: StructureModel) throws {
    var model = base
    model.elementKind = .shell
    model.elementSize = option("shells").flatMap { Float($0) } ?? 0.25
    if let layers = option("shell-layers").flatMap({ Int($0) }) { model.shellLayers = layers }
    let solver = try ShellSolver(device: device, model: model)
    if flag("contact") { solver.contactMode = .always }
    solver.advance(steps: 200)
    let steps = 4000
    let start = ContinuousClock.now
    solver.advance(steps: steps)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let stepSeconds = Double(solver.criticalTimeStep)
    let count = solver.elementCount + solver.beamCount
    print(
        "Structure: \(solver.elementCount) shells and \(solver.beamCount) beams of "
            + "\(format(Double(model.elementSize) * 1000, 0)) mm, \(model.shellLayers) layers, "
            + "time step \(format(stepSeconds * 1e6, 1)) µs, \(format(Double(solver.memoryFootprint) / 1e6, 0)) MB"
    )
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(count) / seconds / 1e6, 1)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 1))x slower than real time")
}

/// Times the structural solver on its own, without the air.
func runStructure() throws {
    guard var model = preset(named: option("preset") ?? "box").scenario.structure else {
        print("That preset has no deformable structure; try --preset wall or --preset box.")
        return
    }
    if flag("elastic") {
        // The same mesh with a linear elastic material, to show what the concrete law costs.
        let concrete = model.material
        model.material = .elastic(
            density: concrete.density, youngsModulus: concrete.youngsModulus,
            poissonRatio: concrete.poissonRatio)
        model.reinforcement = []
    }
    if flag("shells") || option("shells") != nil {
        try runShellStructure(model)
        return
    }
    let solver = try StructureSolver(device: device, model: model)
    if flag("contact") { solver.contactMode = .always }
    solver.advance(steps: 200)
    let steps = 4000
    let start = ContinuousClock.now
    solver.advance(steps: steps)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let stepSeconds = Double(solver.criticalTimeStep)
    print("Device: \(device.name)")
    print(
        "Structure: \(solver.elementCount) hexahedral elements of \(format(Double(model.elementSize) * 1000, 1)) mm, "
            + "\(model.material.name.lowercased()), time step \(format(stepSeconds * 1e6, 1)) µs, "
            + "contact \(solver.contactMode == .always ? "on" : "off until something fails"), "
            + "\(format(Double(solver.memoryFootprint) / 1e6, 0)) MB")
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(solver.elementCount) / seconds / 1e6, 0)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 0))x slower than real time")
}

/// Compares the structural model with the measured response of the Blast Blind Simulation
/// Contest's normal-strength slab.
/// Janney's reinforced beam bent slowly to failure, against the measured moment and deflection.
func runBeam() throws {
    print("Reinforced concrete beam in four-point bending (Janney, Hognestad and McHenry, 1956)")
    print(
        "Measured: yield near 37 kN m at 11 mm, \(format(Double(BeamBenchmark.measuredPeakMoment) / 1000)) kN m "
            + "at failure, \(format(Double(BeamBenchmark.measuredFailureDeflection) * 1000, 0)) mm; "
            + "section analysis \(format(Double(BeamBenchmark.sectionMoment) / 1000)) kN m\n")
    // `--layers 12,24` chooses the meshes, by elements through the depth; `--rate` the plates' speed (m/s).
    let meshes = (option("layers") ?? "12,24").split(separator: ",").compactMap { Int($0) }
    let rate = option("rate").flatMap { Float($0) } ?? 0.1
    var results: [(layers: Int, result: BeamBenchmark.Result)] = []
    print(
        pad("layers", 8) + pad("elements", 10) + pad("peak", 12) + pad("vs test", 9) + pad("fails at", 10)
            + pad("rms", 10) + pad("failed", 8) + pad("run time", 10))
    for layers in meshes {
        // `--crack-spacing 25` sets the distance, in millimetres, a crack's energy is spread over.
        let spacing = option("crack-spacing").flatMap { Float($0) }
        let dowel = option("dowel").flatMap { Float($0) }
        let result = try BeamBenchmark.run(
            device: device, elementsThroughDepth: layers,
            deflection: option("to").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.06, rate: rate,
            unload: flag("unload"), crackSlip: !flag("no-crack-slip"), crackAxes: chosenCrackAxes(),
            bondSlip: chosenBondSlip(diameter: 0.019), crackShearStiffness: flag("crack-shear"),
            slipWidensCracks: !flag("slide-apart"), pressedInterlock: flag("pressed-interlock")
        ) { material in
            applyRateOptions(&material)
            if let spacing { material.crackSpacing = spacing / 1000 }
            if let dowel { material.dowelFactor = dowel }
        }
        results.append((layers, result))
        if let residual = result.residual {
            print(
                "  unloaded from \(format(Double(result.curve.last?.x ?? 0) * 1000, 1)) mm: \(format(Double(residual) * 1000, 1)) mm left"
            )
        }
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                + pad("\(format(Double(result.peakMoment) / 1000)) kN m", 12)
                + pad("\(format(Double(result.peakMoment / BeamBenchmark.measuredPeakMoment) * 100, 0))%", 9)
                + pad(result.failureDeflection.map { "\(format(Double($0) * 1000, 0)) mm" } ?? "holds", 10)
                + pad("\(format(Double(result.curveError()) / 1000)) kN m", 10)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
    }
    print("\nMid-span moment (kN m) against central deflection:")
    print(
        pad("deflection", 12) + pad("measured", 10) + results.map { pad("\($0.layers) layers", 12) }.joined())
    for millimetres in [1, 2, 5, 8, 10, 12, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60] {
        let deflection = Float(millimetres) / 1000
        let measured =
            deflection <= BeamBenchmark.measuredFailureDeflection
            ? format(Double(BeamBenchmark.measuredMoment(at: deflection)) / 1000) : "failed"
        print(
            pad("\(millimetres) mm", 12) + pad(measured, 10)
                + results.map { pad(format(Double($0.result.moment(at: deflection)) / 1000), 12) }.joined())
    }
}

/// A 1 kg charge burst in the air at each scaled distance above rigid ground, against the
/// Kingery-Bulmash reflected peak and impulse under it (the surface-burst curves at W / 1.8).
func runCloseAir() throws {
    let distances =
        option("z").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0.3, 0.5, 0.75, 1]
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.02
    print(
        "1 kg TNT burst in the air above rigid ground, reflected square on below it; cells \(format(Double(cellSize), 3)) m"
    )
    print(pad("Z", 6) + pad("K-B peak", 12) + pad("model", 14) + pad("K-B impulse", 14) + pad("model", 16))
    var refinement = SolverConfiguration()
    configureRefinement(&refinement)
    let finest =
        refinement.refinement > 1
        ? Int(pow(Double(refinement.refinement), Double(refinement.refinementLevels))) : 1
    for z in distances {
        let height = z
        let size = max(3 * height, 1.2)
        var scenario = Scenario(
            name: "Close-in reflection", domainSize: SIMD3(size, size, 2 * height + 0.4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(size / 2, size / 2, height)),
            gauges: [
                Gauge(
                    "ground",
                    // In the air cell against the ground, refined or not (a quarter of the finest
                    // cell up): a cell further up misses the momentum the gas still carries
                    // towards it.
                    at: SIMD3(
                        size / 2, size / 2,
                        (option("gauge-cells").flatMap { Float($0) } ?? 0.25 / Float(finest)) * cellSize))
            ])
        scenario.reflectiveFaces = .ground
        let solver = try makeAirSolver(scenario, cellSize: cellSize)
        solver.advance(until: Double(height) / 340 + 0.004)
        let samples = solver.gaugeHistories[0]
        let ambient = scenario.atmosphere.pressure
        let peak = (samples.map(\.pressure).max() ?? ambient) - ambient
        var impulse: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
        }
        let w = 1.0 / 1.8
        guard let point = KingeryBulmash.point(at: Double(height) / cbrt(w)) else { continue }
        if flag("field") {
            let cell = solver.nearestFluidCell(to: scenario.gauges[0].position)
            print(
                "  field at the gauge: peak \(format(Double(solver.peakOverpressure(cell.i, cell.j, cell.k)) / 1e6, 1)) MPa, impulse \(format(Double(solver.impulse(cell.i, cell.j, cell.k)), 0)) Pa s; \(samples.count) samples"
            )
        }
        print(
            pad(format(Double(z), 2), 6) + pad("\(format(point.reflectedPressure / 1e6, 1)) MPa", 12)
                + pad(
                    "\(format(Double(peak) / 1e6, 1)) (\(format(Double(peak) / point.reflectedPressure * 100, 0))%)",
                    14)
                + pad("\(format(point.reflectedImpulse(mass: w), 0)) Pa s", 14)
                + pad(
                    "\(format(Double(impulse), 0)) (\(format(Double(impulse) / point.reflectedImpulse(mass: w) * 100, 0))%)",
                    16))
    }
}

/// Prints once, at `time`, where along the span elements have failed or been left as bare bars,
/// in 0.2 m bins, and the centre's deflection, with the bolt lines' nodes' slip lengthwise.
func failureProbe(at time: Double) -> (StructureSolver, Double) -> Void {
    var done = false
    return { structure, now in
        guard !done, now >= time else { return }
        done = true
        let h = structure.model.elementSize
        var bins: [Int: (eroded: Int, bare: Int)] = [:]
        for k in 0..<structure.ez {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex {
                    let flag = structure.flag(i, j, k)
                    guard flag == .eroded || flag == .bare else { continue }
                    let x = structure.origin.x + (Float(i) + 0.5) * h
                    let bin = Int(x / 0.2)
                    var entry = bins[bin] ?? (0, 0)
                    if flag == .eroded { entry.eroded += 1 } else { entry.bare += 1 }
                    bins[bin] = entry
                }
            }
        }
        print("  failed / bare elements along the span at \(format(now * 1000, 0)) ms:")
        for bin in bins.keys.sorted() {
            print(
                "    x \(format(Double(bin) * 0.2, 1))-\(format(Double(bin + 1) * 0.2, 1)) m: \(bins[bin]!.eroded) / \(bins[bin]!.bare)"
            )
        }
        let c = CloseInSlabTest.centre
        let j = Int(((c.y - structure.origin.y) / h).rounded())
        for bolt in [Float(1.4), 5.4] {
            let i = Int(((bolt - structure.origin.x) / h).rounded())
            let k = structure.ez / 2
            print(
                "    bolt line \(format(Double(bolt), 1)) m: node displaced \(structure.displacement(i, j, k))"
            )
        }
    }
}

/// Prints, at a few times, the column of elements under the charge from the bottom face up: crack
/// strain, damage, the frozen tensile rate factor, the strain rate and the element's state; and
/// how fast the bottom face moves against the middle of the slab.
func spallProbe() -> (StructureSolver, Double) -> Void {
    var times = [0.0003, 0.0006, 0.001, 0.002, 0.005, 0.01, 0.02]
    return { structure, time in
        guard let next = times.first, time >= next else { return }
        times.removeFirst()
        let h = structure.model.elementSize
        let c = CloseInSlabTest.centre
        let i = Int(((c.x - structure.origin.x) / h).rounded())
        let j = Int(((c.y - structure.origin.y) / h).rounded())
        let top = (0...structure.ez).last { structure.storedNode(i, j, $0) != nil } ?? 0
        print("  t = \(format(time * 1000, 2)) ms: k  crack  damage  factor  rate/s  state")
        for k in 0..<top {
            let flag = structure.flag(i, j, k)
            print(
                "      " + pad("\(k)", 3) + pad(format(Double(structure.crackStrain(i, j, k)), 3), 7)
                    + pad(format(Double(structure.damage(i, j, k)), 2), 8)
                    + pad(format(Double(structure.crackingFactor(i, j, k)), 2), 8)
                    + pad(format(Double(structure.strainRate(i, j, k)), 0), 8) + "  \(flag)")
        }
        let bottom = structure.node(i, j, 0).velocity.z
        let middle = structure.node(i, j, top / 2).velocity.z
        print(
            "      bottom face \(format(Double(bottom), 1)) m/s, mid-depth \(format(Double(middle), 1)) m/s")
    }
}

/// Writes, at every sample until `until` seconds, the state of each element through the slab's
/// thickness at a few distances from under the charge along the span, as CSV: stresses, node
/// velocities, crack and crush histories with the crack planes' tilt, compaction, rate factors.
func closeInTrace(path: String, until: Double) -> (StructureSolver, Double) -> Void {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = FileHandle(forWritingAtPath: path)!
    handle.write(
        ("t,dx,k,flag,sxx,syy,szz,vzLow,vzHigh,h0,h1,h2,n0z,n1z,n2z,c0,c1,c2,compaction,factor,rate,"
            + "display,barX,barY,uz,g0,g1,g2,syz,szx\n").data(using: .utf8)!)
    var next = until
    return { structure, time in
        // Every sample until `until`, then every quarter of a millisecond.
        if time > until {
            guard time >= next else { return }
            next += 0.00025
        }
        let h = structure.model.elementSize
        let c = CloseInSlabTest.centre
        let i0 = Int(((c.x - structure.origin.x) / h).rounded())
        let j = Int(((c.y - structure.origin.y) / h).rounded())
        let top = (0...structure.ez).last { structure.storedNode(i0, j, $0) != nil } ?? 0
        var text = ""
        for dx: Float in [0, 0.1, 0.2, 0.3, 0.5, 1.0] {
            let i = i0 + Int((dx / h).rounded())
            for k in 0..<top {
                let s = structure.stress(i, j, k)
                let planes = structure.crackPlanes(i, j, k)
                let nz = planes.normals.map { abs($0.z) } + [0, 0, 0]
                let bars = structure.barPlasticStrain(i, j, k)
                let values: [Float] =
                    [
                        s[0] / 1e6, s[1] / 1e6, s[2] / 1e6, structure.node(i, j, k).velocity.z,
                        structure.node(i, j, k + 1).velocity.z, planes.history.x, planes.history.y,
                        planes.history.z, nz[0], nz[1], nz[2], planes.crush.x, planes.crush.y, planes.crush.z,
                        structure.compaction(i, j, k), structure.crackingFactor(i, j, k),
                        structure.strainRate(i, j, k), structure.damage(i, j, k), bars.x, bars.y,
                        structure.displacement(i, j, k).z,
                    ] + structure.confinement(i, j, k) + [s[4] / 1e6, s[5] / 1e6]
                text +=
                    "\(time),\(dx),\(k),\(structure.flag(i, j, k)),"
                    + values.map { String(format: "%.5g", $0) }.joined(separator: ",") + "\n"
            }
        }
        handle.write(text.data(using: .utf8)!)
    }
}

/// Prints, once at `time`, how far the slab's faces are cracked loose, by distance from under the
/// charge: on the bottom and top layers of elements, the share whose crack most nearly parallel
/// to the face has opened past 0.5, 1, 2 and 5 mm, and the share removed or left bare.
func faceProbe(at time: Double) -> (StructureSolver, Double) -> Void {
    var done = false
    return { structure, now in
        guard !done, now >= time else { return }
        done = true
        let h = structure.model.elementSize
        let c = CloseInSlabTest.centre
        let i0 = Int(((c.x - structure.origin.x) / h).rounded())
        let j0 = Int(((c.y - structure.origin.y) / h).rounded())
        let top = (0...structure.ez).last { structure.storedNode(i0, j0, $0) != nil } ?? 0
        for (name, k) in [("bottom", 0), ("top", top - 1)] {
            print("  \(name) layer at \(format(now * 1000, 1)) ms: r (m)  n  >0.5  >1  >2  >5 mm  gone")
            var bins: [Int: [Int]] = [:]
            for j in 0..<structure.ey {
                for i in 0..<structure.ex where structure.flag(i, j, k) != .empty {
                    let x = (Float(i) + 0.5) * h + structure.origin.x - c.x
                    let y = (Float(j) + 0.5) * h + structure.origin.y - c.y
                    let bin = Int((x * x + y * y).squareRoot() / 0.1)
                    var counts = bins[bin] ?? [0, 0, 0, 0, 0, 0]
                    counts[0] += 1
                    let flag = structure.flag(i, j, k)
                    if flag == .eroded || flag == .bare {
                        counts[5] += 1
                    } else {
                        let planes = structure.crackPlanes(i, j, k)
                        var opening: Float = 0
                        for p in 0..<3 where abs(planes.normals[p].z) > 0.7 {
                            opening = max(opening, planes.history[p] * h)
                        }
                        for (n, limit) in [Float(0.5e-3), 1e-3, 2e-3, 5e-3].enumerated() where opening > limit
                        {
                            counts[n + 1] += 1
                        }
                    }
                    bins[bin] = counts
                }
            }
            for bin in bins.keys.sorted() where bin < 12 {
                let n = bins[bin]!
                let share = n.dropFirst().map { pad(format(Double($0) / Double(n[0]) * 100, 0), 5) }
                print("    " + pad(format(Double(bin) * 0.1, 1), 5) + pad("\(n[0])", 5) + share.joined())
            }
        }
        // Rubble: elements cracked open across all three planes, by distance from under the charge
        // and layer.
        print("  cracked open across all three planes (> 0.25 mm / > 0.5 mm), by r (m) and layer k:")
        var rubble: [Int: [Int]] = [:]
        for k in 0..<top {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex where structure.flag(i, j, k) == .active {
                    let planes = structure.crackPlanes(i, j, k)
                    let least = planes.history.min() * h
                    guard least > 0.25e-3 else { continue }
                    let x = (Float(i) + 0.5) * h + structure.origin.x - c.x
                    let y = (Float(j) + 0.5) * h + structure.origin.y - c.y
                    let bin = min(Int((x * x + y * y).squareRoot() / 0.1), 20)
                    var counts = rubble[bin] ?? Array(repeating: 0, count: 2 * top)
                    counts[k] += 1
                    if least > 0.5e-3 { counts[top + k] += 1 }
                    rubble[bin] = counts
                }
            }
        }
        for bin in rubble.keys.sorted() {
            let n = rubble[bin]!
            print(
                "    " + pad(format(Double(bin) * 0.1, 1), 5) + n.prefix(top).map { pad("\($0)", 5) }.joined()
                    + "  /" + n.suffix(top).map { pad("\($0)", 5) }.joined())
        }
        print("  removed / left bare, by r (m) and layer k:")
        var gone: [Int: [Int]] = [:]
        for k in 0..<top {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex {
                    let flag = structure.flag(i, j, k)
                    guard flag == .eroded || flag == .bare else { continue }
                    let x = (Float(i) + 0.5) * h + structure.origin.x - c.x
                    let y = (Float(j) + 0.5) * h + structure.origin.y - c.y
                    let bin = min(Int((x * x + y * y).squareRoot() / 0.1), 20)
                    var counts = gone[bin] ?? Array(repeating: 0, count: 2 * top)
                    counts[flag == .eroded ? k : top + k] += 1
                    gone[bin] = counts
                }
            }
        }
        for bin in gone.keys.sorted() {
            let n = gone[bin]!
            print(
                "    " + pad(format(Double(bin) * 0.1, 1), 5) + n.prefix(top).map { pad("\($0)", 5) }.joined()
                    + "  /" + n.suffix(top).map { pad("\($0)", 5) }.joined())
        }
    }
}

/// Prints, at a few times, the slab's kinetic energy, its downward momentum and how fast that is
/// changing, and the energy of a rigid-plastic mechanism with the same angular momentum: the two
/// halves turning about their bolt lines.
func energyProbe() -> (StructureSolver, Double) -> Void {
    var times = [0.0005, 0.001, 0.0015, 0.002, 0.003, 0.004, 0.005, 0.0075, 0.01, 0.02, 0.03, 0.05, 0.08]
    var last: (time: Double, momentum: Double)?
    return { structure, time in
        guard let next = times.first, time >= next else { return }
        times.removeFirst()
        let h = structure.model.elementSize
        let mid = CloseInSlabTest.centre.x
        var kinetic = 0.0
        var momentum = 0.0
        var angular = [0.0, 0.0]
        var inertia = [0.0, 0.0]
        for k in 0...structure.ez {
            for j in 0...structure.ey {
                for i in 0...structure.ex where structure.storedNode(i, j, k) != nil {
                    let n = structure.node(i, j, k)
                    let v = SIMD3<Double>(n.velocity)
                    kinetic += 0.5 * Double(n.mass) * simd_length_squared(v)
                    momentum += Double(n.mass) * v.z
                    let x = Double(structure.origin.x + Float(i) * h)
                    let side = x < Double(mid) ? 0 : 1
                    let bolts = CloseInSlabTest.boltLines
                    let arm = Double(side == 0 ? Float(x) - bolts[0] : bolts[1] - Float(x))
                    if arm > 0 {
                        angular[side] += Double(n.mass) * v.z * arm
                        inertia[side] += Double(n.mass) * arm * arm
                    }
                }
            }
        }
        let mechanism = zip(angular, inertia).reduce(0.0) { $0 + 0.5 * $1.0 * $1.0 / $1.1 }
        let rate = last.map { (momentum - $0.momentum) / (time - $0.time) } ?? 0
        last = (time, momentum)
        print(
            "  \(format(time * 1000, 1)) ms: kinetic \(format(kinetic / 1000, 1)) kJ, momentum \(format(-momentum, 0)) N s "
                + "(changing at \(format(-rate / 1000, 0)) kN), halves turning about the bolts \(format(mechanism / 1000, 1)) kJ"
        )
    }
}

/// Chiquito et al.'s full-scale slabs under charges hung 0.5 and 1 m above them.
func runCloseIn() throws {
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.05
    let elementSize = option("h").flatMap { Float($0) } ?? 0.025
    let duration = option("time").flatMap { Double($0) } ?? 0.3
    let refinement = option("refine").flatMap { Int($0) } ?? 1
    print("Full-scale slabs under close-in charges (Chiquito et al., 2023)")
    print(
        "Air cells \(format(Double(cellSize), 3)) m\(refinement > 1 ? ", refined by \(refinement)" : ""), "
            + "elements \(format(Double(elementSize), 3)) m, \(format(duration * 1000, 0)) ms\n")
    func percent(_ value: Float?) -> String { value.map { "\(format(Double($0) * 100, 1))%" } ?? "-" }
    func mm(_ value: Float?) -> String { value.map { "\(format(Double($0) * 1000, 0))" } ?? "-" }
    for test in CloseInSlabTest.tests where names?.contains(test.name) ?? true {
        var inspect: ((StructureSolver, Double) -> Void)? =
            flag("spall") ? spallProbe() : flag("where") ? failureProbe(at: duration * 0.99) : nil
        if flag("faces") { inspect = faceProbe(at: duration * 0.99) }
        if flag("energy") { inspect = energyProbe() }
        if let path = option("trace") {
            let until = option("trace-until").flatMap { Double($0) } ?? 0.001
            inspect = closeInTrace(path: path.replacingOccurrences(of: "%", with: test.name), until: until)
        }
        let result = try CloseInSlabTest.run(
            device: device, test: test, cellSize: cellSize, elementSize: elementSize, duration: duration,
            refinement: refinement, mappedCharge: !flag("no-map"), afterburning: flag("afterburn"),
            heldLengthwise: !flag("sliding"), stepsPerSample: option("trace") != nil ? 1 : 16,
            adjust: { scenario in
                if flag("no-rate") { scenario.structure?.material.rateDependent = false }
                if let scale = option("charge-scale").flatMap({ Float($0) }) { scenario.charge.mass *= scale }
                if let dowel = option("dowel").flatMap({ Float($0) }) {
                    scenario.structure?.material.dowelFactor = dowel
                }
                if let rupture = option("rupture").flatMap({ Float($0) }) {
                    scenario.structure?.material.steel?.ruptureStrain = rupture
                }
                if flag("no-bare") { scenario.structure?.bareBars = false }
                if flag("skirts") {
                    // Walls along the slab's long edges, from the ground to just below it, which
                    // close the space under it to the wave.
                    let slab = CloseInSlabTest.slab
                    for (low, high) in [(slab.min.y - 0.1, slab.min.y), (slab.max.y, slab.max.y + 0.1)] {
                        scenario.boxes.append(
                            Box(min: SIMD3(1.4, low, 0), max: SIMD3(5.4, high, slab.min.z - 0.02)))
                    }
                }
                if flag("under") {
                    // Under the slab, 0.1 m below its bottom face, at its centre and 1 m along the
                    // span; and on the ground below its centre.
                    let c = CloseInSlabTest.centre
                    let bottom = CloseInSlabTest.slab.min.z - 0.1
                    scenario.gauges += [
                        Gauge("Under, centre", at: SIMD3(c.x, c.y, bottom)),
                        Gauge("Under, 1 m along", at: SIMD3(c.x + 1, c.y, bottom)),
                        Gauge("Ground, centre", at: SIMD3(c.x, c.y, 0.01)),
                    ]
                }
                if var structure = scenario.structure {
                    applyRateOptions(&structure)
                    // `--bond pullout`: bars that slip, of the 12 mm bars' diameter.
                    if let bond = chosenBondSlip(diameter: 0.012) { structure.bondSlip = bond }
                    scenario.structure = structure
                }
            },
            progress: flag("progress")
                ? { line in
                    print("  " + line)
                    fflush(stdout)
                } : nil,
            inspect: inspect)
        if let path = option("trace") {
            let centre = result.gaugeHistories[5]
            let text = centre.map { "\($0.time),\($0.pressure)" }.joined(separator: "\n")
            try text.write(
                toFile: path.replacingOccurrences(of: "%", with: test.name + "-gauge"), atomically: true,
                encoding: .utf8)
        }
        print(
            "\(test.name): \(format(Double(test.charge), 2)) kg TNT at \(format(Double(test.standoff), 1)) m; \(test.remark)"
        )
        print("                      measured        model")
        print(
            "  permanent (mm)      " + pad(mm(test.deflection), 15)
                + "  \(mm(result.permanent)) (peak \(mm(result.peak)))")
        print(
            "  spalled, top        " + pad(percent(test.damagedTop), 15) + "  \(percent(result.damagedTop))")
        print(
            "  spalled, bottom     " + pad(percent(test.damagedBottom), 15)
                + "  \(percent(result.damagedBottom))")
        print(
            "  perforated          " + pad(test.perforated ? "yes" : "no", 15)
                + "  \(result.perforated ? "yes" : "no")")
        let measured = [
            test.nearGauge, test.nearGauge, test.farGauge, test.farGauge, nil, nil, nil, nil, nil,
        ]
        for ((name, pressure), range) in zip(result.gaugePeaks, measured) {
            let text =
                range.map {
                    $0.lowerBound == $0.upperBound
                        ? format(Double($0.lowerBound) / 1e6, 2)
                        : "\(format(Double($0.lowerBound) / 1e6, 2))-\(format(Double($0.upperBound) / 1e6, 2))"
                } ?? "-"
            print(
                "  \(pad(name + " (MPa)", 18))  " + pad(text, 15) + "  \(format(Double(pressure) / 1e6, 2))")
        }
        print("  impulse at the slab's centre: \(format(Double(result.gaugeImpulses[5]), 0)) Pa s")
        for n in result.gaugeImpulses.indices.dropFirst(6) {
            print(
                "  impulse, \(result.gaugePeaks[n].name): \(format(Double(result.gaugeImpulses[n]), 0)) Pa s")
        }
        print("  slab's momentum at 5 ms: \(format(Double(result.impulse), 0)) N s")
        print("  \(result.summary.erodedElements) elements failed; \(format(result.wallSeconds, 0)) s\n")
    }
}

/// Saatci's beams struck by a falling weight (first impacts), against the measured peak and
/// residual mid-span displacements.
func runImpact() throws {
    print("Saatci's beams (2007), struck at mid-span by a weight falling at 8 m/s; first impacts\n")
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let layers = option("layers").flatMap { Int($0) } ?? 16
    let duration = option("time").flatMap { Double($0) } ?? 0.2
    print(
        pad("test", 8) + pad("weight", 8) + pad("measured", 18) + pad("model", 18) + pad("reaction", 18)
            + pad("failed", 8) + pad("run time", 10))
    if flag("ando") {
        // Ando et al. (2000): beams without stirrups, struck once each by 300 kg.
        print(
            pad("test", 8) + pad("speed", 8) + pad("measured", 22) + pad("model", 20) + pad("failed", 8)
                + "  remark")
        if let push = option("push").flatMap({ Float($0) }) {
            // `--push 0.026`: each beam pushed slowly through its plate to that deflection and let go.
            for test in ImpactBenchmark.shearTests where names?.contains(test.name) ?? true {
                var specimen = ImpactBenchmark.specimen(test)
                specimen.spreadBars = flag("spread")
                chooseSupports(&specimen)
                let result = try ImpactBenchmark.run(
                    device: device, specimen: specimen, weight: 0, speed: 0, elementsThroughDepth: layers,
                    push: push
                ) { model in
                    if flag("no-rate") { model.material.rateDependent = false }
                    applyRateOptions(&model)
                } inspect: { solver in
                    if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
                    if flag("bars") { printBarYield(solver) }
                }
                print(
                    pad(test.name, 8) + "  pushed to \(format(Double(push) * 1000)) mm: largest load "
                        + "\(format(Double(result.peakReaction) / 1000, 1)) kN, "
                        + "left \(format(Double(result.residual) * 1000)) mm down, "
                        + "\(result.summary.erodedElements) failed")
            }
            return
        }
        for test in ImpactBenchmark.shearTests where names?.contains(test.name) ?? true {
            let result = try ImpactBenchmark.run(
                device: device, test: test, elementsThroughDepth: layers, duration: min(duration, 0.15),
                spreadBars: flag("spread"), specimen: chooseSupports
            ) { model in
                if flag("no-rate") { model.material.rateDependent = false }
                // `--bond`: the D19 or D13 bars slip.
                if let bond = chosenBondSlip(diameter: test.heavyBars ? 0.019 : 0.013) {
                    model.bondSlip = bond
                }
                applyRateOptions(&model)
            } inspect: { solver in
                if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
                if flag("bars") { printBarYield(solver) }
            }
            let numbers =
                "\(test.peak.map { format(Double($0) * 1000) } ?? "-") / \(test.residual.map { format(Double($0) * 1000) } ?? "-")"
            let measured = test.broken ? "\(numbers), broken" : numbers
            print(
                pad(test.name, 8) + pad("\(format(Double(test.speed), 0)) m/s", 8) + pad(measured, 22)
                    + pad(
                        "\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm",
                        20)
                    + pad("\(result.summary.erodedElements)", 8) + "  " + test.remark)
            if flag("bars") {
                print("    largest reaction at a support \(format(Double(result.peakReaction) / 1000, 0)) kN")
            }
            if flag("history") {
                // Mid-span displacement every 5 ms, in mm.
                let samples = stride(from: 0.0, through: min(duration, 0.15), by: 0.005).map { t in
                    result.history.first { Double($0.x) >= t }.map { format(Double($0.y) * 1000, 1) } ?? "-"
                }
                print("    " + samples.joined(separator: " "))
            }
        }
        return
    }
    if let size = option("beams").flatMap({ Float($0) }) {
        print(
            pad("test", 8) + pad("weight", 8) + pad("measured", 18) + pad("beams", 18) + pad("reaction", 18)
                + pad("sheared", 9) + pad("removed", 9))
        for test in ImpactBenchmark.tests where names?.contains(test.name) ?? true {
            let result = try ImpactBenchmark.runBeams(
                device: device, test: test, size: size, duration: duration,
                sectionShear: !flag("no-section-shear"))
            let measured =
                test.peak.map {
                    "\(format(Double($0) * 1000)) / \(format(Double(test.residual ?? 0) * 1000)) mm"
                }
                ?? "failed"
            print(
                pad(test.name, 8) + pad("\(Int(test.weight)) kg", 8) + pad(measured, 18)
                    + pad(
                        "\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm",
                        18)
                    + pad(
                        "\(Int(test.reaction / 1000)) / \(format(Double(result.peakReaction) / 1000, 0)) kN",
                        18)
                    + pad("\(result.sheared)", 9) + pad("\(result.removed)", 9))
        }
        return
    }
    for test in ImpactBenchmark.tests where names?.contains(test.name) ?? true {
        let result = try ImpactBenchmark.run(
            device: device, test: test, elementsThroughDepth: layers, duration: duration,
            spreadBars: flag("spread"), specimen: chooseSupports
        ) { model in
            if flag("no-rate") { model.material.rateDependent = false }
            // `--bond`: the No. 30 bars slip.
            if let bond = chosenBondSlip(diameter: 0.0299) { model.bondSlip = bond }
            applyRateOptions(&model)
        } inspect: { solver in
            // `--map`: the cracks left in the middle row of elements, top row first.
            if flag("map") { for line in solver.crackMap(row: solver.ey / 2) { print(line) } }
        }
        let measured =
            test.peak.map { "\(format(Double($0) * 1000)) / \(format(Double(test.residual ?? 0) * 1000)) mm" }
            ?? "failed"
        print(
            pad(test.name, 8) + pad("\(Int(test.weight)) kg", 8) + pad(measured, 18)
                + pad(
                    "\(format(Double(result.peak) * 1000)) / \(format(Double(result.residual) * 1000)) mm", 18
                )
                + pad(
                    "\(Int(test.reaction / 1000)) / \(format(Double(result.peakReaction) / 1000, 0)) kN", 18)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10)
                + (flag("force") ? "  impact \(format(Double(result.peakImpactForce) / 1000, 0)) kN" : ""))
    }
    print(
        "\nPeak / residual mid-span displacement, the residual the mean over the last 30 ms; largest"
            + " support reaction, measured / model.")
}

/// `--pins`: Ando's beams held lengthwise at both ends; `--plates 0.02`: on steel plates that
/// turn freely about their centre lines, instead of clamped over their faces.
func chooseSupports(_ specimen: inout ImpactBenchmark.Specimen) {
    // `--pad 2.3`: an elastic pad between the weight and the plate, of that stiffness per unit
    // area (GPa/m).
    if let pad = option("pad").flatMap({ Float($0) }) { specimen.pad = pad * 1e9 }
    if flag("pins") { specimen.pinnedEnds = true }
    if let plates = option("plates").flatMap({ Float($0) }) { specimen.supportPlates = plates }
}

/// `--bars`: how far the bars along x have yielded, row by row of elements that carry them: the
/// largest plastic strain, the length yielded, and the plastic stretch summed along the bars.
func printBarYield(_ solver: StructureSolver) {
    let h = solver.model.elementSize
    for k in 0..<solver.ez {
        var stretch: Float = 0
        var largest: Float = 0
        var yielded = 0
        var carries = false
        for i in 0..<solver.ex {
            var strain: Float = 0
            var count = 0
            for j in 0..<solver.ey where solver.steelRatio(i, j, k).x > 0 {
                carries = true
                let plastic = solver.barPlasticStrain(i, j, k).x
                guard abs(plastic) < 1e8 else { continue }
                strain += plastic
                count += 1
            }
            guard count > 0 else { continue }
            strain /= Float(count)
            stretch += strain * h
            largest = max(largest, strain)
            if strain > 1e-4 { yielded += 1 }
        }
        if carries {
            print(
                "    bars in row \(k): largest plastic strain \(format(Double(largest) * 100, 2))%, "
                    + "yielded over \(format(Double(Float(yielded) * h) * 1000, 0)) mm, "
                    + "plastic stretch \(format(Double(stretch) * 1000, 2)) mm")
        }
    }
}

/// Vecchio and Shim's beam OA1, with no stirrups, pushed to its diagonal-tension failure.
func runShearBeam() throws {
    print("Beam OA1 of Vecchio and Shim (2004), no stirrups, failing in diagonal tension")
    print(
        "Measured: peak \(format(Double(ShearBeamBenchmark.measuredPeak) / 1000, 0)) kN at "
            + "\(format(Double(ShearBeamBenchmark.measuredPeakDeflection) * 1000)) mm, then a sudden drop\n")
    let meshes = (option("layers") ?? "12,24").split(separator: ",").compactMap { Int($0) }
    let rate = option("rate").flatMap { Float($0) } ?? 0.05
    var results: [(layers: Int, result: ShearBeamBenchmark.Result)] = []
    print(
        pad("layers", 8) + pad("elements", 10) + pad("peak", 10) + pad("vs test", 9) + pad("at", 9)
            + pad("failed", 8) + pad("run time", 10))
    for layers in meshes {
        // `--dowel 0.5` scales the bars' dowel action.
        let dowel = option("dowel").flatMap { Float($0) }
        // `--slice 92` models a slice of the beam that many millimetres wide.
        let slice = option("slice").flatMap { Float($0) }.map { $0 / 1000 }
        // `--work`: the work each mechanism has done at every millimetre and at the peak, through
        // the whole beam, and at the peak by part of the beam. Scaled to the whole beam.
        var milestones: [(deflection: Float, load: Float, external: Double, totals: [Double])] = []
        var atPeak: (deflection: Float, load: Float, external: Double, totals: [Double], parts: [[Double]])?
        var external = 0.0
        var last = SIMD2<Float>.zero
        let regions: [(String, (Int, Int, Int, StructureSolver) -> Bool)] = [
            ("top quarter", { _, _, k, s in 4 * k >= 3 * s.ez }),
            ("middle half", { _, _, k, s in 4 * k >= s.ez && 4 * k < 3 * s.ez }),
            ("bottom quarter", { _, _, k, s in 4 * k < s.ez }),
            (
                "0.5 m about the load",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize < 0.25 }
            ),
            (
                "shear spans",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize >= 0.25 }
            ),
        ]
        let scale = Double(ShearBeamBenchmark.width / (slice ?? ShearBeamBenchmark.width))
        let result = try ShearBeamBenchmark.run(
            device: device, elementsThroughDepth: layers, slice: slice, rate: rate,
            crackAxes: chosenCrackAxes(), bondSlip: chosenBondSlip(diameter: 0.028),
            crackShearStiffness: flag("crack-shear"),
            mapAt: option("map").flatMap { Float($0) }.map { $0 / 1000 },
            slipWidensCracks: !flag("slide-apart"),
            pressedInterlock: flag("pressed-interlock"),
            adjust: { material in
                applyRateOptions(&material)
                if let dowel { material.dowelFactor = dowel }
                // `--crack-spacing 25` (mm) and `--aggregate 10` (mm), for studying the shear strength.
                if let spacing = option("crack-spacing").flatMap({ Float($0) }) {
                    material.crackSpacing = spacing / 1000
                }
                if let size = option("aggregate").flatMap({ Float($0) }) {
                    material.aggregateSize = size / 1000
                }
            },
            prepare: prepareTrace,
            sample: flag("work")
                ? { solver, deflection, load in
                    external += Double(0.5 * (load + last.y) * (deflection - last.x))
                    last = SIMD2(deflection, load)
                    let crossed =
                        Int(deflection * 1000) > (milestones.last.map { Int($0.deflection * 1000) } ?? 0)
                    let peak = load > (atPeak?.load ?? 0)
                    guard crossed || peak else { return }
                    let totals = solver.workTotals().map { $0 * scale }
                    if crossed { milestones.append((deflection, load, external, totals)) }
                    if peak {
                        let parts = regions.map { region in
                            solver.workTotals { region.1($0, $1, $2, solver) }.map { $0 * scale }
                        }
                        atPeak = (deflection, load, external, totals, parts)
                    }
                } : nil)
        results.append((layers, result))
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                + pad("\(format(Double(result.peak) / 1000, 0)) kN", 10)
                + pad("\(format(Double(result.peak / ShearBeamBenchmark.measuredPeak) * 100, 0))%", 9)
                + pad("\(format(Double(result.peakDeflection) * 1000)) mm", 9)
                + pad("\(result.summary.erodedElements)", 8) + pad("\(format(result.wallSeconds)) s", 10))
        if let atPeak {
            print("\nWork done by each mechanism (J), \(layers) layers; 'load' the work the load has done:")
            print(workHeader("deflection", 12) + pad("load", 10))
            for m in milestones {
                print(
                    workRow("\(format(Double(m.deflection) * 1000)) mm", 12, m.totals)
                        + pad(format(m.external, 1), 10))
            }
            print(
                workRow("peak \(format(Double(atPeak.deflection) * 1000)) mm", 12, atPeak.totals)
                    + pad(format(atPeak.external, 1), 10))
            print("At the peak, \(format(Double(atPeak.load) / 1000, 0)) kN, by part of the beam:")
            print(workHeader("part", 22))
            for (region, totals) in zip(regions, atPeak.parts) { print(workRow(region.0, 22, totals)) }
            print("")
        }
    }
    // `--map 9` draws the cracks through the middle of the width at 9 mm of deflection.
    for (layers, result) in results where !result.crackMap.isEmpty {
        print(
            "\nCracks open past 0.1% strain, \(layers) layers, at \(option("map") ?? "") mm "
                + "(\(format(Double(result.mapLoad) / 1000, 0)) kN): | vertical, / and \\ inclined, - horizontal"
        )
        for line in result.crackMap { print(line) }
    }
    print("\nMid-span load (kN) against deflection:")
    print(
        pad("deflection", 12) + pad("measured", 10) + results.map { pad("\($0.layers) layers", 12) }.joined())
    for tenths in [5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 140, 160] {
        let deflection = Float(tenths) / 10000
        let measured =
            deflection <= ShearBeamBenchmark.measuredPeakDeflection
            ? format(Double(ShearBeamBenchmark.measuredLoad(at: deflection)) / 1000, 0) : "-"
        print(
            pad("\(format(Double(tenths) / 10)) mm", 12) + pad(measured, 10)
                + results.map { pad(format(Double($0.result.load(at: deflection)) / 1000, 0), 12) }.joined())
    }
}

func runPushOff() throws {
    print(
        "Walraven and Reinhardt's push-off tests (HERON 26(1A), 1981), mix 1, with external restraint bars:")
    print("one crack driven along each specimen's measured opening and slip. Stresses in MPa; across")
    print("the crack compressive positive. 'fit' is the paper's eqs. 1a/1b at the same opening and slip;")
    print("'MCFT' the modified compression field theory's shear limit with the measured stress across.\n")
    let names = option("specimens").map { $0.split(separator: ",").map(String.init) }
    let size = option("size").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.05
    func mpa(_ value: Float?) -> String { value.map { format(Double($0) / 1e6, 2) } ?? "-" }
    for specimen in PushOffTest.specimens where names?.contains(specimen.name) ?? true {
        // `--close`: then pushed back to 0.05 mm open, the slip held, and slid 0.5 mm further.
        let end = SIMD2(specimen.finalSlip, 0.00005)
        let beyond = flag("close") ? [end, end + SIMD2(0.0005, 0)] : []
        let result = try PushOffTest.run(
            device: device, specimen: specimen, size: size, crackShearStiffness: flag("crack-shear"),
            beyond: beyond
        ) { model in applyRateOptions(&model) }
        if flag("close") {
            let closing = result.samples.filter { $0.slip >= specimen.finalSlip - 1e-6 }
            for sample in [closing.first, closing.dropFirst(closing.count / 2).first, closing.last]
                .compactMap({ $0 })
            {
                print(
                    "  closed: slip \(format(Double(sample.slip) * 1000, 2)) mm, open \(format(Double(sample.width) * 1000, 2)) mm: "
                        + "shear \(format(Double(sample.shear) / 1e6, 2)), across \(format(Double(sample.normal) / 1e6, 2)) MPa"
                )
            }
        }
        let material = PushOffTest.material(for: specimen)
        print(
            "\(specimen.name): cube strength \(format(Double(specimen.cubeStrength) / 1e6)) MPa, "
                + "initial width \(format(Double(specimen.initialWidth) * 1000, 2)) mm")
        print(
            pad("slip", 8) + pad("width", 8) + pad("shear", 8) + pad("model", 8) + pad("fit", 8)
                + pad("MCFT", 8)
                + pad("across", 9) + pad("model", 8) + pad("fit", 8))
        var slips: [Float] = [0.1, 0.2, 0.4, 0.8, 1.2, 1.6, 2.0].map { $0 / 1000 }.filter {
            $0 <= specimen.finalSlip
        }
        slips.append(specimen.finalSlip)
        for slip in slips {
            let width = specimen.width(at: slip)
            let modelled = result.modelled(at: slip)
            let pressed = specimen.measuredNormal(at: slip)
            let limit = pressed.map {
                PushOffTest.compressionFieldShear(
                    width: width, pressure: $0, compressiveStrength: material.compressiveStrength,
                    aggregate: material.aggregateSize)
            }
            print(
                pad("\(format(Double(slip) * 1000, 2))", 8) + pad("\(format(Double(width) * 1000, 2))", 8)
                    + pad(mpa(specimen.measuredShear(at: slip)), 8) + pad(mpa(modelled.shear), 8)
                    + pad(
                        mpa(
                            PushOffTest.fittedShear(
                                width: width, slip: slip, cubeStrength: specimen.cubeStrength)), 8)
                    + pad(mpa(limit), 8) + pad(mpa(pressed), 9) + pad(mpa(modelled.normal), 8)
                    + pad(
                        mpa(
                            PushOffTest.fittedNormal(
                                width: width, slip: slip, cubeStrength: specimen.cubeStrength)), 8))
        }
        print("")
    }
}

/// The cracks on the slab's unloaded face at 80 ms, in plan, wider than `--plan` millimetres (0.1
/// by default; a crack's width is its strain over its band: the element with bars that slip, the
/// crack spacing without), and where the cracking lies along the span: columns of elements cracked
/// that wide across most of the width, whose opening, averaged across it, is the largest within
/// an element either side, and the length of span holding nine tenths of the face's opening.
func printSlabCrackPlan(_ solver: StructureSolver) {
    let h = solver.model.elementSize
    let band = solver.model.bondSlip != nil ? h : max(h, solver.model.material.crackSpacing)
    let visible = (option("plan").flatMap { Float($0) } ?? 0.1) / 1000
    let threshold = visible / band
    print(
        "  cracks wider than \(format(Double(visible) * 1000, 2)) mm on the unloaded face at 80 ms, in plan "
            + "(supports at the ^):")
    let supports = [6, 58].map { Int((Float($0) * 0.0254 / h).rounded()) }
    print("    " + String((0..<solver.ex).map { supports.contains($0) ? "^" : " " }))
    for row in solver.crackPlan(layer: 0, threshold: threshold) { print("    " + row) }
    var mean = [Float](repeating: 0, count: solver.ex)
    var share = [Float](repeating: 0, count: solver.ex)
    for i in 0..<solver.ex {
        for j in 0..<solver.ey {
            let opening = solver.crackOpening(i, j, 0)
            mean[i] += opening / Float(solver.ey)
            if opening > threshold { share[i] += 1 / Float(solver.ey) }
        }
    }
    let middle = Float(solver.ex) / 2
    var lines: [(at: Float, width: Float)] = []
    for i in 0..<solver.ex where share[i] > 0.5 {
        let left = i > 0 ? mean[i - 1] : 0
        let right = i + 1 < solver.ex ? mean[i + 1] : 0
        if mean[i] >= left && mean[i] > right {
            lines.append(((Float(i) + 0.5 - middle) * h, mean[i] * band))
        }
    }
    print("  lines of cracking across the width (mm from mid-span: mean width across it, mm):")
    print(
        "    "
            + lines.map { "\(format(Double($0.at) * 1000, 0)): \(format(Double($0.width) * 1000, 2))" }
            .joined(separator: ", "))
    let gaps = zip(lines, lines.dropFirst()).map { $1.at - $0.at }
    if let first = lines.first, let last = lines.last, !gaps.isEmpty {
        print(
            "  \(lines.count) lines over \(format(Double(last.at - first.at) * 1000, 0)) mm, "
                + "\(format(Double(gaps.reduce(0, +) / Float(gaps.count)) * 1000, 0)) mm apart on average")
    }
    // The shortest run of columns holding nine tenths of the opening along the face.
    let total = mean.reduce(0, +)
    var shortest = (from: 0, to: solver.ex - 1)
    for from in 0..<solver.ex {
        var sum: Float = 0
        for to in from..<solver.ex {
            sum += mean[to]
            if sum >= 0.9 * total {
                if to - from < shortest.to - shortest.from { shortest = (from, to) }
                break
            }
        }
    }
    print(
        "  nine tenths of the opening along the face within \(format(Double(shortest.to - shortest.from + 1) * Double(h) * 1000, 0)) mm, "
            + "from \(format(Double((Float(shortest.from) - middle) * h) * 1000, 0)) to "
            + "\(format(Double((Float(shortest.to + 1) - middle) * h) * 1000, 0)) mm; the face opened "
            + "\(format(Double(total * h) * 1000, 1)) mm in all")
}

/// The bars' share of element (i, j, k)'s Cauchy stress along x, times h²: from their force with
/// bars that slip (per unit reference area, so times the element's stretch), else E_s (λ − 1 −
/// ε_p) ρ, exact while they are loaded one way.
func barShare(_ solver: StructureSolver, _ i: Int, _ j: Int, _ k: Int, steelModulus: Float) -> Float {
    let h = solver.model.elementSize
    var stretch: Float = 0
    for (b, c) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        stretch +=
            (simd_length(solver.position(i + 1, j + b, k + c) - solver.position(i, j + b, k + c)) / h - 1) / 4
    }
    if let force = solver.barForce(i, j, k) { return force.x * (1 + stretch) }
    let plastic = solver.barPlasticStrain(i, j, k).x
    return abs(plastic) < 1e8 ? steelModulus * (stretch - plastic) * solver.steelRatio(i, j, k).x * h * h : 0
}

/// `--stiffening`: where the tension along the span is carried, over the columns of elements
/// `columns` (along x), summed over each column and averaged over them, in kN: the bars, and the
/// concrete in tension by its crack across x (opened by its strain past the cracking strain
/// over its band): never cracked, cracked under 0.02 mm, 0.02 to 0.1 mm and wider. With
/// `profile`, column by column too. Bars that slip report their force; bonded bars' force is E_s (ε − ε_p), from the
/// element's stretch along x.
func tensionStiffening(_ solver: StructureSolver, columns: Range<Int>, label: String, profile: Bool) {
    let h = solver.model.elementSize
    let material = solver.model.material
    let band = solver.model.bondSlip != nil ? h : max(h, material.crackSpacing)
    let steelModulus = material.steel?.youngsModulus ?? 200e9
    var parts = [Double](repeating: 0, count: 5)  // bars, uncracked, <0.02, 0.02-0.1, wider
    var rows: [String] = []
    var layers = [[Double]](repeating: [Double](repeating: 0, count: 5), count: solver.ez)
    var net = [Double](repeating: 0, count: solver.ez)
    for i in columns {
        var column = [Double](repeating: 0, count: 5)
        var widest: Float = 0
        for j in 0..<solver.ey {
            for k in 0..<solver.ez where solver.flag(i, j, k) == .active {
                let ratio = solver.steelRatio(i, j, k).x
                let bar = ratio > 0 ? barShare(solver, i, j, k, steelModulus: steelModulus) : 0
                column[0] += Double(bar)
                let concrete = solver.stress(i, j, k)[0] * h * h - bar
                if k < solver.ez - 2 { net[k] += Double(concrete) / Double(columns.count) }
                guard concrete > 0 else { continue }
                let planes = solver.crackPlanes(i, j, k)
                // The plane whose normal lies nearest x.
                let plane = (0..<3).max { abs(planes.normals[$0].x) < abs(planes.normals[$1].x) } ?? 0
                let factor = solver.crackingFactor(i, j, k)
                let onset =
                    material.tensileStrength * material.concreteRateFactor * max(factor, 1)
                    / material.youngsModulus
                let opening = factor > 0 ? max(planes.history[plane] - onset, 0) * band : 0
                widest = max(widest, k == 0 ? opening : 0)
                let bin = factor == 0 ? 1 : opening < 2e-5 ? 2 : opening < 1e-4 ? 3 : 4
                column[bin] += Double(concrete)
                layers[k][bin] += Double(concrete) / Double(columns.count)
            }
        }
        for n in 0..<5 { parts[n] += column[n] / Double(columns.count) }
        if profile {
            let concrete = column[1...4].reduce(0, +)
            rows.append(
                "    \(pad(format(Double((Float(i) + 0.5 - Float(solver.ex) / 2) * h) * 1000, 0), 6)) mm: bars "
                    + "\(pad(format(column[0] / 1000, 1), 6)), concrete \(pad(format(concrete / 1000, 1), 6)) kN "
                    + "(uncracked \(pad(format(column[1] / 1000, 1), 5)), <0.02 mm \(pad(format(column[2] / 1000, 1), 5)), "
                    + "0.02-0.1 \(pad(format(column[3] / 1000, 1), 5)), wider \(pad(format(column[4] / 1000, 1), 5))); "
                    + "face crack \(format(Double(widest) * 1000, 2)) mm")
        }
    }
    if profile, flag("line") {
        // `--line`: along the span at mid-width, in the two layers of elements the bars run
        // through: the bars' force and the concrete's stress along x, the crack across x, and the
        // bars' slip at the node between the layers.
        let j = solver.ey / 2
        let bottom = (0..<solver.ez).first { solver.steelRatio(columns.lowerBound, j, $0).x > 0 } ?? 1
        print("    along the span at mid-width, bars in layers \(bottom) and \(bottom + 1):")
        print("        x mm   bars kN   concrete MPa     crack mm      slip mm  largest")
        for i in columns {
            var bars: Float = 0
            var concrete: [Float] = []
            var cracks: [Float] = []
            for k in bottom...(bottom + 1) {
                let bar = barShare(solver, i, j, k, steelModulus: steelModulus)
                bars += bar
                concrete.append((solver.stress(i, j, k)[0] * h * h - bar) / (h * h))
                let planes = solver.crackPlanes(i, j, k)
                let nearest = (0..<3).max { abs(planes.normals[$0].x) < abs(planes.normals[$1].x) } ?? 0
                let factor = solver.crackingFactor(i, j, k)
                let onset = material.tensileStrength * max(factor, 1) / material.youngsModulus
                cracks.append(factor > 0 ? max(planes.history[nearest] - onset, 0) * band : 0)
            }
            let slip = solver.barSlip(i, j, bottom + 1)
            var line = "    " + pad(format(Double((Float(i) + 0.5 - Float(solver.ex) / 2) * h) * 1000, 0), 8)
            line += pad(format(Double(bars) / 1000, 2), 10)
            line += concrete.map { pad(format(Double($0) / 1e6, 2), 7) }.joined()
            line += cracks.map { pad(format(Double($0) * 1000, 3), 7) }.joined()
            line +=
                pad(format(Double(slip?.slip.x ?? 0) * 1000, 3), 9)
                + pad(format(Double(slip?.largest.x ?? 0) * 1000, 3), 9)
            print(line)
        }
    }
    if profile, let column = option("column").flatMap({ Float($0) }) {
        // `--column -44`: that column (mm from mid-span) element by element, at mid-width.
        let i = Int((column / 1000 / h + Float(solver.ex) / 2).rounded(.down))
        let j = solver.ey / 2
        print(
            "    column \(i), mid-width, bottom first: concrete and bar stress (MPa), crack history, rate factor"
        )
        for k in 0..<solver.ez {
            let planes = solver.crackPlanes(i, j, k)
            let bar: Float = barShare(solver, i, j, k, steelModulus: steelModulus)
            let sigma = solver.stress(i, j, k)
            let total: Double = Double(sigma[0]) / 1e6
            let barStress: Double = Double(bar / (h * h)) / 1e6
            // The concrete's stress across the crack nearest x, and the shear on it.
            let tensor = simd_float3x3(
                SIMD3(sigma[0] - bar / (h * h), sigma[3], sigma[5]), SIMD3(sigma[3], sigma[1], sigma[4]),
                SIMD3(sigma[5], sigma[4], sigma[2]))
            let nearest = (0..<3).max { abs(planes.normals[$0].x) < abs(planes.normals[$1].x) } ?? 0
            let traction = tensor * planes.normals[nearest]
            let across = simd_dot(traction, planes.normals[nearest])
            let along = simd_length(traction - across * planes.normals[nearest])
            let history: [String] = (0..<3).map { format(Double(planes.history[$0]) * 1e3, 3) }
            let normals: [String] = planes.normals.map { n -> String in
                let parts: [String] = [n.x, n.y, n.z].map { format(Double($0), 2) }
                return "(" + parts.joined(separator: ",") + ")"
            }
            var line =
                "      k \(k): total \(format(total, 2)), bars \(format(barStress, 2)), concrete across the crack "
            line +=
                "\(format(Double(across) / 1e6, 2)), shear on it \(format(Double(along) / 1e6, 2)), history "
            line += history.joined(separator: " ") + " e-3, normals " + normals.joined(separator: " ")
            line +=
                ", factor \(format(Double(solver.crackingFactor(i, j, k)), 2)), ratio \(solver.steelRatio(i, j, k).x)"
            line += ", stress " + sigma.map { format(Double($0) / 1e6, 2) }.joined(separator: " ")
            print(line)
        }
    }
    let concrete = parts[1...4].reduce(0, +)
    print(
        "  \(label): bars \(format(parts[0] / 1000, 1)) kN, concrete in tension \(format(concrete / 1000, 1)) kN "
            + "(\(format(100 * concrete / max(parts[0] + concrete, 1), 0))% of the tension): uncracked "
            + "\(format(parts[1] / 1000, 1)), under 0.02 mm \(format(parts[2] / 1000, 1)), 0.02-0.1 mm "
            + "\(format(parts[3] / 1000, 1)), wider \(format(parts[4] / 1000, 1))")
    for row in rows { print(row) }
    if profile {
        print("    by layer, bottom first (kN): uncracked, under 0.02 mm, 0.02-0.1, wider")
        for (k, layer) in layers.enumerated() {
            print(
                "      k \(k): " + layer[1...4].map { pad(format($0 / 1000, 1), 6) }.joined()
                    + "   net, tension and compression: \(format(net[k] / 1000, 1))")
        }
    }
}

/// A reinforced tie pulled to a mean strain of 1.5e-3 (`TieBenchmark`), its cracks and pull against
/// the Model Code's spacing and tension stiffening. `--h 0.02,0.01` the meshes, `--bond none` bonded
/// bars, `--factor 1.25` the concrete's strengths raised by that factor as at blast rates (its
/// fracture energy by the factor's square root, as the tensile rate law raises it), the bond not.
func runTie() throws {
    let sizes = (option("h") ?? "0.02,0.01").split(separator: ",").compactMap { Float($0) }
    let factor = option("factor").flatMap { Float($0) } ?? 1
    let strain = option("strain").flatMap { Float($0) } ?? 1.5e-3
    let bond =
        option("bond") == nil
        ? BondSlip(condition: .pullOut, barDiameter: TieBenchmark.diameter)
        : chosenBondSlip(diameter: TieBenchmark.diameter)
    let strength = TieBenchmark.material.tensileStrength * factor
    print(
        "Tie 1 m x 100 mm x 100 mm, 2% of 12 mm bars, pulled to \(format(Double(strain) * 1000, 2))e-3; "
            + "strengths x\(format(Double(factor), 2))")
    let transfer = TieBenchmark.transferLength(raised: factor)
    print(
        "Model Code, the bond kept static: cracks \(format(Double(transfer) * 1000, 0)) to \(format(Double(2 * transfer) * 1000, 0)) mm apart; pull "
            + "\(format(Double(TieBenchmark.expectedLoad(strain: strain, beta: 0.4, strength: strength)) / 1000, 1)) kN "
            + "(beta 0.4) to \(format(Double(TieBenchmark.expectedLoad(strain: strain, beta: 0.6, strength: strength)) / 1000, 1)) kN (0.6); "
            + "bare bars \(format(Double(TieBenchmark.expectedLoad(strain: strain, beta: 0, strength: strength)) / 1000, 1)) kN"
    )
    for h in sizes {
        let result = try TieBenchmark.run(device: device, elementSize: h, bond: bond, strain: strain) {
            material in
            material.concreteRateFactor = factor
            material.fractureEnergy *= factor.squareRoot()
            applyRateOptions(&material)
        }
        let spacings = result.spacings
        let mean = spacings.isEmpty ? 0 : spacings.reduce(0, +) / Float(spacings.count)
        print(
            "  \(format(Double(h) * 1000, 1)) mm elements: \(spacings.count + 1) cracks, "
                + "\(format(Double(spacings.min() ?? 0) * 1000, 0))-\(format(Double(spacings.max() ?? 0) * 1000, 0)) mm apart "
                + "(mean \(format(Double(mean) * 1000, 0))); pull \(format(Double(result.load) / 1000, 1)) kN"
        )
    }
}

func runSlab() throws {
    if flag("unload") {
        // `--unload`: pushed slowly at mid-span to the test's peak, then released.
        let layers = option("layers").flatMap { Int($0) } ?? 8
        let to = option("to").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.105
        let strengths: [SlabBenchmark.RateTreatment] =
            flag("rate-only") ? [.strainRate] : flag("static-only") ? [.none] : [.none, .strainRate]
        for strength in strengths {
            let result = try SlabBenchmark.pushAndRelease(
                device: device, elementsThroughThickness: layers, deflection: to, strength: strength,
                width: option("strip").flatMap { Float($0) }.map { $0 / 1000 } ?? SlabBenchmark.fullWidth,
                adjust: { model in applyRateOptions(&model) },
                trace: flag("trace")
                    ? { time, deflection, push in
                        print(
                            "  \(format(time * 1000, 0)) ms: \(format(Double(deflection) * 1000, 1)) mm, \(format(Double(push) / 1000, 1)) kN"
                        )
                        fflush(stdout)
                    } : nil,
                shapes: { peak, left in
                    print(
                        "  at peak (mm, support to mid-span): "
                            + peak.map { format(Double($0) * 1000, 1) }.joined(separator: " "))
                    print(
                        "  left:                              "
                            + left.map { format(Double($0) * 1000, 1) }.joined(separator: " "))
                    print(
                        "  recovered:                         "
                            + zip(peak, left).map { format(Double($0 - $1) * 1000, 1) }.joined(separator: " ")
                    )
                },
                hinge: flag("hinge")
                    ? { label, rows in
                        print("  \(label):")
                        for row in rows { print("    " + row) }
                    } : nil)
            print(
                "\(strength.rawValue): pushed to \(format(Double(result.reached) * 1000, 1)) mm with "
                    + "\(format(Double(result.force) / 1000, 1)) kN at most, \(format(Double(result.residual) * 1000, 1)) mm left"
            )
        }
        return
    }
    let load = SlabBenchmark.load
    print("Blast Blind Simulation Contest slab (normal-strength concrete, Grade 60 bars)")
    print(
        "Load: peak \(format(Double((load.history.map(\.y).max() ?? 0) / 6894.76))) psi after scaling the "
            + "hand-read record to the stated \(format(Double(load.impulse / 6.89476), 0)) psi ms")
    print(
        "Measured: peak \(format(Double(SlabBenchmark.measuredPeak) * 1000, 0)) mm at about "
            + "\(format(Double(SlabBenchmark.measuredPeakTime) * 1000, 0)) ms, "
            + "\(format(Double(SlabBenchmark.measuredResidual) * 1000, 0)) mm at the end of the record\n")
    print(
        pad("layers", 8) + pad("elements", 10) + pad("strength", 14) + pad("peak", 10) + pad("vs test", 9)
            + pad("at", 8) + pad("residual", 10) + pad("vs test", 9) + pad("failed", 8) + pad("run time", 10))
    var cases: [(Int, SlabBenchmark.RateTreatment)] = [
        (8, .strainRate), (4, .strainRate), (8, .designFactors), (8, .none),
    ]
    // `--layers 16,32` runs just those meshes, with the strain-rate laws; `--strip 25` runs a
    // strip of the slab that many millimetres wide, which bends the same way, for fine meshes.
    if let layers = option("layers") {
        cases = layers.split(separator: ",").compactMap { Int($0) }.map { ($0, .strainRate) }
    }
    let width = option("strip").flatMap { Float($0) }.map { $0 / 1000 } ?? SlabBenchmark.fullWidth
    var meshes: [(layers: Int, result: SlabBenchmark.Result)] = []
    // `--shells 2,1` runs shells of those sizes in inches instead, with `--shell-layers` layers.
    if let sizes = option("shells") {
        cases = []
        let layers = option("shell-layers").flatMap { Int($0) } ?? 8
        for size in sizes.split(separator: ",").compactMap({ Float($0) }) {
            let rate =
                option("shell-rate").flatMap { SlabBenchmark.RateTreatment(rawValue: $0) } ?? .strainRate
            let result = try SlabBenchmark.runShells(
                device: device, elementSize: size * 0.0254, layers: layers, rate: rate, width: width)
            meshes.append((layers, result))
            print(
                pad("\(layers)", 8) + pad("\(result.elementCount)", 10)
                    + pad("shells \(format(Double(size), 2)) in", 14)
                    + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 9)
                    + pad("\(format(Double(result.peakTime) * 1000, 0)) ms", 8)
                    + pad("\(format(Double(result.residual) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.residual / SlabBenchmark.measuredResidual) * 100, 0))%", 9)
                    + pad("\(result.summary.erodedElements)", 8)
                    + pad("\(format(result.wallSeconds, 1)) s", 10))
        }
    }
    for (layers, rate) in cases {
        // `--held-bearings` supports the slab on 1 in bearings that hold it down.
        let supports: SlabBenchmark.Supports =
            flag("held-bearings") ? .bearings(width: 0.0254, holdDown: true) : .lines
        // `--work`: the work each mechanism has done every 20 mm on the way down, at the peak and
        // at the end, through the whole slab, and at the peak by part of it.
        var milestones: [(label: String, totals: [Double])] = []
        var atPeak: (deflection: Float, totals: [Double], parts: [[Double]])?
        let regions: [(String, (Int, Int, Int, StructureSolver) -> Bool)] = [
            ("loaded half", { _, _, k, s in 2 * k >= s.ez }),
            ("unloaded half", { _, _, k, s in 2 * k < s.ez }),
            (
                "600 mm about mid-span",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize < 0.3 }
            ),
            (
                "the rest",
                { i, _, _, s in abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize >= 0.3 }
            ),
            (
                "unloaded half, 600 mm",
                { i, _, k, s in
                    2 * k < s.ez && abs(Float(i) + 0.5 - Float(s.ex) / 2) * s.model.elementSize < 0.3
                }
            ),
        ]
        let result = try SlabBenchmark.run(
            device: device, elementsThroughThickness: layers, rate: rate, supports: supports, width: width,
            crackAxes: chosenCrackAxes(), bondSlip: chosenBondSlip(diameter: 0.0095),
            crackShearStiffness: flag("crack-shear"),
            adjust: { applyRateOptions(&$0) },
            adjustModel: {
                if flag("element-bar-rate") { $0.barRateAlongBars = false }
                if flag("slide-apart") { $0.slipWidensCracks = false }
                if flag("pressed-interlock") { $0.pressedInterlock = true }
            },
            prepare: prepareTrace,
            sample: flag("stiffening")
                ? { solver in
                    // `--stiffening`: where the tension is carried over the 600 mm about mid-span,
                    // every 20 mm on the way down.
                    let deflection = -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z
                    let step = 0.02 * Float(milestones.count + 1)
                    guard deflection >= step, solver.time < 0.03 else { return }
                    milestones.append(("", []))
                    let reach = Int((0.3 / solver.model.elementSize).rounded())
                    tensionStiffening(
                        solver, columns: (solver.ex / 2 - reach)..<(solver.ex / 2 + reach),
                        label: "\(Int((step * 1000).rounded())) mm, \(format(solver.time * 1000, 1)) ms",
                        profile: flag("profile") && step >= 0.08)
                }
                : flag("work")
                    ? { solver in
                        let deflection = -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z
                        let step = 0.02 * Float(milestones.count + 1)
                        let crossed = deflection >= step && atPeak.map { deflection >= $0.deflection } ?? true
                        let peak = deflection > (atPeak?.deflection ?? 0)
                        let end = solver.time >= 0.08
                        guard crossed || peak || end else { return }
                        let totals = solver.workTotals()
                        if crossed { milestones.append(("\(Int((step * 1000).rounded())) mm", totals)) }
                        if peak {
                            atPeak = (
                                deflection, totals,
                                regions.map { region in solver.workTotals { region.1($0, $1, $2, solver) } }
                            )
                        }
                        if end {
                            milestones.append(("80 ms, \(format(Double(deflection) * 1000, 0)) mm", totals))
                        }
                    } : nil,
            inspect: flag("hinge")
                ? { solver in
                    for offset in [Float(0), 0.15] {
                        print("  at 80 ms, \(Int(offset * 1000)) mm from mid-span:")
                        for row in SlabBenchmark.sectionRows(solver, offset: offset) { print("    " + row) }
                    }
                }
                // `--map`: the cracks through the middle of the width at 80 ms; `--plan`, on the
                // unloaded face, and where the cracks across the span lie.
                : flag("map") || flag("plan")
                    ? { solver in
                        if flag("map") {
                            print("  cracks open past 0.1% strain at 80 ms, half the span from mid-span:")
                            for row in solver.crackMap(row: solver.ey / 2) { print("    " + row) }
                        }
                        if flag("plan") { printSlabCrackPlan(solver) }
                    } : nil)
        if rate == .strainRate { meshes.append((layers, result)) }
        let label =
            ["none": "static", "designFactors": "UFC fixed", "strainRate": "rate laws"][rate.rawValue] ?? ""
        print(
            pad("\(layers)", 8) + pad("\(result.elementCount)", 10) + pad(label, 14)
                + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 9)
                + pad("\(format(Double(result.peakTime) * 1000, 0)) ms", 8)
                + pad("\(format(Double(result.residual) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.residual / SlabBenchmark.measuredResidual) * 100, 0))%", 9)
                + pad("\(result.summary.erodedElements)", 8)
                + pad("\(format(result.wallSeconds, 1)) s", 10))
        if let atPeak {
            print("  work done by each mechanism (J):")
            print("  " + workHeader("", 22))
            for m in milestones { print("  " + workRow(m.label, 22, m.totals)) }
            print("  " + workRow("peak \(format(Double(atPeak.deflection) * 1000, 1)) mm", 22, atPeak.totals))
            print("  at the peak, by part of the slab:")
            for (region, totals) in zip(regions, atPeak.parts) { print("  " + workRow(region.0, 22, totals)) }
        }
        if flag("history") {
            for sample in result.history where Int((sample.x * 1000).rounded()) % 5 == 0 {
                print(
                    "    t = \(format(Double(sample.x) * 1000, 2)) ms   \(format(Double(sample.y) * 1000, 1)) mm"
                )
            }
        }
    }

    // The whole history, not just its peak, against the measured record.
    print("\nMid-span displacement history (mm):")
    print(pad("time", 8) + pad("measured", 10) + meshes.map { pad("\($0.layers) layers", 11) }.joined())
    for time in stride(from: Float(0.005), through: 0.0701, by: 0.005) {
        print(
            pad("\(format(Double(time) * 1000, 0)) ms", 8)
                + pad(format(Double(SlabBenchmark.measuredDisplacement(at: time)) * 1000, 0), 10)
                + meshes.map { pad(format(Double($0.result.displacement(at: time)) * 1000, 0), 11) }.joined())
    }
    print(
        "Root-mean-square difference over the record: "
            + meshes.map { "\(format(Double($0.result.historyError) * 1000, 1)) mm (\($0.layers) layers)" }
            .joined(separator: ", "))
    print("\nPeaks the source reports for other tools on the same slab and load:")
    for other in SlabBenchmark.otherPredictions {
        print(
            "  \(format(Double(other.peak) * 1000, 0)) mm "
                + "(\(format(Double(other.peak / SlabBenchmark.measuredPeak) * 100, 0))%)  \(other.tool)")
    }

    guard flag("sensitivity") else { return }
    print("\nSensitivity of the eight-layer, rate-law result to things the source does not pin down:")
    let variants: [(String, Float, (inout StructureMaterial) -> Void)] = [
        ("load 5% lower", 0.95, { _ in }),
        ("load 5% higher", 1.05, { _ in }),
        ("aggregate 10 mm instead of 16 mm", 1, { $0.aggregateSize = 0.010 }),
        ("crack spacing 50 mm instead of 100 mm", 1, { $0.crackSpacing = 0.05 }),
        ("crack spacing 200 mm", 1, { $0.crackSpacing = 0.2 }),
        ("fracture energy halved", 1, { $0.fractureEnergy *= 0.5 }),
        ("tensile strength 20% lower", 1, { $0.tensileStrength *= 0.8 }),
        ("cracks close fully (no residual opening)", 1, { $0.crackResidual = 0 }),
        ("residual crack opening 20%", 1, { $0.crackResidual = 0.2 }),
        ("residual crack opening 30%", 1, { $0.crackResidual = 0.3 }),
        ("residual crack opening 50%", 1, { $0.crackResidual = 0.5 }),
        ("crushing spread over at least 50 mm", 1, { $0.crushBand = 0.05 }),
        ("crushing averaged over 48 mm (nonlocal)", 1, { $0.crushLength = 0.048 }),
    ]
    var runs: [(String, () throws -> SlabBenchmark.Result)] = variants.map { label, scale, adjust in
        (label, { try SlabBenchmark.run(device: device, loadScale: scale, adjust: adjust) })
    }
    let inch: Float = 0.0254
    runs.append(
        (
            "1 in bearings, held down",
            { try SlabBenchmark.run(device: device, supports: .bearings(width: inch, holdDown: true)) }
        ))
    runs.append(
        (
            "1 in bearings, free to lift",
            { try SlabBenchmark.run(device: device, supports: .bearings(width: inch, holdDown: false)) }
        ))
    if flag("convergence") {
        runs.append(
            (
                "16 elements through the thickness",
                { try SlabBenchmark.run(device: device, elementsThroughThickness: 16) }
            ))
    }
    for (label, run) in runs {
        let result = try run()
        print(
            pad(label, 40) + pad("\(format(Double(result.peak) * 1000, 0)) mm", 10)
                + pad("\(format(Double(result.peak / SlabBenchmark.measuredPeak) * 100, 0))%", 8)
                + pad("residual \(format(Double(result.residual) * 1000, 0)) mm", 16)
                + pad("history RMS \(format(Double(result.historyError) * 1000, 1)) mm", 20)
                + pad("failed \(result.summary.erodedElements)", 14))
    }
}

/// A freestanding wall under a blast on each kind of base connection (`AnchorageStudy`).
func runAnchorage() throws {
    let mass = option("mass").flatMap { Float($0) } ?? 50
    let standoffs = (option("standoff") ?? "6,10,15,25").split(separator: ",").compactMap { Float($0) }
    let duration = option("time").flatMap { Float($0) } ?? 0.5
    // `--shells` meshes the wall with shells (of 0.125 m unless `--h` says otherwise).
    let shells = flag("shells")
    let h = option("h").flatMap { Float($0) } ?? (shells ? 0.125 : 0.0625)
    print(
        "Freestanding wall\(shells ? " of shells" : ""), \(format(Double(AnchorageStudy.height), 0)) m high and "
            + "\(format(Double(AnchorageStudy.thickness) * 1000, 0)) mm thick, a surface burst of "
            + "\(format(Double(mass), 0)) kg; "
            + (flag("air") ? "12 m long, loaded by the air" : "Kingery–Bulmash reflected pulse, no air")
            + "; \(format(Double(duration), 1)) s"
    )
    if flag("panel") {
        print(
            "As a panel 3 m long resting on the ground between two columns, its vertical edges tied to them\n"
                + "by each connection in turn; sway at the top's middle; ties, slip and moment are of all its joints."
        )
    }
    if !flag("air") {
        print(
            "The pulse loads the face alone. A freestanding wall's back face is loaded too, as the wave wraps\n"
                + "over and round it, and it sways about a third as far at 10 m: see --air.")
    }
    // The footing's soil: `--massless` without its mass and radiation damping; `--layer d` a layer
    // d metres deep over rock (or `--beneath sand`, a looser sand, or `--beneath clay`, a soft
    // clay, as a half-space).
    var soil = Soil()
    soil.radiationDamping = !flag("massless")
    soil.layerDepth = option("layer").flatMap { Float($0) }
    switch option("beneath") {
    case "sand": soil.beneath = SoilMaterial(shearModulus: 20e6, poissonRatio: 0.3, density: 1800)
    case "clay": soil.beneath = SoilMaterial(shearModulus: 10e6, poissonRatio: 0.45, density: 1700)
    default: soil.beneath = nil
    }
    if soil != Soil() {
        print(
            "Footing on medium dense sand" + (soil.radiationDamping ? "" : " without its mass")
                + (soil.layerDepth.map {
                    " as a layer \(format(Double($0), 1)) m deep over " + (option("beneath") ?? "rock")
                } ?? ""))
    }
    for standoff in standoffs {
        print("")
        var header = false
        // `--bases clamped,dowelled` picks the bases; `--air` loads a 12 m wall by the air solver
        // instead of the pulse, on cells of `--cell` metres (0.25 by default), the air reaching
        // `--margin` metres (12) beyond the wall and charge and `--height` metres (18) up.
        let bases =
            option("bases").map {
                $0.split(separator: ",").compactMap { BaseConnection(rawValue: String($0)) }
            }
            ?? BaseConnection.allCases
        for base in bases {
            let r =
                flag("air")
                ? try AnchorageStudy.runCoupled(
                    device: device, base: base, mass: mass, standoff: standoff, duration: Double(duration),
                    cellSize: option("cell").flatMap { Float($0) } ?? 0.25, elementSize: h,
                    margin: option("margin").flatMap { Float($0) } ?? 12,
                    domainHeight: option("height").flatMap { Float($0) } ?? 18, soil: soil,
                    progress: flag("progress") ? { print("    " + $0) } : nil)
                : flag("panel")
                    ? try AnchorageStudy.run(
                        device: device, base: .resting, mass: mass, standoff: standoff, duration: duration,
                        elementSize: h, shells: shells, edges: base)
                    : try AnchorageStudy.run(
                        device: device, base: base, mass: mass, standoff: standoff, duration: duration,
                        elementSize: h,
                        shells: shells, soil: soil)
            if !header {
                print(
                    "\(format(Double(standoff), 0)) m: \(format(Double(r.pressure) / 1000, 0)) kPa reflected for "
                        + "\(format(Double(r.duration) * 1000, 1)) ms, "
                        + "\(format(Double(r.pressure * r.duration) / 2, 0)) Pa s")
                print(
                    pad(flag("panel") ? "edges" : "base", 22) + pad("peak sway", 11) + pad("final", 10)
                        + pad("uplift", 10)
                        + pad("slip", 10) + pad("tie failed", 12) + pad("base M", 12) + pad("eroded", 8)
                        + pad("run time", 9))
                header = true
            }
            let anchored = base != .clamped
            // A body resting on the ground has no tie to fail.
            let failed = anchored && base != .resting ? "\(format(Double(r.separated) * 100, 0))%" : "-"
            let sway = pad("\(format(Double(r.peakSway) * 1000, 1)) mm", 11)
            let final = pad("\(format(Double(r.finalSway) * 1000, 1)) mm", 10)
            let uplift = anchored ? "\(format(Double(r.peakUplift) * 1000, 2)) mm" : "-"
            let slip = anchored ? "\(format(Double(r.maxSlip) * 1000, 2)) mm" : "-"
            print(
                pad(base.title.lowercased(), 22) + sway + final + pad(uplift, 10) + pad(slip, 10)
                    + pad(failed, 12)
                    + pad(anchored ? "\(format(Double(r.peakBaseMoment) / 1000, 0)) kN m/m" : "-", 12)
                    + pad("\(r.summary.erodedElements)", 8) + pad("\(format(r.wallSeconds)) s", 9))
            if base == .footing {
                print(
                    pad("", 22)
                        + "footing: turned \(format(Double(r.footingRotation) * 1000, 2)) mrad, heel lifted "
                        + "\(format(Double(r.footingUplift) * 1000, 2)) mm; at the end slid "
                        + "\(format(Double(r.footingSlide) * 1000, 2)) mm, settled \(format(Double(r.footingSettlement) * 1000, 2)) mm"
                )
            }
            if flag("air") {
                print(
                    pad("", 22)
                        + "face \(format(Double(r.pressure * r.duration) / 2, 0)) Pa s (positive phase); "
                        + "over 50 ms, back \(format(Double(r.backImpulse), 0)) Pa s, net \(format(Double(r.netImpulse), 0)) Pa s; "
                        + "back towards the charge \(format(Double(r.peakBackSway) * 1000, 1)) mm")
            }
        }
    }
}

/// The thermal radiation's cost a frame on a scene's receivers, with the visibility tested on the
/// CPU and on the GPU, for a fireball growing from 1 to 15 m across over the frames, as the street's
/// does with afterburning; and whether the two agree.
/// Dial Pack, 500 tons of TNT as a sphere resting on the ground (Suffield, 1970), whose thermal
/// radiation DREO Report 642 measured at 600 and 1,700 m: the fireball reckoned frame by frame as
/// the volume, its opaque shape and its equivalent sphere (both at emissivity 1) radiate it to an
/// instrument at each range aimed along the ground at it, and what it radiated, round it and as
/// the gas lost it. `--csv` writes every frame; `Scripts/compare-dial-pack.py` sets it against the
/// report (Samples/DialPack1970).
func runDialPack() throws {
    let tons = option("tons").flatMap { Float($0) } ?? 500
    let mass = tons * 907.185  // short tons
    let cellSize = option("dx").flatMap { Float($0) } ?? 4
    let side = option("domain").flatMap { Float($0) } ?? 480
    let duration = option("time").flatMap { Double($0) } ?? 1
    // TNT at 1,600 kg/m³, its sphere's centre one radius up.
    let radius = cbrt(3 * mass / (4 * .pi * 1600))
    var scenario = Scenario(
        name: "Dial Pack", domainSize: SIMD3(side, side, side / 2), boxes: [],
        charge: Charge(mass: mass, position: SIMD3(side / 2, side / 2, radius)))
    scenario.gauges = []
    var configuration = SolverConfiguration()
    configureRefinement(&configuration)
    configuration.afterburning = true
    configuration.airModel = .thermallyPerfect
    configuration.radiativeCooling = try chosenCooling()
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    var volume = ThermalSpec()
    // A receiver or so on the ground: only the instruments are reckoned.
    volume.groundSpacing = side
    var shape = volume
    shape.fireball = .shape
    var sphere = volume
    sphere.fireball = .sphere
    let scene = FragmentScene(scenario)
    let models = [("volume", volume), ("shape", shape), ("sphere", sphere)].map {
        (name: $0.0, exposure: ThermalExposure(spec: $0.1, scene: scene))
    }
    let ranges: [Float] = [600, 1700]
    // South of ground zero, 1.5 m up, facing it along the ground.
    let points = ranges.map { range in
        ThermalReceiver(
            position: SIMD3(side / 2, side / 2 - range, 1.5), normal: SIMD3(0, 1, 0), surface: "instrument")
    }
    solver.frameRequest = FrameRequest(thermal: volume)
    var frameTimes: [Double] = []
    var t = 0.0005
    while t < duration - 1e-9 {
        frameTimes.append(t)
        t += t < 0.01 ? 0.0005 : (t < 0.1 ? 0.0025 : (t < 0.3 ? 0.01 : 0.025))
    }
    frameTimes.append(duration)
    print(
        String(
            format:
                "Dial Pack: %.0f t of TNT (%.0f short tons), a sphere %.2f m in radius on the ground, %.0f m cells, %.0f by %.0f by %.0f m, to %.2f s%@",
            mass / 1000, tons, radius, cellSize, side, side, side / 2, duration,
            configuration.radiativeCooling == nil ? "" : ", the gas cooling"))
    var lines = [
        "time_s,diameter_m,temperature_K,hottest_K,radiated_W,gas_lost_J,"
            + models.flatMap { model in ranges.map { "\(model.name)_\(Int($0))_W_m2" } }.joined(
                separator: ",")
    ]
    var last: (time: Double, values: [Float])?
    var fluence = [Double](repeating: 0, count: models.count * ranges.count)
    var peak = [Float](repeating: 0, count: models.count * ranges.count)
    var radiated = 0.0
    var lastPower: (time: Double, power: Double)?
    let started = ContinuousClock.now
    for target in frameTimes {
        while solver.time < target - 1e-9 {
            let result = solver.advance(steps: 256, timeLimit: target)
            if result.steps == 0 || !result.isStable { break }
        }
        let frame = solver.fireball(for: volume)
        var values: [Float] = []
        for model in models { values += model.exposure.irradiance(frame, at: points) }
        let power = models[0].exposure.radiatedPower(frame)
        if let last {
            for n in values.indices {
                fluence[n] += 0.5 * Double(last.values[n] + values[n]) * (solver.time - last.time)
            }
        }
        if let lastPower { radiated += 0.5 * (lastPower.power + power) * (solver.time - lastPower.time) }
        for n in values.indices { peak[n] = max(peak[n], values[n]) }
        last = (solver.time, values)
        lastPower = (solver.time, power)
        lines.append(
            [
                String(format: "%.5f", solver.time), String(format: "%.2f", 2 * frame.radius),
                String(format: "%.0f", frame.temperature), String(format: "%.0f", frame.hottest),
                String(format: "%.4g", power), String(format: "%.4g", solver.radiatedEnergy),
            ].joined(separator: ",") + "," + values.map { String(format: "%.4g", $0) }.joined(separator: ","))
    }
    let charge = Double(scenario.charge.energy)
    for (m, model) in models.enumerated() {
        let text = ranges.enumerated().map { r, range in
            String(
                format: "%.0f m: %.2f kJ/m², peak %.2f kW/m²", range, fluence[m * ranges.count + r] / 1000,
                peak[m * ranges.count + r] / 1000)
        }.joined(separator: "; ")
        print("  as its \(model.name): \(text)")
    }
    print(
        String(
            format: "  radiated round it, the volume: %.3g J, %.2f%% of the charge's energy%@", radiated,
            100 * radiated / charge,
            configuration.radiativeCooling == nil
                ? ""
                : String(
                    format: "; the gas lost %.3g J, %.2f%%", solver.radiatedEnergy,
                    100 * solver.radiatedEnergy / charge)))
    print(
        String(
            format: "  %d steps, simulated in %.0f s", solver.stepCount,
            (ContinuousClock.now - started) / .seconds(1)))
    if let path = option("csv") {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func runThermal() throws {
    let scenario = option("preset") == nil ? ScenarioPreset.streetCanyon.scenario : chosenScenario()
    let scene = FragmentScene(scenario)
    var spec = ThermalSpec()
    if let samples = option("samples").flatMap({ Int($0) }) { spec.samples = samples }
    try spec.validate()
    if let model = option("model").flatMap(FireballModel.init(rawValue:)) { spec.fireball = model }
    if let absorption = option("absorption").flatMap({ Float($0) }) { spec.absorption = absorption }
    try spec.validate()
    let count = option("frames").flatMap { Int($0) } ?? 60
    let frames = (0..<count).map { n -> FireballFrame in
        let s = Float(n) / Float(max(count - 1, 1))
        let radius = 0.5 + 7 * s
        let centre = scenario.charge.position + SIMD3(0, 0, radius * 0.5)
        var frame = FireballFrame(
            time: Double(n) * 0.001, volume: 4 / 3 * Double.pi * pow(Double(radius), 3),
            centre: centre, temperature: 2200 - 400 * s, hottest: 2500)
        guard spec.fireball == .volume else { return frame }
        // For the volume, the sphere in cells 0.25 m a side, above the ground, 2,500 K at its
        // centre and cooler outwards.
        let size: Float = 0.25
        let low = simd_max(centre - radius - size, SIMD3(-1, -1, 0))
        let first = SIMD3<Int32>((low / size).rounded(.down))
        let last = SIMD3<Int32>(((centre + radius + size) / size).rounded(.up))
        let counts = last &- first
        var fills: [UInt8] = []
        var temperatures: [UInt16] = []
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    let x = (SIMD3<Float>(first &+ SIMD3(i, j, k)) + 0.5) * size
                    let d = simd_distance(x, centre)
                    fills.append(d <= radius ? 255 : 0)
                    temperatures.append(d <= radius ? UInt16(2500 - 600 * s * d / radius) : 0)
                }
            }
        }
        frame.cells = LuminousCells(
            voxelSize: size, first: first, counts: counts, fills: fills, temperatures: temperatures,
            products: nil)
        return frame
    }
    /// Times the visibility test within each frame.
    final class Timed: ThermalVisibility, @unchecked Sendable {
        let inner: any ThermalVisibility
        var seconds = 0.0
        var rays = 0
        init(_ inner: any ThermalVisibility) { self.inner = inner }
        func visible(_ rays: [ThermalRay]) -> [Bool] {
            let started = ContinuousClock.now
            defer {
                seconds += (ContinuousClock.now - started) / .seconds(1)
                self.rays += rays.count
            }
            return inner.visible(rays)
        }
    }
    let occluders = ThermalExposure.occluders(scene)
    let metal = MetalThermalVisibility(occluders: occluders)
    print("Device: \(device.name), ray tracing \(device.supportsRaytracing ? "yes" : "no")")
    if spec.fireball == .volume {
        // The march on the GPU, then on the CPU; each frame's irradiance and what it radiated.
        var answers: [[Float]] = []
        for name in ["GPU", "CPU"] {
            if name == "CPU" { setenv("BOMBCAD_THERMAL_VISIBILITY", "cpu", 1) }
            var exposure = ThermalExposure(spec: spec, scene: scene)
            let started = ContinuousClock.now
            for frame in frames { exposure.add(frame) }
            let total = (ContinuousClock.now - started) / .seconds(1)
            answers.append(exposure.peakIrradiance)
            print(
                "\(name): \(exposure.receivers.count) receivers, \(format(total / Double(count) * 1000, 1)) ms a frame"
                    + (exposure.marchGPUSeconds.map {
                        ", \(format($0 / Double(count) * 1000, 2)) ms of it the GPU's"
                    } ?? ""))
        }
        unsetenv("BOMBCAD_THERMAL_VISIBILITY")
        let largest = answers[1].max() ?? 0
        let worst = zip(answers[0], answers[1]).map { abs($0 - $1) }.max() ?? 0
        print(
            "Largest difference in peak irradiance: \(format(Double(worst / max(largest, 1)) * 100, 3))% of the highest"
        )
        return
    }
    var answers: [[Float]] = []
    for (name, visibility) in [("CPU", CPUThermalVisibility(occluders: occluders) as any ThermalVisibility)]
        + (metal.map { [("GPU", $0 as any ThermalVisibility)] } ?? [])
    {
        let timed = Timed(visibility)
        let exposure = ThermalExposure(spec: spec, scene: scene, visibility: timed)
        func processorSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let started = ContinuousClock.now
        let processor = processorSeconds()
        var irradiance: [Float] = []
        for frame in frames { irradiance += exposure.irradiance(frame) }
        let total = (ContinuousClock.now - started) / .seconds(1)
        let busy = processorSeconds() - processor
        answers.append(irradiance)
        print(
            "\(name): \(exposure.receivers.count) receivers, \(timed.rays / count) rays a frame; "
                + "\(format(total / Double(count) * 1000, 1)) ms a frame, "
                + "\(format(timed.seconds / Double(count) * 1000, 1)) ms of it the visibility test; "
                + "\(format(busy / Double(count) * 1000, 1)) ms of the CPU's cores' time a frame")
    }
    if let metal {
        let usage = metal.usage
        print(
            "GPU: \(usage.gpuFrames) frames there, \(usage.cpuFrames) answered first on the CPU, "
                + "\(format(usage.gpuSeconds / Double(max(usage.gpuFrames, 1)) * 1000, 2)) ms of GPU time a frame"
        )
        let differing = zip(answers[0], answers[1]).filter { $0 != $1 }.count
        print("Receivers' irradiance differing between CPU and GPU: \(differing) of \(answers[0].count)")
    }
}

/// A footing rocked slowly on dry sand against Gajan and Kutter's centrifuge test SSG02_03
/// (`FootingRockingTest`). `--shear` is the sand's shear modulus in MPa, `--bearing` its bearing
/// capacity in kPa; `--history` writes rotation, moment and settlement every 10 ms.
func runRocking() throws {
    let shear = (option("shear").flatMap { Float($0) } ?? 40) * 1e6
    let bearing = (option("bearing").flatMap { Float($0) } ?? 814) * 1e3
    let names = option("packets").map { $0.split(separator: ",").map(String.init) }
    let packets = FootingRockingTest.packets.filter { names?.contains($0.name) ?? true }
    print(
        "Gajan and Kutter's SSG02_03: a 29 Mg shear wall on a 2.8 × 0.65 m surface footing on dry dense sand, "
            + "rocked slowly; sand of \(format(Double(shear) / 1e6, 0)) MPa, bearing \(format(Double(bearing) / 1e3, 0)) kPa"
    )
    let result = try FootingRockingTest.run(
        device: device, shearModulus: shear, bearingCapacity: bearing, packets: packets,
        speed: option("speed").flatMap { Float($0) } ?? 0.2, progress: { print("  " + $0) })
    print("")
    print(
        pad("packet", 8) + pad("rotation", 18) + pad("moment forward", 18) + pad("moment back", 18)
            + pad("settlement / L", 18))
    print(pad("", 8) + String(repeating: pad("measured  model", 18), count: 4))
    for (measured, model) in zip(packets, result.packets) {
        func pair(_ a: Float, _ b: Float, _ digits: Int) -> String {
            pad(format(Double(a), digits) + "  " + format(Double(b), digits), 18)
        }
        print(
            pad(measured.name, 8) + pair(measured.peakRotation, model.peakRotation, 4)
                + pair(measured.moment.x, model.moment.x, 3) + pair(measured.moment.y, model.moment.y, 3)
                + pair(measured.settlement, model.settlement, 4))
    }
    print(
        String(
            format: "Largest actuator lag %.1f mm; %.0f s", (result.packets.map(\.lag).max() ?? 0) * 1000,
            result.wallSeconds))
    if let path = option("history") {
        let lines = ["rotation,moment,settlement"] + result.history.map { "\($0.x),\($0.y),\($0.z)" }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Short runs of a few scenes, each summed up as a hash of the air's state, peaks and impulses
/// and of the structure's summary: two builds that print the same hashes ran the same to the bit.
func runDigest() throws {
    func fnv(_ hash: inout UInt64, _ value: Float) {
        hash = (hash ^ UInt64(value.bitPattern)) &* 0x100_0000_01b3
    }
    let steps = option("steps").flatMap { Int($0) } ?? 80
    let cases: [(String, ScenarioPreset, Float, Bool)] = [
        ("open", .openGround, 0.5, false), ("street", .streetCanyon, 0.5, false),
        ("street, afterburning", .streetCanyon, 0.5, true), ("wall", .blastWall, 0.25, false),
    ]
    for (name, preset, cellSize, afterburning) in cases {
        var configuration = SolverConfiguration()
        configureRefinement(&configuration)
        configuration.afterburning = afterburning
        let solver = try BlastSolver(
            device: device, scenario: preset.scenario, cellSize: cellSize, configuration: configuration)
        let result = solver.advance(steps: steps)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        solver.withState { cells in
            for cell in cells {
                for value in [cell.density, cell.momentumX, cell.momentumY, cell.momentumZ, cell.energy] {
                    fnv(&hash, value)
                }
            }
        }
        let grid = solver.grid
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    fnv(&hash, solver.peakOverpressure(i, j, k))
                    fnv(&hash, solver.impulse(i, j, k))
                }
            }
        }
        if let summary = solver.bodySummary() {
            fnv(&hash, summary.maxDisplacement)
            fnv(&hash, summary.maxDamage)
            fnv(&hash, Float(summary.erodedElements))
        }
        print(
            "\(name), \(cellSize) m: \(String(hash, radix: 16)) after \(result.steps) steps, "
                + "\(result.refinedTiles) refined blocks"
                + (result.finerRefinedTiles > 0 ? ", \(result.finerRefinedTiles) at the second level" : ""))
    }
}

/// The layered soil column under ground points: its peak stress against the characteristics'
/// closed form for bilinear soil at several steps, and its cost a frame for a line of points fed
/// a frame a millisecond, as `GroundShockConsumer` runs it.
func runSoilColumn() throws {
    let ratio = Double(option("ratio") ?? "2") ?? 2
    let points = Int(option("points") ?? "31") ?? 31
    let deepest = Float(option("depth") ?? "3") ?? 3
    let (peak, duration) = (100e3, 0.004)
    let surface = { (t: Double) in t >= 0 && t <= duration ? peak * (1 - t / duration) : 0 }
    let depths = [0.5, 1.2, 3, 5]
    print(
        "Bilinear soil, 1,600 kg/m³ loading at 300 m/s, unloading at \(300 * ratio) m/s; 100 kPa over 4 ms:")
    print(
        "step (s)   element (m)   peak stress against the closed form at "
            + depths.map { "\($0) m" }.joined(separator: ", "))
    for step in [2e-4, 1e-4, 5e-5, 2.5e-5, 1.25e-5] {
        let profile = SoilProfile(
            layers: [
                SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: Float(300 * ratio))
            ],
            timeStep: Float(step))
        var column = SoilColumn(profile: profile, depth: 5)
        while column.time < 0.03 {
            let t = column.time
            let mean = { (t: Double) -> Double in
                let s = min(max(t, 0), duration)
                return peak * (s - s * s / (2 * duration))
            }
            column.step(load: (mean(t + step / 2) - mean(t - step / 2)) / column.timeStep)
        }
        let mids = column.elementDepths
        let ratios = depths.map { depth -> String in
            let e = mids.indices.min { abs(mids[$0] - depth) < abs(mids[$1] - depth) }!
            let exact = HystereticAttenuation.peakStress(
                depth: mids[e], loadingSpeed: 300, unloadingSpeed: 300 * ratio, surface: surface)
            return String(format: "%.3f", column.peakStress[e] / exact)
        }
        print(String(format: "%-10g %-13.4f ", step, column.depths[1]) + ratios.joined(separator: "  "))
    }
    // The cost: a line of points, 170 frames a millisecond apart, a triangle arriving later
    // further out.
    print("\nCost, \(points) points to \(deepest) m, 170 frames of 1 ms:")
    for step in [1e-4, 5e-5, 2.5e-5] {
        var spec = GroundShockSpec()
        spec.model = .column
        spec.depths = [0, 1, deepest]
        spec.points = (0..<points).map { SIMD2(Float($0) + 0.5, 0.5) }
        spec.profile = SoilProfile(
            layers: [
                SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: Float(300 * ratio))
            ],
            timeStep: Float(step))
        var consumer = GroundShockConsumer(spec: spec)
        let nx = Int32(points + 1)
        let start = Date()
        for frame in 0..<170 {
            let t = Double(frame) * 1e-3
            var values: [Float] = []
            for _ in 0..<2 {
                for i in 0..<Int(nx) {
                    let s = t - Double(i) * 0.002
                    let p = s >= 0 && s <= duration ? peak * (1 - s / duration) : 0
                    let kept = s >= 0 ? peak : 0
                    let impulse =
                        peak * (min(max(s, 0), duration) - pow(min(max(s, 0), duration), 2) / (2 * duration))
                    values += [Float(p), Float(kept), Float(impulse)]
                }
            }
            consumer.consume(
                GroundSlice(
                    time: t, cellSize: 1, grid: SIMD3(nx, 2, 4), first: .zero, counts: SIMD2(nx, 2),
                    values: values,
                    ambientDensity: 1.225, ambientPressure: 101_325, gamma: 1.4))
        }
        let seconds = Date().timeIntervalSince(start)
        let column = SoilColumn(profile: spec.columnProfile, depth: deepest)
        print(
            String(
                format: "step %-8g %4d elements a column: %.3f ms a frame, %.1f ns an element-step", step,
                column.elementCount, seconds / 170 * 1000,
                seconds / (170 * 1e-3 / column.timeStep * Double(column.elementCount * points)) * 1e9))
    }
}

do {
    switch command {
    case "digest": try runDigest()
    case "slab": try runSlab()
    case "tie": try runTie()
    case "beam": try runBeam()
    case "shear": try runShearBeam()
    case "pushoff": try runPushOff()
    case "impact": try runImpact()
    case "closein": try runCloseIn()
    case "closeair": try runCloseAir()
    case "gas": try runGasPressure()
    case "chamber": try runChamber()
    case "throughput": try runThroughput()
    case "structure": try runStructure()
    case "validate": try runValidation()
    case "snapshot": try runSnapshot()
    case "anchorage": try runAnchorage()
    case "rocking": try runRocking()
    case "thermal": try runThermal()
    case "dialpack": try runDialPack()
    case "soilcolumn": try runSoilColumn()
    case "heating": try runHeating()
    default:
        print("Unknown command \(command). Use throughput, structure, validate, slab or snapshot.")
        exit(2)
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
