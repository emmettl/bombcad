import BlastCore
import BlastModel
import Foundation
import Metal

/// With `--assumed-strain`, how many elements of each body that ran switched to their eight points
/// (`StructureSolver.assumedStrainTally`), printed at the end of the run.
func printAssumedStrainTally() {
    let tally = StructureSolver.assumedStrainTally()
    guard !tally.isEmpty else { return }
    print("\nAssumed strain (elements switched to eight points, of all):")
    for (n, body) in tally.enumerated() {
        let share = 100 * Double(body.switched) / Double(max(body.elements, 1))
        print(
            "  body \(n + 1): \(body.switched) of \(body.elements) (\(format(share, 1))%)"
                + (body.poolFull ? ", the pool full (\(body.capacity))" : ""))
    }
}

/// `--mode-share` on `impact`: the distribution of the intact elements' hourglass-mode share of
/// their deformation (`StructureSolver.modeShares`) at the end of the run, switched elements and the
/// rest apart.
func printModeShares(_ solver: StructureSolver) {
    let shares = solver.modeShares()
    for switched in [false, true] {
        let values = shares.filter { $0.switched == switched }.map(\.share).sorted()
        guard !values.isEmpty else { continue }
        func quantile(_ q: Double) -> Float { values[min(values.count - 1, Int(q * Double(values.count)))] }
        print(
            "    mode share, \(switched ? "switched" : "one-point") elements (\(values.count)): median "
                + "\(format(Double(quantile(0.5)), 2)), 90% \(format(Double(quantile(0.9)), 2)), 99% "
                + "\(format(Double(quantile(0.99)), 2)), most \(format(Double(values.last ?? 0), 1)); over 1: "
                + "\(values.filter { $0 > 1 }.count), over 3: \(values.filter { $0 > 3 }.count)")
    }
}

/// `blastbench assumed-strain-cost [--layers 8] [--steps 400] [--rounds 5]`: what an element that
/// bends in its cracked concrete costs. A reinforced slab 2 m square and 0.2 m deep, unloaded and
/// without gravity, is stepped with the option off, on with no element switched, and on with every
/// element switched to its eight points, in interleaved rounds; the medians of the GPU time per
/// substep and their ratios are printed.
func runAssumedStrainCost(device: MTLDevice) throws {
    let layers = option("layers").flatMap { Int($0) } ?? 8
    let steps = option("steps").flatMap { Int($0) } ?? 400
    let rounds = option("rounds").flatMap { Int($0) } ?? 5
    let h = 0.2 / Float(layers)
    let slab = Box(min: SIMD3(0, 0, 1), max: SIMD3(2, 2, 1.2))
    let steel = SteelProperties(
        yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.08, ruptureStrain: 0.1)
    func solver(_ option: Bool, switchAll: Bool) throws -> StructureSolver {
        var model = StructureModel(
            solids: [slab], material: .concrete(name: "C30", compressiveStrength: 30e6, steel: steel),
            elementSize: h,
            fixedBase: false)
        model.addMat(to: slab, thicknessAxis: 2, areaPerMetre: 5e-4, depth: 0.03)
        model.assumedStrainCracking = option
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        if switchAll { solver.switchToAssumedStrain { _, _, _ in true } }
        return solver
    }
    let cases: [(String, Bool, Bool)] = [
        ("option off", false, false), ("on, none switched", true, false), ("on, all switched", true, true),
    ]
    let solvers = try cases.map { try solver($0.1, switchAll: $0.2) }
    for body in solvers { body.advance(steps: 50) }
    var samples = [[Double]](repeating: [], count: cases.count)
    for _ in 0..<rounds {
        for (n, body) in solvers.enumerated() {
            let before = body.gpuSeconds
            body.advance(steps: steps)
            samples[n].append((body.gpuSeconds - before) / Double(steps))
        }
    }
    let medians = samples.map { $0.sorted()[$0.count / 2] }
    print(
        "Assumed-strain cost: a slab of \(solvers[0].elementCount) elements, \(layers) through, "
            + "\(steps) substeps a round, \(rounds) rounds (median GPU time per substep)")
    for (n, item) in cases.enumerated() {
        let switched = solvers[n].assumedStrainSummary?.switched ?? 0
        print(
            "  \(pad(item.0, 20)) \(format(medians[n] * 1e6, 1)) µs  ×\(format(medians[n] / medians[0], 2))"
                + "  (\(switched) switched)")
    }
    let extra = (medians[2] - medians[0]) / Double(max(solvers[2].elementCount, 1))
    print(
        "  a switched element: \(format(extra * 1e9, 2)) ns more a substep, against "
            + "\(format(medians[0] / Double(max(solvers[0].elementCount, 1)) * 1e9, 2)) ns for the whole substep per element"
    )
}
