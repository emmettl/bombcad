import BlastCore
import BlastRender
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// The large-panel block of flats (see LargePanelBlock.swift):
//
//   blastbench panelblock --case gravity [--time 0.5]
//       the block alone under its own weight, damped at 50/s as the IFC corpus's check is, and
//       judged the same way: stands, stands and deflects, or falls
//   blastbench panelblock --case gas|street [--vent 25 (kPa)] [--storeys 12] [--dx 0.25] [--frames 0.1,0.5,1,2,4] [--out dir]
//                         [--mass 250] [--azimuth 0.6] [--elevation 0.3] [--distance 60]
//       the preset coupled to the air, a snapshot at each frame's time
//
// Writes PNGs into --out (default /Volumes/StudioData/bombcad/panel-block).

func runPanelBlock(device: MTLDevice) throws {
    let event = option("case") ?? "gravity"
    if event == "gravity" {
        try panelBlockGravity(device: device)
        return
    }
    guard let which = LargePanelBlock.Event(rawValue: event) else {
        print("Unknown case \(event): gravity, gas or street")
        exit(2)
    }
    let preset: ScenarioPreset = which == .gas ? .largePanelGas : .largePanelStreet
    // `--storeys 3`: a lower block, for trying things quickly.
    // `--vent 3`: the gas flat's windows going at 3 kPa rather than 25.
    var scenario =
        option("storeys") == nil && option("vent") == nil
        ? preset.scenario
        : LargePanelBlock.scenario(
            which, name: preset.title,
            storeys: option("storeys").flatMap { Int($0) } ?? LargePanelBlock.storeys,
            windowRelease: option("vent").flatMap { Float($0) }.map { $0 * 1000 }
                ?? LargePanelBlock.windowRelease)
    if flag("standing") {
        // What the app shows for the preset: each result's standing, and what is not compared.
        var inputs = StandingInputs(scenario: scenario, cellSize: option("dx").flatMap { Float($0) } ?? 0.125)
        inputs.configuration.openFaces = SolverConfiguration.recommended.openFaces
        let standing = SceneStanding(inputs)
        for result in standing.results {
            print("\(result.kind.title): \(result.level.title). \(result.summary)")
            for option in result.options { print("  option: \(option)") }
        }
        for line in standing.unsupported { print("Not compared: \(line)") }
        return
    }
    if let mass = option("mass").flatMap({ Float($0) }) { scenario.charge.mass = mass }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let frames = (option("frames") ?? "0.1,0.5,1,2,4").split(separator: ",").compactMap { Double($0) }
        .sorted()
    let out = URL(filePath: option("out") ?? "/Volumes/StudioData/bombcad/panel-block")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    // The recommended air (afterburning and hot air do not enter a deflagration).
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cellSize, configuration: .recommended)
    // Pieces that come off their seats fall on what is below them.
    // Diagnostics: `--contact after|off` (always by default), `--no-ground`.
    let contact: ContactMode =
        switch option("contact") {
        case "after": .afterFailure
        case "off": .off
        default: flag("default-contact") ? .afterFailure : .always
        }
    for body in solver.bodies {
        body.solids?.contactMode = contact
        if flag("no-ground") { body.solids?.groundContact = false }
    }
    let model = scenario.structure
    if flag("mask") {
        // Where the corner flat leaks: flood the air's open cells from the cooker through a box
        // two cells round the flat, and list the open cells reached outside it.
        solver.advance(steps: 4)
        let c = solver.grid.cellSize
        let o = SIMD3<Float>(4, 4, 0)
        let z0 = LargePanelBlock.base(ofStorey: LargePanelBlock.gasStorey)
        let inside = Box(
            min: o + SIMD3(0, 0, z0 - LargePanelBlock.h),
            max: o
                + SIMD3(LargePanelBlock.wallLines[1].high, LargePanelBlock.depth, z0 + 27 * LargePanelBlock.h)
        )
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int> { SIMD3<Int>((p / c).rounded(.down)) }
        let low = cell(inside.min) &- 2
        let high = cell(inside.max) &+ 2
        let start = cell(scenario.charge.position)
        var seen: Set<SIMD3<Int>> = [start]
        var stack = [start]
        var leaks: [SIMD3<Int>] = []
        while let n = stack.popLast() {
            for d in [
                SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1),
                SIMD3(0, 0, -1),
            ] {
                let m = n &+ d
                guard all(m .>= low), all(m .<= high), !seen.contains(m), !solver.isSolid(m.x, m.y, m.z)
                else { continue }
                seen.insert(m)
                let centre = (SIMD3<Float>(m) + 0.5) * c
                if all(centre .> inside.min) && all(centre .< inside.max) {
                    stack.append(m)
                } else {
                    leaks.append(m)
                }
            }
        }
        print("open cells reached from the cooker: \(seen.count); outside the flat: \(leaks.count)")
        for m in leaks.prefix(40) {
            let p = (SIMD3<Float>(m) + 0.5) * c - o
            print(
                String(
                    format: "  leak at x %.3f y %.3f z %.3f (block coordinates; storey base %.3f)", p.x, p.y,
                    p.z, z0))
        }
        return
    }
    print(
        String(
            format: "%@: %d elements, %d joints, %.2f m air cells, %d frames to %.1f s",
            scenario.name, solver.bodies.first?.solids?.elementCount ?? 0, model?.supports.count ?? 0,
            cellSize,
            frames.count, frames.last ?? 0))
    let renderer = try SceneRenderer(device: device)
    renderer.settings.showWave = !flag("no-wave")
    let gaugeCells = scenario.gauges.map { gauge in
        (gauge.name, SIMD3<Int>((gauge.position / solver.grid.cellSize).rounded(.down)))
    }
    let started = ContinuousClock.now
    var sleptAt: Double?
    var largest: Float = 0
    for time in frames {
        while solver.time < time - 1e-9 {
            let result = solver.advance(steps: 64, timeLimit: time)
            if solver.airIsAsleep, sleptAt == nil { sleptAt = solver.time }
            if let summary = solver.bodySummary() { largest = max(largest, summary.maxDisplacement) }
            if result.steps == 0 || !result.isStable { break }
        }
        let wall = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
        solver.refreshVisualization()
        renderer.setScene(scenario, solver: solver)
        let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
        renderer.setVentPanels(zip(panels, solver.ventPanelOpenTimes).compactMap { $1 == nil ? $0.box : nil })
        // The block whole, from the side of the event: the corner flat's flank (west) for the gas,
        // the far flank (east) for the street charge.
        let bounds = scenario.structure?.bounds ?? Box(min: .zero, max: scenario.domainSize)
        let centre = (bounds.min + bounds.max) / 2
        var camera = OrbitCamera(
            target: SIMD3(centre.x, centre.y, 0.45 * bounds.max.z), distance: 2.1 * bounds.max.z,
            azimuth: which == .gas ? -2.35 : -0.75, elevation: 0.22)
        // `--target-z 25 --distance 25`: closer in, on the gas flat's floor.
        if let z = option("target-z").flatMap({ Float($0) }) { camera.target.z = z }
        if let distance = option("distance").flatMap({ Float($0) }) { camera.distance = distance }
        if let azimuth = option("azimuth").flatMap({ Float($0) }) { camera.azimuth = azimuth }
        if let elevation = option("elevation").flatMap({ Float($0) }) { camera.elevation = elevation }
        let path = out.appending(path: String(format: "%@-%04.0fms.png", event, time * 1000))
        if let frame = renderer.snapshot(
            commandQueue: solver.commandQueue, width: 1600, height: 1000, camera: camera),
            let destination = CGImageDestinationCreateWithURL(
                path as CFURL, UTType.png.identifier as CFString, 1, nil)
        {
            CGImageDestinationAddImage(destination, frame.image, nil)
            CGImageDestinationFinalize(destination)
        }
        var line = String(format: "t = %.3f s (wall %.0f s)", solver.time, wall)
        if let summary = solver.bodySummary() {
            line += String(
                format: ": %d elements intact, %d failed, deflection %.0f mm (largest %.0f mm)",
                summary.activeElements,
                summary.erodedElements, summary.maxDisplacement * 1000, largest * 1000)
            if summary.hasBlownUp { line += " BLOWN UP" }
        }
        if let pairs = solver.bodies.first?.solids?.pairSummary() {
            line += String(
                format: "; joints: %d pairs, %d separated, %d off their seats, slip %.0f mm, opening %.0f mm",
                pairs.pairs, pairs.separated, pairs.unseated, pairs.maxSlip * 1000, pairs.maxOpening * 1000)
        }
        let peaks = gaugeCells.map { name, cell in
            String(format: "%@ %.1f kPa", name, solver.peakOverpressure(cell.x, cell.y, cell.z) / 1000)
        }
        print(line + "\n    peaks: " + peaks.joined(separator: "; "))
        if let gas = solver.deflagrationState() {
            print(
                String(
                    format: "    gas: %.0f%% burnt (%.1f of %.1f kg unburnt left), %.0f m³ burnt",
                    gas.burntFraction * 100,
                    gas.unburnt, gas.initialUnburnt, gas.burntVolume))
        }
        let opened = solver.ventPanelOpenTimes.map {
            $0.map { String(format: "%.0f ms", $0 * 1000) } ?? "shut"
        }
        if !opened.isEmpty { print("    vent panels: " + opened.joined(separator: ", ")) }
    }
    if let sleptAt { print(String(format: "The air went quiet and was frozen at %.0f ms", sleptAt * 1000)) }
}

