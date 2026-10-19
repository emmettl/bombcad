import BlastCore
import Foundation

/// `blastbench twocharges`: two alike surface bursts far apart on rigid ground (`--mass` kg each,
/// 10; `--apart` m/kg^(1/3), 14), gauges on each one's outer side, against Kingery–Bulmash
/// superposed: each gauge's peak is its own charge's, as the other's arrives far later and
/// weaker; its impulse over the whole record is both charges' summed. `--mapped` starts each
/// charge from its own one-dimensional solution; `--dx` (0.25 m), `--z` (1,1.5,2,3,4,6).
func runTwoCharges(solver makeSolver: (Scenario, Float) throws -> BlastSolver) throws {
    let mass = option("mass").flatMap { Float($0) } ?? 10
    let apart = (option("apart").flatMap { Float($0) } ?? 14) * cbrt(mass)
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let scaled =
        option("z").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [1, 1.5, 2, 3, 4, 6]
    let cube = cbrt(mass)
    let reach = (scaled.max() ?? 6) * cube
    // Faces 4 m/kg^(1/3) beyond the farthest gauge, and as far either side and above.
    let margin = 4 * cube
    let length = apart + 2 * (reach + margin)
    let width = 2 * margin + 2 * cellSize
    let first = SIMD3(reach + margin, width / 2, 0)
    let second = first + SIMD3(apart, 0, 0)
    var gauges: [Gauge] = []
    for z in scaled {
        gauges.append(Gauge("first \(z)", at: first - SIMD3(z * cube, 0, -0.5 * cellSize)))
        gauges.append(Gauge("second \(z)", at: second + SIMD3(z * cube, 0, 0.5 * cellSize)))
    }
    var scenario = Scenario(
        name: "Two charges", domainSize: SIMD3(length, width, margin + cellSize), boxes: [],
        charge: Charge(mass: mass, position: first), gauges: gauges)
    scenario.additionalCharges = [Charge(mass: mass, position: second)]
    scenario.reflectiveFaces = .ground
    let solver = try makeSolver(scenario, cellSize)
    let mapped = solver.mappedRadii
    print(
        "Two \(mass) kg surface bursts \(format(Double(apart), 1)) m apart on rigid ground, cells \(cellSize) m; "
            + (mapped.isEmpty
                ? "as the balloon"
                : "mapped \(mapped.map { format(Double($0), 2) + " m" }.joined(separator: ", ")) out, from \(format(solver.time * 1e3, 2)) ms")
    )
    let farthest = Double(apart + reach) / 340 * 1.6 + 0.02
    solver.advance(until: farthest)
    print(
        pad("Z", 6) + pad("K-B peak", 12) + pad("first", 10) + pad("second", 10) + pad("K-B impulse", 14)
            + pad("first", 10) + "second")
    let ambient = scenario.atmosphere.pressure
    for (n, z) in scaled.enumerated() {
        guard let own = KingeryBulmash.point(at: Double(z)),
            let other = KingeryBulmash.point(at: Double((apart / cube) + z))
        else { continue }
        let impulse = own.incidentImpulse(mass: Double(mass)) + other.incidentImpulse(mass: Double(mass))
        var row = pad(format(Double(z), 1), 6) + pad("\(format(own.incidentPressure / 1e3, 1)) kPa", 12)
        var impulses: [Double] = []
        for g in [2 * n, 2 * n + 1] {
            let samples = solver.gaugeHistories[g]
            let peak = Double((samples.map(\.pressure).max() ?? ambient) - ambient)
            var total = 0.0
            for (a, b) in zip(samples, samples.dropFirst()) {
                total += (b.time - a.time) * Double(max(0.5 * (a.pressure + b.pressure) - ambient, 0))
            }
            impulses.append(total)
            row += pad("\(format(100 * peak / own.incidentPressure, 0))%", 10)
        }
        row += pad("\(format(impulse, 0)) Pa s", 14)
        row += impulses.map { pad("\(format(100 * $0 / impulse, 0))%", 10) }.joined()
        print(row)
    }
}
