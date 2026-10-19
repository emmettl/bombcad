import BlastModel
import Foundation
import Metal
import simd

extension LacroixGlulamTest {
    static func beam(
        device: MTLDevice, series: Series, rate: Float, history: [SIMD2<Float>], withDevice: Bool
    ) throws -> (ShellSolver, middle: [Int]) {
        // Walls get six elements through their depth; the beam a thirtieth of the span.
        let wall = series.width <= 0.5 * series.depth
        let h = wall ? series.depth / 6 : span / 30
        // Supports, third points and mid-span on nodes.
        let lengthwise = (span / (6 * h)).rounded() * 6 * h
        let overhang = (0.1325 / h).rounded() * h
        var model = StructureModel(
            solids: [
                Box(
                    min: SIMD3(-overhang, 0, 0),
                    max: SIMD3(lengthwise + overhang, series.width, series.depth))
            ], material: material(series, rate: rate), elementSize: h, fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        let positions = solver.mesh.positions
        let bottom = positions.map(\.z).min() ?? 0
        func on(_ x: Float, _ z: Float) -> [Int] {
            positions.indices.filter { abs(positions[$0].x - x) < h / 4 && abs(positions[$0].z - z) < h / 4 }
        }
        // Through the section: the device's and the supports' steel bearing plates spread the load
        // and the reactions, which on a point of a six-element-deep wall would crush the timber
        // across its grain (at 3 MPa) until the element collapsed. A line held vertically still
        // lets the end rotate.
        func line(_ x: Float) -> [Int] { positions.indices.filter { abs(positions[$0].x - x) < h / 4 } }
        let supports = line(0) + line(lengthwise)
        let lines = line(lengthwise / 3) + line(2 * lengthwise / 3)
        let middle = on(lengthwise / 2, bottom)
        let clear = series.density * series.width * series.depth * lengthwise
        let deviceMass = withDevice ? max(series.movingMass - clear, 0) : 0
        solver.mutateNodes { nodes in
            // Held sideways throughout, as the device and supports held the beams: in bending in
            // their plane, deep narrow members loaded on their top edge would otherwise buckle.
            for n in nodes.indices { nodes[n].restrain(y: true) }
            for n in supports {
                nodes[n].restrain(z: true)
                if positions[n].x < h { nodes[n].restrain(x: true) }
            }
            for n in lines { nodes[n].mass += deviceMass / Float(lines.count) }
            // A beam turns freely about its axis on its supports; mid-span, where symmetry holds
            // every rotation still anyway, holds it.
            if !wall { for n in middle { nodes[n].restrain(rotation: true) } }
        }
        var shares = [Float](repeating: 0, count: positions.count)
        for n in lines { shares[n] = 1 / Float(lines.count) }
        var load = PressureLoad(axis: 2, positiveSide: true, history: history)
        load.nodeShares = shares
        solver.appliedLoad = load
        return (solver, middle)
    }

    static func broken(_ solver: ShellSolver) -> Bool {
        guard let timber = solver.model.material.timber else { return false }
        let ft = timber.strengthFactor * timber.tensionAlong
        // The fibre index past the end of softening anywhere: on the walls' and the beams' bands.
        let wall = solver.mesh.beams.isEmpty
        let band = wall ? solver.model.elementSize : solver.mesh.beams.map(\.length).min() ?? 1
        let ratio = (timber.fibreEnergy / band) / (0.5 * ft * ft / timber.alongGrain)
        let buffer = wall ? solver.layerBuffer : solver.beamFibreBuffer
        let raw = buffer.contents()
        // Broken through: its index past the end of softening, or past one where it breaks at once.
        let end = max(ratio, 1)
        for n in 0..<(buffer.length / 40) where raw.load(fromByteOffset: n * 40, as: Float.self) > end {
            return true
        }
        return false
    }

    public static func run(
        device: MTLDevice, shot: Shot, rate: Float = 1.14, duration: Double = 0.06
    ) throws -> Result {
        guard let series = series.first(where: { $0.name == shot.series }) else {
            throw BlastError.allocationFailed("series \(shot.series)")
        }
        let fall = 2 * shot.impulse / shot.pressure
        let (solver, middle) = try beam(
            device: device, series: series, rate: rate,
            history: [SIMD2(0, shot.pressure * loadedArea), SIMD2(fall, 0), SIMD2(fall + 1, 0)],
            withDevice: true)
        var peak: Float = 0
        var when: Float = 0
        var atBreak: Float?
        let chunk = max(1, Int(0.0002 / Double(solver.criticalTimeStep)))
        while solver.time < duration {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            if w > peak { (peak, when) = (w, Float(solver.time)) }
            if atBreak == nil, broken(solver) { atBreak = w }
        }
        return Result(deflection: peak, time: when, atBreak: atBreak)
    }

    /// The static test: the load raised over `time` to `load` (N), lightly damped, without the
    /// dynamic increase; the load and deflection when it broke.
    public static func push(device: MTLDevice, series: Series, load: Float, time: Double = 3.0) throws
        -> Result
    {
        let (solver, middle) = try beam(
            device: device, series: series, rate: 1,
            history: [SIMD2(0, 0), SIMD2(Float(time), load), SIMD2(Float(time) + 1, load)], withDevice: false)
        solver.damping = 50
        var curve: [SIMD2<Float>] = []
        var atBreak: Float?
        let chunk = max(1, Int(0.005 / Double(solver.criticalTimeStep)))
        while solver.time < time {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            let applied = load * Float(solver.time / time)
            curve.append(SIMD2(applied, w))
            if atBreak == nil, broken(solver) { atBreak = applied }
            if w > 0.2 { break }
        }
        return Result(
            deflection: curve.last?.y ?? 0, time: Float(solver.time), atBreak: atBreak, curve: curve)
    }
}
