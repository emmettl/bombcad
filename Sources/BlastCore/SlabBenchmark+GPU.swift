import BlastModel
import Foundation
import Metal
import simd

extension SlabBenchmark {
    /// Runs the slab under the recorded pressure for 80 ms, its supports `span` apart about its
    /// middle.
    public static func run(
        device: MTLDevice, elementsThroughThickness: Int = 8, rate: RateTreatment = .strainRate,
        loadScale: Float = 1, supports: Supports = .lines, width: Float = fullWidth, span: Float = span,
        bondSlip: BondSlip? = nil,
        adjust: (inout StructureMaterial) -> Void = { _ in },
        adjustModel: (inout StructureModel) -> Void = { _ in },
        prepare: ((StructureSolver) -> Void)? = nil,
        sample: ((StructureSolver) -> Void)? = nil,
        inspect: ((StructureSolver) -> Void)? = nil
    ) throws -> Result {
        var model = model(elementsThroughThickness: elementsThroughThickness, rate: rate, width: width)
        model.bondSlip = bondSlip
        adjust(&model.material)
        adjustModel(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        var load = load
        load.history = load.history.map { SIMD2($0.x, $0.y * loadScale) }
        solver.appliedLoad = load
        prepare?(solver)

        // Simple supports `span` apart (52 in by default) on the unloaded face. The source does not
        // describe the rig, so how they are modelled is an assumption; see `Supports`.
        let h = model.elementSize
        let first = Int(((64 * inch - span) / 2 / h).rounded())
        let second = Int(((64 * inch + span) / 2 / h).rounded())
        solver.mutateNodes { nodes in
            // The slab's width need not be a whole number of elements, so the lattice's last
            // row of nodes may be unused; only nodes that exist are held.
            func node(_ i: Int, _ j: Int, _ body: (inout StructureNode) -> Void) {
                if let index = solver.storedNode(i, j, 0) { body(&nodes[index]) }
            }
            for j in 0...solver.ey {
                switch supports {
                case .lines:
                    node(first, j) { $0.restrain(x: true, z: true) }
                    node(second, j) { $0.restrain(z: true) }
                case .bearings(let width, let holdDown):
                    let reach = Int((width / 2 / h + 1e-3).rounded(.down))
                    for offset in -reach...reach {
                        for i in [first + offset, second + offset] {
                            if holdDown {
                                node(i, j) { $0.restrain(z: true) }
                            } else {
                                node(i, j) { $0.restsOnSupport = true }
                            }
                        }
                    }
                    node(first, j) { $0.restrain(x: true) }
                }
            }
        }

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.00025 / solver.criticalTimeStep))
        while solver.time < 0.08 {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z))
            sample?(solver)
        }
        let elapsed = ContinuousClock.now - start
        inspect?(solver)
        return result(history, summary: solver.summary(), elementCount: solver.elementCount, elapsed: elapsed)
    }

    /// The slab pushed down slowly at mid-span, across its width, to `deflection`, then drawn
    /// back until it no longer pushes and left to settle: how much of its deflection is elastic,
    /// with no dynamics. Returns the largest push (N), the deflection reached and that left (m).
    public static func pushAndRelease(
        device: MTLDevice, elementsThroughThickness: Int = 8, deflection: Float = 0.105, rate: Float = 0.1,
        strength: RateTreatment = .strainRate, width: Float = fullWidth,
        adjust: (inout StructureModel) -> Void = { _ in },
        trace: ((_ time: Double, _ deflection: Float, _ push: Float) -> Void)? = nil,
        shapes: ((_ peak: [Float], _ left: [Float]) -> Void)? = nil,
        hinge: ((_ label: String, _ rows: [String]) -> Void)? = nil
    ) throws -> (force: Float, reached: Float, residual: Float) {
        var model = model(elementsThroughThickness: elementsThroughThickness, rate: strength, width: width)
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100
        let h = model.elementSize
        let first = Int((6 * inch / h).rounded())
        let second = Int((58 * inch / h).rounded())
        let middle = solver.ex / 2
        // A 2 in plate: through one line of nodes the push would crush the elements under it.
        let plate = Int((inch / h).rounded())
        var pushed: [Int] = []
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                if let n = solver.storedNode(first, j, 0) { nodes[n].restrain(x: true, z: true) }
                if let n = solver.storedNode(second, j, 0) { nodes[n].restrain(z: true) }
                for i in (middle - plate)...(middle + plate) {
                    if let n = solver.storedNode(i, j, solver.ez) {
                        nodes[n].isPushedVertically = true
                        nodes[n].velocity = SIMD3(0, 0, -rate)
                        pushed.append(n)
                    }
                }
            }
        }
        let steps = max(1, Int(0.00025 / rate * 0.1 / solver.criticalTimeStep))
        func reaction() -> Float {
            var total: Float = 0
            for j in 0...solver.ey {
                for i in [first, second] where solver.storedNode(i, j, 0) != nil {
                    total -= solver.nodalForce(i, j, 0).z
                }
            }
            return total
        }
        var force: Float = 0
        var reached: Float = 0
        var nextTrace = 0.0
        func report() {
            guard let trace, solver.time >= nextTrace else { return }
            nextTrace += 0.05
            trace(solver.time, -solver.displacement(middle, solver.ey / 2, 0).z, reaction())
        }
        while reached < deflection, solver.time < Double(2 * deflection / rate) {
            solver.advance(steps: steps)
            reached = -solver.displacement(middle, solver.ey / 2, 0).z
            force = max(force, reaction())
            report()
        }
        // The deflected shape of the bottom face along the span, every eighth of the half span.
        func shape() -> [Float] {
            stride(from: first, through: middle, by: max(1, (middle - first) / 8)).map {
                -solver.displacement($0, solver.ey / 2, 0).z
            }
        }
        let atPeak = shape()
        func section(_ label: String) {
            guard let hinge else { return }
            for offset in [Float(0), 0.15] {
                hinge(
                    "\(label), \(Int((offset * 1000).rounded())) mm from mid-span",
                    sectionRows(solver, offset: offset))
            }
        }
        section("at peak")
        solver.mutateNodes { nodes in
            for n in pushed { nodes[n].velocity = SIMD3(0, 0, rate) }
        }
        let limit = solver.time + Double(deflection / rate)
        while solver.time < limit {
            solver.advance(steps: steps)
            report()
            if reaction() <= 0 { break }
        }
        solver.mutateNodes { nodes in
            for n in pushed {
                nodes[n].isPushedVertically = false
                nodes[n].velocity = .zero
            }
        }
        let settle = solver.time + 0.1
        while solver.time < settle {
            solver.advance(steps: steps)
            report()
        }
        shapes?(atPeak, shape())
        section("left")
        return (force, reached, -solver.displacement(middle, solver.ey / 2, 0).z)
    }

    /// Through the depth `offset` metres from mid-span, over four elements either side: the
    /// lengthwise strain at each row of nodes, and each layer's mean lengthwise stress, largest
    /// crack opening, largest crushing and bar plastic strain, top row first.
    public static func sectionRows(_ solver: StructureSolver, offset: Float) -> [String] {
        let h = solver.model.elementSize
        let j = solver.ey / 2
        let centre = solver.ex / 2 - Int((offset / h).rounded())
        let span = (centre - 4)..<(centre + 4)
        var rows: [String] = []
        for k in 0...solver.ez {
            let stretch =
                (solver.displacement(centre + 4, j, k).x - solver.displacement(centre - 4, j, k).x) / (8 * h)
            var line = String(format: "node row %2d: strain %7.3f%%", k, stretch * 100)
            if k < solver.ez {
                let stress = span.map { solver.stress($0, j, k)[0] }.reduce(0, +) / Float(span.count)
                let bars = span.map { solver.barPlasticStrain($0, j, k).x }.filter { abs($0) < 1e8 }
                let crack = span.map { solver.crackStrain($0, j, k) }.max() ?? 0
                let crush = span.map { solver.plasticStrain($0, j, k) }.max() ?? 0
                line += String(
                    format: "   layer: stress %7.2f MPa, crack %6.2f%%, crush %5.2f%%, bar plastic %5.2f%%",
                    stress / 1e6, crack * 100, crush * 100, (bars.max() ?? 0) * 100)
            }
            rows.append(line)
        }
        return rows.reversed()
    }

    private static func result(
        _ history: [SIMD2<Float>], summary: StructureSummary, elementCount: Int, elapsed: Duration
    ) -> Result {
        let peak = history.max { $0.y < $1.y } ?? .zero
        let tail = history.filter { $0.x >= 0.07 }
        return Result(
            history: history, peak: peak.y, peakTime: peak.x,
            residual: tail.reduce(0) { $0 + $1.y } / Float(max(tail.count, 1)),
            summary: summary, elementCount: elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Runs the slab meshed with shells of side `elementSize` (a whole fraction of an inch keeps
    /// the supports on nodes) and `layers` layers through the thickness, for 80 ms. The supports
    /// are lines of nodes on the midsurface, a pin and a roller.
    public static func runShells(
        device: MTLDevice, elementSize: Float = 0.0254, layers: Int = 8, rate: RateTreatment = .strainRate,
        loadScale: Float = 1, width: Float = fullWidth, adjust: (inout StructureMaterial) -> Void = { _ in }
    ) throws -> Result {
        var model = model(elementsThroughThickness: 4, rate: rate, width: width)
        adjust(&model.material)
        model.elementKind = .shell
        model.elementSize = elementSize
        model.shellLayers = layers
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        var load = load
        load.history = load.history.map { SIMD2($0.x, $0.y * loadScale) }
        solver.appliedLoad = load
        let pin = solver.nodes { abs($0.x - 6 * inch) < 1e-4 }
        let roller = solver.nodes { abs($0.x - 58 * inch) < 1e-4 }
        // The supports must fall on nodes: the element size has to divide 6 in.
        guard !pin.isEmpty, !roller.isEmpty else { throw BlastError.supportsMissNodes }
        solver.mutateNodes { nodes in
            for n in pin { nodes[n].restrain(x: true, z: true) }
            for n in roller { nodes[n].restrain(z: true) }
        }
        let middle = solver.nearestNode(to: SIMD3(32 * inch, width / 2, solver.referencePositions[0].z))

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.00025 / solver.criticalTimeStep))
        while solver.time < 0.08 {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.node(middle).displacement.z))
        }
        let elapsed = ContinuousClock.now - start
        return result(history, summary: solver.summary(), elementCount: solver.elementCount, elapsed: elapsed)
    }
}
