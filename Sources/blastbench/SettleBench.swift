import BlastCore
import Foundation
import Metal
import simd

/// `blastbench settle [--scene office|tower|slab] [--cell 0.5] [--window 0.2] [--element 0.0375]`:
/// how still a structure is when the blast reaches it, given its weight as the run starts and
/// brought to rest under it first (`BlastSolver.settleStructures()`). Until the shock arrives no
/// load but gravity acts, so each body runs alone, without the air, from the start to the
/// shock's arrival at its nearest point (Kingery–Bulmash) and on for `--window` seconds: the
/// motion its own weight would add to what the blast does. The settled run's state at arrival is
/// the rest state each is measured from.
func runSettle(device: MTLDevice) throws {
    let scene = option("scene") ?? "office"
    let cell = option("cell").flatMap { Float($0) } ?? 0.5
    let element = option("element").flatMap { Float($0) } ?? 0.0375
    var scenario: Scenario
    var hold: ((BlastSolver) -> Void)?
    switch scene {
    case "tower": scenario = ScenarioPreset.coreTower.scenario
    case "office": scenario = ScenarioPreset.officeTower.scenario
    case "slab":
        // Yao's 4 x 5 m slab, 150 mm thick, on its two bearings, under T1's 0.5 kg at 1 m.
        let test = TwoFaceSlabTests.yaoTests[0]
        scenario = TwoFaceSlabTests.scenario(test, elementSize: element)
        hold = { solver in
            guard let structure = solver.structure else { return }
            let h = structure.model.elementSize
            structure.mutateNodes { nodes in
                TwoFaceSlabTests.yaoHold(structure, nodes) { value, axis in
                    Int(((value - structure.origin[axis]) / h).rounded())
                }
            }
        }
    default:
        print("--scene is office, tower or slab")
        exit(2)
    }
    let window = option("window").flatMap { Double($0) } ?? (scene == "slab" ? 0.02 : 0.2)
    let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cell)
    // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
    solver.configuration = .recommended.balloonStart

    struct State {
        var u: [SIMD3<Float>] = []
        var v: [SIMD3<Float>] = []
        var m: [Float] = []
    }
    func state(_ body: StructuralBody) -> State {
        var s = State()
        body.solids?.mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                s.u.append(node.displacement)
                s.v.append(node.velocity)
                s.m.append(node.mass)
            }
        }
        body.shells?.mutateNodes { nodes in
            for node in nodes where node.mass > 0 && node.flags & 256 == 0 {
                s.u.append(node.displacement)
                s.v.append(node.velocity)
                s.m.append(node.mass)
            }
        }
        return s
    }
    /// Mass-weighted root mean square of `values`.
    func rms(_ values: [SIMD3<Float>], _ m: [Float]) -> Double {
        var sum = 0.0
        var mass = 0.0
        for (value, mass1) in zip(values, m) {
            sum += Double(mass1) * Double(simd_length_squared(value))
            mass += Double(mass1)
        }
        return mass > 0 ? (sum / mass).squareRoot() : 0
    }
    func advance(_ body: StructuralBody, steps: Int) {
        if let mixed = body.mixed {
            mixed.advance(steps: steps)
        } else {
            body.solids?.advance(steps: steps)
            body.shells?.advance(steps: steps)
        }
    }
    /// The nearest node of `body` to the charge, m.
    func range(_ body: StructuralBody) -> Float {
        let charge = scenario.charge.position
        var nearest = Float.infinity
        if let shells = body.shells {
            for p in shells.referencePositions { nearest = min(nearest, simd_distance(p, charge)) }
        }
        if let solids = body.solids {
            for k in 0...solids.ez {
                for j in 0...solids.ey {
                    for i in 0...solids.ex where solids.storedNode(i, j, k) != nil {
                        nearest = min(nearest, simd_distance(solids.position(i, j, k), charge))
                    }
                }
            }
        }
        return nearest
    }
    func arrival(_ range: Float) -> Double {
        let mass = Double(scenario.charge.mass)
        let z = Double(range) / cbrt(mass)
        guard z <= 40, let point = KingeryBulmash.point(at: z) else { return Double(range) / 343 }
        return point.arrival(mass: mass)
    }

    struct Trace {
        /// At arrival: the RMS and largest speed (m/s), and the RMS and largest distance from rest
        /// (m); then the largest distance from rest over the window.
        var speed = 0.0
        var fastest: Float = 0
        var offRest = 0.0
        var furthest: Float = 0
        var windowFurthest: Float = 0
        var windowOffRest = 0.0
    }
    print(
        "Scene \(scenario.name): charge \(scenario.charge.mass) kg; window \(window * 1000) ms after arrival")
    var rest: [[SIMD3<Float>]] = []
    var traces: [[Trace]] = [[], []]
    for (pass, settles) in [true, false].enumerated() {
        solver.configuration.settlesStructures = settles
        try solver.load(scenario)
        hold?(solver)
        let start = Date()
        solver.settleStructures()
        let settling = Date().timeIntervalSince(start)
        if settles {
            for s in solver.settlements {
                print(
                    String(
                        format: "  settled %@: %@ in %.0f ms of its time (%d steps), %.1f s here; "
                            + "residual speed %.3f of its largest; largest displacement %.2f mm",
                        s.name, s.settled ? "came to rest" : "did NOT come to rest", s.time * 1000, s.steps,
                        s.seconds, s.residualSpeed, s.displacement * 1000)
                        + (s.cached ? " (from the cache)" : ""))
            }
            print(String(format: "  settling took %.1f s in all", settling))
        }
        for (b, body) in solver.bodies.enumerated() {
            let distance = range(body)
            let t = arrival(distance)
            let step = Double(body.criticalTimeStep)
            let atArrival = max(0, Int((t / step).rounded()))
            advance(body, steps: atArrival)
            let s = state(body)
            if settles { rest.append(s.u) }
            let off = zip(s.u, rest[b]).map { $0 - $1 }
            var trace = Trace(
                speed: rms(s.v, s.m), fastest: s.v.map { simd_length($0) }.max() ?? 0, offRest: rms(off, s.m),
                furthest: off.map { simd_length($0) }.max() ?? 0)
            let sample = max(1, Int((0.001 / step).rounded()))
            var elapsed = 0
            while Double(elapsed) * step < window {
                advance(body, steps: sample)
                elapsed += sample
                let now = state(body)
                let off = zip(now.u, rest[b]).map { $0 - $1 }
                trace.windowFurthest = max(trace.windowFurthest, off.map { simd_length($0) }.max() ?? 0)
                trace.windowOffRest = max(trace.windowOffRest, rms(off, now.m))
            }
            traces[pass].append(trace)
            if pass == 0 {
                print(
                    String(
                        format: "  %@: nearest node %.2f m from the charge, shock arrives at %.1f ms; "
                            + "at rest its RMS displacement is %.2f mm, largest %.2f mm",
                        body.name, distance, t * 1000, rms(s.u, s.m) * 1000,
                        (s.u.map { simd_length($0) }.max() ?? 0) * 1000))
            }
        }
    }
    print("")
    print(
        "  body                      start      RMS speed  largest   RMS off rest  largest   over window: RMS  largest"
    )
    print(
        "                                       mm/s       mm/s      mm            mm                     mm    mm"
    )
    for (b, body) in solver.bodies.enumerated() {
        for (pass, label) in ["settled", "from rest"].enumerated() {
            let t = traces[pass][b]
            print(
                String(
                    format: "  %-24@  %-9@  %9.3f  %8.3f  %12.3f  %8.3f   %15.3f  %7.3f",
                    String(body.name.prefix(24)), label, t.speed * 1000, t.fastest * 1000, t.offRest * 1000,
                    t.furthest * 1000, t.windowOffRest * 1000, t.windowFurthest * 1000))
        }
    }
}
