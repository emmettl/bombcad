import Foundation
import Metal
import simd

/// Reinforced concrete beams struck at mid-span by a falling weight: S. Saatci, "Behaviour and
/// modelling of reinforced concrete structures subjected to impact loads", PhD thesis,
/// University of Toronto, 2007 (published with F. J. Vecchio in the ACI Structural Journal,
/// 2009). Eight beams in four pairs, differing only in their stirrups, each struck first with a
/// 211 kg or a 600 kg weight falling 3.26 m (8.0 m/s); the first impact on each is used here,
/// on an undamaged beam.
public enum ImpactBenchmark {
    /// 250 mm wide, 410 mm deep and 4,880 mm long, on supports 3,000 mm apart that hold it
    /// down as well as up but let it rotate and slide. Two No. 30 bars in the bottom and two in
    /// the top, centred 53 mm in (38 mm cover); closed D-6 stirrups.
    public static let width: Float = 0.25
    public static let depth: Float = 0.41
    public static let length: Float = 4.88
    public static let span: Float = 3.0
    public static let barArea: Float = 2 * 700e-6
    public static let barDepth: Float = 0.053
    /// The 50 mm steel plate, 300 mm square, that the weight struck (here 250 mm across, the
    /// beam's width).
    public static let plate = SIMD2<Float>(0.3, 0.05)
    public static let impactSpeed: Float = 8.0
    public static let bearingLength: Float = 0.1

    public struct Test: Sendable {
        public var name: String
        /// Stirrup spacing in metres, or nil for none.
        public var stirrupSpacing: Float?
        public var weight: Float
        /// Concrete strength at the time of the tests (cylinders tested in December 2005).
        public var concreteStrength: Float
        /// Measured peak and residual mid-span displacements, in metres; nil where the beam failed.
        public var peak: Float?
        public var residual: Float?
        /// Largest reaction recorded at a support (N), Table 5.4.
        public var reaction: Float
        public var remark: String
    }

    /// The first impacts (Table 6.3 of the thesis), and SS0b-1, which failed.
    public static let tests: [Test] = [
        Test(
            name: "SS0a-1", stirrupSpacing: nil, weight: 211, concreteStrength: 50.1e6, peak: 0.0093,
            residual: 0.0016, reaction: 305e3,
            remark: "diagonal cracks up to 0.5 mm"),
        Test(
            name: "SS1a-1", stirrupSpacing: 0.3, weight: 211, concreteStrength: 44.7e6, peak: 0.0121,
            residual: 0.0009, reaction: 356e3,
            remark: ""),
        Test(
            name: "SS2a-1", stirrupSpacing: 0.2, weight: 211, concreteStrength: 47.0e6, peak: 0.0100,
            residual: 0.0005, reaction: 327e3,
            remark: ""),
        Test(
            name: "SS0b-1", stirrupSpacing: nil, weight: 600, concreteStrength: 50.1e6, peak: nil,
            residual: nil,
            reaction: 399e3,
            remark: "punched through: a shear plug, the bars exposed and bent"),
        Test(
            name: "SS1b-1", stirrupSpacing: 0.3, weight: 600, concreteStrength: 44.7e6, peak: 0.0395,
            residual: 0.0177, reaction: 625e3,
            remark: ""),
        Test(
            name: "SS2b-1", stirrupSpacing: 0.2, weight: 600, concreteStrength: 47.0e6, peak: 0.0379,
            residual: 0.0185, reaction: 592e3,
            remark: ""),
        Test(
            name: "SS3b-1", stirrupSpacing: 0.1, weight: 600, concreteStrength: 46.7e6, peak: 0.0353,
            residual: 0.0177, reaction: 682e3,
            remark: ""),
    ]

