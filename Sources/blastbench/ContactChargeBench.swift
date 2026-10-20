import BlastCore
import Foundation
import Metal
import simd

// `blastbench contact` and `blastbench rubblecost`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Hupfauf's slabs under contact charges: the debris's velocity off the protective face, the
/// spall crater and the breach, against the thesis's measurements and fits.
func runContact() throws {
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.02
    let refinement = option("refine").flatMap { Int($0) } ?? 2
    let levels = option("levels").flatMap { Int($0) } ?? 2
    let layers = option("layers").flatMap { Int($0) } ?? 12
    let duration = option("time").flatMap { Double($0) } ?? 0.003
    print("Slabs under contact charges (Hupfauf, 2024)")
    print(
        "Air cells \(format(Double(cellSize), 3)) m, refined \(levels > 1 ? "twice " : "")by \(refinement); "
            + "\(layers) elements through each slab; \(format(duration * 1000, 1)) ms\n")
    func cm(_ value: Float) -> String { format(Double(value) * 100, 1) }
    func list(_ values: [Float], scale: Float = 1, digits: Int = 1) -> String {
        values.map { format(Double($0 * scale), digits) }.joined(separator: ", ")
    }
    for test in ContactSlabTest.tests where names?.contains(test.name) ?? true {
        let fastest = fastestNodes()
        let column = axisColumn()
        var reported = false
        let result = try ContactSlabTest.run(
            device: device, test: test, cellSize: cellSize, elementSize: test.thickness / Float(layers),
            refinement: refinement, levels: levels, duration: duration,
            stepDivisor: option("step-divisor").flatMap { Float($0) } ?? 4,
            adjust: { scenario in
                if flag("no-rate") { scenario.structure?.material.rateDependent = false }
                // `--charge 1.64`: a TNT sphere of this mass instead, still touching the slab.
                if let mass = option("charge").flatMap({ Float($0) }),
                    let top = scenario.structure?.bounds.max.z
                {
                    let radius = Float(cbrt(3 * Double(mass) / (4 * Double.pi * 1600)))
                    scenario.charge = Charge(
                        mass: mass,
                        position: SIMD3(scenario.charge.position.x, scenario.charge.position.y, top + radius))
                }
                if var structure = scenario.structure {
                    applyRateOptions(&structure)
                    scenario.structure = structure
                }
            },
            afterburning: burning, airModel: chosenGas(), openFaces: chosenFaces(),
            progress: flag("progress")
                ? { line in
                    print("  " + line)
                    fflush(stdout)
                } : nil,
            inspect: { structure, time in
                lastStructure = structure
                if flag("no-debris-drag") { structure.debrisDrag = false }
                applyFragmentThresholds(structure)
                if flag("rubble-trace") { rubbleTrace(structure, time) }
                if flag("no-contact") { structure.contactMode = .off }
                if flag("report") || flag("census"), time >= duration * 0.995, !reported {
                    reported = true
                    if flag("report") { columnReport(structure, i: structure.ex / 2, j: structure.ey / 2) }
                    if flag("census") { removalCensus(structure, i: structure.ex / 2, j: structure.ey / 2) }
                }
                if flag("fastest") { fastest(structure, time) }
                if flag("column") { column(structure, time) }
                // `--watch 48,48,9 [--watch-from 0.00019 --watch-to 0.000215]`: one element's state
                // each sample: its flag, volume against its reference, stress, bars' plastic
                // strain, hourglass forces and its corners' vertical speeds.
                if let spec = option("watch")?.split(separator: ",").compactMap({ Int($0) }), spec.count == 3,
                    time >= (option("watch-from").flatMap { Double($0) } ?? 0),
                    time <= (option("watch-to").flatMap { Double($0) } ?? 1)
                {
                    let (i, j, k) = (spec[0], spec[1], spec[2])
                    let h = structure.model.elementSize
                    var c = [SIMD3<Float>](repeating: .zero, count: 3)
                    var speeds: [Float] = []
                    for a in 0..<8 {
                        let s = SIMD3<Float>(
                            a & 1 == 0 ? -1 : 1, (a >> 1) & 1 == 0 ? -1 : 1, (a >> 2) & 1 == 0 ? -1 : 1)
                        let p = structure.position(i + (a & 1), j + ((a >> 1) & 1), k + ((a >> 2) & 1))
                        c[0] += p * s.x / 8
                        c[1] += p * s.y / 8
                        c[2] += p * s.z / 8
                        speeds.append(
                            structure.node(i + (a & 1), j + ((a >> 1) & 1), k + ((a >> 2) & 1)).velocity.z)
                    }
                    let volume = 8 * simd_dot(c[0], simd_cross(c[1], c[2])) / (h * h * h)
                    let st = structure.stress(i, j, k)
                    let bars = structure.barPlasticStrain(i, j, k)
                    let q = structure.hourglassForces(i, j, k).map { simd_length($0) }
                    print(
                        String(
                            format:
                                "  W %.2f us %@ V/V0 %.3f szz %.0f sxx %.0f MPa bars-plastic %.3g %.3g %.3g |q| %.0f %.0f %.0f %.0f N  vz %@",
                            time * 1e6, "\(structure.flag(i, j, k))", volume, st[2] / 1e6, st[0] / 1e6,
                            bars.x, bars.y,
                            bars.z, q[0], q[1], q[2], q[3],
                            speeds.map { String(format: "%.0f", $0) }.joined(separator: ",")))
                }
            }, configure: applyChosenMask)
        print(
            "\(test.name): \(format(Double(test.thickness) * 100, 0)) cm, \(format(Double(test.semtex) * 1000, 0)) g SEMTEX 10 "
                + "(\(format(Double(test.tntSphere) * 1000, 0)) g TNT sphere), T_W \(format(Double(test.scaledThickness), 2))"
        )
        print("                               measured           fit       model")
        print(
            "  tip velocity (m/s)           " + pad(list(test.tipVelocity), 19)
                + pad(format(Double(test.fittedTipVelocity), 1), 10)
                + "\(format(Double(result.tipVelocityAtEnd), 1)) (largest \(format(Double(result.tipVelocity), 1)))"
        )
        print(
            "  spall crater diameter (cm)   " + pad(list(test.spallDiameter, scale: 100), 19) + pad("", 10)
                + "\(cm(2 * result.separatedRadius)) come away, \(cm(2 * result.spallRadiusByDamage)) cracked loose"
        )
        print(
            "  breach                       " + pad(test.breach ? "yes" : "no", 19) + pad("", 10)
                + (result.breached ? "yes" : "no"))
        print(
            "  debris mass (kg)             " + pad(list(test.debrisMass), 19) + pad("", 10)
                + "\(format(result.removedProtective, 1)) removed from the protective half "
                + "(\(format(result.removedLoaded, 1)) from the loaded)")
        print(
            "  loaded-face crater (cm)      " + pad("44-54 across", 19) + pad("", 10)
                + "\(cm(2 * result.craterRadius)) across, \(cm(result.craterDepth)) deep")
        let at = [0.0001, 0.0002, 0.0005, 0.001]
        let momenta = at.map { t in result.momentum.first { $0.x >= t }?.y ?? 0 }
        print(
            "  slab's momentum (N s)        at 0.1, 0.2, 0.5, 1 ms: "
                + momenta.map { format($0, 0) }.joined(separator: ", ")
                + "; largest \(format(result.momentum.map(\.y).max() ?? 0, 0))")
        print(
            "  kinetic energy (kJ)          debris, fit: \(format(Double(151 / test.scaledThickness - 60), 1)); "
                + "slab, model: \(format(result.kineticEnergy / 1000, 1))")
        print("  protective face's velocity (m/s) over the radius (cm), fit and model at each time:")
        var radii: [Int] = []
        var n = 0
        while (Float(n) + 0.5) * result.ring <= 0.6 {
            radii.append(n)
            n += max(1, Int((0.04 / result.ring).rounded()))
        }
        print(
            "    r       "
                + radii.map { pad(format(Double((Float($0) + 0.5) * result.ring) * 100, 0), 6) }.joined())
        print(
            "    fit     "
                + radii.map {
                    pad(format(Double(test.fittedVelocity(at: (Float($0) + 0.5) * result.ring)), 1), 6)
                }.joined())
        for (time, velocity) in result.faceProfiles {
            print(
                "    " + pad(format(time * 1000, 1) + " ms", 8)
                    + radii.map { pad(format(Double(velocity[$0]), 1), 6) }.joined())
        }
        if let structure = lastStructure { printRubble(structure) }
        print("  \(result.summary.erodedElements) elements failed; \(format(result.wallSeconds, 0)) s\n")
        fflush(stdout)
    }
}

