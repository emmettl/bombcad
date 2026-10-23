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
//                         [--awake] [--no-rubble] [--dir /Volumes/StudioData/bombcad/whole-event/<name>]
//                         [--continue]
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
// `--awake` keeps the air awake (no sleep), as a dust cloud would need; by default the air sleeps
// as the recommended settings have it. Diagnostics: `--inspect <checkpoint>` lists the fastest
// nodes of a saved state with the elements round them; `--watch 20` does so at each sample with a
// node faster than 20 m/s (and a run that goes unstable does as it stops);
// `--erode-crushed-bare` and `--release-bare-hourglass` turn on those two options.

private struct WholeEventState: Codable {
    var stepCount: Int
    var time: Double
    var wallSeconds: Double
    var gpuSeconds: Double
    var baselineRise: Double
    var nextSample: Double
    var nextCheckpoint: Double
    var framesDone: [Double]
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
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let end = option("time").flatMap { Double($0) } ?? 10
    let every = option("every").flatMap { Double($0) } ?? 0.05
    let budget = (option("budget").flatMap { Double($0) } ?? 80) * 60
    let checkpointEvery = option("checkpoint-every").flatMap { Double($0) } ?? 1
    let frames = (option("frames") ?? "1,2,4,6,8,10").split(separator: ",").compactMap { Double($0) }.sorted()
    let awake = flag("awake")
    let name =
        "street-\(storeys)s-\(Int(scenario.charge.mass))kg-\(rubble ? "rubble" : "norubble")\(awake ? "-awake" : "")"
    let dir = URL(filePath: option("dir") ?? "/Volumes/StudioData/bombcad/whole-event/\(name)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var configuration = SolverConfiguration.recommended
    if awake {
        configuration.airSleepThreshold = 0
        configuration.airSleepCrossings = 0
    }
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    guard let body = solver.bodies.first, let solids = body.solids else {
        print("No solid structure")
        exit(2)
    }
    solids.contactMode = .always
    if let inspect = option("inspect") {
        solids.tracesWork = true
        let header = try solver.restoreCheckpoint(from: URL(filePath: inspect), scene: scenario)
        inspectFastest(solids, time: header.time)
        return
    }

    // Where to start: the latest checkpoint in the folder with `--continue`, else afresh.
    let fm = FileManager.default
    var state: WholeEventState
    let csv = dir.appending(path: "phases.csv")
    if flag("continue"),
        let latest = try fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasPrefix("step-") }).sorted()
            .last(
                where: { fm.fileExists(atPath: dir.appending(path: "\($0)/whole-event.json").path) })
    {
        let folder = dir.appending(path: latest)
        solids.tracesWork = true
        let header = try solver.restoreCheckpoint(from: folder, scene: scenario)
        state = try JSONDecoder().decode(
            WholeEventState.self, from: Data(contentsOf: folder.appending(path: "whole-event.json")))
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
            nextSample: 0, nextCheckpoint: checkpointEvery, framesDone: [])
        try? fm.removeItem(at: csv)
    }
    print(
        String(
            format:
                "%@: %d elements, %d nodes, %.2f m air cells (%d), rubble %@, air %@; structure step %.2f µs; to %.1f s in pieces of %.0f min",
            scenario.name, solids.elementCount, solids.nodeCount, cellSize,
            solver.grid.nx * solver.grid.ny * solver.grid.nz,
            rubble ? "on" : "off", awake ? "kept awake" : "sleeping as recommended",
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

    func sample() {
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
    if state.stepCount == 0 { sample() }
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
