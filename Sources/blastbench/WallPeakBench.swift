import BlastCore
import Foundation
import Metal
import simd

/// `blastbench wallpeak [--z 1,1.5,2,3,4] [--dx 0.5,0.25,0.125] [--mass 100]`: where a reflected
/// peak at a rigid wall's foot is lost. For each scaled distance and cell size, a surface burst on
/// rigid ground with a rigid wall at that stand-off, and the same without the wall:
/// - the incident peak at the wall's place (no wall), against Kingery–Bulmash's incident;
/// - the reflected peak the gauge reads (the wall cell's pressure), against Kingery–Bulmash's
///   reflected and against the normal reflection (Rankine–Hugoniot, γ = 1.4) of the incident the
///   grid carried there, which separates what the reflection loses from what the incident had lost;
/// - the pressure at the wall from the wall cell's state against its mirror (two shocks), the
///   reflection read from the gas arriving rather than from the reflected shock resolved.
func runWallPeak(device: MTLDevice) throws {
    let distances = (option("z") ?? "1,1.5,2,3,4").split(separator: ",").compactMap { Double($0) }
    let cellSizes = (option("dx") ?? "0.5,0.25,0.125").split(separator: ",").compactMap { Float($0) }
    let mass = option("mass").flatMap { Double($0) } ?? 100
    let ambient: Float = 101_325
    print("Reflected peaks at a rigid wall's foot, \(format(mass, 0)) kg surface burst, recommended air")
    print(
        "  Z      R m   dx     cells/R  KB inc   sim inc  KB refl  RH(sim)  cell     two-shock  (kPa; % of KB refl)"
    )
    for z in distances {
        guard let point = KingeryBulmash.point(at: z) else { continue }
        let range = Float(point.range(mass: mass))
        for dx in cellSizes {
            // The charge 3 m in from the low x face; the wall the high x face; far-field faces round
            // the sides and the top, rigid ground.
            let lead: Float = 3
            let length = ((lead + range) / dx).rounded() * dx
            let width = ((range + 8) / dx).rounded(.up) * dx
            let height = ((0.5 * range + 4) / dx).rounded(.up) * dx
            func run(wall: Bool) throws -> (cell: Float, reflected: Float) {
                var scenario = Scenario(
                    name: "Wall peak", domainSize: SIMD3(length, width, height), boxes: [],
                    charge: Charge(mass: Float(mass), position: SIMD3(length - range, width / 2, 0)))
                scenario.reflectiveFaces = wall ? [.zMin, .xMax] : [.zMin]
                var configuration = SolverConfiguration.recommended
                configureRefinement(&configuration)
                applyChosenAir(&configuration)
                let solver = try BlastSolver(
                    device: device, scenario: scenario, cellSize: dx, configuration: configuration)
                // The cell at the wall's foot (the last along x, the first above the ground).
                let i = solver.grid.nx - 1
                let j = solver.grid.ny / 2
                let arrival = point.arrival(mass: mass)
                // Large batches until shortly before the shock, then a step at a time.
                _ = solver.advance(until: 0.6 * arrival)
                var cellPeak: Float = 0
                var reflectedPeak: Float = 0
                let end = 1.5 * arrival + 0.002
                while solver.time < end {
                    let result = solver.advance(steps: 1, timeLimit: end)
                    let s = solver.primitive(i, j, 0)
                    cellPeak = max(cellPeak, s.pressure - ambient)
                    let towards = s.velocity.x
                    reflectedPeak = max(
                        reflectedPeak, wallPressure(rho: s.density, p: s.pressure, towards: towards) - ambient
                    )
                    if result.steps == 0 { break }
                }
                return (cellPeak, reflectedPeak)
            }
            let incident = try run(wall: false)
            let walled = try run(wall: true)
            let ps = Double(incident.cell)
            let p0 = Double(ambient)
            let rh = 2 * ps * (7 * p0 + 4 * ps) / (7 * p0 + ps)
            let kbr = point.reflectedPressure
            func pct(_ v: Double) -> String { "\(format(v / 1000, 1)) (\(format(100 * v / kbr, 0))%)" }
            print(
                pad(format(z, 2), 7) + pad(format(Double(range), 2), 7) + pad(format(Double(dx), 3), 7)
                    + pad(format(Double(range / dx), 1), 9) + pad(format(point.incidentPressure / 1000, 1), 9)
                    + pad(format(ps / 1000, 1), 9) + pad(format(kbr / 1000, 1), 9) + pad(pct(rh), 16)
                    + pad(pct(Double(walled.cell)), 16) + pct(Double(walled.reflected)))
            fflush(stdout)
        }
    }
}

/// The pressure at a rigid wall that gas of density `rho` and pressure `p` meets moving towards
/// it at `towards` m/s (negative: away): two shocks between it and its mirror, or two
/// rarefactions, for γ = 1.4.
func wallPressure(rho: Float, p: Float, towards: Float) -> Float {
    let gamma: Float = 1.4
    let c = sqrt(gamma * p / rho)
    if towards <= 0 {
        return p * pow(max(1 + 0.5 * (gamma - 1) * towards / c, 0), 2 * gamma / (gamma - 1))
    }
    let a = 2 / ((gamma + 1) * rho)
    let b = (gamma - 1) / (gamma + 1) * p
    var q = p + rho * c * towards
    for _ in 0..<8 {
        let root = sqrt(a / (q + b))
        let f = (q - p) * root - towards
        let slope = root * (1 - 0.5 * (q - p) / (q + b))
        q = max(q - f / slope, p)
    }
    return q
}
