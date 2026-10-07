import Foundation
import Metal
import simd

/// The normal-strength slab of the 2013 Blast Blind Simulation Contest (UMKC with ACI
/// Committees 447 and 370), tested in the Blast Loading Simulator at the US Army Engineer
/// Research and Development Center.
///
/// Figures are taken from T. H. Kewaisy, A. A. Khalil and A. ElFouly, "Advanced Modeling of
/// Blast Response of Reinforced Concrete Walls with and without FRP Retrofit", ACI Spring
/// Convention 2018, which reproduces the contest's specimen drawing, material curves, pressure
/// record and measured displacement history.
public enum SlabBenchmark {
    static let inch: Float = 0.0254
    static let psi: Float = 6894.76

    /// Peak mid-span displacement measured in the test, in metres (about 4.25 in at 30 ms).
    public static let measuredPeak: Float = 4.25 * inch
    public static let measuredPeakTime: Float = 0.030
    /// Displacement at the end of the record, in metres (about 3.6 in at 70 ms).
    public static let measuredResidual: Float = 3.6 * inch

    /// The measured mid-span displacement history, read off the published plot: time in seconds
    /// against displacement in metres. The record ends at about 72 ms.
    public static let measuredHistory: [SIMD2<Float>] = {
        let points: [(Float, Float)] = [
            (0, 0), (2, 0.02), (5, 0.35), (7.5, 0.8), (10, 1.38), (12.5, 2.0), (15, 2.6), (17.5, 3.15),
            (20, 3.48), (22.5, 3.85), (25, 4.05), (27.5, 4.2), (30, 4.25), (32.5, 4.22), (35, 4.22),
            (37.5, 4.0), (40, 3.85), (43, 3.65), (45, 3.75), (50, 3.85), (55, 3.86), (60, 3.78),
            (62, 3.7), (65, 3.63), (70, 3.56), (72, 3.55),
        ]
        return points.map { SIMD2($0.0 * 1e-3, $0.1 * inch) }
    }()

    /// Measured displacement at `time`, interpolated from `measuredHistory`.
    public static func measuredDisplacement(at time: Float) -> Float {
        interpolate(measuredHistory, at: time)
    }

    /// Peak displacements that the source reports for other tools given the same slab and load,
    /// read off its comparison plot, in metres.
    public static let otherPredictions: [(tool: String, peak: Float)] = [
        ("Extreme Loading for Structures (applied element method)", 4.2 * inch),
        ("RCBlast (single degree of freedom)", 4.6 * inch),
        ("SBEDS (single degree of freedom, flexure)", 9.4 * inch),
    ]

    static func interpolate(_ curve: [SIMD2<Float>], at time: Float) -> Float {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if time <= first.x { return first.y }
        for (a, b) in zip(curve, curve.dropFirst()) where time <= b.x {
            return a.y + (b.y - a.y) * (time - a.x) / max(b.x - a.x, 1e-9)
        }
        return last.y
    }

    public static let statedPeakPressure: Float = 50 * psi
    public static let statedImpulse: Float = 1020 * psi * 1e-3

    /// The reflected pressure record "Set-1a", read off the published plot (ms, psi) and scaled
    /// to the stated impulse of 1,020 psi ms.
    public static var load: PressureLoad {
        let points: [(Float, Float)] = [
            (0, 0), (0.2, 31), (1.2, 29), (2.5, 36.5), (3.3, 35), (4.2, 34.5), (5.5, 41.5), (6.8, 49.8),
            (7.6, 44), (8.3, 40.5), (9.2, 39), (10, 34), (11, 30), (11.5, 28.5), (12.2, 29), (13, 24.5),
            (14, 22.5), (15.5, 20.5), (17, 18), (18.5, 15.8), (19.5, 15), (20.5, 17), (22, 16.5),
            (24, 15.8), (26, 16.2), (28, 15), (30, 13.5), (31.5, 11.2), (33.5, 13), (35, 11.5), (37, 10),
            (38.5, 8), (40.3, 11), (42, 9), (43.3, 6.5), (45, 8.5), (46.2, 7), (47.5, 8.3), (49.5, 6.5),
            (52, 6.2), (55, 4.5), (57, 3.8), (60, 3), (62, 2.3), (64, 2.5), (66, 1.3), (70, 1), (74, 0.8),
            (78, 0.5), (80, 0),
        ]
        var load = PressureLoad(
            axis: 2, positiveSide: true, history: points.map { SIMD2($0.0 * 1e-3, $0.1 * psi) })
        let scale = statedImpulse / load.impulse
        load.history = load.history.map { SIMD2($0.x, $0.y * scale) }
        return load
    }

    /// How closely the hand-read record matched the stated impulse before it was scaled.
    public static var digitisationScale: Float {
        let raw = load.impulse
        return raw / statedImpulse  // 1 after scaling; kept for symmetry with `load`
    }

    /// How strength is raised for the speed of the loading.
    public enum RateTreatment: String, CaseIterable, Sendable {
        /// Static strengths.
        case none
        /// The fixed design factors of UFC 3-340-02 for bending in the far range.
        case designFactors
        /// Strain-rate laws evaluated element by element.
        case strainRate
    }

