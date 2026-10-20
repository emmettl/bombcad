import BlastCore
import Foundation
import Metal
import simd

// `blastbench gas`.
// Split from main.swift (emmettl/bombcad-work#51).

func runGasPressure() throws {
    let side: Float = 6
    let settle = option("time").flatMap { Double($0) } ?? 0.08
    print(
        "Charge in the middle of a closed \(Int(side)) m cubic room, after the shocks have settled (\(format(settle * 1000, 0)) ms)"
            + (burning ? ", with afterburning" : "")
            + (chosenAirModel().map { ", \($0) air" } ?? ""))
    print(
        pad("W/V kg/m3", 11) + pad("charge", 10) + pad("model", 12) + pad("(g-1)E/V", 12)
            + pad("UFC 2-152", 12)
            + pad("model/UFC", 11) + pad("burnt", 8) + (flag("radiate") ? pad("radiated", 9) : ""))
    // `--per-volume 0.1415` runs other ratios (that one is Cooper's closed-vessel example).
    let ratios =
        option("per-volume").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [
            0.25, 0.5, 1, 2, 4,
        ]
    for chargePerVolume in ratios {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: chargePerVolume * side * side * side, position: SIMD3(repeating: side / 2)))
        scenario.reflectiveFaces = .all
        let solver = try makeAirSolver(scenario, cellSize: option("dx").flatMap { Float($0) } ?? 0.25)
        solver.advance(until: settle)
        let burnt = 1 - solver.speciesTotals().fuel / Double(scenario.charge.mass)
        let volume = Double(side * side * side)
        let totals = solver.totals()
        // Mean pressure of the gas: (gamma - 1) times its internal energy per volume, less the
        // kinetic energy still sloshing about (small by now).
        var kinetic = 0.0
        solver.withState { cells in
            for cell in cells {
                kinetic +=
                    0.5
                    * Double(
                        cell.momentumX * cell.momentumX + cell.momentumY * cell.momentumY
                            + cell.momentumZ * cell.momentumZ) / Double(max(cell.density, 1e-6))
            }
        }
        let cellVolume = Double(pow(solver.grid.cellSize, 3))
        let gamma = Double(solver.configuration.gamma)
        let mean =
            Double(
                solver.configuration.airModel.pressure(
                    density: Float(totals.mass / volume),
                    internalEnergy: Float((totals.energy - kinetic * cellVolume) / volume),
                    gamma: Float(gamma)))
            - Double(scenario.atmosphere.pressure)
        let ideal = (gamma - 1) * Double(scenario.charge.energy) / volume
        let reference = UFC340.peakGasPressure(chargePerVolume: Double(chargePerVolume)) ?? .nan
        print(
            pad(format(Double(chargePerVolume), 2), 11) + pad("\(Int(scenario.charge.mass)) kg", 10)
                + pad("\(format(mean / 1e6, 2)) MPa", 12) + pad("\(format(ideal / 1e6, 2)) MPa", 12)
                + pad("\(format(reference / 1e6, 2)) MPa", 12)
                + pad("\(format(100 * mean / reference, 0))%", 11)
                + pad(solver.configuration.afterburning ? "\(format(100 * burnt, 0))%" : "-", 8)
                + (flag("radiate")
                    ? pad("\(format(100 * solver.radiatedEnergy / Double(scenario.charge.energy), 1))%", 9)
                    : ""))
    }
}
