import BlastCore
import Foundation
import Metal
import simd

// `blastbench mapped-cost`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The fine one-dimensional start's own time (CPU), by charge and cell: `--masses 1,10,100
/// --dx 0.125,0.25,0.5 --cells 64`.
/// `--z 4,6,8`: the one-dimensional solution out to these scaled distances instead, which its
/// cost depends on alone.
func runMappedCost() throws {
    if let reaches = option("z") {
        for z in reaches.split(separator: ",").compactMap({ Float($0) }) {
            let cost = BlastSolver.mappedStartCost(
                mass: 10, cellSize: z * cbrt(10) / 64, cells: 64, configuration: .recommended)
            print(
                "Z \(z): \(String(format: "%.2f", cost.seconds)) s, \(cost.cells) cells, \(cost.steps) steps, digest \(String(cost.digest, radix: 16))"
            )
        }
        return
    }
    let masses = (option("masses") ?? "1,10,100,1000").split(separator: ",").compactMap { Float($0) }
    let cells = (option("dx") ?? "0.125,0.25,0.5,1").split(separator: ",").compactMap { Float($0) }
    let reach = option("cells").flatMap { Float($0) } ?? 64
    for mass in masses {
        for dx in cells {
            let cost = BlastSolver.mappedStartCost(
                mass: mass, cellSize: dx, cells: reach, configuration: .recommended)
            print(
                "\(mass) kg, \(dx) m: \(String(format: "%.2f", cost.seconds)) s, \(cost.cells) cells, \(cost.steps) steps"
            )
        }
    }
}