    /// Concrete of 5,400 psi and the bars' published stress-strain curve: yield at 72 ksi, a
    /// short plateau, 118 ksi at 8% strain and rupture at about 15%.
    public static func material(rate: RateTreatment) -> StructureMaterial {
        var steel = SteelProperties(
            yieldStress: 72_000 * psi, ultimateStress: 118_000 * psi, ultimateStrain: 0.08,
            ruptureStrain: 0.155)
        // Read off the published engineering stress-strain curve (plastic strain, ksi).
        let curve: [(Float, Float)] = [
            (0, 72), (0.006, 74), (0.021, 94), (0.026, 107), (0.052, 115), (0.08, 118), (0.12, 112),
            (0.155, 98),
        ]
        steel.measuredCurve = curve.map { SIMD2($0.0, $0.1 * 1000 * psi) }
        var material = StructureMaterial.concrete(
            name: "Contest slab", compressiveStrength: 5400 * psi, steel: steel)
        switch rate {
        case .none: break
        case .designFactors:
            material.concreteRateFactor = 1.19
            material.steelRateFactor = 1.17
        case .strainRate:
            material.rateDependent = true
        }
        return material
    }

    /// The slab: 64 in long, 33.75 in wide and 4 in thick, with nine No. 3 bars along its length
    /// one inch from the unloaded face and No. 3 bars at 12 in across them.
    /// The specimen's width, 33.75 in.
    public static let fullWidth: Float = 33.75 * 0.0254

    /// `width` is the slab's width; a narrow strip of it, which bends the same way, makes fine
    /// meshes affordable.
    public static func model(
        elementsThroughThickness: Int, rate: RateTreatment, width: Float = fullWidth
    ) -> StructureModel {
        let h = 4 * inch / Float(elementsThroughThickness)
        // Lifted clear of the ground plane; the test slab stood vertically, so gravity is ignored.
        let base = (1 / h).rounded() * h
        let slab = Box(min: SIMD3(0, 0, base), max: SIMD3(64 * inch, width, base + 4 * inch))
        var model = StructureModel(
            solids: [slab], material: material(rate: rate), elementSize: h,
            fixedBase: false)
        let barArea: Float = 71e-6  // No. 3 bar, m²
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 9 * barArea / (33.75 * inch),
            transverseAreaPerMetre: barArea / (12 * inch), longitudinalAxis: 0, depth: 1 * inch,
            faces: (low: true, high: false))
        return model
    }

    public struct Result: Sendable {
        /// Mid-span displacement of the unloaded face, in metres, against time in seconds.
        public var history: [SIMD2<Float>]
        public var peak: Float
        public var peakTime: Float
        /// Mean displacement over the last 10 ms of the run.
        public var residual: Float
        public var summary: StructureSummary
        public var elementCount: Int
        public var wallSeconds: Double

        /// Predicted displacement at `time`, interpolated from `history`.
        public func displacement(at time: Float) -> Float {
            SlabBenchmark.interpolate(history, at: time)
        }

        /// Root-mean-square difference from the measured history over the measured record,
        /// sampled every millisecond, in metres.
        public var historyError: Float {
            let end = SlabBenchmark.measuredHistory.last?.x ?? 0
            let times = stride(from: Float(0.001), through: end, by: 0.001)
            let squares = times.map {
                pow(displacement(at: $0) - SlabBenchmark.measuredDisplacement(at: $0), 2)
            }
            return (squares.reduce(0, +) / Float(max(squares.count, 1))).squareRoot()
        }
    }

    /// How the supports are modelled.
    public enum Supports: Sendable {
        /// A pin and a roller, each a single line of nodes held against moving up or down.
        /// The reaction concentrates on that line, which on fine meshes tears the elements
        /// beside it.
        case lines
        /// Bearings of the given width, either holding the slab down as well as up or letting
        /// it lift off, in which case it rotates onto their inner edges.
        case bearings(width: Float, holdDown: Bool)
    }

    /// Runs the slab under the recorded pressure for 80 ms.
    public static func run(
        device: MTLDevice, elementsThroughThickness: Int = 8, rate: RateTreatment = .strainRate,
        loadScale: Float = 1, supports: Supports = .lines, width: Float = fullWidth,
        crackAxes: CrackAxes = .turningUntilOpen, adjust: (inout StructureMaterial) -> Void = { _ in }
    ) throws -> Result {
        var model = model(elementsThroughThickness: elementsThroughThickness, rate: rate, width: width)
        model.crackAxes = crackAxes
        adjust(&model.material)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        var load = load
        load.history = load.history.map { SIMD2($0.x, $0.y * loadScale) }
        solver.appliedLoad = load

        // Simple supports 52 in apart on the unloaded face. The source does not describe the rig,
        // so how they are modelled is an assumption; see `Supports`.
        let h = model.elementSize
        let first = Int((6 * inch / h).rounded())
        let second = Int((58 * inch / h).rounded())
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
        }
        let elapsed = ContinuousClock.now - start
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
        // Through the depth at mid-span: the lengthwise strain over the four elements either side
        // of the middle, from the nodes, and each layer's bar plastic strain and crushing there.
        func section(_ label: String) {
            guard let hinge else { return }
            let j = solver.ey / 2
            var rows: [String] = []
            for k in 0...solver.ez {
                let stretch =
                    (solver.displacement(middle + 4, j, k).x - solver.displacement(middle - 4, j, k).x)
                    / (8 * h)
                var line = String(format: "node row %2d: strain %7.2f%%", k, stretch * 100)
                if k < solver.ez {
                    let bars = (middle - 4..<middle + 4).map { solver.barPlasticStrain($0, j, k).x }.filter {
                        abs($0) < 1e8
                    }
                    let crush = (middle - 4..<middle + 4).map { solver.plasticStrain($0, j, k) }.max() ?? 0
                    let crack = (middle - 4..<middle + 4).map { solver.crackStrain($0, j, k) }.max() ?? 0
                    line += String(
                        format: "   layer: bar plastic %6.2f%%, crush %6.2f%%, crack %6.2f%%",
                        (bars.max() ?? 0) * 100, crush * 100, crack * 100)
                }
                rows.append(line)
            }
            hinge(label, rows)
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
