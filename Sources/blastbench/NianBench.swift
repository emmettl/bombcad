import BlastCore
import Foundation
import Metal
import simd

// `blastbench nian [--charges 5,20] [--dx 0.1] [--time 0.04]`: Nian et al.'s (2024) reinforced concrete
// blast wall, 6 m long, 2.5 m high and 0.4 m thick with no wing walls, TNT on the ground 3 m in front
// of it; the pressures on the ground before and behind it and reflected on its face, against those
// measured (Fixtures/Nian2024). The wall is rigid; each charge is run with it and without it, the
// latter for the wall's factor on the peaks. The air on the recommended settings.

struct NianGauge {
    var name: String
    var position: SIMD3<Float>
    var reflected: Bool
}

func runNian(device: MTLDevice) throws {
    let charges = (option("charges") ?? "5,20").split(separator: ",").compactMap { Float($0) }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.1
    let duration = option("time").flatMap { Double($0) } ?? 0.04
    // Measured peaks (kPa) by gauge and charge: Fixtures/Nian2024 (nil where the gauge was invalid).
    let measured: [String: [Float: Float]] = [
        "p-1": [5: 310, 20: 1620], "p-2": [5: 122, 20: 220], "p-3": [5: 63, 20: 170],
        "p-4": [5: 49, 20: 120],
        "pg-1": [5: 3240, 20: 7720], "ph-1": [5: 14.3], "ph-2": [20: 52.1], "ph-3": [5: 12.2],
    ]
    // The charge 4 m from the domain's back face, centred across it; the wall's front face 3 m on.
    let charge = SIMD3<Float>(4, 12, 0)
    let front = charge.x + 3
    let wall = Box(min: SIMD3(front, charge.y - 3, 0), max: SIMD3(front + 0.4, charge.y + 3, 2.5))
    let domain = SIMD3<Float>(front + 0.4 + 6 + 4.6, 24, 8)
    var gauges: [NianGauge] = []
    for (n, d) in [Float(3), 5, 7, 9].enumerated() {
        gauges.append(
            NianGauge(name: "p-\(n + 1)", position: SIMD3(charge.x, charge.y + d, 0), reflected: false))
    }
    gauges.append(
        NianGauge(name: "pg-1", position: SIMD3(front - 0.5 * cellSize, charge.y, 0.22), reflected: true))
    for (n, r) in [Float(2), 4, 6].enumerated() {
        gauges.append(
            NianGauge(name: "ph-\(n + 1)", position: SIMD3(front + 0.4 + r, charge.y, 0), reflected: false))
    }
    print(
        "Nian et al. (2024): a rigid wall 6 x 2.5 x 0.4 m, TNT on the ground 3 m in front; air \(format(Double(cellSize), 3)) m, \(format(duration * 1000, 0)) ms"
    )
    for mass in charges {
        var peaks: [Bool: [Float]] = [:]
        for withWall in [true, false] {
            let scenario = Scenario(
                name: "Nian \(mass) kg", domainSize: domain, boxes: withWall ? [wall] : [],
                charge: Charge(mass: mass, position: charge),
                gauges: gauges.map { Gauge($0.name, at: $0.position) })
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: cellSize, configuration: .recommended)
            solver.advance(until: duration)
            let ambient = scenario.atmosphere.pressure
            peaks[withWall] = solver.gaugeHistories.map { history in
                ((history.map(\.pressure).max() ?? ambient) - ambient) / 1000
            }
        }
        print("\n\(format(Double(mass), 0)) kg TNT")
        print(
            pad("gauge", 8) + pad("where", 30) + pad("measured kPa", 14) + pad("model, wall", 13)
                + pad("model / measured", 18) + pad("no wall", 10) + "wall's factor")
        for (index, gauge) in gauges.enumerated() {
            let withWall = peaks[true]![index]
            let open = peaks[false]![index]
            let place =
                gauge.reflected
                ? "front face, 0.22 m up"
                : gauge.name.hasPrefix("ph")
                    ? "\(format(Double(gauge.position.x - front - 0.4), 0)) m behind, ground"
                    : "\(format(Double(gauge.position.y - charge.y), 0)) m along, ground"
            let reading = measured[gauge.name]?[mass]
            print(
                pad(gauge.name, 8) + pad(place, 30) + pad(reading.map { format(Double($0), 1) } ?? "-", 14)
                    + pad(format(Double(withWall), 1), 13)
                    + pad(reading.map { format(Double(withWall / $0), 2) } ?? "-", 18)
                    + pad(format(Double(open), 1), 10) + format(Double(withWall / max(open, 1e-3)), 2))
        }
    }
}
