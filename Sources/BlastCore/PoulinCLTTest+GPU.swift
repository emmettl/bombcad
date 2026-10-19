import BlastModel
import Foundation
import Metal
import simd

extension PoulinCLTTest {
    /// The panel on its supports, with the device's mass on its load lines (unless `withDevice`
    /// is false, as for the static tests' jack) and its force, of `history` (total newtons against
    /// time), shared between strips under them.
    static func panel(
        device: MTLDevice, plies: Int, elementSize: Float, rate: Float, history: [SIMD2<Float>],
        rollingScale: Float = 1, withDevice: Bool = true
    ) throws -> (ShellSolver, middle: [Int]) {
        let h = elementSize
        let thickness = 0.035 * Float(plies)
        let overhang = 2 * h
        let lengthwise = (span / h).rounded() * h
        let across = (width / h).rounded() * h
        var model = StructureModel(
            solids: [Box(min: SIMD3(-overhang, 0, 0), max: SIMD3(lengthwise + overhang, across, thickness))],
            material: material(plies: plies, rate: rate, rollingScale: rollingScale), elementSize: h,
            fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        let supports = solver.nodes { abs($0.x) < h / 4 || abs($0.x - lengthwise) < h / 4 }
        let lines: [Float] = [lengthwise / 3, 2 * lengthwise / 3]
        let loaded = solver.nodes { p in lines.contains { abs(p.x - $0) < h / 4 } }
        let middle = solver.nodes { abs($0.x - lengthwise / 2) < h / 4 }
        // The panel's clear span and the device take the moving mass.
        let clear = 450 * thickness * across * lengthwise
        let device = withDevice ? max(movingMass(plies: plies) - clear, 0) : 0
        solver.mutateNodes { nodes in
            for n in supports {
                nodes[n].restrain(z: true)
                if solver.position(n).x < h { nodes[n].restrain(x: true) }
            }
            for n in loaded { nodes[n].mass += device / Float(loaded.count) }
        }
        // Strips one element wide, centred on the load lines, take the force.
        var shares: [Float] = []
        for element in solver.mesh.elements {
            let x = (0..<4).map { solver.mesh.positions[Int(element.nodes[$0])].x }
            let (low, high) = (x.min()!, x.max()!)
            let overlap = lines.map { max(0, min(high, $0 + h / 2) - max(low, $0 - h / 2)) }.reduce(0, +)
            shares.append(overlap / h)
        }
        let strip = Float(lines.count) * h * across
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true, history: history.map { SIMD2($0.x, $0.y / strip) })
        solver.appliedLoad?.elementShares = shares
        return (solver, middle)
    }

    /// The largest damage in each mode, from the timber layers' states: fibre and rolling shear
    /// from their largest indices, as the kernel's `timberDamage`, splitting as stored.
    static func damage(_ solver: ShellSolver, plies: Int, rate: Float) -> (
        fibre: Float, splitting: Float, rolling: Float
    ) {
        guard let timber = solver.model.material.timber else { return (0, 0, 0) }
        func damage(_ r: Float, _ ratio: Float) -> Float {
            r <= 1 ? 0 : ratio <= 1 ? 1 : min(1, ratio / (ratio - 1) * (1 - 1 / r))
        }
        let h = solver.model.elementSize
        let ft = rate * timber.tensionAlong
        let fr = rate * timber.rollingStrength
        let fibreRatio = (timber.fibreEnergy / h) / (0.5 * ft * ft / timber.alongGrain)
        let rollingRatio = (timber.rollingEnergy / 0.035) / (0.5 * fr * fr / timber.rollingShearModulus)
        let count = solver.layerBuffer.length / 40
        let raw = solver.layerBuffer.contents()
        var fibre: Float = 0
        var splitting: Float = 0
        var rolling: Float = 0
        for n in 0..<count {
            // Stored: crack (the fibre and splitting indices), crush, the rate and its factor as
            // halves, residual (the rolling index and the splitting damage).
            let base = raw + n * 40
            fibre = max(fibre, damage(base.load(as: Float.self), fibreRatio))
            rolling = max(rolling, damage(base.load(fromByteOffset: 20, as: Float.self), rollingRatio))
            splitting = max(splitting, base.load(fromByteOffset: 24, as: Float.self))
        }
        return (fibre, splitting, rolling)
    }

    /// The mode that has broken through a layer, if any: rolling shear first, then fibre, then
    /// splitting, where several have.
    static func firstBroken(_ solver: ShellSolver, plies: Int, rate: Float) -> String? {
        let modes = damage(solver, plies: plies, rate: rate)
        if modes.rolling >= 1 { return "rolling shear" }
        if modes.fibre >= 1 { return "flexure (fibre)" }
        if modes.splitting >= 1 { return "splitting" }
        return nil
    }

    /// One shot: the triangle of its peak and impulse, run for `duration`.
    public static func run(
        device: MTLDevice, shot: Shot, elementSize: Float = 0.0745, rate: Float = 1.28,
        duration: Double = 0.08
    ) throws -> Result {
        let fall = 2 * shot.impulse / shot.pressure
        let force = shot.pressure * loadedArea
        let (solver, middle) = try panel(
            device: device, plies: shot.plies, elementSize: elementSize, rate: rate,
            history: [SIMD2(0, force), SIMD2(fall, 0), SIMD2(fall + 1, 0)])
        var peak: Float = 0
        var when: Float = 0
        var first: (String, Float)?
        let chunk = max(1, Int(0.0002 / Double(solver.criticalTimeStep)))
        while solver.time < duration {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            if w > peak { (peak, when) = (w, Float(solver.time)) }
            if first == nil, let mode = firstBroken(solver, plies: shot.plies, rate: rate) {
                first = (mode, Float(solver.time))
            }
        }
        let modes = damage(solver, plies: shot.plies, rate: rate)
        return Result(
            deflection: peak, time: when, fibre: modes.fibre, splitting: modes.splitting,
            rolling: modes.rolling,
            removed: solver.summary().erodedElements, firstMode: first?.0, firstAt: first?.1 ?? 0)
    }

    /// The static test: the load raised steadily over `time` to `load` (N) by the jack alone,
    /// lightly damped, without the dynamic increase; the curve of load against mid-span deflection.
    public static func push(
        device: MTLDevice, plies: Int, load: Float, elementSize: Float = 0.0745, time: Double = 3.0,
        rollingScale: Float = 1
    ) throws -> Result {
        let (solver, middle) = try panel(
            device: device, plies: plies, elementSize: elementSize, rate: 1,
            history: [SIMD2(0, 0), SIMD2(Float(time), load), SIMD2(Float(time) + 1, load)],
            rollingScale: rollingScale, withDevice: false)
        solver.damping = 50
        var curve: [SIMD2<Float>] = []
        var first: (String, Float)?
        let chunk = max(1, Int(0.005 / Double(solver.criticalTimeStep)))
        while solver.time < time {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            let applied = load * Float(solver.time / time)
            curve.append(SIMD2(applied, w))
            if first == nil, let mode = firstBroken(solver, plies: plies, rate: 1) { first = (mode, applied) }
            if w > 0.3 { break }
        }
        let modes = damage(solver, plies: plies, rate: 1)
        return Result(
            deflection: curve.last?.y ?? 0, time: Float(solver.time), fibre: modes.fibre,
            splitting: modes.splitting,
            rolling: modes.rolling, removed: solver.summary().erodedElements, firstMode: first?.0,
            firstAt: first?.1 ?? 0, curve: curve)
    }
}
