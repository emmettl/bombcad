import BlastCore
import Foundation
import Metal

/// `blastbench mendonca-static [--slab 4] [--layers 8] [--ramp 0.5] [--to 200]`: Mendonça's slab on
/// its trestles as the harness holds it, without air, under a uniform pressure on its top face
/// rising linearly from nothing to `--to` kPa over `--ramp` seconds: its resistance curve, slowly
/// enough that inertia hardly enters (halve the rate to check). Prints the centre's deflection
/// against the pressure, when it first cracks and its bars first yield, and the pressure at 5,
/// 10 and 20 mm.
func runMendoncaStatic(device: MTLDevice) throws {
    let inputs = try MendoncaSlabTest.inputs(
        from: URL(filePath: option("inputs") ?? "Samples/Mendonca2020/inputs/slabs.json"))
    var settings = MendoncaSlabTest.Settings()
    if let layers = option("layers").flatMap({ Int($0) }) { settings.elementsThroughDepth = layers }
    let name = option("slab") ?? "4"
    guard let slab = inputs.slabs.first(where: { $0.name == name }) else {
        print("No slab \(name)")
        return
    }
    let scenario = MendoncaSlabTest.scenario(slab, inputs: inputs, settings: settings)
    guard var model = scenario.structure else { return }
    applyRateOptions(&model)
    // `--no-rate`: the materials without their strain-rate laws.
    if flag("no-rate") {
        model.material.rateDependent = false
        model.solidMaterial = model.solidMaterial.map {
            $0.map {
                var m = $0
                m.rateDependent = false
                return m
            }
        }
    }
    let solver = try StructureSolver(device: device, model: model)
    solver.gravity = 0
    solver.groundContact = false
    let s = MendoncaSlabTest.slabBox(inputs: inputs, settings: settings)
    let h = solver.model.elementSize
    func index(_ value: Float, _ axis: Int) -> Int { Int(((value - solver.origin[axis]) / h).rounded()) }
    let bottom = index(s.min.z, 2)
    let top = index(s.max.z, 2)
    let ci = index((s.min.x + s.max.x) / 2, 0)
    let cj = index((s.min.y + s.max.y) / 2, 1)
    let low = index(s.min.y + (inputs.plan - inputs.trestleLength) / 2, 1)
    let high = index(s.max.y - (inputs.plan - inputs.trestleLength) / 2, 1)
    let bearing = Int((settings.bearingWidth / h).rounded())
    let near = index(s.min.x, 0)
    let far = index(s.max.x, 0)
    // As the harness holds it: resting on the trestles, free to lift; held along the span at the
    // near bearing's middle line, and across at the middle of each.
    solver.mutateNodes { nodes in
        for j in low...high {
            for i in Array(near...(near + bearing)) + Array((far - bearing)...far) {
                guard let n = solver.storedNode(i, j, bottom) else { continue }
                nodes[n].restsOnSupport = true
                if i == near + bearing / 2 { nodes[n].restrain(x: true) }
                if j == cj && (i == near + bearing / 2 || i == far - bearing / 2) {
                    nodes[n].restrain(y: true)
                }
            }
        }
    }
    // `--account`: the work by mechanism at first cracking, 5 mm and 20 mm.
    let accounting = flag("account")
    if accounting { solver.tracesWork = true }
    var accounted: Set<String> = []
    func account(_ label: String) {
        let key = String(label.prefix(while: { $0 != "(" }))
        guard accounting, !accounted.contains(key) else { return }
        accounted.insert(key)
        let totals = solver.workTotals()
        typealias C = StructureSolver.WorkChannel
        let groups: [(String, [C])] = [
            ("concrete in tension, uncracked", [.tensionNormal]),
            ("between cracks (hairline)", [.tensionHairline]),
            ("across open cracks", [.tensionCracked]),
            ("compression", [.compressionNormal, .compressionCrushed]),
            ("shear", [.uncrackedShear, .crackShear, .crackShearPressed, .interlock, .interlockPressed]),
            ("bars", [.bars, .bond, .dowel, .kink]),
            ("hourglass", [.hourglass, .hourglassCapped]),
            ("other", [.other, .viscosity]),
        ]
        let all = totals.reduce(0, +)
        print(
            "    work at \(label) (J, share): "
                + groups.map { name, channels in
                    let w = channels.reduce(0.0) { $0 + totals[$1.rawValue] }
                    return "\(name) \(format(w, 1)) (\(format(100 * w / all, 0))%)"
                }.joined(separator: "; "))
    }
    // The bending moment across the mid-span section (N m): what statics needs, from the support
    // reactions beside it and the load on that side, against what the elements' stresses (concrete
    // and bars) carry; the rest is the hourglass control's.
    let column = ci
    let middle = solver.origin.x + (Float(column) + 0.5) * h
    let rows = index(s.min.y, 1)..<index(s.max.y, 1)
    func moments(_ pressure: Double) -> (statics: Double, stresses: Double) {
        var statics = 0.0
        for j in low...high {
            for i in near...(near + bearing) {
                guard solver.storedNode(i, j, bottom) != nil else { continue }
                let x = solver.origin.x + Float(i) * h
                statics -= Double(solver.nodalForce(i, j, bottom).z) * Double(middle - x)
            }
        }
        let half = Double(middle - s.min.x)
        statics -= pressure * 1000 * Double(inputs.plan) * half * half / 2
        var stresses = 0.0
        let centre = (s.min.z + s.max.z) / 2
        for j in rows {
            for k in bottom..<top {
                let z = solver.origin.z + (Float(k) + 0.5) * h - centre
                stresses -= Double(solver.stress(column, j, k)[0]) * Double(z) * Double(h * h)
            }
        }
        return (statics, stresses)
    }
    var nextMoment = 0.0
    let ramp = option("ramp").flatMap { Double($0) } ?? 0.5
    let peak = (option("to").flatMap { Float($0) } ?? 200) * 1000
    solver.appliedLoad = PressureLoad(
        axis: 2, positiveSide: true,
        history: [SIMD2(0, 0), SIMD2(Float(ramp), peak), SIMD2(Float(ramp) * 10, peak)])
    let span = Double(inputs.plan - settings.bearingWidth)
    print(
        String(
            format:
                "Slab %@ on its trestles, no air: %.0f elements of %.1f mm, %.2f µs steps; uniform pressure to %.0f kPa over %.2f s (span %.2f m)",
            name, Double(solver.elementCount), Double(h) * 1000, Double(solver.criticalTimeStep) * 1e6,
            Double(peak) / 1000, ramp,
            span))
    print("  pressure kPa   centre mm   cracked elements   yielded elements")
    let samples = 200
    let stepsPerSample = max(1, Int((ramp / Double(samples) / Double(solver.criticalTimeStep)).rounded()))
    var firstCrack: Double?
    var firstYield: Double?
    var marks: [Double: Double] = [:]
    for _ in 0..<samples {
        solver.advance(steps: stepsPerSample)
        let pressure = Double(peak) * min(solver.time / ramp, 1) / 1000
        let centre = Double(-solver.displacement(ci, cj, bottom).z) * 1000
        var cracked = 0
        var yielded = 0
        for i in near..<far {
            for j in index(s.min.y, 1)..<index(s.max.y, 1) {
                for k in bottom..<top where solver.flag(i, j, k) == .active || solver.flag(i, j, k) == .bare {
                    if solver.crackingFactor(i, j, k) > 0 { cracked += 1 }
                    let p = solver.barPlasticStrain(i, j, k)
                    if max(abs(p.x), abs(p.y), abs(p.z)) > 0 { yielded += 1 }
                }
            }
        }
        if firstCrack == nil && cracked > 0 {
            firstCrack = pressure
            account("first cracking (\(format(pressure, 1)) kPa)")
        }
        if centre >= 5 { account("5 mm (\(format(pressure, 1)) kPa)") }
        if centre >= 20 { account("20 mm (\(format(pressure, 1)) kPa)") }
        if pressure >= nextMoment {
            nextMoment += 10
            let (statics, stresses) = moments(pressure)
            print(
                "    mid-span moment: statics \(format(statics / 1000, 2)) kN m, the elements' stresses "
                    + "\(format(stresses / 1000, 2)) (\(format(100 * stresses / statics, 0))%), hourglass the rest"
            )
        }
        if firstYield == nil && yielded > 0 { firstYield = pressure }
        for mark in [5.0, 10, 20] where marks[mark] == nil && centre >= mark { marks[mark] = pressure }
        print(
            "  " + pad(format(pressure, 1), 12) + pad(format(centre, 2), 12) + pad("\(cracked)", 19)
                + pad("\(yielded)", 19))
        if centre > 40 || !centre.isFinite { break }
    }
    print(
        "  first cracked at \(firstCrack.map { format($0, 1) } ?? "-") kPa; bars first yielded at "
            + "\(firstYield.map { format($0, 1) } ?? "-") kPa; at 5 / 10 / 20 mm: "
            + [5.0, 10, 20].map { marks[$0].map { format($0, 1) } ?? "-" }.joined(separator: " / ") + " kPa")
}
