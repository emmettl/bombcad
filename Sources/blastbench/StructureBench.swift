import BlastCore
import Foundation
import Metal
import simd

// `blastbench structure`.
// Split from main.swift (emmettl/bombcad-work#51).

/// Times a structure meshed with shells (and beams) on its own.
func runShellStructure(_ base: StructureModel) throws {
    var model = base
    model.elementKind = .shell
    model.elementSize = option("shells").flatMap { Float($0) } ?? 0.25
    if let layers = option("shell-layers").flatMap({ Int($0) }) { model.shellLayers = layers }
    let solver = try ShellSolver(device: device, model: model)
    if flag("contact") { solver.contactMode = .always }
    solver.advance(steps: 200)
    let steps = 4000
    let start = ContinuousClock.now
    solver.advance(steps: steps)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let stepSeconds = Double(solver.criticalTimeStep)
    let count = solver.elementCount + solver.beamCount
    print(
        "Structure: \(solver.elementCount) shells and \(solver.beamCount) beams of "
            + "\(format(Double(model.elementSize) * 1000, 0)) mm, \(model.shellLayers) layers, "
            + "time step \(format(stepSeconds * 1e6, 1)) µs, \(format(Double(solver.memoryFootprint) / 1e6, 0)) MB"
    )
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(count) / seconds / 1e6, 1)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 1))x slower than real time")
}

/// Times the structural solver on its own, without the air.
func runStructure() throws {
    guard var model = preset(named: option("preset") ?? "box").scenario.structure else {
        print("That preset has no deformable structure; try --preset wall or --preset box.")
        return
    }
    if flag("elastic") {
        // The same mesh with a linear elastic material, to show what the concrete law costs.
        let concrete = model.material
        model.material = .elastic(
            density: concrete.density, youngsModulus: concrete.youngsModulus,
            poissonRatio: concrete.poissonRatio)
        model.reinforcement = []
    }
    if flag("shells") || option("shells") != nil {
        try runShellStructure(model)
        return
    }
    let solver = try StructureSolver(device: device, model: model)
    if flag("contact") { solver.contactMode = .always }
    solver.advance(steps: 200)
    let steps = 4000
    let start = ContinuousClock.now
    solver.advance(steps: steps)
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let stepSeconds = Double(solver.criticalTimeStep)
    print("Device: \(device.name)")
    print(
        "Structure: \(solver.elementCount) hexahedral elements of \(format(Double(model.elementSize) * 1000, 1)) mm, "
            + "\(model.material.name.lowercased()), time step \(format(stepSeconds * 1e6, 1)) µs, "
            + "contact \(solver.contactMode == .always ? "on" : "off until something fails"), "
            + "\(format(Double(solver.memoryFootprint) / 1e6, 0)) MB")
    print(
        "\(format(Double(steps) / seconds, 0)) steps/s, "
            + "\(format(Double(steps) * Double(solver.elementCount) / seconds / 1e6, 0)) M element-updates/s, "
            + "\(format(seconds / (Double(steps) * stepSeconds), 0))x slower than real time")
    printResultValues("structure", solids: solver)
}
