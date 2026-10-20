import BlastCore
import Foundation
import Metal
import simd

// `blastbench digest`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Short runs of a few scenes, each summed up as a hash of the air's state, peaks and impulses
/// and of the structure's summary: two builds that print the same hashes ran the same to the bit.
func runDigest() throws {
    func fnv(_ hash: inout UInt64, _ value: Float) {
        hash = (hash ^ UInt64(value.bitPattern)) &* 0x100_0000_01b3
    }
    let steps = option("steps").flatMap { Int($0) } ?? 80
    let cases: [(String, ScenarioPreset, Float, Bool, Bool)] = [
        ("open", .openGround, 0.5, false, false), ("street", .streetCanyon, 0.5, false, false),
        ("street, afterburning", .streetCanyon, 0.5, true, false), ("wall", .blastWall, 0.25, false, false),
        ("wall as shells", .blastWall, 0.25, false, true),
    ]
    // `--case open` (or another case's name) runs that case alone.
    for (name, preset, cellSize, afterburning, shells) in cases
    where option("case").map({ $0 == name }) ?? true {
        // `--recommended` starts from the recommended air (afterburning throughout), `--gravity` adds
        // gravity in the air.
        // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
        var configuration =
            flag("recommended") ? SolverConfiguration.recommended.balloonStart : SolverConfiguration()
        configureRefinement(&configuration)
        configuration.afterburning = afterburning || flag("recommended")
        configuration.gravity = chosenGravity()
        // `--mapped`: from the mapped one-dimensional start.
        if flag("mapped") { configuration.mappedCharge = true }
        var scenario = preset.scenario
        if shells { scenario.structure?.elementKind = .shell }
        // `--terrain flat` lays the floor down as a heightfield, which must change nothing; another
        // shape (`hill`, `ridge`, `slope`) lays it on the preset's ground.
        if option("terrain") == "flat" {
            scenario.terrain = .flat(domain: scenario.domainSize, spacing: cellSize)
        } else if let terrain = option("terrain") {
            applyTerrain(terrain, to: &scenario)
        }
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        // `--batch N` takes the steps N at a time, as the app's batches do; with `--record`, a
        // timeline recorder's view field is cut out at the end of each batch that passes its next
        // frame, every `--frame-interval` seconds (0.05 ms by default), and read: which must change
        // nothing.
        var result = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        var frames = 0
        if let batch = option("batch").flatMap({ Int($0) }) {
            let interval = option("frame-interval").flatMap { Double($0) } ?? 5e-5
            var next = interval
            while result.steps < steps {
                if flag("record") { solver.viewFieldCapture = ViewFieldCapture(stride: 2, from: next) }
                let part = solver.advance(steps: min(batch, steps - result.steps))
                result.steps += part.steps
                result.isStable = result.isStable && part.isStable
                result.refinedTiles = part.refinedTiles
                result.finerRefinedTiles = part.finerRefinedTiles
                if part.steps == 0 || !part.isStable { break }
                guard solver.time >= next - 1e-12 else { continue }
                if flag("record") {
                    _ = try solver.viewField(stride: 2)
                    frames += 1
                }
                while next <= solver.time + 1e-12 { next += interval }
            }
        } else {
            result = solver.advance(steps: steps)
        }
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
                + (result.finerRefinedTiles > 0 ? ", \(result.finerRefinedTiles) at the second level" : "")
                // A run that broke (a NaN in the air) hashes whatever the NaN left, which need not
                // be the same twice.
                + (result.isStable ? "" : ", unstable")
                + (solver.refinementPoolGrewLate ? ", a pool grew too late" : "")
                + (frames > 0 ? ", \(frames) frames recorded" : ""))
    }
    // The structure on its own, in solids and in shells: a wall struck hard enough to fail, over
    // more than one 2,000-substep run of `advance`, so that its contact joins in.
    for shells in [false, true] where option("case") == nil {
        let wall = Box(min: .zero, max: SIMD3(0.2, 2, 2))
        var model = StructureModel(solids: [wall], elementSize: 0.1, fixedBase: true)
        model.addMat(to: wall, thicknessAxis: 0, areaPerMetre: 4e-4, depth: 0.04)
        let load = PressureLoad(
            axis: 0, positiveSide: false,
            history: [SIMD2(0, 0), SIMD2(0.0005, 3e6), SIMD2(0.004, 0), SIMD2(10, 0)])
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let summary: StructureSummary
        let substeps = option("substeps").flatMap { Int($0) } ?? 3000
        if shells {
            model.elementKind = .shell
            let solver = try ShellSolver(device: device, model: model)
            solver.appliedLoad = load
            solver.advance(steps: substeps)
            solver.mutateNodes { nodes in
                for node in nodes {
                    for value in [node.ux, node.uy, node.uz, node.vx, node.vy, node.vz] { fnv(&hash, value) }
                }
            }
            summary = solver.summary()
        } else {
            let solver = try StructureSolver(device: device, model: model)
            solver.appliedLoad = load
            solver.advance(steps: substeps)
            solver.mutateNodes { nodes in
                for node in nodes {
                    for value in [node.ux, node.uy, node.uz, node.vx, node.vy, node.vz] { fnv(&hash, value) }
                }
            }
            summary = solver.summary()
        }
        fnv(&hash, summary.maxDisplacement)
        fnv(&hash, summary.maxDamage)
        fnv(&hash, Float(summary.erodedElements))
        print(
            "wall alone\(shells ? " as shells" : ""): \(String(hash, radix: 16)) after \(substeps) substeps, "
                + "\(summary.erodedElements) elements failed")
    }
}