/// Chiquito et al.'s full-scale slabs under charges hung 0.5 and 1 m above them.
/// Slabs with steel in one face or both (Wu et al. 2023, Wang et al. 2022): `--wu S5,D5` or
/// `--wang A,B`, at `--dx` air cells refined by `--refine`, `--h` elements, for `--time`
/// seconds; `--held` holds Wu's slabs lengthwise at both edges; `--bond pullout` and the other
/// concrete options as elsewhere; `--work` prints the work by mechanism at the peak and the end;
/// `--history` the first probe's displacement every millisecond; `--out dir` writes each
/// record there as CSV; for Wang's, `--edges hinged|sliding` (or `--hinged`) holds the edges
/// otherwise than fixed (see `TwoFaceSlabTests.WangEdges`), and `--afterburn` lets the products
/// burn on.
/// `blastbench rubblecost [--h 0.0125] [--radius 0.15] [--steps 400]`: what rubble costs a step.
/// Wu's slab on its own, a disc of elements through its thickness about the centre failed at
/// once and given a spread of speeds, then the structure stepped with and without rubble: wall
/// time per step, the particles' count, and the structure's step for scale.
func runRubbleCost() throws {
    let h = option("h").flatMap { Float($0) } ?? 0.0125
    let radius = option("radius").flatMap { Float($0) } ?? 0.15
    let steps = option("steps").flatMap { Int($0) } ?? 400
    print(
        "Wu's slab alone, \(format(Double(h) * 1000, 1)) mm elements, a disc \(format(Double(radius) * 200, 0)) cm across failed"
    )
    for rubble in [false, true] {
        var model = TwoFaceSlabTests.scenario(TwoFaceSlabTests.wuTests[7], elementSize: h).structure!
        model.rubbleParticles = rubble
        let solver = try StructureSolver(device: device, model: model)
        let c = TwoFaceSlabTests.wuCentre
        var failed = 0
        for k in 0..<solver.ez {
            for j in 0..<solver.ey {
                for i in 0..<solver.ex {
                    let p = solver.origin + SIMD3(Float(i) + 0.5, Float(j) + 0.5, 0) * h
                    guard solver.flag(i, j, k) == .active, simd_length(SIMD2(p.x - c.x, p.y - c.y)) < radius
                    else { continue }
                    solver.failElement(i, j, k)
                    failed += 1
                }
            }
        }
        // Thrown down and outwards, as a crater's rubble is, so that it meets the slab and itself.
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k) else { continue }
                        let p = solver.referencePosition(i, j, k)
                        let r = SIMD2(p.x - c.x, p.y - c.y)
                        guard simd_length(r) < radius + h else { continue }
                        nodes[n].velocity = SIMD3(
                            30 * r.x / radius, 30 * r.y / radius, -100 + 50 * (p.z - 0.6) / 0.1)
                    }
                }
            }
        }
        solver.advance(steps: 20)
        let start = ContinuousClock.now
        solver.advance(steps: steps)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        print(
            "  \(rubble ? "rubble   " : "no rubble") \(solver.elementCount) elements, \(failed) failed, \(solver.rubbleParticles().count) particles: \(format(seconds / Double(steps) * 1e6, 1)) µs a step (step \(format(Double(solver.criticalTimeStep) * 1e6, 2)) µs)"
        )
    }
}
