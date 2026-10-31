import BlastCore
import BlastRender
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// Whole-event simulation, first step (emmettl/bombcad-work#36): the large-panel block under the
// street charge carried past its collapse, with failed concrete as rubble particles and the air
// coupled throughout, and measured as it goes, to find what gives out first: the contact, the
// time step, the memory or the energy (docs/whole-event.md).
//
//   blastbench wholeevent [--storeys 12] [--mass 500] [--dx 0.25] [--time 10] [--every 0.05]
//                         [--budget 80 (minutes)] [--checkpoint-every 1] [--frames 1,2,4,6,8,10]
//                         [--sleeping-air] [--no-rubble] [--dir /Volumes/StudioData/bombcad/whole-event/<name>]
//                         [--continue] [--ground-friction 0.6 (0 for the frictionless ground)]
//
// Runs in pieces: after `--budget` minutes of wall time it saves a checkpoint at the next 64-step
// boundary and stops; `--continue` (with the same options) carries on from the latest checkpoint
// in `--dir`, the same to the bit as an unbroken run. Each sample (every `--every` s of the
// run, at the first batch end after it) appends a row to `<dir>/phases.csv`:
// - the clocks: the air's step and the structure's, whether the air sleeps, wall and GPU seconds;
// - memory: the process's footprint and the device's allocation;
// - contact: nodes listed, moved and pushed, the contact table's crowded entries and the nodes
//   they leave out, rubble particles and theirs (`StructureSolver.census()`);
// - energy: kinetic (nodes, particles), the particles' internal energy, the work gravity has done,
//   the elements' work by mechanism (the work trace, `StructureSolver.tracesWork`), and what is
//   left: the net work of the air, the joints, contact and the ground; and the joints' slip work
//   and the joints' and contact's power at that instant.
// The air is kept awake (no sleep) by default since 31 October 2026, as a dust cloud would need:
// asleep, the air is frozen as it was, and its pressures on the faces of a collapsing block push it
// down (docs/whole-event.md, energy budget; adopted: awake air). `--sleeping-air` lets it sleep as
// the recommended settings have it, to reproduce the runs before that date; `--awake` is accepted
// and changes nothing. `--continue` and the readers of a saved state take the air as the run was
// started with it, whatever is given. Diagnostics: `--inspect <checkpoint>` lists the fastest
// nodes of a saved state with the elements round them; `--watch 20` does so at each sample with a
// node faster than 20 m/s (and a run that goes unstable does as it stops);
// `--erode-crushed-bare` and `--release-bare-hourglass` turn on those two options. `--split-work`
// splits the census by source each substep (`StructureSolver.traceExternalWork`), to
// work-split.csv; `--trace-node i,j,k` (and `--trace-element i,j,k`) record one node's (and one
// element's) forces each substep, to trace.csv (and element-trace.csv). `--assumed-strain` and the
// other element options (`applyHourglassOptions`) apply to the block. `--breakdown <checkpoint>`
// prints where the elements' work went in a saved state, by part and by state, and the hourglass
// forces the elements hold (emmettl/bombcad-work#36 step 3, docs/whole-event.md section 7).
// `--outcome <checkpoint or run folder>` prints what a user reads from each saved state: floor
// area down and storeys lost, failures by part, rubble, debris outside the plan and its reach
// (WholeEventOutcome.swift; docs/whole-event.md, a range).

private struct WholeEventState: Codable {
    var stepCount: Int
    var time: Double
    var wallSeconds: Double
    var gpuSeconds: Double
    var baselineRise: Double
    var nextSample: Double
    var nextCheckpoint: Double
    var framesDone: [Double]
    /// The ground's Coulomb friction the run was started with; nil in a run saved before it was
    /// recorded (30 October 2026), whose ground was frictionless unless `--ground-friction` was given.
    var groundFriction: Float?
    /// Whether the air sleeps in the run (`--sleeping-air`); nil in a run saved before it was
    /// recorded (31 October 2026). What decides it on carrying on is the checkpoint's configuration.
    var airSleeps: Bool?
}

/// Whole-event runs' ground friction by default: Coulomb 0.6, concrete on concrete or hard ground,
/// as Keys's walls are run with; adopted on the user's word of 30 October 2026
/// (emmettl/bombcad-work#36; docs/whole-event.md, adopted: ground friction 0.6). For whole-event
/// runs only: the solver's own default stays frictionless.
let wholeEventGroundFriction: Float = 0.6

/// The air of a whole-event run: kept awake (no sleep) by default, adopted on the user's word of
/// 31 October 2026 (emmettl/bombcad-work#36; docs/whole-event.md, adopted: awake air), or sleeping
/// as the recommended settings have it (`--sleeping-air`, the runs before that date). For whole-event
/// runs only: the solver's own sleeping air is unchanged.
func wholeEventConfiguration(airSleeps: Bool) -> SolverConfiguration {
    var configuration = SolverConfiguration.recommended
    if !airSleeps {
        configuration.airSleepThreshold = 0
        configuration.airSleepCrossings = 0
    }
    return configuration
}

private func processFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : 0
}

