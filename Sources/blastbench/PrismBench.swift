import BlastCore
import Foundation
import Metal
import simd

// `blastbench prism`.
// Split from main.swift (emmettl/bombcad-work#51).

/// `blastbench prism [--rate 10] [--h 0.0094] [--confinement 0] ...`: Peterson's concrete as a free
/// prism, 3 elements square and 12 long, crushed along its length at a strain rate (1/s), its
/// sides free: the axial stress over the cylinder strength against the strain, and in the middle
/// element the stresses across it and its confinement gains. With nothing holding its sides there
/// is nothing to confine it: any lateral stress or gain there is the model's own.
func runPrism() throws {
    let rate = option("rate").flatMap { Float($0) } ?? 10
    let h = option("h").flatMap { Float($0) } ?? 0.15 / 16
    let fc: Float = 36e6
    let steel = SteelProperties(
        yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
    var material = StructureMaterial.concrete(
        name: "Peterson", compressiveStrength: fc, density: 2400, steel: steel)
    material.rateDependent = !flag("no-rate")
    applyRateOptions(&material)
    var model = StructureModel(
        solids: [Box(min: SIMD3(0, 0, 0.5), max: SIMD3(3 * h, 3 * h, 0.5 + 12 * h))], material: material,
        elementSize: h, fixedBase: false)
    applyRateOptions(&model)
    let solver = try StructureSolver(device: device, model: model)
    solver.gravity = 0
    solver.groundContact = false
    let length = 12 * h
    let speed = rate * length
    solver.mutateNodes { nodes in
        for j in 0...3 {
            for i in 0...3 {
                guard let bottom = solver.storedNode(i, j, 0), let top = solver.storedNode(i, j, 12) else {
                    continue
                }
                nodes[bottom].restrain(z: true)
                nodes[top].isPrescribed = true
                nodes[top].velocity = SIMD3(0, 0, -speed)
            }
        }
        if let corner = solver.storedNode(0, 0, 0) { nodes[corner].restrain(x: true, y: true, z: true) }
        if let other = solver.storedNode(3, 0, 0) { nodes[other].restrain(y: true, z: true) }
    }
    print(
        "Free prism of 36 MPa concrete, \(format(Double(h) * 1000, 1)) mm elements, crushed at \(format(Double(rate), 0))/s"
    )
    print("  strain %   axial/fc   middle: xx/fc   yy/fc   zz/fc   gains x/y/z     crushed %")
    let target: Float = option("to").flatMap { Float($0) } ?? 0.03
    let samples = 30
    let duration = Double(target / rate)
    let stepsPerSample = max(1, Int((duration / Double(samples) / Double(solver.criticalTimeStep)).rounded()))
    for _ in 0..<samples {
        solver.advance(steps: stepsPerSample)
        var force: Float = 0
        for j in 0...3 {
            for i in 0...3 { force += solver.nodalForce(i, j, 12).z }
        }
        let strain = Float(solver.time) * rate
        let s = solver.stress(1, 1, 6)
        let gain = solver.confinementGain(1, 1, 6)
        let crush = solver.crackPlanes(1, 1, 6).crush
        print(
            "  " + pad(format(Double(strain) * 100, 2), 11)
                + pad(format(Double(force / (9 * h * h * fc)), 2), 11)
                + pad(format(Double(s[0] / fc), 2), 8) + pad(format(Double(s[1] / fc), 2), 8)
                + pad(format(Double(s[2] / fc), 2), 8)
                + pad(
                    "\(format(Double(gain.x), 2))/\(format(Double(gain.y), 2))/\(format(Double(gain.z), 2))",
                    16)
                + format(Double(crush.max()) * 100, 2))
    }
}
