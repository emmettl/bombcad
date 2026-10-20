import BlastCore
import Foundation
import Metal

// Command-line companion to the app: measures solver throughput, compares a surface burst
// against the Kinney-Graham curve and renders offscreen snapshots.
//
//   blastbench [throughput] [--preset open|single|street|courtyard|wall|box|frame|infill|storeys|tall|tower|column|
//               office|protected|glass|carpark|underpass|house|blockwall|chamber|gasroom|panel-gas|panel-street|
//               plant|warehouse|terraced]
//               [--full] [--dx 0.5,0.25]
//   blastbench structure [--preset wall|box] [--contact] [--elastic]
//   (any command) [--rounding default|unfused|relaxed]   (the kernels' rounding; see KernelRounding)
//   blastbench validate [--dx 0.25] [--histories dir --until 0.25 [--tag name]] [--domain-scale 2]
//   blastbench beam [--layers 12,24] [--rate 0.1]
//   blastbench shear [--layers 12,24] [--rate 0.05] [--slice 92] [--dowel 1] [--map 9]
//               [--bond pullout|splitting|confined]   (also on beam and slab)
//               [--pressed-interlock]   (also on beam, slab, pushoff, impact, chamber and closein)
//               [--work] [--hourglass 0.5] [--interlock 0.2] [--dowel 0] [--confinement 0]
//               [--fracture-energy 0.5] [--tensile-strength 0.8]   (work trace on slab too; knobs everywhere)
//   blastbench pushoff [--specimens 1/.2/.4,1/.4/.3] [--size 50] [--dilatancy 0.5] [--close]
//   blastbench impact [--tests SS0a-1,SS0b-1] [--layers 16] [--time 0.2] [--beams 0.1] [--map] [--bond ...]
//   blastbench closeair [--z 0.3,0.5,0.75,1] [--dx 0.02] [--mapped] [--refine 2] [--refine-levels 2]
//   blastbench closein [--tests P1,P7] [--dx 0.05] [--h 0.025] [--time 0.3] [--refine 2] [--afterburn] [--progress] [--bond ...]
//                      [--trace out-%.csv [--trace-until 0.001]] [--faces] [--energy] [--under] [--skirts]
//                      [--roomy] [--history out-%.csv]   (open faces 4 m/kg^(1/3) out; the deflection's record)
//   blastbench twoface [--wu S8] [--wang A] [--yao T4] [--roomy] [--out dir]   (Wu's, Wang's and Yao's slabs;
//                      --roomy moves every open face out to 4 m/kg^(1/3), as Scenario.openFaceRoom)
//   --balloon-start on closein, twoface, perimeter, keys, envelope-debris and mendonca --recommended:
//                      the charge started from the balloon these were recorded on before 18 October 2026
//   blastbench contact [--tests SN142,SN131] [--dx 0.02] [--refine 2] [--levels 2] [--layers 12] [--time 0.003] [--step-divisor 4] [--charge 1.64] [--progress] [--fastest] [--column] [--no-debris-drag] [--no-contact]
//   blastbench slab [--history] [--history-csv dir] [--sensitivity [--convergence]] [--layers 16,32] [--strip 25] [--map] [--plan [0.1]]
//                   [--stiffening [--profile [--line] [--column -44]]]   (where the tension along the span is carried)
//   blastbench tie [--h 0.02,0.01] [--bond none|splitting] [--factor 1.25]   (a tie against the Model Code)
//                   [--shells 2,1 [--shell-layers 8] [--shell-rate none|designFactors|strainRate]]
//   blastbench perimeter [--study air] [--layout half|street|canopied] [--dx 0.05] [--refine 2] [--columns 0.2] [--wing 6] [--out dir]
//                        (Alsubaei's perimeter walls; see PerimeterBench.swift)
//   blastbench keys [--trials WR1A,WR1B,WR2C] [--dx 0.1] [--h 0.0375] [--time 3]
//                        (Keys's brick walls' debris under 41 kg; see KeysBench.swift)
//   blastbench anchorage [--mass 50] [--standoff 6,10,15,25] [--time 0.5] [--h 0.0625] [--shells]
//                        [--bases clamped,resting] [--air [--cell 0.25] [--margin 12] [--height 18] [--progress]]
//                        [--massless] [--layer 3 [--beneath rock|sand|clay]] [--embed 1] [--elastic]   (the footing's soil)
//                        [--panel]   (a 3 m panel resting on the ground, its edges tied to columns by each base)
//   blastbench seat [--speeds 4,8,12] [--seats 0.1,0.2] [--time 1.5] [--h 0.1] [--dowels]
//                   (a precast beam on corbels of two columns, one column struck away from the span)
//   blastbench precast [--tests i0_50,i0_100,i0_150] [--friction 0.7] [--neoprene] [--reversals 40] [--samples Samples/PrecastSeat] [--history out-%.csv]
//                      (a precast beam's seat cycled along its corbel, against Batalha et al.'s tests)
//   blastbench rocking [--shear 40] [--bearing 814] [--packets a,b,c,d,e] [--speed 0.2] [--history out.csv]
//                      [--elastic | --elastic-share 0.12 --memory 0 --heave 0]   (the sand's settling; also for shaking)
//   blastbench shaking [--tests ssg04-dsw,ssg04-shw,ssg03-dsw] [--shear 80] [--bearing 814] [--samples Samples/FoRDy]
//                      [--history out-%.csv] [--massless] [--damping 0.2]   (a wall on a footing shaken at its base, against FoRDy's SSG03/SSG04)
//   blastbench hillside [--mass 500] [--dx 0.25] [--duration 0.1] [--every 0.01]
//                       (the two-storey frame on a hillside, each column's footing set in the slope)
//   blastbench gravity [--preset office] [--time 0.3] [--damping 50]
//                      (a layout's structure under gravity alone, damped: stands, deflects or falls)
//   blastbench snapshot --out frame.png [--preset street] [--dx 0.25] [--time 0.03] [--mass kg] [--fit-reach Z]
//                       [--mode peak|now|impulse|fluence|irradiance]
//                       [--fragments spec.json [--dot 5] [--hazard]] [--ground-shock spec.json] [--ground <type> [--explosive anfo]]
//                       [--thermal spec.json [--thermal-compare [--thermal-compare-with shape]]
//                        [--thermal-variants a.json,b.json]]
//                       [--air thermal] [--afterburn] [--radiate [--absorption 0.1] [--soot-yield 0.185]]
//                       [--stationary-walls] [--cloud spec.json [--frame-cloud] [--cloud-results out.json]]
//                       [--checkpoint-at T --checkpoint-out DIR] [--resume DIR] [--from DIR]
//                        (a checkpoint saved at the first 64-step boundary from T s; a run carried on from
//                        one; or one drawn as it was saved: SolverCheckpoint)
//   blastbench checkpoint-check [--steps 192] [--at 128] [--recommended] [--refine 2] [--refine-levels 2]
//                       [--terrain ridge] [--gravity] [--case open] [--dx 0.25] [--out DIR]
//                        (a run saved part way and carried on from it, against the same run straight through)
//                       [--standing]   (the standing a new document of the preset shows, in place of a run)
//   blastbench dialpack [--dx 4] [--time 1] [--tons 500] [--domain 480] [--radiate] [--refine 2]
//                       [--balloon-start] [--early-voxels n] [--early-samples s] [--hot-air|--grey-air] [--frame-detail]
//                       [--budget out.csv]   (the fireball's energy budget each frame: heat released by
//                        temperature and mixture, the luminous gas, what the gas lost to radiation)
//                       [--burn-mixing C]   (afterburning limited by the sub-grid mixing, an eddy-break-up
//                        rate; also on validate, gas, gauging and the scene benches)
//   blastbench radial-profile [--mass 453600] [--reach 2] [--times 0.5,1,1.25,2,5] [--every 4] [--dump prefix] [--jwl]
//                      (the mapped start's one-dimensional burst through its products' edge and shock)
//   blastbench shell-sphere [--profile file.csv [--mass kg]] [--voxel 0.5,0.25]
//                      (the thermal volume's march against exact rays through a layered sphere)
//   blastbench hazards [--mass 100] [--fragments spec.json [--height 1]]
//                      (the safety standards' distances, the minimum safe distance and the free
//                      field's injury radii, a charge on the ground)
//   blastbench fragment-throw [--count 100000]
//                      (hazardous fragment distance against DoD 4145.26-M's single items in the open)
//                       [--csv out.csv]   (500 t of TNT's fireball radiation, against DREO 642)
//   blastbench bubble [--dx 0.5] [--radius 4] [--hot 2] [--time 20] [--lapse 6.5] [--csv out.csv]
//                     (a hot bubble rising under gravity, against the cloud's integral model)
//   blastbench mixinglayer [--dx 0.5] [--speed 50] [--time 8] [--length 128] [--mixing] [--csv out.csv]
//                          (a temporal mixing layer's growth, against dθ/dt = 0.014 ΔU)
//   blastbench thermal [--preset street] [--frames 60] [--samples 128] [--model volume] [--absorption 0.1] [--terrain hill]
//                      (the volume's march, or the shape's and sphere's visibility, on CPU and GPU)
//   blastbench deflagration [vessel|vented|tube|ball|slope|layout] [--gas methane|propane] [--percent 9.5] [--air thermal]
//                           [--laminar] [--turbulence 0.7] [--factor 1] [--wrinkling 1] [--mixing [--mixing-model smagorinsky]]
//                           vented: [--vent 5.4] [--dx 0.1] [--ignition back] [--release Pa] [--posts 0.2] [--speeds]
//                           [--arrivals f.csv] [--history f.csv] [--front] [--axis --until s]; ball: [--closed] [--shells]
//                           (closed sphere against the thin-flame model; vented room against EN 14994/NFPA 68;
//                            a tube's and a free sphere's flame profiles; layout --out f.json writes the
//                            gas-room preset as a layout for `BombCAD run`)
//   blastbench terrain --study wedge|shield|hill ...   (the terrain's checks; see TerrainBench.swift)
//   blastbench landscape [--mass 500000] [--dx 8] ...   (large surface bursts; see LandscapeBench.swift)
//   blastbench advise --calibrate [--time]   (the cost-against-fidelity advisor; see AdvisorBench.swift)
//   blastbench hrynyk [--slabs TH2,TH6,TH7] [--layers 16] [--impacts 4] [--ensemble 16]   (blind test 1; see HrynykBench.swift)
//   blastbench contact-profile [--cases solid,shell,debris,terraced] [--steps 2000]
//   blastbench profile [--preset open] [--dx 0.5] [--closein] [--refine 2] [--terrain ridge|slope|hill] [--staircase]
//                      (GPU time per stage, on the recommended air)
//                        (where contact's time goes; see ContactBench.swift)
//   blastbench mendonca [--slabs 1,2,4,5,7,9,10] [--layers 8] [--dx 0.0125] [--ensemble 8]   (blind test 2; see MendoncaBench.swift)
//   blastbench reynolds [--slabs HSCV1,HSCV4] [--layers 8] [--load tail] [--ensemble 8]   (blind test 3; see ReynoldsBench.swift)
//   blastbench panelblock --case gravity|gas|street [--dx 0.25] [--frames 0.1,1,4]   (large-panel flats; see PanelBlockBench.swift)
//   blastbench merge [--rigs A,C,E,C*] [--gas methane,propane] [--dx 0.25] [--factor 1] [--out f.json]
//                    (MERGE's congested rigs through the congestion model; see MergeBench.swift)
//   blastbench langdon [--tests c622] [--h 0.0572]   (corrugated panels under pulse pressure; see LangdonBench.swift)
//   blastbench adblast [--tests 3,7] [--held]   (trapezoidal cladding on screws under C4; see AdblastBench.swift)
//   blastbench buildings [--dx 0.5] [--duration 0.12] [--mass 50] [--out f.json]
//                        (three buildings across a street, together and each alone; see BuildingsBench.swift)
//   blastbench digest [--refine 2] [--refine-levels 2] [--steps 80] [--terrain flat|hill|ridge|slope] [--recommended]
//                     [--gravity] [--case open]
//                     [--gravity]   (hashes of short runs, to compare builds)

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "throughput"