    /// Concrete of the measured strength, 3.2 MPa in tension (measured after the tests: 3.1 to
    /// 3.4 MPa) and 10 mm aggregate, strengthening with strain rate; No. 30 bars yielding at 464
    /// MPa, 630 MPa at ultimate, 195 GPa. The D-6 stirrups (605 MPa) are taken with the bars'
    /// curve.
    public static func material(_ test: Test) -> StructureMaterial {
        var steel = SteelProperties(
            yieldStress: 464e6, ultimateStress: 630e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        steel.youngsModulus = 195e9
        var material = StructureMaterial.concrete(
            name: "Saatci beam", compressiveStrength: test.concreteStrength, density: 2437, steel: steel)
        material.tensileStrength = 3.2e6
        material.aggregateSize = 0.010
        material.rateDependent = true
        return material
    }

    /// A beam struck at mid-span: its section, span, bars, stirrups, the steel plate the weight
    /// strikes and the bearings, all in metres.
    public struct Specimen: Sendable {
        public var width: Float
        public var depth: Float
        public var length: Float
        /// Between the supports' centres, which are central on the beam.
        public var span: Float
        /// Bars along the beam: total area (m²) and the height of their centre above the bottom.
        public var bars: [(area: Float, height: Float)]
        /// Closed stirrups: the area of their two legs together, and their spacing.
        public var stirrups: (legs: Float, spacing: Float)?
        /// The plate struck: its length along the beam and its thickness (it spans the width).
        public var plate: SIMD2<Float>
        public var bearingLength: Float
        public var material: StructureMaterial
        /// Both supports hold the beam lengthwise (pins), rather than one (a pin and a roller).
        public var pinnedEnds = false
        /// Steel plates of this thickness, `bearingLength` long, under and over the beam at each
        /// support, held along their centre lines only: clamps that turn with the beam. Nil
        /// holds the beam's own faces over the bearing length instead, which resists its ends'
        /// turning.
        public var supportPlates: Float?
    }

    public static func specimen(_ test: Test) -> Specimen {
        Specimen(
            width: width, depth: depth, length: length, span: span,
            bars: [(barArea, barDepth), (barArea, depth - barDepth)],
            stirrups: test.stirrupSpacing.map { (2 * 38.71e-6, $0) }, plate: plate,
            bearingLength: bearingLength,
            material: material(test))
    }

    /// The beam meshed with solid elements, `elementsThroughDepth` of them, with the steel plate on
    /// top at mid-span.
    public static func model(_ test: Test, elementsThroughDepth: Int) -> StructureModel {
        model(specimen(test), elementsThroughDepth: elementsThroughDepth)
    }

    public static func model(_ specimen: Specimen, elementsThroughDepth: Int) -> StructureModel {
        let s = specimen
        let h = s.depth / Float(elementsThroughDepth)
        let base = (1 / h).rounded() * h
        let beam = Box(min: SIMD3(0, 0, base), max: SIMD3(s.length, s.width, base + s.depth))
        let middle = s.length / 2
        let plateBox = Box(
            min: SIMD3(middle - s.plate.x / 2, 0, base + s.depth),
            max: SIMD3(middle + s.plate.x / 2, s.width, base + s.depth + s.plate.y))
        var solids = [beam, plateBox]
        if let thickness = s.supportPlates {
            let t = max((thickness / h).rounded(), 1) * h
            for support in [(s.length - s.span) / 2, (s.length + s.span) / 2] {
                let x = (support - s.bearingLength / 2)...(support + s.bearingLength / 2)
                solids.append(
                    Box(min: SIMD3(x.lowerBound, 0, base - t), max: SIMD3(x.upperBound, s.width, base)))
                solids.append(
                    Box(
                        min: SIMD3(x.lowerBound, 0, base + s.depth),
                        max: SIMD3(x.upperBound, s.width, base + s.depth + t)))
            }
        }
        var model = StructureModel(
            solids: solids, material: s.material, elementSize: h, fixedBase: false)
        for index in 1..<solids.count { model.setMaterial(.structuralSteel, of: index) }
        var bands: [ReinforcementLayer] = []
        for bar in s.bars {
            var band = beam
            band.min.z = base + bar.height - h / 2
            band.max.z = base + bar.height + h / 2
            bands.append(ReinforcementLayer(region: band, ratio: SIMD3(bar.area / (s.width * h), 0, 0)))
        }
        if let stirrups = s.stirrups {
            // Two legs each way, smeared through the section.
            bands.append(
                ReinforcementLayer(
                    region: beam,
                    ratio: SIMD3(
                        0, stirrups.legs / (s.depth * stirrups.spacing),
                        stirrups.legs / (s.width * stirrups.spacing))))
        }
        model.reinforcement = bands
        return model
    }

    public struct Result: Sendable {
        /// Mid-span displacement of the bottom face (m, downwards) against time (s).
        public var history: [SIMD2<Float>]
        public var peak: Float
        public var residual: Float
        /// Largest reaction at either support (N), averaged over 0.5 ms as the load cells, read
        /// 2,400 times a second, would see it.
        public var peakReaction: Float
        public var summary: StructureSummary
        public var elementCount: Int
        public var wallSeconds: Double
    }

    /// Strikes the beam: the weight's mass is added to the plate's top nodes, which start down
    /// with its momentum at 8.0 m/s shared with their own mass, and leaves them once they turn
    /// back up. Gravity is on. Runs for `duration`; the residual is the mean over its last 30 ms.
    public static func run(
        device: MTLDevice, test: Test, elementsThroughDepth: Int = 16, duration: Double = 0.2,
        adjust: (inout StructureModel) -> Void = { _ in }, inspect: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        try run(
            device: device, specimen: specimen(test), weight: test.weight, speed: impactSpeed,
            elementsThroughDepth: elementsThroughDepth, duration: duration, adjust: adjust, inspect: inspect)
    }

    /// Strikes `specimen` at mid-span with `weight` kilograms at `speed` metres per second, as
    /// `run(device:test:)` does. With `bounce`, the weight leaves the plate once the plate stops
    /// going down, as a real one does; without it, it stays on.
    public static func run(
        device: MTLDevice, specimen: Specimen, weight: Float, speed impact: Float,
        elementsThroughDepth: Int = 16,
        duration: Double = 0.2, bounce: Bool = true, adjust: (inout StructureModel) -> Void = { _ in },
        inspect: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        let length = specimen.length
        let depth = specimen.depth
        let span = specimen.span
        let plate = specimen.plate
        let bearingLength = specimen.bearingLength
        var model = model(specimen, elementsThroughDepth: elementsThroughDepth)
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        let h = model.elementSize
        let middle = Int((length / 2 / h).rounded())
        // With support plates the lattice starts at their undersides, this many rows below the beam.
        let plateRows = specimen.supportPlates.map { Int(max(($0 / h).rounded(), 1)) } ?? 0
        let beamBottom = plateRows
        let beamTop = plateRows + Int((depth / h).rounded())
        // The plate is as many elements thick as its 50 mm rounds to.
        let top = (0...solver.ez).last { solver.storedNode(middle, 0, $0) != nil } ?? solver.ez
        let reach = Int((plate.x / 2 / h).rounded())
        let supports = [(length - span) / 2, (length + span) / 2].map { Int(($0 / h).rounded()) }
        // Rollers below and hinges above, the hinges held down by bars, bear on the beam through
        // steel plates, taken as 100 mm long: through one line of nodes the reaction would crush
        // the concrete. The beam is pushed up from below and held down from above, so that it
        // never hangs from its bottom face.
        let bearing = max(Int((bearingLength / 2 / h).rounded()), 0)
        let bearingNodes = supports.map { (($0 - bearing)...($0 + bearing)) }
        var struck: [Int] = []
        for i in (middle - reach)...(middle + reach) {
            for j in 0...solver.ey {
                if let n = solver.storedNode(i, j, top) { struck.append(n) }
            }
        }
        solver.mutateNodes { nodes in
            // The weight's momentum, shared with the plate's top nodes it strikes.
            let carried = struck.reduce(Float(0)) { $0 + nodes[$1].mass }
            let speed = weight * impact / (weight + carried)
            for n in struck {
                nodes[n].mass += weight / Float(struck.count)
                nodes[n].velocity = SIMD3(0, 0, -speed)
            }
            if plateRows > 0 {
                // The plates are held along their centre lines, under the bottom plate and over
                // the top one, up and down; lengthwise at the bottom line, at one support or both.
                for (side, support) in supports.enumerated() {
                    for j in 0...solver.ey {
                        if let n = solver.storedNode(support, j, 0) {
                            nodes[n].restrain(x: side == 0 || specimen.pinnedEnds, y: j == 0, z: true)
                        }
                        if let n = solver.storedNode(support, j, beamTop + plateRows) {
                            nodes[n].restrain(z: true)
                        }
                    }
                }
                return
            }
            for range in bearingNodes {
                for i in range {
                    for j in 0...solver.ey {
                        if let n = solver.storedNode(i, j, 0) {
                            nodes[n].restsOnSupport = true
                            nodes[n].restrain(y: j == 0)
                        }
                        if let n = solver.storedNode(i, j, beamTop) { nodes[n].isHeldDown = true }
                    }
                }
            }
            if specimen.pinnedEnds {
                // Lengthwise at mid-depth along the whole clamp, so the thrust is not on one line.
                for range in bearingNodes {
                    for i in range {
                        for j in 0...solver.ey {
                            if let n = solver.storedNode(i, j, beamTop / 2) { nodes[n].restrain(x: true) }
                        }
                    }
                }
            } else if let n = solver.storedNode(supports[0], 0, 0) {
                nodes[n].restrain(x: true)
            }
        }
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        var reactions: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.0001 / solver.criticalTimeStep))
        var attached = true
        while solver.time < duration {
            solver.advance(steps: stepsPerSample)
            history.append(
                SIMD2(Float(solver.time), -solver.displacement(middle, solver.ey / 2, beamBottom).z))
            if attached && bounce {
                // The weight rides the plate down and leaves it once the plate turns back up:
                // its mass comes off, carrying away its share of the plate's (by then nearly
                // nil) momentum.
                solver.mutateNodes { nodes in
                    let rising = struck.reduce(Float(0)) { $0 + nodes[$1].velocity.z } / Float(struck.count)
                    if rising > 0 {
                        for n in struck { nodes[n].mass -= weight / Float(struck.count) }
                        attached = false
                    }
                }
            }
            var reaction = SIMD2<Float>.zero
            if plateRows > 0 {
                for (side, support) in supports.enumerated() {
                    for j in 0...solver.ey {
                        for k in [0, beamTop + plateRows] where solver.storedNode(support, j, k) != nil {
                            reaction[side] += solver.nodalForce(support, j, k).z
                        }
                    }
                }
            }
            for (side, range) in bearingNodes.enumerated() where plateRows == 0 {
                for i in range {
                    // Only the nodes sitting on their stops bear on the supports.
                    for j in 0...solver.ey {
                        if solver.storedNode(i, j, 0) != nil, solver.displacement(i, j, 0).z == 0 {
                            reaction[side] += solver.nodalForce(i, j, 0).z
                        }
                        if solver.storedNode(i, j, beamTop) != nil, solver.displacement(i, j, beamTop).z == 0
                        {
                            reaction[side] += solver.nodalForce(i, j, beamTop).z
                        }
                    }
                }
            }
            reactions.append(reaction)
        }
        let elapsed = ContinuousClock.now - start
        inspect(solver)
        let window = max(
            1, Int((0.0005 / (Double(stepsPerSample) * Double(solver.criticalTimeStep))).rounded()))
        var peakReaction: Float = 0
        if reactions.count >= window {
            for end in window...reactions.count {
                let mean = reactions[(end - window)..<end].reduce(.zero, +) / Float(window)
                peakReaction = max(peakReaction, abs(mean).max())
            }
        }
        let tail = history.filter { Double($0.x) >= duration - 0.03 }
        return Result(
            history: history, peak: history.map(\.y).max() ?? 0,
            residual: tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1)), peakReaction: peakReaction,
            summary: solver.summary(), elementCount: solver.elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    public struct BeamResult: Sendable {
        public var peak: Float
        public var residual: Float
        public var peakReaction: Float
        /// Beams whose section failed in shear, and beams removed.
        public var sheared: Int
        public var removed: Int
        public var wallSeconds: Double
    }

    /// The same beam meshed with beam elements of `size`, stirrups as their tie ratio, struck
    /// through the nodes under the plate; supported at the nodes over each bearing, on the
    /// beam's axis. With the sectional shear check (`sectionShear`), the sections beside the
    /// plate fail in the first half millisecond under every drop: see docs/validation.md.
    public static func runBeams(
        device: MTLDevice, test: Test, size: Float = 0.1, duration: Double = 0.2, sectionShear: Bool = true
    ) throws -> BeamResult {
        var model = model(test, elementsThroughDepth: 12)
        model.solids.removeLast()
        model.solidMaterial = []
        model.elementSize = size
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        if !sectionShear { solver.disableSectionShear() }
        let axis = solver.referencePositions[solver.nearestNode(to: SIMD3(length / 2, width / 2, 0))]
        func nodes(within half: Float, of x: Float) -> [Int] {
            let at = solver.referencePositions[solver.nearestNode(to: SIMD3(x, axis.y, axis.z))].x
            return solver.nodes { abs($0.x - at) <= half + 1e-4 && abs($0.z - axis.z) < 1e-4 }
        }
        let struck = nodes(within: plate.x / 2, of: length / 2)
        let supports = [(length - span) / 2, (length + span) / 2].map { nodes(within: 0, of: $0) }
        let middle = solver.nearestNode(to: SIMD3(length / 2, axis.y, axis.z))
        solver.mutateNodes { nodes in
            let carried = struck.reduce(Float(0)) { $0 + nodes[$1].mass }
            let speed = test.weight * impactSpeed / (test.weight + carried)
            for n in struck {
                nodes[n].mass += test.weight / Float(struck.count)
                nodes[n].velocity = SIMD3(0, 0, -speed)
            }
            for (side, support) in supports.enumerated() {
                for n in support { nodes[n].restrain(x: side == 0, y: true, z: true) }
            }
        }
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        var reactions: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.0001 / solver.criticalTimeStep))
        while solver.time < duration {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.node(middle).displacement.z))
            reactions.append(SIMD2(supports.map { $0.reduce(Float(0)) { $0 + solver.nodalForce($1).z } }))
        }
        let elapsed = ContinuousClock.now - start
        let window = max(
            1, Int((0.0005 / (Double(stepsPerSample) * Double(solver.criticalTimeStep))).rounded()))
        var peakReaction: Float = 0
        if reactions.count >= window {
            for end in window...reactions.count {
                peakReaction = max(
                    peakReaction, abs(reactions[(end - window)..<end].reduce(.zero, +) / Float(window)).max())
            }
        }
        let tail = history.filter { Double($0.x) >= duration - 0.03 }
        return BeamResult(
            peak: history.map(\.y).max() ?? 0,
            residual: tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1)),
            peakReaction: peakReaction,
            sheared: (0..<solver.beamCount).filter { solver.beamHasShearFailed($0) }.count,
            removed: (0..<solver.beamCount).filter { solver.beamFlag($0) != .active }.count,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Beams without stirrups struck once each, at increasing speeds, until they broke in shear:
    /// T. Ando, N. Kishi, H. Mikami and K. G. Matsuoka, "Weight falling impact tests on
    /// shear-failure type RC beams without stirrups", *Structures under Shock and Impact VI*, WIT
    /// Press, 2000 (open access). 150 × 250 mm beams, two bottom bars 40 mm up (D19 in series A,
    /// D13 in B), clamped top and bottom 200 mm in from each end, struck at mid-span by 300 kg.
    /// Assumed: the weight's face as a 100 mm steel plate, the clamps 50 mm long, 2,350 kg/m³ and
    /// 20 mm aggregate. 33 MPa concrete, 393 MPa bars.
    public struct ShearTest: Sendable {
        public var name: String
        /// Rebar series: true for A (2 D19, 1.82%), false for B (2 D13, 0.80%).
        public var heavyBars: Bool
        /// Shear span over effective depth (span = 2 a, d = 208 mm).
        public var shearSpanRatio: Float
        public var speed: Float
        /// What the paper reports: whether the beam broke apart in shear, and its peak and
        /// residual mid-span displacement where given (read off its plots, to about 2 mm).
        public var broken: Bool
        public var peak: Float?
        public var residual: Float?
        public var remark: String
    }

    /// The tests the paper's text and figures report: the 1.5 m beams' displacement histories,
    /// and the loops of load against displacement for the 1.0 m beams with D19 bars and the
    /// 2.0 m beams with D13, whose ends give the peak and where they come back to no load the
    /// residual.
    public static let shearTests: [ShearTest] = {
        func test(
            _ name: String, _ heavy: Bool, _ ratio: Float, _ speed: Float, _ peak: Float?, _ residual: Float?,
            broken: Bool = false, _ remark: String = ""
        ) -> ShearTest {
            ShearTest(
                name: name, heavyBars: heavy, shearSpanRatio: ratio, speed: speed, broken: broken,
                peak: peak.map { $0 / 1000 }, residual: residual.map { $0 / 1000 }, remark: remark)
        }
        return [
            test("A24-1", true, 2.4, 1, 2, 0),
            test("A24-3", true, 2.4, 3, 11, 8),
            test("A24-4", true, 2.4, 4, 16, 11),
            test("A24-5", true, 2.4, 5, 29, 25, broken: true, "broken by diagonal cracks"),
            test("A24-6", true, 2.4, 6, 54, 48, broken: true, "broken by diagonal cracks"),
            test("A36-1", true, 3.6, 1, 1.5, 0, "flexural cracks only"),
            test("A36-3", true, 3.6, 3, 13.5, 9.5, "a severe diagonal crack from the load to the support"),
            test("A36-4", true, 3.6, 4, 28, 24, "diagonal cracks"),
            test("A36-5", true, 3.6, 5, 66, 53, broken: true, "split into three by diagonal cracks"),
            test("A48-4", true, 4.8, 4, nil, 10.7, "bent, not failed"),
            test("B36-1", false, 3.6, 1, 2.7, 0, "flexural cracks only"),
            test("B36-3", false, 3.6, 3, 16, 11.4, "flexure cracks"),
            test("B36-4", false, 3.6, 4, 26, 22.6, "bent, flexure cracks only"),
            test("B36-5", false, 3.6, 5, 105, 88, broken: true, "broken by a wide diagonal crack"),
            test("B48-1", false, 4.8, 1, 4, 0, "flexure cracks"),
            test("B48-3", false, 4.8, 3, 21, 19, "bent"),
            test("B48-4", false, 4.8, 4, 36, 30, "bent"),
            test("B48-5", false, 4.8, 5, 55, 47, "bent far"),
            test("B48-6", false, 4.8, 6, 73, 70, "bent far"),
        ]
    }()

    /// The paper's measured materials (two casts, averaged): concrete of 33 MPa with a modulus
    /// of 23.3 GPa and Poisson's ratio 0.21; D19 bars yielding at 385 MPa and breaking at 577,
    /// D13 at 400 and 573, both 206 GPa.
    public static func specimen(_ test: ShearTest) -> Specimen {
        let span = 2 * test.shearSpanRatio * 0.208
        var steel = SteelProperties(
            yieldStress: test.heavyBars ? 385e6 : 400e6, ultimateStress: test.heavyBars ? 577e6 : 573e6,
            ultimateStrain: 0.1, ruptureStrain: 0.15)
        steel.youngsModulus = 206e9
        var material = StructureMaterial.concrete(
            name: "Ando beam", compressiveStrength: 33e6, density: 2350, steel: steel)
        material.youngsModulus = 23.3e9
        material.poissonRatio = 0.21
        material.aggregateSize = 0.02
        material.rateDependent = true
        // The paper describes the clamps as letting the beam turn and nothing else. Held as pins
        // at both ends, or on plates that turn freely, the beams went further than with the
        // clamps holding their faces over 50 mm, and further than the tests (docs/validation.md).
        return Specimen(
            width: 0.15, depth: 0.25, length: span + 0.4, span: span,
            bars: [(test.heavyBars ? 2 * 286.5e-6 : 2 * 126.7e-6, 0.04)], stirrups: nil,
            plate: SIMD2(0.1, 0.04), bearingLength: 0.05, material: material)
    }

    public static func run(
        device: MTLDevice, test: ShearTest, elementsThroughDepth: Int = 16, duration: Double = 0.15,
        adjust: (inout StructureModel) -> Void = { _ in }, inspect: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        try run(
            device: device, specimen: specimen(test), weight: 300, speed: test.speed,
            elementsThroughDepth: elementsThroughDepth, duration: duration, adjust: adjust, inspect: inspect)
    }
}
