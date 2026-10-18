import BlastCore
import Foundation
import Metal
import simd

/// `blastbench walloffset [--dx 0.25] [--offsets 0,0.1,...] [--time 0.012] [--mass 1] [--thickness 0.3]
/// [--element dx/2] [--cut] [--probe]`: a free wall 2 m high, 3 m wide and 0.3 m thick, its face about 3 m from a surface burst, placed at a
/// fraction of a cell off the lattice: the momentum the air has given it by the end and its
/// largest force, which a wall's outline drawn in whole cells makes depend on the offset.
func runWallOffset(device: MTLDevice) throws {
    let dx = option("dx").flatMap { Float($0) } ?? 0.25
    let mass = option("mass").flatMap { Float($0) } ?? 1
    let duration = option("time").flatMap { Double($0) } ?? 0.012
    let thickness = option("thickness").flatMap { Float($0) } ?? 0.3
    // The wall's elements lie on a lattice of their size, and its faces with them: at dx / 2 a
    // face moves in half cells whatever the offset asked. 0.025 m puts it at every tenth of 0.25.
    let element = option("element").flatMap { Float($0) } ?? dx / 2
    let offsets = (option("offsets") ?? "0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1")
        .split(separator: ",").compactMap { Float($0) }
    print(
        "A free wall 3 m from \(format(Double(mass), 1)) kg on \(format(Double(dx), 3)) m cells, to \(format(duration * 1000, 1)) ms"
    )
    print("  offset (cells)  face x m   front N s (3 ms)  per 1/R   peak force kN")
    for offset in offsets {
        let face = 5 + offset * dx
        let wall = Box(min: SIMD3(face, 1.5, 0), max: SIMD3(face + thickness, 4.5, 2))
        var model = StructureModel(
            solids: [wall], material: .elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2),
            elementSize: element, fixedBase: false)
        model.elementKind = .solid
        let scenario = Scenario(
            name: "Wall offset", domainSize: SIMD3(10, 6, 4), boxes: [],
            charge: Charge(mass: mass, position: SIMD3(2, 3, 0)), structure: model)
        var configuration = SolverConfiguration.recommended
        configureRefinement(&configuration)
        applyChosenMask(&configuration)
        configuration.settlesStructures = false
        // `--cut`: the wall's outline as cut cells.
        configuration.structureCutCells = flag("cut")
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: dx, configuration: configuration)
        guard let structure = solver.structure else { continue }
        structure.gravity = 0
        structure.groundContact = false
        var history: [(time: Double, momentum: Double)] = [(0, 0)]
        let started = Date()
        var airSteps = 0
        while solver.time < duration {
            let result = solver.advance(steps: 1, timeLimit: duration)
            history.append((solver.time, structure.momentum().x))
            if flag("probe"), history.count % 3 == 0, solver.time > 0.0025, solver.time < 0.0045 {
                let row = (18...22).map { i -> String in
                    (solver.isSolid(i, 12, 4) ? "#" : " ")
                        + String(format: "%7.1f", (solver.primitive(i, 12, 4).pressure - 101325) / 1000)
                }
                print(
                    String(format: "    %.3f ms %8.2f N s ", solver.time * 1000, structure.momentum().x)
                        + row.joined(separator: " "))
            }
            airSteps += result.steps
            if result.steps == 0 { break }
        }
        var peak = 0.0
        for (a, b) in zip(history, history.dropFirst()) where b.time > a.time {
            peak = max(peak, (b.momentum - a.momentum) / (b.time - a.time))
        }
        // The front's load alone: the impulse over `window` from when the momentum, interpolated
        // between steps, first passes a hundredth of what it ends with, before the wave has come
        // round to the back. (From the first step past a share of the peak force, the window's
        // start moved in whole steps and the impulse with it.)
        let window = option("window").flatMap { Double($0) } ?? 0.003
        func momentum(at t: Double) -> Double {
            guard let i = history.firstIndex(where: { $0.time >= t }), i > 0 else {
                return history.last!.momentum
            }
            let (a, b) = (history[i - 1], history[i])
            return a.momentum + (b.momentum - a.momentum) * (t - a.time) / max(b.time - a.time, 1e-12)
        }
        var arrival = 0.0
        let onset = 0.01 * (history.last?.momentum ?? 0)
        for (a, b) in zip(history, history.dropFirst()) where b.momentum > onset && a.momentum <= onset {
            arrival = a.time + (b.time - a.time) * (onset - a.momentum) / max(b.momentum - a.momentum, 1e-12)
            break
        }
        let front = momentum(at: arrival + window) - momentum(at: arrival)
        print(
            String(
                format:
                    "  %6.2f          %6.3f     %9.2f      %9.2f    %9.2f   arrival %.2f ms  %d steps %.1f s",
                offset,
                face, front, front * Double(face - 2) / 3, peak / 1000, arrival * 1000, airSteps,
                -started.timeIntervalSinceNow))
        fflush(stdout)
    }
}
