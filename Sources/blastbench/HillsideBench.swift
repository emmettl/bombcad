import BlastCore
import Foundation
import Metal
import simd

/// `blastbench hillside [--mass 500] [--dx 0.25] [--duration 0.1] [--every 0.01]`: the two-storey
/// frame on a hillside ("Two-storey frame on a hillside"), each column on a pad footing set in the
/// slope. Settles it, then runs the blast, reporting each footing: the ground's slope round it,
/// the factor that puts on its bearing capacity, how much of that capacity it uses, and how far it
/// has slid, settled and turned.
func runHillside(device: MTLDevice) throws {
    let cell = option("dx").flatMap(Float.init) ?? 0.25
    let duration = option("duration").flatMap(Double.init) ?? 0.1
    var scenario = ScenarioPreset.hillsideFrame.scenario
    if let mass = option("mass").flatMap(Float.init) { scenario.charge.mass = mass }
    if flag("dry"), var structure = scenario.structure {
        // `--elastic`: the footings' sand elastic; `--massless`: no radiation damping; `--clamped`:
        // the columns clamped at their bases, no footings.
        for index in structure.supports.indices {
            guard var law = structure.anchorage(ofSupport: index), var footing = law.footing else { continue }
            if flag("elastic") { footing.soil.cyclic = nil }
            if flag("massless") { footing.soil.radiationDamping = false }
            law.footing = flag("no-footing") ? nil : footing
            // `--joint-scale 0.1`: the joints' stiffness, E/h and G/h by default, scaled.
            if let scale = option("joint-scale").flatMap(Float.init) {
                let e = structure.material.youngsModulus / structure.elementSize
                law.normalStiffness = e * scale
                law.shearStiffness = e / (2 * (1 + structure.material.poissonRatio)) * scale
            }
            structure.setAnchorage(flag("clamped") ? nil : law, ofSupport: index)
        }
        // The frame alone under its weight, damped, without the air: how it stands on its footings.
        let solver = try StructureSolver(
            device: device, model: structure.standing(on: flag("level") ? nil : scenario.terrain))
        // As the scene's settling does (`BlastSolver.settleStructures`): damped at 50/s, still once
        // its mean speed is 1% of the largest on the way.
        solver.damping = 50
        // `--step-scale 0.5`: the body's step that much smaller than its stable one.
        if let scale = option("step-scale").flatMap(Float.init) {
            solver.stepOverride = solver.criticalTimeStep * scale
        }
        let steps = Int((0.5 / Double(solver.criticalTimeStep)).rounded())
        var peak = 0.0
        for n in 1...5 {
            for _ in 0..<10 {
                solver.advance(steps: steps / 50)
                var energy = 0.0
                var mass = 0.0
                solver.mutateNodes { nodes in
                    for node in nodes where node.mass > 0 {
                        energy += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                        mass += Double(node.mass)
                    }
                }
                let speed = (2 * energy / mass).squareRoot()
                peak = max(peak, speed)
                print(
                    "    speed \(String(format: "%.2e", speed)) m/s, \(String(format: "%.4f", speed / peak)) of the peak"
                )
            }
            // Where the fastest nodes are.
            var fastest: [(speed: Float, at: SIMD3<Float>)] = []
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        let node = solver.node(i, j, k)
                        guard node.mass > 0 else { continue }
                        fastest.append((simd_length(node.velocity), solver.referencePosition(i, j, k)))
                    }
                }
            }
            for entry in fastest.sorted(by: { $0.speed > $1.speed }).prefix(5) {
                print("    node at \(entry.at): \(String(format: "%.2e", entry.speed)) m/s")
            }
            let summary = solver.summary()
            print(
                "\(Double(n) * 0.1) s: largest displacement \(String(format: "%.2f", summary.maxDisplacement * 1000)) mm"
            )
            for footing in solver.footingSummaries() {
                print(
                    "  footing at x \(String(format: "%.1f", footing.baseCentre.x)): bearing "
                        + "\(String(format: "%.0f", footing.soilForce.z / 1e3)) kN of "
                        + "\(String(format: "%.0f", footing.capacity / 1e3)), joint \(footing.jointForce / 1e3) kN, "
                        + "settled \(String(format: "%.2f", -footing.displacement.z * 1000)) mm, slid "
                        + "\(String(format: "%.2f", footing.displacement.x * 1000)) mm")
            }
        }
        return
    }
    // `--no-structure`: the air over the slope alone; `--staircase`: the terrain as whole cells.
    if flag("no-structure") { scenario.structure = nil }
    var configuration = SolverConfiguration.recommended
    // `--refine 2 [--refine-levels 2]`, `--staircase` and the rest of the refinement's options.
    configureRefinement(&configuration)
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cell, configuration: configuration)
    var peak: [Float] = []
    func report(_ label: String) {
        guard let body = solver.bodies.first, let solids = body.solids else {
            print("\(label): no structure")
            return
        }
        let summary = solids.summary()
        print(
            "\(label): \(summary.erodedElements) elements removed, damage up to "
                + "\(String(format: "%.2f", summary.maxDamage)), largest displacement "
                + "\(String(format: "%.0f", summary.maxDisplacement * 1000)) mm")
        let footings = solids.footingSummaries()
        if peak.count != footings.count { peak = [Float](repeating: 0, count: footings.count) }
        for (n, footing) in footings.enumerated() {
            let used = footing.soilForce.z / footing.capacity
            peak[n] = max(peak[n], used)
            let slope = atan(simd_length(footing.groundSlope)) * 180 / .pi
            print(
                "  footing at x \(String(format: "%.1f", footing.baseCentre.x)), y "
                    + "\(String(format: "%.1f", footing.baseCentre.y)), base z "
                    + "\(String(format: "%.2f", footing.baseCentre.z)): slope \(String(format: "%.1f", slope))°, "
                    + "capacity × \(String(format: "%.2f", footing.bearingFactor)) = "
                    + "\(String(format: "%.0f", footing.capacity / 1e3)) kN; bearing "
                    + "\(String(format: "%.0f", footing.soilForce.z / 1e3)) kN (\(String(format: "%.0f%%", used * 100)), "
                    + "peak \(String(format: "%.0f%%", peak[n] * 100))); slid "
                    + "\(String(format: "%.1f %.1f", footing.displacement.x * 1000, footing.displacement.y * 1000)) mm, "
                    + "moved up \(String(format: "%.1f", footing.displacement.z * 1000)) mm, lifted "
                    + "\(String(format: "%.1f", footing.uplift * 1000)) mm, joint up "
                    + "\(String(format: "%.0f", -footing.jointForce.z / 1e3)) kN, "
                    + "settled \(String(format: "%.1f", footing.settlement * 1000)) mm, turned "
                    + "\(String(format: "%.2f", simd_length(footing.rotation) * 1000)) mrad; sides "
                    + "\(String(format: "%.0f %.0f", footing.sideForce.x / 1e3, footing.sideForce.y / 1e3)) kN, "
                    + "given way \(String(format: "%.1f", footing.sideGiveWay * 1000)) mm")
        }
    }
    let size = scenario.domainSize
    print(
        "\(scenario.charge.mass) kg TNT on the slope 7 m in front; air \(cell) m; domain "
            + "\(Int(size.x)) x \(Int(size.y)) x \(Int(size.z)) m"
            + (scenario.tightFacesNote.map { "; " + $0 } ?? ""))
    solver.settleStructures()
    for settlement in solver.settlements {
        print(
            "\(settlement.settled ? "Settled" : "Did not settle") in \(String(format: "%.2f", settlement.time)) s"
        )
    }
    report("At rest")
    print(
        "Terrain " + (configuration.cutsTerrain(of: scenario, cellSize: cell) ? "cut" : "as a staircase")
            + (configuration.refinement > 1
                ? ", air refined by \(configuration.refinement), \(configuration.refinementLevels) level(s)"
                : ""))
    let settled = solver.totals()
    peak = []
    let every = option("every").flatMap(Double.init) ?? duration
    var time = 0.0
    while time < duration - 1e-9 {
        time = min(time + every, duration)
        let result = solver.advance(until: time)
        report("After \(String(format: "%.1f", time * 1000)) ms\(result.isStable ? "" : " (unstable)")")
        guard result.isStable else { break }
    }
    // The air's mass and energy since it settled (the faces are open: the blast's own outflow
    // shows too), and each gauge's peak overpressure.
    let now = solver.totals()
    print(String(format: "The air's step buffers' GPU time %.2f s", solver.stepGPUSeconds))
    print(
        String(
            format: "Air since settling: mass %+.3e, energy %+.3e (relative)",
            (now.mass - settled.mass) / settled.mass,
            (now.energy - settled.energy) / settled.energy))
    for (gauge, samples) in zip(scenario.gauges, solver.gaugeHistories) {
        let first = samples.first?.pressure ?? 0
        let high = (samples.map(\.pressure).max() ?? first) - first
        print(String(format: "  %@: peak %.1f kPa", gauge.name as NSString, high / 1000))
    }
}
