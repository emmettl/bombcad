import BlastModel
import Foundation
import Metal
import simd

extension ShearBeamBenchmark {
    /// Pushes the loading plate down at `rate` (m/s), slow against the beam's period, with light
    /// damping, until the centre has gone down by `deflection`. With a `slice` of the width, the
    /// load is scaled up to the whole beam's.
    public static func run(
        device: MTLDevice, elementsThroughDepth: Int = 12, slice: Float? = nil, deflection: Float = 0.016,
        rate: Float = 0.05, bondSlip: BondSlip? = nil,
        mapAt: Float? = nil,
        pressedInterlock: Bool = false,
        adjustModel: (inout StructureModel) -> Void = { _ in },
        adjust: (inout StructureMaterial) -> Void = { _ in },
        prepare: ((StructureSolver) -> Void)? = nil,
        sample: ((_ solver: StructureSolver, _ deflection: Float, _ load: Float) -> Void)? = nil
    ) throws -> Result {
        var model = model(elementsThroughDepth: elementsThroughDepth, slice: slice)
        let scale = width / (slice ?? width)
        model.bondSlip = bondSlip
        adjust(&model.material)
        model.pressedInterlock = pressedInterlock
        adjustModel(&model)
        let solver = try StructureSolver(device: device, model: model.loadedSlowly())
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100
        prepare?(solver)

        let h = model.elementSize
        let overhang = (length - span) / 2
        let reach = max(Int((plate / 2 / h).rounded()), 0)
        let supports = [overhang, length - overhang].map { Int(($0 / h).rounded()) }
        let middle = Int((length / 2 / h).rounded())
        // Bearings and the loading plate are lines of nodes across the beam, a plate's width
        // along it. The bearings hold the beam up, one of them lengthwise too; the loading plate
        // moves down and is free lengthwise, so no arch or tie forms through it.
        // The beam's width need not be a whole number of elements, so the lattice's last row of
        // nodes across it may be unused; only nodes that exist are held.
        solver.mutateNodes { nodes in
            func node(_ i: Int, _ j: Int, _ k: Int, _ body: (inout StructureNode) -> Void) {
                if let index = solver.storedNode(i, j, k) { body(&nodes[index]) }
            }
            for j in 0...solver.ey {
                for offset in -reach...reach {
                    node(supports[0] + offset, j, 0) { $0.restrain(z: true) }
                    node(supports[1] + offset, j, 0) { $0.restrain(z: true) }
                    node(middle + offset, j, solver.ez) {
                        $0.isPushedVertically = true
                        $0.velocity = SIMD3(0, 0, -rate)
                    }
                }
                node(supports[0], j, 0) { $0.restrain(x: true, y: j == 0) }
            }
        }

        let start = ContinuousClock.now
        var curve: [SIMD2<Float>] = [.zero]
        var map: [String] = []
        var mapLoad: Float = 0
        let stepsPerSample = max(1, Int(0.0001 / rate / solver.criticalTimeStep))
        while curve.last!.x < deflection, solver.time < Double(1.5 * deflection / rate) {
            solver.advance(steps: stepsPerSample)
            var reaction: Float = 0
            for j in 0...solver.ey {
                for support in supports {
                    for offset in -reach...reach where solver.storedNode(support + offset, j, 0) != nil {
                        reaction -= solver.nodalForce(support + offset, j, 0).z
                    }
                }
            }
            let centre = -solver.displacement(middle, solver.ey / 2, 0).z
            curve.append(SIMD2(centre, reaction * scale))
            sample?(solver, centre, reaction * scale)
            if let mapAt, map.isEmpty, centre >= mapAt {
                map = solver.crackMap(row: solver.ey / 2)
                mapLoad = reaction * scale
            }
            if !centre.isFinite { break }
        }
        let elapsed = ContinuousClock.now - start
        let top = curve.max { $0.y < $1.y } ?? .zero
        return Result(
            curve: curve, peak: top.y, peakDeflection: top.x, summary: solver.summary(),
            elementCount: solver.elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
            crackMap: map, mapLoad: mapLoad)
    }
}