func runWholeEvent(device: MTLDevice) throws {
    let storeys = option("storeys").flatMap { Int($0) } ?? LargePanelBlock.storeys
    var scenario = LargePanelBlock.scenario(
        .street, name: ScenarioPreset.largePanelStreet.title, storeys: storeys)
    if let mass = option("mass").flatMap({ Float($0) }) { scenario.charge.mass = mass }
    let rubble = !flag("no-rubble")
    scenario.structure?.rubbleParticles = rubble
    // The crushed bare elements' options (both off by default): `--erode-crushed-bare`,
    // `--release-bare-hourglass`.
    if flag("erode-crushed-bare") { scenario.structure?.erodesCrushedBare = true }
    if flag("release-bare-hourglass") { scenario.structure?.releasesCrushedBareHourglass = true }
    // The hourglass and element options (`--assumed-strain`, `--hourglass-secant`,
    // `--hourglass-no-steel`, …; `applyHourglassOptions`), all off unless given.
    if var structure = scenario.structure {
        applyHourglassOptions(&structure)
        scenario.structure = structure
    }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let end = option("time").flatMap { Double($0) } ?? 10
    let every = option("every").flatMap { Double($0) } ?? 0.05
    let budget = (option("budget").flatMap { Double($0) } ?? 80) * 60
    let checkpointEvery = option("checkpoint-every").flatMap { Double($0) } ?? 1
    let frames = (option("frames") ?? "1,2,4,6,8,10").split(separator: ",").compactMap { Double($0) }.sorted()
    let givenSleeping = flag("sleeping-air")
    if givenSleeping, flag("awake") {
        print("--sleeping-air and --awake: give one (the air is awake unless --sleeping-air)")
        exit(2)
    }
    let givenFriction = option("ground-friction").map { Float($0) ?? -1 }
    if let givenFriction, givenFriction < 0 {
        print("--ground-friction takes a coefficient, 0 or more (0 for the frictionless ground)")
        exit(2)
    }
    let name =
        "street-\(storeys)s-\(Int(scenario.charge.mass))kg-\(rubble ? "rubble" : "norubble")\(givenSleeping ? "-asleep" : "")"
    let dir = URL(filePath: option("dir") ?? "/Volumes/StudioData/bombcad/whole-event/\(name)")
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    // The saved states to read: `--inspect`'s or `--breakdown`'s, every one in `--outcome`'s folder
    // (or the one it names), or with `--continue` the latest in `--dir`.
    func checkpoints(in url: URL) throws -> [URL] {
        fm.fileExists(atPath: url.appending(path: "checkpoint.json").path)
            ? [url]
            : try fm.contentsOfDirectory(atPath: url.path).filter { $0.hasPrefix("step-") }.sorted().map {
                url.appending(path: $0)
            }
    }
    let outcomeFolders = try option("outcome").map { try checkpoints(in: URL(filePath: $0)) }
    let latest =
        flag("continue")
        ? try fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasPrefix("step-") }).sorted()
            .last(where: { fm.fileExists(atPath: dir.appending(path: "\($0)/whole-event.json").path) })
            .map { dir.appending(path: $0) }
        : nil
    let reading =
        (option("inspect") ?? option("breakdown")).map { URL(filePath: $0) } ?? outcomeFolders?.first
        ?? latest

    // The air as the saved state was run, read from its configuration's fingerprint (so a run from
    // before 31 October 2026, which does not record it, carries on asleep if it slept), else as given.
    var airSleeps = givenSleeping
    if let reading, let saved = try? SolverCheckpoint.header(in: reading).configuration {
        for sleeps in [true, false]
        where saved == SolverCheckpoint.fingerprint(configuration: wholeEventConfiguration(airSleeps: sleeps))
        {
            if sleeps != givenSleeping, flag("sleeping-air") || flag("awake") {
                print("The saved state's air \(sleeps ? "sleeps" : "is awake"): taken as it was saved")
            }
            airSleeps = sleeps
        }
    }
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize,
        configuration: wholeEventConfiguration(airSleeps: airSleeps))
    guard let body = solver.bodies.first, let solids = body.solids else {
        print("No solid structure")
        exit(2)
    }
    solids.contactMode = .always
    // Coulomb friction on the ground, 0.6 by default (`wholeEventGroundFriction`). `--ground-friction 0`
    // gives the frictionless ground of the runs before 30 October 2026, where what lands sheds its
    // sliding speed at 8/s only while pressed into the ground and debris creeps on for seconds
    // (docs/whole-event.md, ground friction). `--continue` carries on with the friction the run was
    // started with, unless given again.
    solids.groundFrictionCoefficient = givenFriction ?? wholeEventGroundFriction
    if let inspect = option("inspect") {
        solids.tracesWork = true
        let header = try solver.restoreCheckpoint(from: URL(filePath: inspect), scene: scenario)
        inspectFastest(solids, time: header.time)
        return
    }
    if let path = option("breakdown") {
        solids.tracesWork = true
        let header = try solver.restoreCheckpoint(from: URL(filePath: path), scene: scenario)
        breakdownWork(solids, time: header.time)
        return
    }
    if let folders = outcomeFolders {
        // One checkpoint, or every checkpoint in a run's folder, in order.
        print(WholeEventOutcome.header)
        for folder in folders {
            solids.tracesWork = true
            let header = try solver.restoreCheckpoint(from: folder, scene: scenario)
            print(WholeEventOutcome(solids, storeys: storeys).row(time: header.time))
            fflush(stdout)
        }
        return
    }

    // Where to start: the latest checkpoint in the folder with `--continue`, else afresh.
    var state: WholeEventState
    let csv = dir.appending(path: "phases.csv")
    if let folder = latest {
        solids.tracesWork = true
        let header = try solver.restoreCheckpoint(from: folder, scene: scenario)
        state = try JSONDecoder().decode(
            WholeEventState.self, from: Data(contentsOf: folder.appending(path: "whole-event.json")))
        if givenFriction == nil {
            solids.groundFrictionCoefficient = state.groundFriction ?? 0
        }
        state.groundFriction = solids.groundFrictionCoefficient
        state.airSleeps = airSleeps
        print(String(format: "Resumed from %@: step %d, %.4f s", folder.path, header.stepCount, header.time))
        // Rows written after this checkpoint by a piece that did not reach its next are dropped.
        if let text = try? String(contentsOf: csv, encoding: .utf8) {
            let kept = text.split(separator: "\n").filter { line in
                guard let step = line.split(separator: ",").dropFirst().first.flatMap({ Int($0) }) else {
                    return true
                }
                return step <= header.stepCount
            }
            try (kept.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
        }
    } else {
        // Settled under its own weight first, then the trace begins: the work from here on is the event's.
        solver.settleStructures()
        solids.tracesWork = true
        state = WholeEventState(
            stepCount: 0, time: 0, wallSeconds: 0, gpuSeconds: 0, baselineRise: solids.census().massTimesRise,
            nextSample: 0, nextCheckpoint: checkpointEvery, framesDone: [],
            groundFriction: solids.groundFrictionCoefficient, airSleeps: airSleeps)
        try? fm.removeItem(at: csv)
    }
    print(
        String(
            format:
                "%@: %d elements, %d nodes, %.2f m air cells (%d), rubble %@, air %@, ground friction %.2f; structure step %.2f µs; to %.1f s in pieces of %.0f min",
            scenario.name, solids.elementCount, solids.nodeCount, cellSize,
            solver.grid.nx * solver.grid.ny * solver.grid.nz,
            rubble ? "on" : "off", airSleeps ? "sleeping as recommended (--sleeping-air)" : "kept awake",
            solids.groundFrictionCoefficient,
            Double(solids.criticalTimeStep) * 1e6, end, budget / 60))
    fflush(stdout)

    func work(_ totals: [Double], _ cases: [StructureSolver.WorkChannel]) -> Double {
        cases.reduce(0) { $0 + totals[$1.rawValue] }
    }
    let header = [
        "t", "step", "air_dt_us", "structure_dt_us", "asleep", "wall_s", "gpu_s", "footprint_GB", "device_GB",
        "active", "failed", "nodes", "listed", "moved", "in_contact", "entries", "entries_full",
        "nodes_dropped",
        "entries_aliased", "particles", "particles_in_contact", "particle_entries_full", "particles_dropped",
        "particles_on_ground", "fastest_node", "fastest_particle", "deepest_node", "deepest_particle",
        "ke_nodes_J", "ke_particles_J", "internal_particles_J", "gravity_work_J", "elastic_J", "fracture_J",
        "crushing_J", "steel_J", "hourglass_J", "hourglass_capped_J", "viscosity_J", "other_J",
        "internal_work_J", "residual_J",
        "max_displacement_m", "not_finite", "joint_slip_J", "joint_power_W", "contact_power_W",
        "particle_contact_power_W",
    ]
    if !fm.fileExists(atPath: csv.path) {
        try (header.joined(separator: ",") + "\n").write(to: csv, atomically: true, encoding: .utf8)
    }
    let out = try FileHandle(forWritingTo: csv)
    out.seekToEndOfFile()

    let renderer = try SceneRenderer(device: device)
    func frame(_ time: Double) {
        solver.refreshVisualization()
        renderer.setScene(scenario, solver: solver)
        let bounds = scenario.structure?.bounds ?? Box(min: .zero, max: scenario.domainSize)
        let centre = (bounds.min + bounds.max) / 2
        let camera = OrbitCamera(
            target: SIMD3(centre.x + 3, centre.y, 0.4 * bounds.max.z), distance: 2.3 * bounds.max.z,
            azimuth: -0.75, elevation: 0.22)
        let path = dir.appending(path: String(format: "frame-%05.0fms.png", time * 1000))
        if let image = renderer.snapshot(
            commandQueue: solver.commandQueue, width: 1600, height: 1000, camera: camera),
            let destination = CGImageDestinationCreateWithURL(
                path as CFURL, UTType.png.identifier as CFString, 1, nil)
        {
            CGImageDestinationAddImage(destination, image.image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    let startedWall = ContinuousClock.now
    let startedGPU = solver.stepGPUSeconds
    func wall() -> Double {
        state.wallSeconds + Double((ContinuousClock.now - startedWall) / .milliseconds(1)) / 1000
    }
    func gpu() -> Double { state.gpuSeconds + solver.stepGPUSeconds - startedGPU }
    var lastAirStep = 0.0
    var largest: Float = 0

    // `--split-work`: the census split by source (`StructureSolver.traceExternalWork`), to
    // work-split.csv: the residual's change since the split began, and each source's work since.
    var splitOut: FileHandle? = nil
    var splitStart: (residual: Double, internalWork: Double)? = nil
    // `phases: false` writes the census split's row alone (`--split-work`, as a piece stops).
    func sample(phases: Bool = true) {
        autoreleasepool {
            let c = solids.census()
            let totals = solids.workTotals()
            let summary = solids.summary()
            largest = max(largest, summary.maxDisplacement)
            let elastic = work(totals, [.tensionNormal, .compressionNormal, .uncrackedShear])
            let fracture = work(
                totals,
                [
                    .tensionCracked, .tensionHairline, .crackShear, .crackShearPressed, .interlock,
                    .interlockPressed,
                    .dowel, .kink,
                ])
            let crushing = work(totals, [.compressionCrushed])
            let steel = work(totals, [.bars, .bond])
            let hourglass = work(totals, [.hourglass, .hourglassCapped])
            let capped = work(totals, [.hourglassCapped])
            let viscosity = work(totals, [.viscosity])
            let other = work(totals, [.other])
            let internalWork = totals.reduce(0, +)
            let g = Double(solids.gravity)
            let gravityWork = -g * (c.massTimesRise - state.baselineRise)
            let kinetic = c.nodeKinetic + c.particleKinetic
            // What the elements' work, the motion and gravity leave: the net work done on the body by
            // the air, its joints, contact between its pieces and the ground (and the settle's
            // damping, none after it).
            let residual = kinetic + c.particleInternal + internalWork - gravityWork
            if let splitOut {
                // The elements' work on the nodes and their own work as the trace counts it should
                // cancel; what the sources leave of the residual's change is the conversion to
                // rubble's (zero if it passes energy across exactly) and rounding.
                let w = solids.externalWork()
                let start = splitStart ?? (residual, internalWork)
                splitStart = start
                let parts = [
                    w.elements - w.airOnFaces + internalWork - start.internalWork, w.airOnFaces, w.air,
                    w.contact,
                    w.links, w.anchors, w.pairs,
                    w.ground + w.particleGround - w.step, w.step, w.particleContact, w.particleAir,
                ]
                let detail = [w.contactWithParticles, w.cappedSubsteps]
                let sum = parts.reduce(0, +)
                let overlaps = solids.rubbleOverlaps()
                let row =
                    [String(format: "%.5f", solver.time), String(format: "%.1f", residual - start.residual)]
                    + parts.map { String(format: "%.1f", $0) } + [
                        String(format: "%.1f", sum), String(format: "%.1f", residual - start.residual - sum),
                        "\(overlaps.particlePairs)", String(format: "%.5f", overlaps.deepestBetweenParticles),
                        "\(overlaps.nodePairs)", String(format: "%.5f", overlaps.deepestOnNodes),
                        "\(overlaps.ownCornerPairs)", String(format: "%.5f", overlaps.deepestOnOwnCorners),
                    ] + detail.map { String(format: "%.1f", $0) }
                splitOut.write((row.joined(separator: ",") + "\n").data(using: .utf8)!)
            }
            let values: [String] = [
                String(format: "%.5f", solver.time), "\(solver.stepCount)",
                String(format: "%.3f", lastAirStep * 1e6),
                String(format: "%.4f", Double(solids.criticalTimeStep) * 1e6), solver.airIsAsleep ? "1" : "0",
                String(format: "%.1f", wall()), String(format: "%.1f", gpu()),
                String(format: "%.3f", processFootprint()),
                String(format: "%.3f", Double(device.currentAllocatedSize) / 1e9),
                "\(summary.activeElements)", "\(summary.erodedElements)", "\(c.nodes)", "\(c.listedNodes)",
                "\(c.movedNodes)", "\(c.nodesInContact)", "\(c.nodeEntries)", "\(c.nodeEntriesFull)",
                "\(c.nodesDropped)", "\(c.nodeEntriesAliased)", "\(c.particles)", "\(c.particlesInContact)",
                "\(c.particleEntriesFull)", "\(c.particlesDropped)", "\(c.particlesOnGround)",
                String(format: "%.2f", c.fastestNode), String(format: "%.2f", c.fastestParticle),
                String(format: "%.4f", c.deepestNode), String(format: "%.4f", c.deepestParticle),
                String(format: "%.1f", c.nodeKinetic), String(format: "%.1f", c.particleKinetic),
                String(format: "%.1f", c.particleInternal), String(format: "%.1f", gravityWork),
                String(format: "%.1f", elastic), String(format: "%.1f", fracture),
                String(format: "%.1f", crushing),
                String(format: "%.1f", steel), String(format: "%.1f", hourglass - capped),
                String(format: "%.1f", capped), String(format: "%.1f", viscosity),
                String(format: "%.1f", other), String(format: "%.1f", internalWork),
                String(format: "%.1f", residual),
                String(format: "%.4f", summary.maxDisplacement),
                c.notFinite || summary.hasBlownUp ? "1" : "0",
                String(format: "%.1f", c.jointSlipWork), String(format: "%.1f", c.jointPower),
                String(format: "%.1f", c.contactPower), String(format: "%.1f", c.particleContactPower),
            ]
            guard phases else { return }
            out.write((values.joined(separator: ",") + "\n").data(using: .utf8)!)
            print(
                String(
                    format:
                        "t %.3f s, step %d (air %.0f µs%@), wall %.0f s, GPU %.0f s, %.2f GB; %d failed, %d particles; "
                        + "contact: %d listed, %d pushed, %d dropped (+%d particles); KE %.2f MJ, gravity %.2f MJ, work %.2f MJ "
                        + "(fracture %.2f, crushing %.2f, steel %.2f, hourglass %.2f), net in %.2f MJ; fastest %.0f / %.0f m/s%@",
                    solver.time, solver.stepCount, lastAirStep * 1e6, solver.airIsAsleep ? ", asleep" : "",
                    wall(), gpu(),
                    processFootprint(), summary.erodedElements, c.particles, c.listedNodes, c.nodesInContact,
                    c.nodesDropped, c.particlesDropped, kinetic / 1e6, gravityWork / 1e6, internalWork / 1e6,
                    fracture / 1e6,
                    crushing / 1e6, steel / 1e6, hourglass / 1e6, residual / 1e6, c.fastestNode,
                    c.fastestParticle,
                    c.notFinite || summary.hasBlownUp ? " NOT FINITE" : ""))
            if let pool = solids.assumedStrainSummary {
                print(
                    "  assumed strain: \(pool.switched) of \(pool.elements) switched\(pool.poolFull ? ", pool full" : "")"
                )
            }
            // `--nodes i,j,k;…`: those nodes at each sample, and how near each is to the others.
            if let list = option("nodes") {
                let picked = list.split(separator: ";").map {
                    $0.split(separator: ",").compactMap { Int($0) }
                }
                .filter { $0.count == 3 }
                let places = picked.map { solids.position($0[0], $0[1], $0[2]) }
                for (n, ijk) in picked.enumerated() {
                    let node = solids.node(ijk[0], ijk[1], ijk[2])
                    var around: [String] = []
                    for a in 0..<8 {
                        let (i, j, k) = (ijk[0] - (a & 1), ijk[1] - ((a >> 1) & 1), ijk[2] - ((a >> 2) & 1))
                        guard i >= 0, j >= 0, k >= 0, i < solids.ex, j < solids.ey, k < solids.ez else {
                            continue
                        }
                        let flag = solids.flag(i, j, k)
                        guard flag != .empty else {
                            around.append("empty")
                            continue
                        }
                        // Its stress (MPa: xx yy zz xy yz zx) and steel ratios.
                        let sigma = solids.stress(i, j, k).map { String(format: "%.0f", $0 / 1e6) }.joined(
                            separator: " ")
                        let steel = solids.steelRatio(i, j, k)
                        around.append(
                            "\(flag)[\(sigma)|" + String(format: "%.3f %.3f %.3f", steel.x, steel.y, steel.z)
                                + "]")
                    }
                    let nearest =
                        places.indices.filter { $0 != n }.map { simd_distance(places[$0], places[n]) }.min()
                        ?? 0
                    print(
                        String(
                            format:
                                "  node (%d,%d,%d): at (%.3f, %.3f, %.3f), v (%.2f, %.2f, %.2f), %.3g kg, nearest listed %.3f m; %@",
                            ijk[0], ijk[1], ijk[2], places[n].x, places[n].y, places[n].z, node.vx, node.vy,
                            node.vz,
                            node.mass, nearest, around.joined(separator: " ")))
                }
            }
            // `--watch 20`: the fastest nodes, whenever one is faster than 20 m/s.
            if let watch = option("watch").flatMap({ Float($0) }), c.fastestNode > watch {
                inspectFastest(solids, time: solver.time, count: 6)
            }
            fflush(stdout)
        }
    }

    func save() throws {
        // The work trace's GPU sums folded in first, so the checkpoint holds them all.
        _ = solids.workTotals()
        let folder = dir.appending(path: String(format: "step-%07d", solver.stepCount))
        let saved = try solver.saveCheckpoint(to: folder, scene: scenario)
        var snapshot = state
        snapshot.stepCount = solver.stepCount
        snapshot.time = solver.time
        snapshot.wallSeconds = wall()
        snapshot.gpuSeconds = gpu()
        try JSONEncoder().encode(snapshot).write(to: folder.appending(path: "whole-event.json"))
        print(
            String(
                format: "Saved a checkpoint at step %d, %.4f s (%.0f MB stored, %.1f s)", saved.stepCount,
                saved.time,
                Double(saved.storedBytes) / 1e6, saved.seconds))
        fflush(stdout)
    }

    var traceOut: FileHandle? = nil
    var elementTraceOut: FileHandle? = nil
    if let ijk = option("trace-node")?.split(separator: ",").compactMap({ Int($0) }), ijk.count == 3 {
        try solids.traceNode(ijk[0], ijk[1], ijk[2])
        // `--trace-element i,j,k`: and that element's forces, to element-trace.csv.
        if let e = option("trace-element")?.split(separator: ",").compactMap({ Int($0) }), e.count == 3 {
            try solids.traceElement(e[0], e[1], e[2])
            try "".write(to: dir.appending(path: "element-trace.csv"), atomically: true, encoding: .utf8)
            elementTraceOut = try FileHandle(forWritingTo: dir.appending(path: "element-trace.csv"))
        }
        let path = dir.appending(path: "trace.csv")
        try
            ("t,step,substep,mass,v_before,elements,contact,anchors,pairs,air,v_after,displacement,intact,held,"
            + (0..<8).map { "element\($0)" }.joined(separator: ",") + "\n").write(
                to: path, atomically: true, encoding: .utf8)
        traceOut = try FileHandle(forWritingTo: path)
        traceOut?.seekToEndOfFile()
    }
    if flag("split-work") {
        try solids.traceExternalWork()
        let path = dir.appending(path: "work-split.csv")
        // A run carried on adds its piece's rows, each piece's split counted from zero at its first
        // row (its sources' work since it began); a fresh run starts the file.
        if !(state.stepCount > 0 && FileManager.default.fileExists(atPath: path.path)) {
            try
                ("t,residual_change,elements_less_trace,air_on_faces,air,contact,links,anchors,pairs,ground,step,particle_contact,"
                + "particle_air,sum,left,particle_pairs_over,deepest_particle_m,node_pairs_over,"
                + "deepest_node_m,own_corner_pairs_over,deepest_own_corner_m,contact_with_particles,capped_substeps\n")
                .write(to: path, atomically: true, encoding: .utf8)
        }
        splitOut = try FileHandle(forWritingTo: path)
        splitOut?.seekToEndOfFile()
        sample()
    } else if state.stepCount == 0 {
        sample()
    }
    var stopped = "reached the end"
    while solver.time < end - 1e-9 {
        let interval = BlastSolver.checkpointInterval
        // `--step-by n`: batches of n air steps, to see inside a 64-step batch (no checkpoints then).
        let stepBy = option("step-by").flatMap { Int($0) }
        if traceOut != nil { solids.clearNodeTrace() }
        let result = autoreleasepool {
            solver.advance(steps: stepBy ?? (interval - solver.stepCount % interval))
        }
        // `--trace-node i,j,k`: each substep's record of that node's forces by source, to trace.csv.
        if let traceOut {
            for r in solids.nodeTrace(substeps: 2048) {
                let around = r.around.map {
                    String(format: "%.4g;%.4g;%.4g;%d", $0.force.x, $0.force.y, $0.force.z, $0.flag)
                }
                let row =
                    [
                        String(format: "%.7f", solver.time), String(solver.stepCount), String(r.substep),
                        String(format: "%.4g", r.mass),
                    ]
                    + [
                        r.velocityBefore, r.elements, r.contact, r.anchors, r.pairs, r.air, r.velocityAfter,
                        r.displacement,
                    ]
                    .map { String(format: "%.5g;%.5g;%.5g", $0.x, $0.y, $0.z) } + [
                        String(r.intact), String(r.held),
                    ] + around
                traceOut.write((row.joined(separator: ",") + "\n").data(using: .utf8)!)
            }
            for (s, r) in solids.elementTrace(substeps: 2048).enumerated() {
                let row =
                    [String(format: "%.7f", solver.time), String(solver.stepCount), String(s)]
                    + r.map { String(format: "%.5g;%.5g;%.5g;%.5g", $0.x, $0.y, $0.z, $0.w) }
                elementTraceOut?.write((row.joined(separator: ",") + "\n").data(using: .utf8)!)
            }
        }
        if result.steps > 0 { lastAirStep = result.lastTimeStep }
        if solver.time >= state.nextSample - 1e-9 || !result.isStable || result.steps == 0 {
            sample()
            while state.nextSample <= solver.time + 1e-9 { state.nextSample += every }
        }
        for time in frames where solver.time >= time - 1e-9 && !state.framesDone.contains(time) {
            frame(time)
            state.framesDone.append(time)
        }
        if !result.isStable || result.steps == 0 {
            stopped = "stopped unstable at \(solver.time) s"
            inspectFastest(solids, time: solver.time)
            break
        }
        if option("step-by") == nil, solver.time >= state.nextCheckpoint - 1e-9 {
            while state.nextCheckpoint <= solver.time + 1e-9 { state.nextCheckpoint += checkpointEvery }
            try save()
        } else if wall() - state.wallSeconds >= budget {
            // The split's work to the checkpoint, from which the next piece's split starts again.
            if splitOut != nil { sample(phases: false) }
            try save()
            stopped = "stopped for the budget; carry on with --continue"
            break
        }
    }
    let last = dir.appending(path: String(format: "step-%07d", solver.stepCount))
    if option("step-by") == nil, solver.time >= end - 1e-9, !fm.fileExists(atPath: last.path) { try save() }
    out.closeFile()
    print(
        String(
            format: "%@ at %.3f s: wall %.0f s, GPU %.0f s this run %.0f s; largest displacement %.1f m",
            stopped,
            solver.time, wall(), gpu(), wall() - state.wallSeconds, largest))
}

/// `--inspect <checkpoint>`: the fastest nodes of the body as saved, with their mass and the
/// elements round them, to tell a light node flung loose from a piece in motion.
private func inspectFastest(_ s: StructureSolver, time: Double, count: Int = 15) {
    var nodes: [(speed: Float, mass: Float, i: Int, j: Int, k: Int, flags: UInt32)] = []
    for k in 0...s.ez {
        for j in 0...s.ey {
            for i in 0...s.ex where s.storedNode(i, j, k) != nil {
                let node = s.node(i, j, k)
                guard node.mass > 0 else { continue }
                nodes.append((simd_length(node.velocity), node.mass, i, j, k, node.flags))
            }
        }
    }
    nodes.sort { $0.speed > $1.speed }
    let over = [20, 50, 100].map { v in nodes.filter { $0.speed > Float(v) }.count }
    print(
        String(
            format: "At %.4f s: %d nodes with mass; faster than 20 / 50 / 100 m/s: %d / %d / %d", time,
            nodes.count,
            over[0], over[1], over[2]))
    for entry in nodes.prefix(count) {
        var around: [String] = []
        for a in 0..<8 {
            let (i, j, k) = (entry.i - (a & 1), entry.j - ((a >> 1) & 1), entry.k - ((a >> 2) & 1))
            guard i >= 0, j >= 0, k >= 0, i < s.ex, j < s.ey, k < s.ez else { continue }
            let flag = s.flag(i, j, k)
            if flag != .empty { around.append("\(flag)") }
        }
        let p = s.position(entry.i, entry.j, entry.k)
        print(
            String(
                format:
                    "  %.1f m/s, %.3g kg, lattice (%d, %d, %d) at (%.2f, %.2f, %.2f), flags %d; elements: %@",
                entry.speed, entry.mass, entry.i, entry.j, entry.k, p.x, p.y, p.z, entry.flags,
                around.joined(separator: " ")))
    }
}

/// `--breakdown <checkpoint>`: where the elements' work since the settle went, from a saved
/// state's per-element sums (the work trace's): by part (each material, floor or wall by the axis
/// its solid is thinnest along, and how many elements through) and by each element's state as
/// saved (uncracked, cracked, crushed, bare bars, gone), the hourglass control's work, below its
/// cap and at it, against the rest. An element's state is its last, so a gone element's work
/// includes what it did while whole.
private func breakdownWork(_ s: StructureSolver, time: Double) {
    typealias Channel = StructureSolver.WorkChannel
    let channels = Channel.allCases.count
    let sums = s.workByElement()
    let count = s.elementCount
    let instances = s.instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(count, 1))
    let flags = s.flagBuffer.contents().bindMemory(to: UInt8.self, capacity: s.ex * s.ey * s.ez)
    let materialIndex = s.materialIndexBuffer.contents().bindMemory(to: UInt8.self, capacity: max(count, 1))
    let states = s.stateBuffer.contents()
    let stride = 196
    var occupied = [Bool](repeating: false, count: s.ex * s.ey * s.ez)
    for n in 0..<count { occupied[Int(instances[n])] = true }
    func filled(_ at: SIMD3<Int>) -> Bool {
        at.x >= 0 && at.y >= 0 && at.z >= 0 && at.x < s.ex && at.y < s.ey && at.z < s.ez
            && occupied[at.x + s.ex * (at.y + s.ey * at.z)]
    }
    let classes = ["uncracked", "cracked", "crushed", "bare", "gone"]
    struct Tally {
        var elements = 0
        var hourglass = 0.0
        var capped = 0.0
        var all = 0.0
        var bars = 0.0
        var fracture = 0.0
    }
    let fractureChannels: [Channel] = [
        .tensionCracked, .tensionHairline, .crackShear, .crackShearPressed, .interlock, .interlockPressed,
        .dowel, .kink, .compressionCrushed,
    ]
    var parts: [String] = []
    var table: [String: [Tally]] = [:]
    var total = Tally()
    for n in 0..<count {
        let index = Int(instances[n])
        let (i, j, k) = s.elementCoordinates(index)
        // The solid's thickness along each axis, up to five elements either way.
        var runs = SIMD3<Int>(1, 1, 1)
        for axis in 0..<3 {
            for direction in [-1, 1] {
                var at = SIMD3(i, j, k)
                for _ in 1...5 {
                    at[axis] += direction
                    guard filled(at) else { break }
                    runs[axis] += 1
                }
            }
        }
        let material = s.materials[Int(materialIndex[n] & 15)]
        let thin = runs.min()
        let axis = runs.x == thin ? 0 : (runs.y == thin ? 1 : 2)
        let part = "\(material.name), \(axis == 2 ? "floor" : "wall") \(thin) through"
        let base = states.advanced(by: n * stride)
        let crack = (0..<3).map { base.load(fromByteOffset: 80 + 4 * $0, as: Float.self) }.max() ?? 0
        let crush = (0..<3).map { base.load(fromByteOffset: 124 + 4 * $0, as: Float.self) }.max() ?? 0
        let onset = material.youngsModulus > 0 ? material.tensileStrength / material.youngsModulus : 1
        let kind: Int
        switch flags[index] {
        case 2, 3: kind = 4
        case 4, 5, 6: kind = 3
        default: kind = crush > 0.0035 ? 2 : (crack > 1.5 * onset ? 1 : 0)
        }
        if table[part] == nil {
            table[part] = [Tally](repeating: Tally(), count: classes.count)
            parts.append(part)
        }
        let w = Array(sums[(n * channels)..<((n + 1) * channels)])
        var t = table[part]![kind]
        t.elements += 1
        t.hourglass += w[Channel.hourglass.rawValue]
        t.capped += w[Channel.hourglassCapped.rawValue]
        t.bars += w[Channel.bars.rawValue] + w[Channel.bond.rawValue]
        t.all += w.reduce(0, +)
        t.fracture += fractureChannels.reduce(0) { $0 + w[$1.rawValue] }
        table[part]![kind] = t
        total.elements += 1
        total.hourglass += w[Channel.hourglass.rawValue]
        total.capped += w[Channel.hourglassCapped.rawValue]
        total.all += w.reduce(0, +)
    }
    // The hourglass forces each element holds now, as the capacity (MPa) a cap at that force
    // would be (|q| / (h² / 8)), by part and state for elements whose work was mostly hourglass
    // control: their quartiles, and how often each mode is the largest.
    var held: [String: [Float]] = [:]
    var largestMode: [String: [Int]] = [:]
    var bendingShare: [String: [Double]] = [:]
    let h = s.model.elementSize
    for n in 0..<count {
        let index = Int(instances[n])
        guard flags[index] == 1 || flags[index] == 4 else { continue }
        let w = sums[(n * channels)..<((n + 1) * channels)]
        let hourglass =
            w[w.startIndex + Channel.hourglass.rawValue] + w[w.startIndex + Channel.hourglassCapped.rawValue]
        guard hourglass > 1 else { continue }
        // A switched element (`--assumed-strain`) has no hourglass control; a traced run keeps its
        // modes' forces in the slot (the work trace's record), which are not hourglass forces.
        let (i, j, k) = s.elementCoordinates(index)
        guard !s.isSwitched(i, j, k) else { continue }
        let base = states.advanced(by: n * stride)
        var best: Float = 0
        var mode = 0
        var bendingSquared: Float = 0
        var allSquared: Float = 0
        for m in 0..<4 {
            let q = SIMD3<Float>(
                base.load(fromByteOffset: 32 + 12 * m, as: Float.self),
                base.load(fromByteOffset: 36 + 12 * m, as: Float.self),
                base.load(fromByteOffset: 40 + 12 * m, as: Float.self))
            let size = (q * q).sum().squareRoot()
            if size > best {
                best = size
                mode = m
            }
            // A mode's components along the axes its signs vary with stretch fibres across the
            // element (its own bending); the others (and the fourth mode's) warp it.
            let bends: SIMD3<Float> =
                m == 0 ? [0, 1, 1] : m == 1 ? [1, 0, 1] : m == 2 ? [1, 1, 0] : [0, 0, 0]
            bendingSquared += (q * q * bends).sum()
            allSquared += (q * q).sum()
        }
        let key = "\(s.materials[Int(materialIndex[n] & 15)].name), \(flags[index] == 4 ? "bare" : "whole")"
        bendingShare[key, default: [0, 0]][0] += Double(bendingSquared)
        bendingShare[key, default: [0, 0]][1] += Double(allSquared)
        held[key, default: []].append(best / (0.125 * h * h) / 1e6)
        largestMode[key, default: [0, 0, 0, 0]][mode] += 1
    }
    for key in held.keys.sorted() {
        let values = held[key]!.sorted()
        let q = { (p: Double) in values[min(values.count - 1, Int(p * Double(values.count)))] }
        print(
            String(
                format:
                    "held now, %@ (%d elements with > 1 J of hourglass work): |q| as a cap %.3f / %.3f / %.3f MPa (quartiles), modes largest %@",
                key, values.count, q(0.25), q(0.5), q(0.75),
                largestMode[key]!.map(String.init).joined(separator: "/")))
        let share = bendingShare[key]!
        print(
            String(
                format: "  of |q|², in components that bend the element: %.0f%%",
                100 * share[0] / max(share[1], 1e-30)))
    }
    let allHourglass = total.hourglass + total.capped
    print(
        String(
            format:
                "At %.4f s: %d elements, their work %.3f MJ, of which hourglass %.3f MJ (%.0f%%; %.3f at its cap)",
            time, total.elements, total.all / 1e6, allHourglass / 1e6,
            100 * allHourglass / max(total.all, 1e-9),
            total.capped / 1e6))
    print(
        "part | state | elements | work MJ | hourglass MJ (at cap) | its share | fracture+crushing MJ | bars MJ | of all hourglass"
    )
    for part in parts {
        for (kind, t) in table[part]!.enumerated() where t.elements > 0 {
            let hourglass = t.hourglass + t.capped
            print(
                String(
                    format: "%@ | %@ | %d | %.3f | %.3f (%.3f) | %.0f%% | %.3f | %.3f | %.1f%%", part,
                    classes[kind], t.elements, t.all / 1e6, hourglass / 1e6, t.capped / 1e6,
                    100 * hourglass / max(abs(t.all), 1e-9), t.fracture / 1e6, t.bars / 1e6,
                    100 * hourglass / max(allHourglass, 1e-9)))
        }
    }
}