/// The block alone under its own weight for `--time` seconds (0.5), damped at 50/s, judged as the
/// IFC corpus's gravity check judges an imported building (Scripts/ifc-corpus.py): it stands
/// where 95% of its weight reaches the ground; else it stands and deflects where the weight that
/// moved is coming to rest (under half the falling speed, g/50, and slowing), and falls where it
/// is not.
func panelBlockGravity(device: MTLDevice) throws {
    let model = LargePanelBlock.model()
    let solver = try StructureSolver(device: device, model: model)
    solver.contactMode = .always
    solver.damping = 50
    let duration = option("time").flatMap { Double($0) } ?? 0.5
    func moving() -> Float {
        var weight: Float = 0
        var momentum: Float = 0
        solver.mutateNodes { nodes in
            for node in nodes where simd_length(node.displacement) >= 0.01 {
                weight += node.mass
                momentum += node.mass * simd_length(node.velocity)
            }
        }
        return weight > 0 ? momentum / weight : 0
    }
    let started = ContinuousClock.now
    let steps = Int(duration / Double(solver.criticalTimeStep))
    solver.advance(steps: steps * 5 / 6)
    let early = moving()
    solver.advance(steps: steps - steps * 5 / 6)
    let late = moving()
    var mass: Float = 0
    var held: Float = 0
    solver.mutateNodes { nodes in
        for node in nodes {
            mass += node.mass
            if simd_length(node.displacement) < 0.01 { held += node.mass }
        }
    }
    var reaction: Float = 0
    for j in 0...solver.ey {
        for i in 0...solver.ex where solver.storedNode(i, j, 0) != nil {
            reaction -= solver.nodalForce(i, j, 0).z
        }
    }
    let carried = reaction / (mass * 9.81)
    let terminal: Float = 9.81 / 50
    let verdict =
        carried >= 0.95
        ? "stands"
        : late < 0.5 * terminal && late <= early
            ? String(format: "stands, deflects (%.2f m/s)", late)
            : String(format: "falls (%.2f m/s, %.0f%% of the weight moving)", late, (1 - held / mass) * 100)
    let summary = solver.summary()
    let wall = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
    print(
        String(
            format:
                "Large-panel block under its own weight, %.2f s damped at 50/s: %d elements of %.1f mm, %d joints, "
                + "%.0f t", duration, solver.elementCount, model.elementSize * 1000, model.supports.count,
            mass / 1000))
    print(
        String(
            format:
                "  weight carried at the ground %.1f%%; moving weight's speed %.3f then %.3f m/s; %.1f%% of the "
                + "weight moved under 10 mm; largest displacement %.1f mm; %d elements failed",
            carried * 100, early, late, held / mass * 100, summary.maxDisplacement * 1000,
            summary.erodedElements))
    if let pairs = solver.pairSummary() {
        print(
            String(
                format: "  joints: %d pairs, %d separated, %d off their seats, slip %.2f mm, opening %.2f mm",
                pairs.pairs, pairs.separated, pairs.unseated, pairs.maxSlip * 1000, pairs.maxOpening * 1000))
    }
    print("  verdict: \(verdict) (\(String(format: "%.0f", wall)) s)")
}