guard let metalDevice = MTLCreateSystemDefaultDevice() else {
    print("No Metal device available")
    exit(1)
}
/// The GPU the commands run on: a global, which the commands' files reach (a `guard`'s binding
/// stays in this file).
let device = metalDevice

// `--rounding unfused` or `relaxed` (or `default`): the kernels round as the rounding ensemble's
// do (`KernelRounding`); a command run with each gives the spread its results after failure have
// between builds whose arithmetic rounds differently.
if let name = option("rounding") {
    guard let rounding = KernelRounding(rawValue: name) else {
        print("--rounding takes \(KernelRounding.allCases.map(\.rawValue).joined(separator: ", ")).")
        exit(2)
    }
    unsetenv("BOMBCAD_KERNEL_MATH")
    unsetenv("BOMBCAD_KERNEL_CONTRACT")
    for (key, value) in rounding.environment { setenv(key, value, 1) }
}
// `--no-settle`: structures take their weight as the run starts, as before 17 October 2026, in
// any bench (`BOMBCAD_SETTLE=off`, read by `BlastSolver.settleStructures()`).
if flag("no-settle") { setenv("BOMBCAD_SETTLE", "off", 1) }

do {
    guard let run = commands[command] else {
        print("Unknown command \(command). Use throughput, structure, validate, slab or snapshot.")
        exit(2)
    }
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
